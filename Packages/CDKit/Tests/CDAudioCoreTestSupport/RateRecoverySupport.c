#include "CDAudioCoreTestSupport.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define TEST_CAPACITY 8u

typedef struct {
    bool present;
    char uid[256];
    AudioDeviceID device;
    double rate;
    int32_t owner;
    AudioStreamBasicDescription virtualFormat;
    AudioStreamBasicDescription physicalFormat;
} TestDevice;

struct CDRateTestBackend {
    TestDevice devices[TEST_CAPACITY];
    size_t deviceCount;
    CDRateRecord records[TEST_CAPACITY];
    size_t recordCount;
    OSStatus setFailure;
    bool waitFailure;
    OSStatus virtualSetFailure;
    OSStatus physicalSetFailure;
    bool virtualWaitFailure;
    bool physicalWaitFailure;
    UInt32 coupledPhysicalBits;
    unsigned virtualFormatSetCalls;
    unsigned setCalls;
    unsigned waitCalls;
};

static TestDevice *device_for_id(CDRateTestBackend *backend, AudioDeviceID device)
{
    for (size_t i = 0; i < backend->deviceCount; ++i)
        if (backend->devices[i].present && backend->devices[i].device == device) return &backend->devices[i];
    return NULL;
}

static TestDevice *device_for_uid(CDRateTestBackend *backend, const char *uid)
{
    for (size_t i = 0; i < backend->deviceCount; ++i)
        if (backend->devices[i].present && strcmp(backend->devices[i].uid, uid) == 0) return &backend->devices[i];
    return NULL;
}

static size_t record_index(CDRateTestBackend *backend, const char *uid)
{
    for (size_t i = 0; i < backend->recordCount; ++i)
        if (strcmp(backend->records[i].uid, uid) == 0) return i;
    return backend->recordCount;
}

static OSStatus fake_resolve_device(void *context, const char *uid, AudioDeviceID *device)
{
    CDRateTestBackend *backend = context;
    TestDevice *found = device_for_uid(backend, uid);
    *device = found ? found->device : kAudioObjectUnknown;
    return noErr;
}

static OSStatus fake_read_rate(void *context, AudioDeviceID device, double *rate)
{
    TestDevice *found = device_for_id(context, device);
    if (!found) return kAudioHardwareBadDeviceError;
    *rate = found->rate;
    return noErr;
}

static OSStatus fake_read_hog_owner(void *context, AudioDeviceID device, int32_t *owner)
{
    TestDevice *found = device_for_id(context, device);
    if (!found) return kAudioHardwareBadDeviceError;
    *owner = found->owner;
    return noErr;
}

static OSStatus fake_resolve_single_stream(void *context, AudioDeviceID device, AudioStreamID *stream)
{
    TestDevice *found = device_for_id(context, device);
    if (!found) return kAudioHardwareBadDeviceError;
    *stream = (AudioStreamID)device;
    return noErr;
}

static OSStatus fake_read_stream_format(void *context, AudioStreamID stream, bool physical,
                                        AudioStreamBasicDescription *format)
{
    TestDevice *found = device_for_id(context, (AudioDeviceID)stream);
    if (!found) return kAudioHardwareBadDeviceError;
    *format = physical ? found->physicalFormat : found->virtualFormat;
    return noErr;
}

static AudioStreamBasicDescription preferred_physical_format(const CDRateTestBackend *backend, double rate,
                                                             UInt32 channels)
{
    UInt32 bytes = backend->coupledPhysicalBits / 8 * channels;
    return (AudioStreamBasicDescription){
        .mSampleRate = rate, .mFormatID = kAudioFormatLinearPCM,
        .mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
        .mBytesPerPacket = bytes, .mFramesPerPacket = 1, .mBytesPerFrame = bytes,
        .mChannelsPerFrame = channels, .mBitsPerChannel = backend->coupledPhysicalBits, .mReserved = 0
    };
}

static OSStatus fake_set_stream_format(void *context, AudioStreamID stream, bool physical,
                                       const AudioStreamBasicDescription *format)
{
    CDRateTestBackend *backend = context;
    if (!physical) ++backend->virtualFormatSetCalls;
    OSStatus failure = physical ? backend->physicalSetFailure : backend->virtualSetFailure;
    if (failure != noErr) return failure;
    TestDevice *found = device_for_id(backend, (AudioDeviceID)stream);
    if (!found) return kAudioHardwareBadDeviceError;
    if (physical) found->physicalFormat = *format;
    else found->virtualFormat = *format;
    if (backend->coupledPhysicalBits != 0) {
        found->rate = format->mSampleRate;
        if (physical) found->virtualFormat.mSampleRate = format->mSampleRate;
        else found->physicalFormat = preferred_physical_format(backend, format->mSampleRate, format->mChannelsPerFrame);
    }
    return noErr;
}

static int fake_wait_for_stream_format(void *context, AudioStreamID stream, bool physical,
                                       const AudioStreamBasicDescription *format, CDError *error)
{
    CDRateTestBackend *backend = context;
    if (physical ? backend->physicalWaitFailure : backend->virtualWaitFailure) {
        if (error) {
            error->code = CD_FORMAT_UNAVAILABLE;
            error->systemStatus = 0;
            snprintf(error->message, sizeof(error->message), "%s", "The output did not switch to the requested stream format");
        }
        return CD_FORMAT_UNAVAILABLE;
    }
    AudioStreamBasicDescription actual = {0};
    OSStatus status = fake_read_stream_format(context, stream, physical, &actual);
    if (status != noErr) return CD_CORE_AUDIO_ERROR;
    if (!cd_audio_stream_formats_equal(&actual, format)) {
        if (error) {
            error->code = CD_FORMAT_UNAVAILABLE;
            error->systemStatus = 0;
            snprintf(error->message, sizeof(error->message), "%s", "The output did not switch to the requested stream format");
        }
        return CD_FORMAT_UNAVAILABLE;
    }
    return CD_OK;
}

static bool fake_owned_by_another_process(void *context, int32_t owner)
{
    (void)context;
    return owner != -1 && owner != 4242;
}

static OSStatus fake_set_rate(void *context, AudioDeviceID device, double rate)
{
    CDRateTestBackend *backend = context;
    ++backend->setCalls;
    if (backend->setFailure != noErr) return backend->setFailure;
    TestDevice *found = device_for_id(backend, device);
    if (!found) return kAudioHardwareBadDeviceError;
    if (backend->coupledPhysicalBits != 0 && found->rate != rate) {
        found->physicalFormat = preferred_physical_format(backend, rate, found->physicalFormat.mChannelsPerFrame);
        found->virtualFormat.mSampleRate = rate;
    }
    found->rate = rate;
    return noErr;
}

static int fake_wait_for_rate(void *context, AudioDeviceID device, double rate, CDError *error)
{
    CDRateTestBackend *backend = context;
    ++backend->waitCalls;
    if (backend->waitFailure) {
        if (error) {
            error->code = CD_FORMAT_UNAVAILABLE;
            error->systemStatus = 0;
            snprintf(error->message, sizeof(error->message), "%s", "The output did not switch to the requested sample rate");
        }
        return CD_FORMAT_UNAVAILABLE;
    }
    double actual = 0;
    OSStatus status = fake_read_rate(backend, device, &actual);
    if (status != noErr)
        return CD_CORE_AUDIO_ERROR;
    if (actual != rate) {
        if (error) {
            error->code = CD_FORMAT_UNAVAILABLE;
            error->systemStatus = 0;
            snprintf(error->message, sizeof(error->message), "%s", "The output did not switch to the requested sample rate");
        }
        return CD_FORMAT_UNAVAILABLE;
    }
    return CD_OK;
}

static int fake_remember_rate(void *context, const char *uid, double originalRate, double appliedRate,
                              CDError *error)
{
    (void)error;
    CDRateTestBackend *backend = context;
    size_t index = record_index(backend, uid);
    bool created = index == backend->recordCount;
    if (index == backend->recordCount) {
        if (backend->recordCount == TEST_CAPACITY) return CD_CORE_AUDIO_ERROR;
        memset(&backend->records[index], 0, sizeof(backend->records[index]));
        ++backend->recordCount;
    }
    CDRateRecord *record = &backend->records[index];
    if (record->originalRate != originalRate || record->appliedRate != appliedRate) {
        record->hasFormatChange = false;
        memset(&record->originalVirtualFormat, 0, sizeof(record->originalVirtualFormat));
        memset(&record->appliedVirtualFormat, 0, sizeof(record->appliedVirtualFormat));
        memset(&record->originalPhysicalFormat, 0, sizeof(record->originalPhysicalFormat));
        memset(&record->appliedPhysicalFormat, 0, sizeof(record->appliedPhysicalFormat));
    }
    if (created)
        snprintf(record->uid, sizeof(record->uid), "%s", uid);
    record->originalRate = originalRate;
    record->appliedRate = appliedRate;
    record->recoveryPending = false;
    return CD_OK;
}

static int fake_remember_formats(void *context, const char *uid, double originalRate, double appliedRate,
                                 const AudioStreamBasicDescription *originalVirtualFormat,
                                 const AudioStreamBasicDescription *appliedVirtualFormat,
                                 const AudioStreamBasicDescription *originalPhysicalFormat,
                                 const AudioStreamBasicDescription *appliedPhysicalFormat, CDError *error)
{
    (void)error;
    CDRateTestBackend *backend = context;
    size_t index = record_index(backend, uid);
    if (index == backend->recordCount) {
        if (backend->recordCount == TEST_CAPACITY) return CD_CORE_AUDIO_ERROR;
        CDRateRecord *record = &backend->records[backend->recordCount++];
        memset(record, 0, sizeof(*record));
        snprintf(record->uid, sizeof(record->uid), "%s", uid);
        record->originalRate = originalRate;
        record->appliedRate = appliedRate;
    } else if (backend->records[index].appliedRate != appliedRate) {
        backend->records[index].hasFormatChange = false;
        backend->records[index].originalRate = originalRate;
        backend->records[index].appliedRate = appliedRate;
    }
    CDRateRecord *record = &backend->records[index];
    record->hasFormatChange = true;
    record->originalVirtualFormat = *originalVirtualFormat;
    record->appliedVirtualFormat = *appliedVirtualFormat;
    record->originalPhysicalFormat = *originalPhysicalFormat;
    record->appliedPhysicalFormat = *appliedPhysicalFormat;
    record->recoveryPending = false;
    return CD_OK;
}

static int fake_clear_formats(void *context, const char *uid, CDError *error)
{
    (void)error;
    CDRateTestBackend *backend = context;
    size_t index = record_index(backend, uid);
    if (index == backend->recordCount || !backend->records[index].hasFormatChange) return CD_OK;
    CDRateRecord *record = &backend->records[index];
    record->hasFormatChange = false;
    memset(&record->originalVirtualFormat, 0, sizeof(record->originalVirtualFormat));
    memset(&record->appliedVirtualFormat, 0, sizeof(record->appliedVirtualFormat));
    memset(&record->originalPhysicalFormat, 0, sizeof(record->originalPhysicalFormat));
    memset(&record->appliedPhysicalFormat, 0, sizeof(record->appliedPhysicalFormat));
    if (record->originalRate == record->appliedRate) {
        for (size_t i = index + 1; i < backend->recordCount; ++i)
            backend->records[i - 1] = backend->records[i];
        --backend->recordCount;
    }
    return CD_OK;
}

static int fake_forget_rate(void *context, const char *uid, CDError *error)
{
    (void)error;
    CDRateTestBackend *backend = context;
    size_t index = record_index(backend, uid);
    if (index == backend->recordCount) return CD_OK;
    for (size_t i = index + 1; i < backend->recordCount; ++i)
        backend->records[i - 1] = backend->records[i];
    --backend->recordCount;
    return CD_OK;
}

static bool fake_object_gone(void *context, OSStatus status)
{
    (void)context;
    return status == kAudioHardwareBadObjectError || status == kAudioHardwareBadDeviceError;
}

static CDRateRecoveryOperations operations_for(CDRateTestBackend *backend)
{
    return (CDRateRecoveryOperations){
        .context = backend,
        .resolveDevice = fake_resolve_device,
        .readRate = fake_read_rate,
        .readHogOwner = fake_read_hog_owner,
        .ownedByAnotherProcess = fake_owned_by_another_process,
        .setRate = fake_set_rate,
        .waitForRate = fake_wait_for_rate,
        .rememberRate = fake_remember_rate,
        .resolveSingleStream = fake_resolve_single_stream,
        .readStreamFormat = fake_read_stream_format,
        .setStreamFormat = fake_set_stream_format,
        .waitForStreamFormat = fake_wait_for_stream_format,
        .rememberFormats = fake_remember_formats,
        .clearFormats = fake_clear_formats,
        .forgetRate = fake_forget_rate,
        .objectGone = fake_object_gone
    };
}

CDRateTestBackend *cd_rate_test_backend_create(void)
{
    return calloc(1, sizeof(CDRateTestBackend));
}

void cd_rate_test_backend_destroy(CDRateTestBackend *backend)
{
    free(backend);
}

int cd_rate_test_add_device(CDRateTestBackend *backend, const char *uid, AudioDeviceID device,
                            double rate, int32_t owner)
{
    if (!backend || !uid || uid[0] == '\0' || backend->deviceCount == TEST_CAPACITY) return CD_INVALID_ARGUMENT;
    TestDevice *found = device_for_uid(backend, uid);
    if (!found) found = &backend->devices[backend->deviceCount++];
    found->present = true;
    snprintf(found->uid, sizeof(found->uid), "%s", uid);
    found->device = device;
    found->rate = rate;
    found->owner = owner;
    return CD_OK;
}

void cd_rate_test_remove_device(CDRateTestBackend *backend, const char *uid)
{
    if (!backend || !uid) return;
    TestDevice *device = device_for_uid(backend, uid);
    if (device) device->present = false;
}

void cd_rate_test_set_device_rate(CDRateTestBackend *backend, const char *uid, double rate)
{
    if (!backend || !uid) return;
    TestDevice *device = device_for_uid(backend, uid);
    if (device) device->rate = rate;
}

void cd_rate_test_set_device_owner(CDRateTestBackend *backend, const char *uid, int32_t owner)
{
    if (!backend || !uid) return;
    TestDevice *device = device_for_uid(backend, uid);
    if (device) device->owner = owner;
}

void cd_rate_test_set_stream_formats(CDRateTestBackend *backend, const char *uid,
                                     const AudioStreamBasicDescription *virtualFormat,
                                     const AudioStreamBasicDescription *physicalFormat)
{
    if (!backend || !uid || !virtualFormat || !physicalFormat) return;
    TestDevice *device = device_for_uid(backend, uid);
    if (!device) return;
    device->virtualFormat = *virtualFormat;
    device->physicalFormat = *physicalFormat;
}

void cd_rate_test_fail_set(CDRateTestBackend *backend, OSStatus status)
{
    if (backend) backend->setFailure = status;
}

void cd_rate_test_couple_formats(CDRateTestBackend *backend, UInt32 preferredPhysicalBits)
{
    if (backend) backend->coupledPhysicalBits = preferredPhysicalBits;
}

void cd_rate_test_fail_set_format(CDRateTestBackend *backend, bool physical, OSStatus status)
{
    if (!backend) return;
    if (physical) backend->physicalSetFailure = status;
    else backend->virtualSetFailure = status;
}

void cd_rate_test_fail_wait(CDRateTestBackend *backend, bool fail)
{
    if (backend) backend->waitFailure = fail;
}

void cd_rate_test_fail_wait_format(CDRateTestBackend *backend, bool physical, bool fail)
{
    if (!backend) return;
    if (physical) backend->physicalWaitFailure = fail;
    else backend->virtualWaitFailure = fail;
}

int cd_rate_test_add_record(CDRateTestBackend *backend, const char *uid, double originalRate,
                            double appliedRate, bool recoveryPending)
{
    if (!backend || !uid || uid[0] == '\0') return CD_INVALID_ARGUMENT;
    int result = fake_remember_rate(backend, uid, originalRate, appliedRate, NULL);
    if (result == CD_OK) backend->records[record_index(backend, uid)].recoveryPending = recoveryPending;
    return result;
}

int cd_rate_test_add_format_record(CDRateTestBackend *backend, const char *uid,
                                   double originalRate, double appliedRate,
                                   const AudioStreamBasicDescription *originalVirtualFormat,
                                   const AudioStreamBasicDescription *appliedVirtualFormat,
                                   const AudioStreamBasicDescription *originalPhysicalFormat,
                                   const AudioStreamBasicDescription *appliedPhysicalFormat,
                                   bool recoveryPending)
{
    if (!backend || !uid || uid[0] == '\0' || !originalVirtualFormat || !appliedVirtualFormat ||
        !originalPhysicalFormat || !appliedPhysicalFormat) return CD_INVALID_ARGUMENT;
    int result = fake_remember_formats(backend, uid, originalRate, appliedRate,
                                       originalVirtualFormat, appliedVirtualFormat,
                                       originalPhysicalFormat, appliedPhysicalFormat, NULL);
    if (result == CD_OK) backend->records[record_index(backend, uid)].recoveryPending = recoveryPending;
    return result;
}

int cd_rate_test_remember_formats(CDRateTestBackend *backend, const char *uid,
                                  double originalRate, double appliedRate,
                                  const AudioStreamBasicDescription *originalVirtualFormat,
                                  const AudioStreamBasicDescription *appliedVirtualFormat,
                                  const AudioStreamBasicDescription *originalPhysicalFormat,
                                  const AudioStreamBasicDescription *appliedPhysicalFormat,
                                  CDError *error)
{
    if (!backend) return CD_INVALID_ARGUMENT;
    CDRateRecoveryOperations operations = operations_for(backend);
    return cd_rate_remember_stream_formats(uid, originalRate, appliedRate, originalVirtualFormat,
                                           appliedVirtualFormat, originalPhysicalFormat,
                                           appliedPhysicalFormat, &operations, error);
}

int cd_rate_test_apply_formats(CDRateTestBackend *backend, const char *uid, double originalRate,
                               double appliedRate,
                               const AudioStreamBasicDescription *originalVirtualFormat,
                               const AudioStreamBasicDescription *appliedVirtualFormat,
                               const AudioStreamBasicDescription *originalPhysicalFormat,
                               const AudioStreamBasicDescription *appliedPhysicalFormat,
                               CDError *error)
{
    if (!backend || !uid) return CD_INVALID_ARGUMENT;
    TestDevice *device = device_for_uid(backend, uid);
    if (!device) return CD_OUTPUT_UNAVAILABLE;
    CDRateRecoveryOperations operations = operations_for(backend);
    return cd_rate_apply_stream_formats((AudioStreamID)device->device, uid, originalRate, appliedRate,
                                        originalVirtualFormat, appliedVirtualFormat,
                                        originalPhysicalFormat, appliedPhysicalFormat,
                                        &operations, error);
}

int cd_rate_test_apply(CDRateTestBackend *backend, const char *uid, double appliedRate, CDError *error)
{
    if (!backend || !uid) return CD_INVALID_ARGUMENT;
    TestDevice *device = device_for_uid(backend, uid);
    if (!device) return CD_OUTPUT_UNAVAILABLE;
    CDRateRecoveryOperations operations = operations_for(backend);
    bool recorded = false;
    return cd_rate_apply(device->device, uid, device->rate, appliedRate, &operations, &recorded, error);
}

int cd_rate_test_restore_uid(CDRateTestBackend *backend, const char *uid, CDError *error)
{
    if (!backend || !uid) return CD_INVALID_ARGUMENT;
    size_t index = record_index(backend, uid);
    TestDevice *device = device_for_uid(backend, uid);
    if (index == backend->recordCount || !device) return CD_OUTPUT_UNAVAILABLE;
    CDRateRecoveryOperations operations = operations_for(backend);
    CDRateRecord record = backend->records[index];
    return cd_rate_restore_device(device->device, device->owner, &record, &operations, error);
}

int cd_rate_test_restore_formats_uid(CDRateTestBackend *backend, const char *uid, CDError *error)
{
    if (!backend || !uid) return CD_INVALID_ARGUMENT;
    size_t index = record_index(backend, uid);
    if (index == backend->recordCount) return CD_OK;
    TestDevice *device = device_for_uid(backend, uid);
    if (!device) return CD_OK;
    CDRateRecoveryOperations operations = operations_for(backend);
    CDRateRecord record = backend->records[index];
    return cd_rate_restore_stream_formats(device->device, device->owner, &record, &operations, error);
}

int cd_rate_test_restore_records(CDRateTestBackend *backend, bool recoveryOnly, CDError *error)
{
    if (!backend) return CD_INVALID_ARGUMENT;
    CDRateRecoveryOperations operations = operations_for(backend);
    CDRateRecord records[TEST_CAPACITY];
    size_t count = backend->recordCount;
    memcpy(records, backend->records, count * sizeof(*records));
    return cd_rate_restore_records(records, count, recoveryOnly, &operations, error);
}

double cd_rate_test_current_rate(const CDRateTestBackend *backend, const char *uid)
{
    if (!backend || !uid) return 0;
    for (size_t i = 0; i < backend->deviceCount; ++i)
        if (backend->devices[i].present && strcmp(backend->devices[i].uid, uid) == 0)
            return backend->devices[i].rate;
    return 0;
}

bool cd_rate_test_has_record(const CDRateTestBackend *backend, const char *uid)
{
    if (!backend || !uid) return false;
    for (size_t i = 0; i < backend->recordCount; ++i)
        if (strcmp(backend->records[i].uid, uid) == 0) return true;
    return false;
}

bool cd_rate_test_has_format_record(const CDRateTestBackend *backend, const char *uid)
{
    if (!backend || !uid) return false;
    for (size_t i = 0; i < backend->recordCount; ++i)
        if (strcmp(backend->records[i].uid, uid) == 0) return backend->records[i].hasFormatChange;
    return false;
}

bool cd_rate_test_get_stream_formats(const CDRateTestBackend *backend, const char *uid,
                                     AudioStreamBasicDescription *virtualFormat,
                                     AudioStreamBasicDescription *physicalFormat)
{
    if (!backend || !uid || !virtualFormat || !physicalFormat) return false;
    for (size_t i = 0; i < backend->deviceCount; ++i) {
        const TestDevice *device = &backend->devices[i];
        if (device->present && strcmp(device->uid, uid) == 0) {
            *virtualFormat = device->virtualFormat;
            *physicalFormat = device->physicalFormat;
            return true;
        }
    }
    return false;
}

unsigned cd_rate_test_set_calls(const CDRateTestBackend *backend)
{
    return backend ? backend->setCalls : 0;
}

unsigned cd_rate_test_wait_calls(const CDRateTestBackend *backend)
{
    return backend ? backend->waitCalls : 0;
}

unsigned cd_rate_test_virtual_format_set_calls(const CDRateTestBackend *backend)
{
    return backend ? backend->virtualFormatSetCalls : 0;
}
