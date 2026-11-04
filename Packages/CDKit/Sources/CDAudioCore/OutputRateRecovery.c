#include "CDAudioCore.h"
#include <math.h>
#include <stdio.h>
#include <string.h>

static int rate_failure(CDError *error, CDResult code, OSStatus status, const char *message)
{
    if (error) {
        error->code = code;
        error->systemStatus = status;
        snprintf(error->message, sizeof(error->message), "%s", message);
    }
    return code;
}

static bool has_recovery_operations(const CDRateRecoveryOperations *operations)
{
    return operations && operations->readRate && operations->setRate && operations->waitForRate &&
        operations->rememberRate && operations->forgetRate;
}

bool cd_audio_stream_formats_equal(const AudioStreamBasicDescription *left,
                                   const AudioStreamBasicDescription *right)
{
    if (!left || !right) return false;
    return left->mSampleRate == right->mSampleRate && left->mFormatID == right->mFormatID &&
        left->mFormatFlags == right->mFormatFlags && left->mBytesPerPacket == right->mBytesPerPacket &&
        left->mFramesPerPacket == right->mFramesPerPacket && left->mBytesPerFrame == right->mBytesPerFrame &&
        left->mChannelsPerFrame == right->mChannelsPerFrame && left->mBitsPerChannel == right->mBitsPerChannel &&
        left->mReserved == right->mReserved;
}

int cd_rate_remember_stream_formats(const char *uid, double originalRate, double appliedRate,
                                    const AudioStreamBasicDescription *originalVirtualFormat,
                                    const AudioStreamBasicDescription *appliedVirtualFormat,
                                    const AudioStreamBasicDescription *originalPhysicalFormat,
                                    const AudioStreamBasicDescription *appliedPhysicalFormat,
                                    const CDRateRecoveryOperations *operations, CDError *error)
{
    if (!uid || uid[0] == '\0' || !originalVirtualFormat || !appliedVirtualFormat ||
        !originalPhysicalFormat || !appliedPhysicalFormat || !operations || !operations->rememberFormats)
        return rate_failure(error, CD_INVALID_ARGUMENT, 0, "Invalid stream-format recovery operation");
    return operations->rememberFormats(
        operations->context, uid, originalRate, appliedRate, originalVirtualFormat, appliedVirtualFormat,
        originalPhysicalFormat, appliedPhysicalFormat, error
    );
}

/* Writing a virtual format lets the HAL re-pick its preferred physical format at that rate; a USB DAC's
   48 kHz 16-bit physical format became 32-bit even though the virtual format was already in place. The
   virtual format is therefore written only when the physical write did not already bring it there, and
   a physical format the virtual write replaced is written back. */
static int write_virtual_format_keeping_physical(AudioStreamID stream,
                                                 const AudioStreamBasicDescription *virtualFormat,
                                                 const char *setFailureMessage,
                                                 const CDRateRecoveryOperations *operations, CDError *error)
{
    AudioStreamBasicDescription current = {0}, physical = {0};
    OSStatus status = operations->readStreamFormat(operations->context, stream, false, &current);
    if (status != noErr)
        return rate_failure(error, CD_CORE_AUDIO_ERROR, status, "Cannot inspect the virtual stream format");
    if (cd_audio_stream_formats_equal(&current, virtualFormat)) return CD_OK;
    status = operations->readStreamFormat(operations->context, stream, true, &physical);
    if (status != noErr)
        return rate_failure(error, CD_CORE_AUDIO_ERROR, status, "Cannot inspect the physical stream format");

    status = operations->setStreamFormat(operations->context, stream, false, virtualFormat);
    if (status != noErr) return rate_failure(error, CD_CORE_AUDIO_ERROR, status, setFailureMessage);
    int result = operations->waitForStreamFormat(operations->context, stream, false, virtualFormat, error);
    if (result != CD_OK) return result;

    status = operations->readStreamFormat(operations->context, stream, true, &current);
    if (status != noErr)
        return rate_failure(error, CD_CORE_AUDIO_ERROR, status, "Cannot inspect the physical stream format");
    if (cd_audio_stream_formats_equal(&current, &physical)) return CD_OK;
    status = operations->setStreamFormat(operations->context, stream, true, &physical);
    if (status != noErr)
        return rate_failure(error, CD_CORE_AUDIO_ERROR, status,
                            "Cannot keep the physical stream format after a virtual format change");
    result = operations->waitForStreamFormat(operations->context, stream, true, &physical, error);
    if (result != CD_OK) return result;
    return operations->waitForStreamFormat(operations->context, stream, false, virtualFormat, error);
}

int cd_rate_apply_stream_formats(AudioStreamID stream, const char *uid, double originalRate, double appliedRate,
                                 const AudioStreamBasicDescription *originalVirtualFormat,
                                 const AudioStreamBasicDescription *appliedVirtualFormat,
                                 const AudioStreamBasicDescription *originalPhysicalFormat,
                                 const AudioStreamBasicDescription *appliedPhysicalFormat,
                                 const CDRateRecoveryOperations *operations, CDError *error)
{
    if (!operations || !operations->readStreamFormat || !operations->setStreamFormat ||
        !operations->waitForStreamFormat || !operations->clearFormats)
        return rate_failure(error, CD_INVALID_ARGUMENT, 0, "Stream-format apply operations are unavailable");
    int result = cd_rate_remember_stream_formats(uid, originalRate, appliedRate, originalVirtualFormat,
                                                appliedVirtualFormat, originalPhysicalFormat,
                                                appliedPhysicalFormat, operations, error);
    if (result != CD_OK) return result;

    OSStatus status = operations->setStreamFormat(operations->context, stream, true, appliedPhysicalFormat);
    if (status != noErr)
        return rate_failure(error, CD_CORE_AUDIO_ERROR, status,
                            "Cannot set the selected physical stream format");

    result = operations->waitForStreamFormat(operations->context, stream, true, appliedPhysicalFormat, error);
    if (result != CD_OK) return result;
    return write_virtual_format_keeping_physical(stream, appliedVirtualFormat,
                                                 "Cannot set the selected virtual stream format", operations, error);
}

int cd_rate_apply(AudioDeviceID device, const char *uid, double originalRate, double appliedRate,
                  const CDRateRecoveryOperations *operations, bool *recorded, CDError *error)
{
    if (!uid || uid[0] == '\0' || !recorded || !has_recovery_operations(operations))
        return rate_failure(error, CD_INVALID_ARGUMENT, 0, "Invalid sample-rate recovery operation");

    *recorded = false;
    if (originalRate == appliedRate) return CD_OK;

    int result = operations->rememberRate(operations->context, uid, originalRate, appliedRate, error);
    if (result != CD_OK) return result;
    *recorded = true;

    OSStatus status = operations->setRate(operations->context, device, appliedRate);
    if (status != noErr) {
        char message[64];
        double kilohertz = appliedRate / 1000.0;
        snprintf(message, sizeof(message),
                 kilohertz == round(kilohertz) ? "Cannot set native %.0f kHz" : "Cannot set native %.1f kHz", kilohertz);
        int setFailure = rate_failure(error, CD_CORE_AUDIO_ERROR, status, message);
        CDError cleanupError = {0};
        if (operations->forgetRate(operations->context, uid, &cleanupError) == CD_OK) {
            *recorded = false;
        } else if (error) {
            size_t used = strlen(error->message);
            snprintf(error->message + used, sizeof(error->message) - used,
                     " Recovery-record cleanup failed: %.160s", cleanupError.message);
        }
        return setFailure;
    }

    return operations->waitForRate(operations->context, device, appliedRate, error);
}

static int restore_recorded_stream_formats(AudioDeviceID device, const CDRateRecord *record,
                                           const CDRateRecoveryOperations *operations, CDError *error)
{
    if (!record->hasFormatChange) return CD_OK;
    if (!operations->resolveSingleStream || !operations->readStreamFormat ||
        !operations->setStreamFormat || !operations->waitForStreamFormat || !operations->clearFormats)
        return rate_failure(error, CD_INVALID_ARGUMENT, 0, "Stream-format recovery operations are unavailable");
    AudioStreamID stream = kAudioObjectUnknown;
    OSStatus status = operations->resolveSingleStream(operations->context, device, &stream);
    if (status != noErr)
        return rate_failure(error, CD_CORE_AUDIO_ERROR, status,
                            "Cannot identify the output stream during format recovery");
    AudioStreamBasicDescription currentVirtual = {0}, currentPhysical = {0};
    status = operations->readStreamFormat(operations->context, stream, false, &currentVirtual);
    if (status != noErr)
        return rate_failure(error, CD_CORE_AUDIO_ERROR, status,
                            "Cannot inspect the virtual stream format during recovery");
    status = operations->readStreamFormat(operations->context, stream, true, &currentPhysical);
    if (status != noErr)
        return rate_failure(error, CD_CORE_AUDIO_ERROR, status,
                            "Cannot inspect the physical stream format during recovery");

    bool virtualOriginal = cd_audio_stream_formats_equal(&currentVirtual, &record->originalVirtualFormat);
    bool virtualApplied = cd_audio_stream_formats_equal(&currentVirtual, &record->appliedVirtualFormat);
    bool physicalOriginal = cd_audio_stream_formats_equal(&currentPhysical, &record->originalPhysicalFormat);
    bool physicalApplied = cd_audio_stream_formats_equal(&currentPhysical, &record->appliedPhysicalFormat);
    if ((physicalOriginal || physicalApplied) && !physicalOriginal) {
        status = operations->setStreamFormat(operations->context, stream, true, &record->originalPhysicalFormat);
        if (status != noErr)
            return rate_failure(error, CD_CORE_AUDIO_ERROR, status,
                                "Cannot restore the original physical stream format");
        int result = operations->waitForStreamFormat(
            operations->context, stream, true, &record->originalPhysicalFormat, error);
        if (result != CD_OK) return result;
    }
    if ((virtualOriginal || virtualApplied) && !virtualOriginal) {
        int result = write_virtual_format_keeping_physical(
            stream, &record->originalVirtualFormat, "Cannot restore the original virtual stream format",
            operations, error);
        if (result != CD_OK) return result;
    }
    return operations->clearFormats(operations->context, record->uid, error);
}

int cd_rate_restore_stream_formats(AudioDeviceID device, int32_t owner, const CDRateRecord *record,
                                   const CDRateRecoveryOperations *operations, CDError *error)
{
    if (!record || !has_recovery_operations(operations) || !operations->ownedByAnotherProcess)
        return rate_failure(error, CD_INVALID_ARGUMENT, 0, "Invalid stream-format recovery record");
    double currentRate = 0;
    OSStatus status = operations->readRate(operations->context, device, &currentRate);
    if (status != noErr)
        return rate_failure(error, CD_CORE_AUDIO_ERROR, status, "Cannot inspect the sample rate during cleanup");
    if (currentRate != record->appliedRate)
        return operations->forgetRate(operations->context, record->uid, error);
    if (operations->ownedByAnotherProcess(operations->context, owner))
        return rate_failure(error, CD_CORE_AUDIO_ERROR, 0,
                            "The original stream format cannot be restored while another app has exclusive use of the output");
    int result = restore_recorded_stream_formats(device, record, operations, error);
    if (result != CD_OK) return result;
    status = operations->readRate(operations->context, device, &currentRate);
    if (status != noErr)
        return rate_failure(error, CD_CORE_AUDIO_ERROR, status,
                            "Cannot inspect the sample rate after format recovery");
    if (currentRate != record->appliedRate)
        return operations->forgetRate(operations->context, record->uid, error);
    return CD_OK;
}

int cd_rate_restore_device(AudioDeviceID device, int32_t owner, const CDRateRecord *record,
                           const CDRateRecoveryOperations *operations, CDError *error)
{
    if (!record || !has_recovery_operations(operations) || !operations->ownedByAnotherProcess)
        return rate_failure(error, CD_INVALID_ARGUMENT, 0, "Invalid sample-rate recovery record");

    double currentRate = 0;
    OSStatus status = operations->readRate(operations->context, device, &currentRate);
    if (status != noErr)
        return rate_failure(error, CD_CORE_AUDIO_ERROR, status, "Cannot inspect the sample rate during cleanup");
    if (currentRate != record->appliedRate)
        return operations->forgetRate(operations->context, record->uid, error);
    if (operations->ownedByAnotherProcess(operations->context, owner))
        return rate_failure(error, CD_CORE_AUDIO_ERROR, 0,
                            "The original sample rate cannot be restored while another app has exclusive use of the output");
    int result = restore_recorded_stream_formats(device, record, operations, error);
    if (result != CD_OK) return result;
    if (record->hasFormatChange) {
        status = operations->readRate(operations->context, device, &currentRate);
        if (status != noErr)
            return rate_failure(error, CD_CORE_AUDIO_ERROR, status,
                                "Cannot inspect the sample rate after format recovery");
        if (currentRate == record->originalRate)
            return operations->forgetRate(operations->context, record->uid, error);
        if (currentRate != record->appliedRate)
            return operations->forgetRate(operations->context, record->uid, error);
    }

    status = operations->setRate(operations->context, device, record->originalRate);
    if (status != noErr)
        return rate_failure(error, CD_CORE_AUDIO_ERROR, status, "Cannot restore the original output sample rate");

    result = operations->waitForRate(operations->context, device, record->originalRate, error);
    if (result == CD_OK)
        result = operations->forgetRate(operations->context, record->uid, error);
    return result;
}

int cd_rate_restore_records(const CDRateRecord *records, size_t count, bool recoveryOnly,
                            const CDRateRecoveryOperations *operations, CDError *error)
{
    if ((!records && count != 0) || !operations || !operations->resolveDevice ||
        !operations->readHogOwner || !operations->ownedByAnotherProcess || !operations->objectGone ||
        !has_recovery_operations(operations))
        return rate_failure(error, CD_INVALID_ARGUMENT, 0, "Invalid sample-rate recovery operation");

    int result = CD_OK;
    for (size_t i = 0; i < count; ++i) {
        if (records[i].uid[0] == '\0' || (recoveryOnly && !records[i].recoveryPending)) continue;

        AudioDeviceID device = kAudioObjectUnknown;
        CDError restoreError = {0};
        int restoreResult = CD_OK;
        OSStatus status = operations->resolveDevice(operations->context, records[i].uid, &device);
        if (status != noErr) {
            restoreResult = rate_failure(&restoreError, CD_CORE_AUDIO_ERROR, status,
                                         "Cannot find an output whose sample rate playback changed");
        } else if (device != kAudioObjectUnknown) {
            int32_t owner = -1;
            status = operations->readHogOwner(operations->context, device, &owner);
            if (status == noErr) {
                restoreResult = cd_rate_restore_device(device, owner, &records[i], operations, &restoreError);
            } else if (!operations->objectGone(operations->context, status)) {
                restoreResult = rate_failure(&restoreError, CD_CORE_AUDIO_ERROR, status,
                                             "Cannot inspect ownership while restoring the output");
            }
        }
        if (restoreResult != CD_OK && result == CD_OK) {
            result = restoreResult;
            if (error) *error = restoreError;
        }
    }
    return result;
}
