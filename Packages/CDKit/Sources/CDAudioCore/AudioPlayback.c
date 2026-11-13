#include "CDAudioCore.h"
#include "PageBuffer.h"
#include <AudioToolbox/AudioToolbox.h>
#include <CoreFoundation/CoreFoundation.h>
#include <errno.h>
#include <math.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <hdcd_simple.h>

#define PRODUCER_CHUNK 4096u
#define WATCH_COUNT 9u

_Static_assert(sizeof(int) == sizeof(int32_t), "libhdcd requires 32-bit int samples");

typedef struct {
    AudioObjectID object;
    AudioObjectPropertyAddress address;
    bool registered;
} CDPropertyWatch;

struct CDPlayback {
    CDPCMSource source;
    uint64_t totalFrames;
    uint64_t startFrame;
    CDRingBuffer *ring;
    CDLevelTable *levels;
    _Atomic uint32_t levelRun;
    size_t bufferFrames;
    size_t prefillFrames;
    pthread_t producer;
    bool producerStarted;
    _Atomic bool outputEnabled;
    _Atomic bool buffering;
    _Atomic uint64_t bufferingEpoch;
    _Atomic uint64_t producedFrames;
    _Atomic bool readTimedOut;
    uint64_t observedBufferingEpoch;
    uint64_t observedProducedFrames;
    uint64_t waitStartedNanos;
    _Atomic bool producerStop;
    /* Paced waits sleep on this until the ring has drained to its watermark; a stop request wakes them. */
    pthread_mutex_t producerWaitLock;
    pthread_cond_t producerWake;
    _Atomic bool producerFailed;
    CDError producerError;
    _Atomic bool configurationChanged;
    _Atomic bool invalidOutput;
    _Atomic uint64_t renderedFrames;
    _Atomic uint64_t underrunFrames;
    _Atomic uint64_t pcmChecksum;
    _Atomic uint64_t concealedSectors;
    _Atomic bool unverified;
    hdcd_simple *hdcd;
    /* The first 2 s as read and as decoded, held until HDCD detection decides how they play. Claimed
       only while that decision is pending, which is once per disc unless playback stops first. */
    CDPageBuffer hdcdStartup;
    size_t hdcdStartupFrames;
    uint64_t hdcdScannedFrames;
    uint32_t hdcdTrackNumber;
    CDHDCDStatus hdcdKnownStatus;
    bool hdcdDecodeEnabled;
    bool hdcdDecisionMade;
    bool hdcdOutputSupports20;
    bool hdcdDecodeActive;
    bool hdcdPendingDecode;
    _Atomic int hdcdStatus;
    /* The producer's state, up to a whole buffer ahead of what plays. The snapshot reports decoding only
       once the playing position reaches hdcdDecodeFrame, the first disc frame written decoded. */
    _Atomic bool hdcdDecoded;
    _Atomic uint64_t hdcdDecodeFrame;
    _Atomic uint32_t physicalOutputBits;
    /* Silence each prepare plays before the first source frame, set from the output start holds. */
    uint64_t leadInFrames;
    _Atomic uint64_t leadInRemaining;
    bool silentOutput;
    AudioDeviceID device;
    AudioStreamID stream;
    AudioDeviceIOProcID ioProc;
    /* Apple's HAL output unit, used when System Default needs conversion or a wired device has
       multiple output streams. It exists only while running. */
    AudioUnit converter;
    bool running;
    /* The selected output is configured and watched; immediate track changes keep it. */
    bool hasOutput;
    CDOutputTarget target;
    char targetUID[256];
    char outputName[256];
    bool converting;
    bool channelMapped;
    UInt32 preferredLeftChannel;
    UInt32 preferredRightChannel;
    bool changedRate;
    bool changedFormat;
    bool hasOutputDataSource;
    uint32_t outputDataSource;
    double originalRate;
    /* The output's persistent UID, shared by its rate and stream-format recovery records. */
    char uid[256];
    CDPropertyWatch watches[WATCH_COUNT];
};

/* Pending original rates are keyed by UID because reconnecting outputs get new object IDs. */
#define RATE_RECORD_CAPACITY 8u

static pthread_mutex_t rate_records_lock = PTHREAD_MUTEX_INITIALIZER;
static CDRateRecord rate_records[RATE_RECORD_CAPACITY];
static size_t rate_record_count;
static bool rate_records_loaded;

#define RATE_RECORDS_DOMAIN CFSTR("io.github.ylau674.CDPlayer")
#define RATE_RECORDS_KEY CFSTR("ChangedOutputRates")

static int fail(CDError *error, CDResult code, int32_t status, const char *message);

static bool valid_stored_stream_format(const AudioStreamBasicDescription *format)
{
    return isfinite(format->mSampleRate) && format->mSampleRate > 0 &&
        format->mFormatID != 0 && format->mChannelsPerFrame > 0;
}

static bool load_rate_records_locked(CDError *error)
{
    if (rate_records_loaded) return true;
    CFPropertyListRef stored = CFPreferencesCopyAppValue(RATE_RECORDS_KEY, RATE_RECORDS_DOMAIN);
    if (!stored) {
        rate_records_loaded = true;
        return true;
    }
    if (CFGetTypeID(stored) != CFArrayGetTypeID()) {
        CFRelease(stored);
        fail(error, CD_CORE_AUDIO_ERROR, 0, "Saved output sample-rate records are malformed");
        return false;
    }

    CFArrayRef array = (CFArrayRef)stored;
    CFIndex count = CFArrayGetCount(array);
    if (count < 0 || count > RATE_RECORD_CAPACITY) {
        CFRelease(stored);
        fail(error, CD_CORE_AUDIO_ERROR, 0, "Saved output sample-rate records exceed the supported limit");
        return false;
    }

    CDRateRecord loaded[RATE_RECORD_CAPACITY] = {0};
    for (CFIndex i = 0; i < count; ++i) {
        CFTypeRef value = CFArrayGetValueAtIndex(array, i);
        if (CFGetTypeID(value) != CFDictionaryGetTypeID()) {
            CFRelease(stored);
            fail(error, CD_CORE_AUDIO_ERROR, 0, "A saved output sample-rate record is malformed");
            return false;
        }
        CFDictionaryRef dictionary = (CFDictionaryRef)value;
        CFTypeRef uidValue = CFDictionaryGetValue(dictionary, CFSTR("uid"));
        CFTypeRef originalValue = CFDictionaryGetValue(dictionary, CFSTR("originalRate"));
        CFTypeRef appliedValue = CFDictionaryGetValue(dictionary, CFSTR("appliedRate"));
        CFTypeRef originalVirtualValue = CFDictionaryGetValue(dictionary, CFSTR("originalVirtualFormat"));
        CFTypeRef appliedVirtualValue = CFDictionaryGetValue(dictionary, CFSTR("appliedVirtualFormat"));
        CFTypeRef originalPhysicalValue = CFDictionaryGetValue(dictionary, CFSTR("originalPhysicalFormat"));
        CFTypeRef appliedPhysicalValue = CFDictionaryGetValue(dictionary, CFSTR("appliedPhysicalFormat"));
        bool hasAnyFormat = originalVirtualValue || appliedVirtualValue ||
                            originalPhysicalValue || appliedPhysicalValue;
        bool hasAllFormats = originalVirtualValue && appliedVirtualValue &&
                             originalPhysicalValue && appliedPhysicalValue;
        if (!uidValue || CFGetTypeID(uidValue) != CFStringGetTypeID() ||
            !originalValue || CFGetTypeID(originalValue) != CFNumberGetTypeID() ||
            !appliedValue || CFGetTypeID(appliedValue) != CFNumberGetTypeID() ||
            (hasAnyFormat && (!hasAllFormats ||
                CFGetTypeID(originalVirtualValue) != CFDataGetTypeID() ||
                CFGetTypeID(appliedVirtualValue) != CFDataGetTypeID() ||
                CFGetTypeID(originalPhysicalValue) != CFDataGetTypeID() ||
                CFGetTypeID(appliedPhysicalValue) != CFDataGetTypeID() ||
                CFDataGetLength((CFDataRef)originalVirtualValue) != sizeof(AudioStreamBasicDescription) ||
                CFDataGetLength((CFDataRef)appliedVirtualValue) != sizeof(AudioStreamBasicDescription) ||
                CFDataGetLength((CFDataRef)originalPhysicalValue) != sizeof(AudioStreamBasicDescription) ||
                CFDataGetLength((CFDataRef)appliedPhysicalValue) != sizeof(AudioStreamBasicDescription))) ||
            !CFStringGetCString((CFStringRef)uidValue, loaded[i].uid, sizeof(loaded[i].uid),
                                kCFStringEncodingUTF8) ||
            !CFNumberGetValue((CFNumberRef)originalValue, kCFNumberDoubleType, &loaded[i].originalRate) ||
            !CFNumberGetValue((CFNumberRef)appliedValue, kCFNumberDoubleType, &loaded[i].appliedRate) ||
            loaded[i].uid[0] == '\0' || !isfinite(loaded[i].originalRate) ||
            !isfinite(loaded[i].appliedRate) || loaded[i].originalRate <= 0 ||
            loaded[i].appliedRate <= 0 ||
            (loaded[i].originalRate == loaded[i].appliedRate && !hasAnyFormat)) {
            CFRelease(stored);
            fail(error, CD_CORE_AUDIO_ERROR, 0, "A saved output sample-rate record is invalid");
            return false;
        }
        if (hasAnyFormat) {
            memcpy(&loaded[i].originalVirtualFormat, CFDataGetBytePtr((CFDataRef)originalVirtualValue),
                   sizeof(AudioStreamBasicDescription));
            memcpy(&loaded[i].appliedVirtualFormat, CFDataGetBytePtr((CFDataRef)appliedVirtualValue),
                   sizeof(AudioStreamBasicDescription));
            memcpy(&loaded[i].originalPhysicalFormat, CFDataGetBytePtr((CFDataRef)originalPhysicalValue),
                   sizeof(AudioStreamBasicDescription));
            memcpy(&loaded[i].appliedPhysicalFormat, CFDataGetBytePtr((CFDataRef)appliedPhysicalValue),
                   sizeof(AudioStreamBasicDescription));
            loaded[i].hasFormatChange = true;
            if (!valid_stored_stream_format(&loaded[i].originalVirtualFormat) ||
                !valid_stored_stream_format(&loaded[i].appliedVirtualFormat) ||
                !valid_stored_stream_format(&loaded[i].originalPhysicalFormat) ||
                !valid_stored_stream_format(&loaded[i].appliedPhysicalFormat)) {
                CFRelease(stored);
                fail(error, CD_CORE_AUDIO_ERROR, 0, "A saved output stream-format record is invalid");
                return false;
            }
        }
        loaded[i].recoveryPending = true;
        for (CFIndex previous = 0; previous < i; ++previous) {
            if (strcmp(loaded[previous].uid, loaded[i].uid) == 0) {
                CFRelease(stored);
                fail(error, CD_CORE_AUDIO_ERROR, 0, "Saved output sample-rate records contain a duplicate device");
                return false;
            }
        }
    }
    memcpy(rate_records, loaded, (size_t)count * sizeof(*loaded));
    rate_record_count = (size_t)count;
    rate_records_loaded = true;
    CFRelease(stored);
    return true;
}

static bool persist_rate_records_locked(CDError *error)
{
    CFMutableArrayRef array = CFArrayCreateMutable(kCFAllocatorDefault, 0, &kCFTypeArrayCallBacks);
    if (!array) {
        fail(error, CD_OUT_OF_MEMORY, 0, "Cannot allocate output sample-rate recovery data");
        return false;
    }
    for (size_t i = 0; i < rate_record_count; ++i) {
        CFStringRef uid = CFStringCreateWithCString(kCFAllocatorDefault, rate_records[i].uid,
                                                    kCFStringEncodingUTF8);
        CFNumberRef original = CFNumberCreate(kCFAllocatorDefault, kCFNumberDoubleType,
                                              &rate_records[i].originalRate);
        CFNumberRef applied = CFNumberCreate(kCFAllocatorDefault, kCFNumberDoubleType,
                                             &rate_records[i].appliedRate);
        CFDataRef originalVirtual = rate_records[i].hasFormatChange
            ? CFDataCreate(kCFAllocatorDefault, (const UInt8 *)&rate_records[i].originalVirtualFormat,
                           sizeof(AudioStreamBasicDescription)) : NULL;
        CFDataRef appliedVirtual = rate_records[i].hasFormatChange
            ? CFDataCreate(kCFAllocatorDefault, (const UInt8 *)&rate_records[i].appliedVirtualFormat,
                           sizeof(AudioStreamBasicDescription)) : NULL;
        CFDataRef originalPhysical = rate_records[i].hasFormatChange
            ? CFDataCreate(kCFAllocatorDefault, (const UInt8 *)&rate_records[i].originalPhysicalFormat,
                           sizeof(AudioStreamBasicDescription)) : NULL;
        CFDataRef appliedPhysical = rate_records[i].hasFormatChange
            ? CFDataCreate(kCFAllocatorDefault, (const UInt8 *)&rate_records[i].appliedPhysicalFormat,
                           sizeof(AudioStreamBasicDescription)) : NULL;
        CFMutableDictionaryRef dictionary = CFDictionaryCreateMutable(
            kCFAllocatorDefault, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        bool formatDataMissing = rate_records[i].hasFormatChange &&
            (!originalVirtual || !appliedVirtual || !originalPhysical || !appliedPhysical);
        if (!uid || !original || !applied || formatDataMissing || !dictionary) {
            if (uid) CFRelease(uid);
            if (original) CFRelease(original);
            if (applied) CFRelease(applied);
            if (originalVirtual) CFRelease(originalVirtual);
            if (appliedVirtual) CFRelease(appliedVirtual);
            if (originalPhysical) CFRelease(originalPhysical);
            if (appliedPhysical) CFRelease(appliedPhysical);
            if (dictionary) CFRelease(dictionary);
            CFRelease(array);
            fail(error, CD_OUT_OF_MEMORY, 0, "Cannot encode output rate and format recovery data");
            return false;
        }
        CFDictionarySetValue(dictionary, CFSTR("uid"), uid);
        CFDictionarySetValue(dictionary, CFSTR("originalRate"), original);
        CFDictionarySetValue(dictionary, CFSTR("appliedRate"), applied);
        if (rate_records[i].hasFormatChange) {
            CFDictionarySetValue(dictionary, CFSTR("originalVirtualFormat"), originalVirtual);
            CFDictionarySetValue(dictionary, CFSTR("appliedVirtualFormat"), appliedVirtual);
            CFDictionarySetValue(dictionary, CFSTR("originalPhysicalFormat"), originalPhysical);
            CFDictionarySetValue(dictionary, CFSTR("appliedPhysicalFormat"), appliedPhysical);
        }
        CFArrayAppendValue(array, dictionary);
        CFRelease(uid);
        CFRelease(original);
        CFRelease(applied);
        if (originalVirtual) CFRelease(originalVirtual);
        if (appliedVirtual) CFRelease(appliedVirtual);
        if (originalPhysical) CFRelease(originalPhysical);
        if (appliedPhysical) CFRelease(appliedPhysical);
        CFRelease(dictionary);
    }
    CFPreferencesSetAppValue(RATE_RECORDS_KEY, rate_record_count ? array : NULL, RATE_RECORDS_DOMAIN);
    Boolean synchronized = CFPreferencesAppSynchronize(RATE_RECORDS_DOMAIN);
    CFRelease(array);
    if (!synchronized) {
        fail(error, CD_CORE_AUDIO_ERROR, 0, "Cannot persist output sample-rate recovery data");
        return false;
    }
    return true;
}

/* The latest rate wins: an output already at another rate was set by someone after any earlier change. */
static int remember_rate(const char *uid, double originalRate, double appliedRate, CDError *error)
{
    if (uid[0] == '\0')
        return fail(error, CD_CORE_AUDIO_ERROR, 0, "Cannot identify the output for sample-rate recovery");
    pthread_mutex_lock(&rate_records_lock);
    if (!load_rate_records_locked(error)) {
        pthread_mutex_unlock(&rate_records_lock);
        return CD_CORE_AUDIO_ERROR;
    }
    CDRateRecord previous[RATE_RECORD_CAPACITY];
    size_t previousCount = rate_record_count;
    memcpy(previous, rate_records, sizeof(previous));
    size_t i = 0;
    while (i < rate_record_count && strcmp(rate_records[i].uid, uid) != 0) ++i;
    if (i == rate_record_count && rate_record_count < RATE_RECORD_CAPACITY) {
        memset(&rate_records[i], 0, sizeof(rate_records[i]));
        snprintf(rate_records[i].uid, sizeof(rate_records[i].uid), "%s", uid);
        ++rate_record_count;
    }
    if (i == rate_record_count) {
        pthread_mutex_unlock(&rate_records_lock);
        return fail(error, CD_CORE_AUDIO_ERROR, 0, "Too many output sample-rate recovery records");
    }
    if (rate_records[i].originalRate != originalRate || rate_records[i].appliedRate != appliedRate) {
        rate_records[i].hasFormatChange = false;
        memset(&rate_records[i].originalVirtualFormat, 0, sizeof(AudioStreamBasicDescription));
        memset(&rate_records[i].appliedVirtualFormat, 0, sizeof(AudioStreamBasicDescription));
        memset(&rate_records[i].originalPhysicalFormat, 0, sizeof(AudioStreamBasicDescription));
        memset(&rate_records[i].appliedPhysicalFormat, 0, sizeof(AudioStreamBasicDescription));
    }
    rate_records[i].originalRate = originalRate;
    rate_records[i].appliedRate = appliedRate;
    rate_records[i].recoveryPending = false;
    if (!persist_rate_records_locked(error)) {
        memcpy(rate_records, previous, sizeof(previous));
        rate_record_count = previousCount;
        pthread_mutex_unlock(&rate_records_lock);
        return CD_CORE_AUDIO_ERROR;
    }
    pthread_mutex_unlock(&rate_records_lock);
    return CD_OK;
}

static int remember_stream_formats(const char *uid, double originalRate, double appliedRate,
                                   const AudioStreamBasicDescription *originalVirtualFormat,
                                   const AudioStreamBasicDescription *appliedVirtualFormat,
                                   const AudioStreamBasicDescription *originalPhysicalFormat,
                                   const AudioStreamBasicDescription *appliedPhysicalFormat,
                                   CDError *error)
{
    if (!uid || uid[0] == '\0' || !originalVirtualFormat || !appliedVirtualFormat ||
        !originalPhysicalFormat || !appliedPhysicalFormat ||
        !valid_stored_stream_format(originalVirtualFormat) ||
        !valid_stored_stream_format(appliedVirtualFormat) ||
        !valid_stored_stream_format(originalPhysicalFormat) ||
        !valid_stored_stream_format(appliedPhysicalFormat) ||
        !isfinite(originalRate) || !isfinite(appliedRate) || originalRate <= 0 || appliedRate <= 0)
        return fail(error, CD_INVALID_ARGUMENT, 0, "Invalid output stream-format recovery data");

    pthread_mutex_lock(&rate_records_lock);
    if (!load_rate_records_locked(error)) {
        pthread_mutex_unlock(&rate_records_lock);
        return CD_CORE_AUDIO_ERROR;
    }
    CDRateRecord previous[RATE_RECORD_CAPACITY];
    size_t previousCount = rate_record_count;
    memcpy(previous, rate_records, sizeof(previous));
    size_t i = 0;
    while (i < rate_record_count && strcmp(rate_records[i].uid, uid) != 0) ++i;
    if (i == rate_record_count) {
        if (rate_record_count == RATE_RECORD_CAPACITY) {
            pthread_mutex_unlock(&rate_records_lock);
            return fail(error, CD_CORE_AUDIO_ERROR, 0, "Too many output sample-rate recovery records");
        }
        memset(&rate_records[i], 0, sizeof(rate_records[i]));
        snprintf(rate_records[i].uid, sizeof(rate_records[i].uid), "%s", uid);
        rate_records[i].originalRate = originalRate;
        rate_records[i].appliedRate = appliedRate;
        ++rate_record_count;
    } else if (rate_records[i].appliedRate != appliedRate) {
        memset(&rate_records[i].originalVirtualFormat, 0, sizeof(AudioStreamBasicDescription));
        memset(&rate_records[i].appliedVirtualFormat, 0, sizeof(AudioStreamBasicDescription));
        memset(&rate_records[i].originalPhysicalFormat, 0, sizeof(AudioStreamBasicDescription));
        memset(&rate_records[i].appliedPhysicalFormat, 0, sizeof(AudioStreamBasicDescription));
        rate_records[i].originalRate = originalRate;
        rate_records[i].appliedRate = appliedRate;
    }
    rate_records[i].hasFormatChange = true;
    rate_records[i].originalVirtualFormat = *originalVirtualFormat;
    rate_records[i].appliedVirtualFormat = *appliedVirtualFormat;
    rate_records[i].originalPhysicalFormat = *originalPhysicalFormat;
    rate_records[i].appliedPhysicalFormat = *appliedPhysicalFormat;
    rate_records[i].recoveryPending = false;
    if (!persist_rate_records_locked(error)) {
        memcpy(rate_records, previous, sizeof(previous));
        rate_record_count = previousCount;
        pthread_mutex_unlock(&rate_records_lock);
        return CD_CORE_AUDIO_ERROR;
    }
    pthread_mutex_unlock(&rate_records_lock);
    return CD_OK;
}

static int clear_stream_formats(const char *uid, CDError *error)
{
    if (!uid || uid[0] == '\0') return CD_OK;
    pthread_mutex_lock(&rate_records_lock);
    if (!load_rate_records_locked(error)) {
        pthread_mutex_unlock(&rate_records_lock);
        return CD_CORE_AUDIO_ERROR;
    }
    CDRateRecord previous[RATE_RECORD_CAPACITY];
    size_t previousCount = rate_record_count;
    memcpy(previous, rate_records, sizeof(previous));
    size_t i = 0;
    while (i < rate_record_count && strcmp(rate_records[i].uid, uid) != 0) ++i;
    if (i == rate_record_count || !rate_records[i].hasFormatChange) {
        pthread_mutex_unlock(&rate_records_lock);
        return CD_OK;
    }
    memset(&rate_records[i].originalVirtualFormat, 0, sizeof(AudioStreamBasicDescription));
    memset(&rate_records[i].appliedVirtualFormat, 0, sizeof(AudioStreamBasicDescription));
    memset(&rate_records[i].originalPhysicalFormat, 0, sizeof(AudioStreamBasicDescription));
    memset(&rate_records[i].appliedPhysicalFormat, 0, sizeof(AudioStreamBasicDescription));
    rate_records[i].hasFormatChange = false;
    if (rate_records[i].originalRate == rate_records[i].appliedRate) {
        rate_records[i] = rate_records[--rate_record_count];
    }
    if (!persist_rate_records_locked(error)) {
        memcpy(rate_records, previous, sizeof(previous));
        rate_record_count = previousCount;
        pthread_mutex_unlock(&rate_records_lock);
        return CD_CORE_AUDIO_ERROR;
    }
    pthread_mutex_unlock(&rate_records_lock);
    return CD_OK;
}

static bool saved_rate_record(const char *uid, CDRateRecord *record, CDError *error)
{
    if (!uid || uid[0] == '\0' || !record) return false;
    pthread_mutex_lock(&rate_records_lock);
    if (!load_rate_records_locked(error)) {
        pthread_mutex_unlock(&rate_records_lock);
        return false;
    }
    bool found = false;
    for (size_t i = 0; i < rate_record_count; ++i) {
        if (strcmp(rate_records[i].uid, uid) == 0) {
            *record = rate_records[i];
            found = true;
            break;
        }
    }
    pthread_mutex_unlock(&rate_records_lock);
    return found;
}

static int forget_rate(const char *uid, CDError *error)
{
    if (uid[0] == '\0') return CD_OK;
    pthread_mutex_lock(&rate_records_lock);
    if (!load_rate_records_locked(error)) {
        pthread_mutex_unlock(&rate_records_lock);
        return CD_CORE_AUDIO_ERROR;
    }
    CDRateRecord previous[RATE_RECORD_CAPACITY];
    size_t previousCount = rate_record_count;
    memcpy(previous, rate_records, sizeof(previous));
    bool found = false;
    for (size_t i = 0; i < rate_record_count; ++i) {
        if (strcmp(rate_records[i].uid, uid) == 0) {
            rate_records[i] = rate_records[--rate_record_count];
            found = true;
            break;
        }
    }
    if (found && !persist_rate_records_locked(error)) {
        memcpy(rate_records, previous, sizeof(previous));
        rate_record_count = previousCount;
        pthread_mutex_unlock(&rate_records_lock);
        return CD_CORE_AUDIO_ERROR;
    }
    pthread_mutex_unlock(&rate_records_lock);
    return CD_OK;
}

static int mark_rate_for_recovery(const char *uid, CDError *error)
{
    if (uid[0] == '\0') return CD_OK;
    pthread_mutex_lock(&rate_records_lock);
    if (!load_rate_records_locked(error)) {
        pthread_mutex_unlock(&rate_records_lock);
        return CD_CORE_AUDIO_ERROR;
    }
    size_t i = 0;
    while (i < rate_record_count && strcmp(rate_records[i].uid, uid) != 0) ++i;
    if (i == rate_record_count || rate_records[i].recoveryPending) {
        pthread_mutex_unlock(&rate_records_lock);
        return CD_OK;
    }
    rate_records[i].recoveryPending = true;
    if (!persist_rate_records_locked(error)) {
        rate_records[i].recoveryPending = false;
        pthread_mutex_unlock(&rate_records_lock);
        return CD_CORE_AUDIO_ERROR;
    }
    pthread_mutex_unlock(&rate_records_lock);
    return CD_OK;
}

static int recorded_rate(const char *uid, double *rate, CDError *error)
{
    pthread_mutex_lock(&rate_records_lock);
    if (!load_rate_records_locked(error)) {
        pthread_mutex_unlock(&rate_records_lock);
        return -1;
    }
    bool found = false;
    for (size_t i = 0; i < rate_record_count && !found; ++i) {
        if (strcmp(rate_records[i].uid, uid) == 0) {
            *rate = rate_records[i].originalRate;
            found = true;
        }
    }
    pthread_mutex_unlock(&rate_records_lock);
    return found ? 1 : 0;
}

/* macOS's usual rate for built-in outputs. The output-rate switch restores it when no earlier rate
   is recorded, such as after a force-quit lost the record. */
#define FALLBACK_OUTPUT_RATE 48000.0

static int fail(CDError *error, CDResult code, int32_t status, const char *message)
{
    if (error) {
        error->code = code;
        error->systemStatus = status;
        if (status)
            snprintf(error->message, sizeof(error->message), "%s (status %d).", message, status);
        else
            snprintf(error->message, sizeof(error->message), "%s", message);
    }
    return code;
}

/* Names the target in a message, preserving the legacy built-in and System Default wording. */
static int fail_output(CDError *error, CDResult code, int32_t status, const char *before,
                       CDOutputTarget target, const char *deviceName, const char *after)
{
    char message[sizeof(((CDError *)0)->message)];
    const char *name = target == CD_TARGET_DEVICE && deviceName && deviceName[0]
        ? deviceName
        : target == CD_TARGET_SYSTEM_DEFAULT ? "default output" : "built-in output";
    snprintf(message, sizeof(message), "%s%s%s", before,
             name, after);
    return fail(error, code, status, message);
}

CDSourceFormat cd_source_format_compact_disc(void)
{
    return (CDSourceFormat){CD_DA_SAMPLE_RATE, CD_DA_BITS_PER_CHANNEL, CD_DA_CHANNELS};
}

bool cd_source_format_supported(CDSourceFormat format)
{
    return format.sampleRate == CD_DA_SAMPLE_RATE && format.bitsPerChannel == CD_DA_BITS_PER_CHANNEL &&
        format.channelsPerFrame == CD_PCM_CHANNELS;
}

static bool valid_source_rate(double rate)
{
    return isfinite(rate) && rate > 0;
}

/* "44.1 kHz" or "48 kHz", as the player names rates. */
static void rate_text(double rate, char *text, size_t size)
{
    double kilohertz = rate / 1000.0;
    snprintf(text, size, kilohertz == round(kilohertz) ? "%.0f kHz" : "%.1f kHz", kilohertz);
}

static int fail_source_rate(CDError *error, CDResult code, const char *before, CDOutputTarget target,
                            const char *deviceName, const char *afterRate, double rate)
{
    char after[128];
    char rateName[32];
    rate_text(rate, rateName, sizeof(rateName));
    snprintf(after, sizeof(after), "%s%s", afterRate, rateName);
    return fail_output(error, code, 0, before, target, deviceName, after);
}

static void include_selected_output_name(CDError *error, CDOutputTarget target, const char *name)
{
    if (!error || target != CD_TARGET_DEVICE || !name || !name[0] || strstr(error->message, name)) return;
    size_t used = strnlen(error->message, sizeof(error->message));
    if (used >= sizeof(error->message) - 1) return;
    snprintf(error->message + used, sizeof(error->message) - used, " Selected output: %.150s", name);
}

static AudioObjectPropertyAddress address(AudioObjectPropertySelector selector,
                                           AudioObjectPropertyScope scope)
{
    AudioObjectPropertyAddress result = {selector, scope, kAudioObjectPropertyElementMain};
    return result;
}

static OSStatus get_property(AudioObjectID object, AudioObjectPropertySelector selector,
                              AudioObjectPropertyScope scope, void *value, UInt32 size)
{
    AudioObjectPropertyAddress a = address(selector, scope);
    return AudioObjectGetPropertyData(object, &a, 0, NULL, &size, value);
}

static OSStatus set_property(AudioObjectID object, AudioObjectPropertySelector selector,
                              const void *value, UInt32 size)
{
    AudioObjectPropertyAddress a = address(selector, kAudioObjectPropertyScopeGlobal);
    return AudioObjectSetPropertyData(object, &a, 0, NULL, size, value);
}

static void sleep_milliseconds(long milliseconds)
{
    struct timespec delay = {milliseconds / 1000, (milliseconds % 1000) * 1000000};
    nanosleep(&delay, NULL);
}

static OSStatus get_output_stream(AudioDeviceID device, AudioStreamID *stream, bool *singleStream)
{
    if (!stream || !singleStream) return kAudioHardwareIllegalOperationError;
    *singleStream = false;
    AudioObjectPropertyAddress a = address(kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput);
    UInt32 size = 0;
    OSStatus status = AudioObjectGetPropertyDataSize(device, &a, 0, NULL, &size);
    CDOutputStreamTopology topology = cd_audio_classify_output_stream_query(status, size);
    if (topology == CD_STREAM_TOPOLOGY_QUERY_ERROR)
        return status != noErr ? status : kAudioHardwareBadPropertySizeError;
    if (topology == CD_STREAM_TOPOLOGY_MULTIPLE) return noErr;
    UInt32 capacity = size;
    status = AudioObjectGetPropertyData(device, &a, 0, NULL, &size, stream);
    if (status == noErr) {
        if (size != capacity) return kAudioHardwareBadPropertySizeError;
        *singleStream = true;
    }
    return status;
}

static OSStatus get_first_output_stream(AudioDeviceID device, AudioStreamID *stream)
{
    AudioObjectPropertyAddress a = address(kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput);
    UInt32 size = 0;
    OSStatus status = AudioObjectGetPropertyDataSize(device, &a, 0, NULL, &size);
    if (status != noErr) return status;
    if (size < sizeof(*stream) || size % sizeof(*stream) != 0)
        return kAudioHardwareUnsupportedOperationError;
    AudioStreamID *streams = malloc(size);
    if (!streams) return kAudioHardwareUnspecifiedError;
    status = AudioObjectGetPropertyData(device, &a, 0, NULL, &size, streams);
    if (status == noErr) {
        if (size < sizeof(*stream) || size % sizeof(*stream) != 0)
            status = kAudioHardwareBadPropertySizeError;
        else
            *stream = streams[0];
    }
    free(streams);
    return status;
}

static UInt32 output_channel_count(AudioDeviceID device)
{
    AudioObjectPropertyAddress a = address(kAudioDevicePropertyStreamConfiguration,
                                           kAudioDevicePropertyScopeOutput);
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(device, &a, 0, NULL, &size) != noErr ||
        size < offsetof(AudioBufferList, mBuffers) + sizeof(AudioBuffer))
        return 0;
    AudioBufferList *buffers = malloc(size);
    if (!buffers) return 0;
    UInt32 channels = 0;
    if (AudioObjectGetPropertyData(device, &a, 0, NULL, &size, buffers) == noErr) {
        UInt32 count = buffers->mNumberBuffers;
        size_t available = (size - offsetof(AudioBufferList, mBuffers)) / sizeof(AudioBuffer);
        if (count > available) count = (UInt32)available;
        for (UInt32 i = 0; i < count; ++i) channels += buffers->mBuffers[i].mNumberChannels;
    }
    free(buffers);
    return channels;
}

static void preferred_stereo_channels(AudioDeviceID device, UInt32 channelCount,
                                     UInt32 *left, UInt32 *right)
{
    *left = 0;
    *right = 1;
    if (channelCount < CD_PCM_CHANNELS) return;
    UInt32 channels[CD_PCM_CHANNELS] = {0, 0};
    OSStatus status = get_property(device, kAudioDevicePropertyPreferredChannelsForStereo,
                                   kAudioObjectPropertyScopeOutput, channels, sizeof(channels));
    if (status == noErr && channels[0] > 0 && channels[1] > 0 &&
        channels[0] <= channelCount && channels[1] <= channelCount && channels[0] != channels[1]) {
        *left = channels[0] - 1;
        *right = channels[1] - 1;
    }
}

static OSStatus get_string(AudioDeviceID device, AudioObjectPropertySelector selector,
                           char *text, size_t capacity)
{
    text[0] = '\0';
    CFStringRef value = NULL;
    OSStatus status = get_property(device, selector, kAudioObjectPropertyScopeGlobal, &value, sizeof(value));
    if (status != noErr) return status;
    if (!value) return kAudioHardwareUnspecifiedError;
    bool copied = CFStringGetCString(value, text, (CFIndex)capacity, kCFStringEncodingUTF8);
    CFRelease(value);
    if (!copied) text[0] = '\0';
    return copied ? noErr : kAudioHardwareBadPropertySizeError;
}

static OSStatus get_name(AudioDeviceID device, char *name, size_t capacity)
{
    return get_string(device, kAudioObjectPropertyName, name, capacity);
}

/* An unknown device, not an error, is the result for a UID no connected device has. */
static OSStatus device_for_uid(const char *uid, AudioDeviceID *device)
{
    *device = kAudioObjectUnknown;
    CFStringRef value = CFStringCreateWithCString(kCFAllocatorDefault, uid, kCFStringEncodingUTF8);
    if (!value) return kAudioHardwareUnspecifiedError;
    AudioObjectPropertyAddress a = address(kAudioHardwarePropertyTranslateUIDToDevice,
                                           kAudioObjectPropertyScopeGlobal);
    UInt32 size = sizeof(*device);
    OSStatus status = AudioObjectGetPropertyData(kAudioObjectSystemObject, &a, sizeof(value), &value,
                                                 &size, device);
    CFRelease(value);
    return status;
}

static AudioDeviceID default_output_device(void)
{
    AudioDeviceID device = kAudioObjectUnknown;
    if (get_property(kAudioObjectSystemObject, kAudioHardwarePropertyDefaultOutputDevice,
                     kAudioObjectPropertyScopeGlobal, &device, sizeof(device)) != noErr)
        return kAudioObjectUnknown;
    return device;
}

/* Hog mode makes a device unusable for, and its controls unchangeable by, every other process. */
static bool owned_by_another_process(pid_t owner)
{
    return owner != -1 && owner != getpid();
}

static bool object_gone(OSStatus status)
{
    return status == kAudioHardwareBadObjectError || status == kAudioHardwareBadDeviceError;
}

/* A device without hog mode can never be owned exclusively. */
static OSStatus read_hog_owner(AudioDeviceID device, pid_t *owner)
{
    *owner = -1;
    OSStatus status = get_property(device, kAudioDevicePropertyHogMode, kAudioObjectPropertyScopeGlobal,
                                   owner, sizeof(*owner));
    if (status != kAudioHardwareUnknownPropertyError) return status;
    *owner = -1;
    return noErr;
}

int cd_output_rank(bool isDefaultOutput, const char *name)
{
    if (isDefaultOutput) return 1000;
    return name && strcasestr(name, "headphone") ? 100 : 10;
}

static bool supports_rate(const AudioValueRange *ranges, size_t count, double rate)
{
    for (size_t i = 0; i < count; ++i)
        if (ranges[i].mMinimum <= rate && ranges[i].mMaximum >= rate) return true;
    return false;
}

static bool has_settable_output_volume(AudioDeviceID device)
{
    for (AudioObjectPropertyElement element = kAudioObjectPropertyElementMain; element <= 2; ++element) {
        AudioObjectPropertyAddress a = {kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeOutput,
                                        element};
        Boolean settable = false;
        if (AudioObjectHasProperty(device, &a) &&
            AudioObjectIsPropertySettable(device, &a, &settable) == noErr && settable)
            return true;
    }
    return false;
}

static int inspect_device(AudioDeviceID device, AudioStreamID stream, double sourceRate,
                           CDDeviceInfo *info, CDError *error)
{
    OSStatus status;
    memset(info, 0, sizeof(*info));
    info->deviceID = device;
    info->hasVolumeControl = has_settable_output_volume(device);
    status = get_property(device, kAudioDevicePropertyTransportType, kAudioObjectPropertyScopeGlobal,
                          &info->transportType, sizeof(info->transportType));
    if (status != noErr)
        return fail(error, CD_CORE_AUDIO_ERROR, status, "Cannot read the output transport");
    status = get_string(device, kAudioDevicePropertyDeviceUID, info->uid, sizeof(info->uid));
    if (status != noErr)
        return fail(error, CD_CORE_AUDIO_ERROR, status, "Cannot read the output UID");
    info->outputChannels = output_channel_count(device);
    status = get_name(device, info->name, sizeof(info->name));
    if (status != noErr) return fail(error, CD_CORE_AUDIO_ERROR, status, "Cannot read the output name");
    status = get_property(device, kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal,
                           &info->sampleRate, sizeof(info->sampleRate));
    if (status != noErr) return fail(error, CD_CORE_AUDIO_ERROR, status, "Cannot read the output sample rate");
    UInt32 running = 0;
    status = get_property(device, kAudioDevicePropertyDeviceIsRunningSomewhere, kAudioObjectPropertyScopeGlobal,
                           &running, sizeof(running));
    if (status != noErr) return fail(error, CD_CORE_AUDIO_ERROR, status, "Cannot inspect whether the output is in use");
    info->isRunning = running != 0;

    AudioObjectPropertyAddress hog = address(kAudioDevicePropertyHogMode, kAudioObjectPropertyScopeGlobal);
    info->hogOwner = -1;
    if (AudioObjectHasProperty(device, &hog)) {
        status = get_property(device, kAudioDevicePropertyHogMode, kAudioObjectPropertyScopeGlobal,
                               &info->hogOwner, sizeof(info->hogOwner));
        if (status != noErr) return fail(error, CD_CORE_AUDIO_ERROR, status, "Cannot inspect exclusive ownership");
    }
    info->isDefaultOutput = device == default_output_device();

    AudioObjectPropertyAddress rates = address(kAudioDevicePropertyAvailableNominalSampleRates,
                                                kAudioObjectPropertyScopeGlobal);
    UInt32 size = 0;
    status = AudioObjectGetPropertyDataSize(device, &rates, 0, NULL, &size);
    if (status != noErr || size == 0)
        return fail(error, CD_CORE_AUDIO_ERROR, status, "Cannot inspect supported sample rates");
    AudioValueRange *values = malloc(size);
    if (!values) return fail(error, CD_OUT_OF_MEMORY, 0, "Cannot allocate sample-rate inspection data");
    status = AudioObjectGetPropertyData(device, &rates, 0, NULL, &size, values);
    if (status == noErr) {
        size_t count = size / sizeof(*values);
        info->supportsSourceRate = supports_rate(values, count, sourceRate);
        char uid[256];
        double recorded = 0;
        int hasRecordedRate = 0;
        if (get_string(device, kAudioDevicePropertyDeviceUID, uid, sizeof(uid)) == noErr) {
            hasRecordedRate = recorded_rate(uid, &recorded, error);
            if (hasRecordedRate < 0) {
                free(values);
                return CD_CORE_AUDIO_ERROR;
            }
        }
        if (hasRecordedRate && supports_rate(values, count, recorded))
            info->restoreRate = recorded;
        else if (supports_rate(values, count, FALLBACK_OUTPUT_RATE))
            info->restoreRate = FALLBACK_OUTPUT_RATE;
    }
    free(values);
    if (status != noErr) return fail(error, CD_CORE_AUDIO_ERROR, status, "Cannot read supported sample rates");

    UInt32 terminal = kAudioStreamTerminalTypeUnknown;
    AudioObjectPropertyAddress terminalAddress = address(kAudioStreamPropertyTerminalType,
                                                         kAudioObjectPropertyScopeGlobal);
    if (AudioObjectHasProperty(stream, &terminalAddress)) {
        status = get_property(stream, kAudioStreamPropertyTerminalType, kAudioObjectPropertyScopeGlobal,
                               &terminal, sizeof(terminal));
        if (status != noErr) return fail(error, CD_CORE_AUDIO_ERROR, status, "Cannot inspect the output terminal");
    }
    info->outputTerminalType = terminal;
    info->usesSpeakers = terminal == kAudioStreamTerminalTypeSpeaker ||
                        strcasestr(info->name, "speaker") != NULL;
    AudioObjectPropertyAddress latencyAddress = address(kAudioStreamPropertyLatency,
                                                         kAudioObjectPropertyScopeGlobal);
    if (AudioObjectHasProperty(stream, &latencyAddress)) {
        status = get_property(stream, kAudioStreamPropertyLatency, kAudioObjectPropertyScopeGlobal,
                              &info->streamLatencyFrames, sizeof(info->streamLatencyFrames));
        if (status != noErr)
            return fail(error, CD_CORE_AUDIO_ERROR, status, "Cannot inspect output stream latency");
        info->hasStreamLatency = true;
    }
    AudioObjectPropertyAddress dataSourceAddress = address(kAudioDevicePropertyDataSource,
                                                             kAudioObjectPropertyScopeOutput);
    if (AudioObjectHasProperty(device, &dataSourceAddress)) {
        status = get_property(device, kAudioDevicePropertyDataSource, kAudioObjectPropertyScopeOutput,
                              &info->outputDataSource, sizeof(info->outputDataSource));
        if (status != noErr)
            return fail(error, CD_CORE_AUDIO_ERROR, status, "Cannot inspect the active output source");
        info->hasOutputDataSource = true;
    }
    return CD_OK;
}

static int choose_built_in_device(double sourceRate, CDDeviceInfo *info, AudioStreamID *stream,
                                  CDError *error)
{
    if (!info) return fail(error, CD_INVALID_ARGUMENT, 0, "An output-information destination is required");
    AudioObjectPropertyAddress a = address(kAudioHardwarePropertyDevices, kAudioObjectPropertyScopeGlobal);
    UInt32 size = 0;
    OSStatus status = AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &a, 0, NULL, &size);
    if (status != noErr || size == 0)
        return fail(error, CD_NO_BUILT_IN_OUTPUT, status, "No audio devices are available");
    AudioDeviceID *devices = malloc(size);
    if (!devices) return fail(error, CD_OUT_OF_MEMORY, 0, "Cannot allocate audio-device inspection data");
    status = AudioObjectGetPropertyData(kAudioObjectSystemObject, &a, 0, NULL, &size, devices);
    if (status != noErr) {
        free(devices);
        return fail(error, CD_CORE_AUDIO_ERROR, status, "Cannot enumerate audio devices");
    }
    int bestScore = -1;
    AudioDeviceID defaultOutput = default_output_device();
    AudioDeviceID selected = kAudioObjectUnknown;
    AudioStreamID selectedStream = kAudioObjectUnknown;
    for (size_t i = 0; i < size / sizeof(*devices); ++i) {
        UInt32 transport = 0, alive = 0;
        AudioStreamID candidateStream = kAudioObjectUnknown;
        if (get_property(devices[i], kAudioDevicePropertyTransportType, kAudioObjectPropertyScopeGlobal,
                          &transport, sizeof(transport)) != noErr ||
            transport != kAudioDeviceTransportTypeBuiltIn)
            continue;
        if (get_property(devices[i], kAudioDevicePropertyDeviceIsAlive, kAudioObjectPropertyScopeGlobal,
                          &alive, sizeof(alive)) != noErr || !alive)
            continue;
        if (output_channel_count(devices[i]) < CD_PCM_CHANNELS) continue;
        bool singleStream = false;
        status = get_output_stream(devices[i], &candidateStream, &singleStream);
        if (object_gone(status)) continue;
        if (status != noErr) {
            free(devices);
            return fail(error, CD_CORE_AUDIO_ERROR, status,
                        "Cannot inspect a built-in output's stream topology");
        }
        if (!singleStream) continue;
        char name[256];
        status = get_name(devices[i], name, sizeof(name));
        if (status != noErr) {
            free(devices);
            return fail(error, CD_CORE_AUDIO_ERROR, status, "Cannot identify a built-in audio device");
        }
        int score = cd_output_rank(devices[i] == defaultOutput, name);
        if (score > bestScore) {
            bestScore = score;
            selected = devices[i];
            selectedStream = candidateStream;
        }
    }
    free(devices);
    if (selected == kAudioObjectUnknown)
        return fail(error, CD_NO_BUILT_IN_OUTPUT, 0, "No supported built-in stereo output is available");
    if (stream) *stream = selectedStream;
    return inspect_device(selected, selectedStream, sourceRate, info, error);
}

/* Predicts System Default's path: playing directly needs one stereo output stream that can run at
   the source rate. Start checks the actual formats and reports the path it used. */
static OSStatus predicts_conversion(AudioDeviceID device, const CDDeviceInfo *info, bool *converts)
{
    *converts = true;
    if (!info->supportsSourceRate || info->outputChannels != CD_PCM_CHANNELS) return noErr;
    AudioStreamID only = kAudioObjectUnknown;
    bool singleStream = false;
    OSStatus status = get_output_stream(device, &only, &singleStream);
    if (status == noErr) *converts = !singleStream;
    return status;
}

static int choose_default_device(double sourceRate, CDDeviceInfo *info, AudioStreamID *stream,
                                 CDError *error)
{
    if (!info) return fail(error, CD_INVALID_ARGUMENT, 0, "An output-information destination is required");
    AudioDeviceID device = default_output_device();
    if (device == kAudioObjectUnknown)
        return fail(error, CD_NO_BUILT_IN_OUTPUT, 0, "macOS has no default audio output");
    UInt32 alive = 0;
    OSStatus status = get_property(device, kAudioDevicePropertyDeviceIsAlive, kAudioObjectPropertyScopeGlobal,
                                   &alive, sizeof(alive));
    if (status != noErr || !alive)
        return fail(error, CD_NO_BUILT_IN_OUTPUT, status, "The default output is not available");
    AudioStreamID first = kAudioObjectUnknown;
    status = get_first_output_stream(device, &first);
    if (status != noErr)
        return fail(error, CD_NO_BUILT_IN_OUTPUT, status, "The default output has no output stream");
    int result = inspect_device(device, first, sourceRate, info, error);
    if (result != CD_OK) return result;
    status = predicts_conversion(device, info, &info->converts);
    if (status != noErr)
        return fail(error, CD_CORE_AUDIO_ERROR, status, "Cannot inspect the default output streams");
    if (stream) *stream = first;
    return CD_OK;
}

static int choose_uid_device(const char *uid, double sourceRate, CDDeviceInfo *info, AudioStreamID *stream,
                             CDError *error)
{
    if (!uid || !uid[0] || !info)
        return fail(error, CD_INVALID_ARGUMENT, 0, "A wired output UID and information destination are required");
    AudioDeviceID device = kAudioObjectUnknown;
    OSStatus status = device_for_uid(uid, &device);
    if (status != noErr || device == kAudioObjectUnknown)
        return fail(error, CD_OUTPUT_UNAVAILABLE, status, "The selected wired output is not connected");
    UInt32 alive = 0, transport = 0;
    status = get_property(device, kAudioDevicePropertyDeviceIsAlive, kAudioObjectPropertyScopeGlobal,
                          &alive, sizeof(alive));
    if (status != noErr || !alive)
        return fail(error, CD_OUTPUT_UNAVAILABLE, status, "The selected wired output is not available");
    status = get_property(device, kAudioDevicePropertyTransportType, kAudioObjectPropertyScopeGlobal,
                          &transport, sizeof(transport));
    if (status != noErr)
        return fail(error, CD_CORE_AUDIO_ERROR, status, "Cannot read the selected output transport");
    if (transport != kAudioDeviceTransportTypeBuiltIn && transport != kAudioDeviceTransportTypeUSB &&
        transport != kAudioDeviceTransportTypeHDMI && transport != kAudioDeviceTransportTypeDisplayPort &&
        transport != kAudioDeviceTransportTypeThunderbolt)
        return fail(error, CD_OUTPUT_UNAVAILABLE, 0, "The selected output is not a supported wired device");
    AudioStreamID first = kAudioObjectUnknown;
    status = get_first_output_stream(device, &first);
    if (status != noErr)
        return fail(error, CD_OUTPUT_UNAVAILABLE, status, "The selected wired output has no output stream");
    int result = inspect_device(device, first, sourceRate, info, error);
    if (result != CD_OK) return result;
    if (info->outputChannels < CD_PCM_CHANNELS)
        return fail_output(error, CD_FORMAT_UNAVAILABLE, 0, "The ", CD_TARGET_DEVICE, info->name,
                           " has no stereo output channels");
    if (stream) *stream = first;
    return CD_OK;
}

static int choose_device(CDOutputTarget target, const char *uid, double sourceRate, CDDeviceInfo *info,
                         AudioStreamID *stream, CDError *error)
{
    if (!valid_source_rate(sourceRate))
        return fail(error, CD_INVALID_ARGUMENT, 0, "A valid source sample rate is required");
    switch (target) {
    case CD_TARGET_BUILT_IN:
        return choose_built_in_device(sourceRate, info, stream, error);
    case CD_TARGET_SYSTEM_DEFAULT:
        return choose_default_device(sourceRate, info, stream, error);
    case CD_TARGET_DEVICE:
        return choose_uid_device(uid, sourceRate, info, stream, error);
    }
    return fail(error, CD_INVALID_ARGUMENT, 0, "Unknown audio output target");
}

/* Re-describes a chosen output, such as after a rate change. */
static int describe_output(CDOutputTarget target, const char *uid, AudioDeviceID device,
                           AudioStreamID stream, double sourceRate, CDDeviceInfo *info, CDError *error)
{
    int result = inspect_device(device, stream, sourceRate, info, error);
    if (result == CD_OK && target == CD_TARGET_SYSTEM_DEFAULT) {
        OSStatus status = predicts_conversion(device, info, &info->converts);
        if (status != noErr)
            return fail(error, CD_CORE_AUDIO_ERROR, status, "Cannot inspect the default output streams");
    }
    if (result == CD_OK && target == CD_TARGET_DEVICE && uid && strcmp(uid, info->uid) != 0)
        return fail(error, CD_CONFIGURATION_CHANGED, 0, "The selected wired output changed identity");
    return result;
}

int cd_audio_inspect(CDOutputTarget target, const char *uid, double sourceRate, CDDeviceInfo *info,
                     CDError *error)
{
    return choose_device(target, uid, sourceRate, info, NULL, error);
}

int cd_audio_copy_output_devices(double sourceRate, CDDeviceInfo **result, size_t *resultCount, CDError *error)
{
    if (!result || !resultCount)
        return fail(error, CD_INVALID_ARGUMENT, 0, "Output-list destinations are required");
    *result = NULL;
    *resultCount = 0;
    if (!valid_source_rate(sourceRate))
        return fail(error, CD_INVALID_ARGUMENT, 0, "A valid source sample rate is required");
    *result = NULL;
    *resultCount = 0;

    AudioObjectPropertyAddress a = address(kAudioHardwarePropertyDevices, kAudioObjectPropertyScopeGlobal);
    UInt32 size = 0;
    OSStatus status = AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &a, 0, NULL, &size);
    if (status != noErr)
        return fail(error, CD_CORE_AUDIO_ERROR, status, "Cannot enumerate audio devices");
    if (size == 0) return CD_OK;
    AudioDeviceID *devices = malloc(size);
    if (!devices) return fail(error, CD_OUT_OF_MEMORY, 0, "Cannot allocate audio-device list");
    status = AudioObjectGetPropertyData(kAudioObjectSystemObject, &a, 0, NULL, &size, devices);
    if (status != noErr) {
        free(devices);
        return fail(error, CD_CORE_AUDIO_ERROR, status, "Cannot read audio devices");
    }

    size_t capacity = size / sizeof(*devices);
    CDDeviceInfo *outputs = calloc(capacity, sizeof(*outputs));
    if (!outputs) {
        free(devices);
        return fail(error, CD_OUT_OF_MEMORY, 0, "Cannot allocate output inspection data");
    }
    size_t count = 0;
    AudioDeviceID defaultOutput = default_output_device();
    for (size_t i = 0; i < capacity; ++i) {
        UInt32 transport = 0, alive = 0;
        if (get_property(devices[i], kAudioDevicePropertyTransportType, kAudioObjectPropertyScopeGlobal,
                         &transport, sizeof(transport)) != noErr)
            continue;
        if (get_property(devices[i], kAudioDevicePropertyDeviceIsAlive, kAudioObjectPropertyScopeGlobal,
                         &alive, sizeof(alive)) != noErr || !alive)
            continue;

        AudioStreamID stream = kAudioObjectUnknown;
        status = get_first_output_stream(devices[i], &stream);
        if (status == kAudioHardwareUnsupportedOperationError || object_gone(status)) continue;
        if (status != noErr) {
            free(outputs);
            free(devices);
            return fail(error, CD_CORE_AUDIO_ERROR, status, "Cannot inspect an output stream");
        }

        CDDeviceInfo info;
        CDError inspectionError = {0};
        int inspected = inspect_device(devices[i], stream, sourceRate, &info, &inspectionError);
        if (inspected != CD_OK && object_gone(inspectionError.systemStatus)) continue;
        if (inspected != CD_OK) {
            free(outputs);
            free(devices);
            if (error) *error = inspectionError;
            return inspected;
        }
        info.isDefaultOutput = devices[i] == defaultOutput;
        outputs[count++] = info;
    }
    free(devices);
    if (count == 0) {
        free(outputs);
        return CD_OK;
    }
    *result = outputs;
    *resultCount = count;
    return CD_OK;
}

void cd_audio_free_output_devices(CDDeviceInfo *devices)
{
    free(devices);
}

static int wait_for_rate(AudioDeviceID device, double wanted, CDError *error)
{
    for (int attempt = 0; attempt < 100; ++attempt) {
        double actual = 0;
        OSStatus status = get_property(device, kAudioDevicePropertyNominalSampleRate,
                                        kAudioObjectPropertyScopeGlobal, &actual, sizeof(actual));
        if (status != noErr) return fail(error, CD_CORE_AUDIO_ERROR, status, "Cannot verify the output sample rate");
        if (actual == wanted) return CD_OK;
        sleep_milliseconds(10);
    }
    return fail(error, CD_FORMAT_UNAVAILABLE, 0, "The output did not switch to the requested sample rate");
}

static OSStatus core_audio_resolve_device(void *context, const char *uid, AudioDeviceID *device)
{
    (void)context;
    return device_for_uid(uid, device);
}

static OSStatus core_audio_read_rate(void *context, AudioDeviceID device, double *rate)
{
    (void)context;
    return get_property(device, kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal,
                        rate, sizeof(*rate));
}

static OSStatus core_audio_read_hog_owner(void *context, AudioDeviceID device, int32_t *owner)
{
    (void)context;
    pid_t process = -1;
    OSStatus status = read_hog_owner(device, &process);
    *owner = (int32_t)process;
    return status;
}

static bool core_audio_owned_by_another_process(void *context, int32_t owner)
{
    (void)context;
    return owned_by_another_process((pid_t)owner);
}

static OSStatus core_audio_set_rate(void *context, AudioDeviceID device, double rate)
{
    (void)context;
    return set_property(device, kAudioDevicePropertyNominalSampleRate, &rate, sizeof(rate));
}

static int core_audio_wait_for_rate(void *context, AudioDeviceID device, double rate, CDError *error)
{
    (void)context;
    return wait_for_rate(device, rate, error);
}

static OSStatus core_audio_resolve_single_stream(void *context, AudioDeviceID device, AudioStreamID *stream)
{
    (void)context;
    bool singleStream = false;
    OSStatus status = get_output_stream(device, stream, &singleStream);
    if (status == noErr && !singleStream) return kAudioHardwareUnsupportedOperationError;
    return status;
}

static OSStatus core_audio_read_stream_format(void *context, AudioStreamID stream, bool physical,
                                              AudioStreamBasicDescription *format)
{
    (void)context;
    AudioObjectPropertySelector selector = physical
        ? kAudioStreamPropertyPhysicalFormat : kAudioStreamPropertyVirtualFormat;
    return get_property(stream, selector, kAudioObjectPropertyScopeGlobal, format, sizeof(*format));
}

static OSStatus core_audio_set_stream_format(void *context, AudioStreamID stream, bool physical,
                                             const AudioStreamBasicDescription *format)
{
    (void)context;
    AudioObjectPropertySelector selector = physical
        ? kAudioStreamPropertyPhysicalFormat : kAudioStreamPropertyVirtualFormat;
    return set_property(stream, selector, format, sizeof(*format));
}

static int core_audio_wait_for_stream_format(void *context, AudioStreamID stream, bool physical,
                                             const AudioStreamBasicDescription *wanted, CDError *error)
{
    for (int attempt = 0; attempt < 100; ++attempt) {
        AudioStreamBasicDescription actual = {0};
        OSStatus status = core_audio_read_stream_format(context, stream, physical, &actual);
        if (status != noErr)
            return fail(error, CD_CORE_AUDIO_ERROR, status, "Cannot verify the output stream format");
        if (cd_audio_stream_formats_equal(&actual, wanted)) return CD_OK;
        sleep_milliseconds(10);
    }
    return fail(error, CD_FORMAT_UNAVAILABLE, 0, "The output did not switch to the requested stream format");
}

static int core_audio_remember_rate(void *context, const char *uid, double originalRate, double appliedRate,
                                    CDError *error)
{
    (void)context;
    return remember_rate(uid, originalRate, appliedRate, error);
}

static int core_audio_remember_formats(void *context, const char *uid, double originalRate, double appliedRate,
                                       const AudioStreamBasicDescription *originalVirtualFormat,
                                       const AudioStreamBasicDescription *appliedVirtualFormat,
                                       const AudioStreamBasicDescription *originalPhysicalFormat,
                                       const AudioStreamBasicDescription *appliedPhysicalFormat, CDError *error)
{
    (void)context;
    return remember_stream_formats(uid, originalRate, appliedRate, originalVirtualFormat, appliedVirtualFormat,
                                   originalPhysicalFormat, appliedPhysicalFormat, error);
}

static int core_audio_clear_formats(void *context, const char *uid, CDError *error)
{
    (void)context;
    return clear_stream_formats(uid, error);
}

static int core_audio_forget_rate(void *context, const char *uid, CDError *error)
{
    (void)context;
    return forget_rate(uid, error);
}

static bool core_audio_object_gone(void *context, OSStatus status)
{
    (void)context;
    return object_gone(status);
}

static const CDRateRecoveryOperations core_audio_rate_operations = {
    .resolveDevice = core_audio_resolve_device,
    .readRate = core_audio_read_rate,
    .readHogOwner = core_audio_read_hog_owner,
    .ownedByAnotherProcess = core_audio_owned_by_another_process,
    .setRate = core_audio_set_rate,
    .waitForRate = core_audio_wait_for_rate,
    .rememberRate = core_audio_remember_rate,
    .resolveSingleStream = core_audio_resolve_single_stream,
    .readStreamFormat = core_audio_read_stream_format,
    .setStreamFormat = core_audio_set_stream_format,
    .waitForStreamFormat = core_audio_wait_for_stream_format,
    .rememberFormats = core_audio_remember_formats,
    .clearFormats = core_audio_clear_formats,
    .forgetRate = core_audio_forget_rate,
    .objectGone = core_audio_object_gone
};

/* Restores a changed rate only when the device still has the rate this app applied. */
static int restore_rate(AudioDeviceID device, pid_t owner, const char *uid, double originalRate,
                        double appliedRate, CDError *error)
{
    CDRateRecord record = {0};
    snprintf(record.uid, sizeof(record.uid), "%s", uid ? uid : "");
    record.originalRate = originalRate;
    record.appliedRate = appliedRate;
    CDError savedError = {0};
    if (saved_rate_record(uid, &record, &savedError)) {
        originalRate = record.originalRate;
        appliedRate = record.appliedRate;
    } else if (savedError.code != 0) {
        if (error) *error = savedError;
        return savedError.code;
    } else {
        snprintf(record.uid, sizeof(record.uid), "%s", uid ? uid : "");
        record.originalRate = originalRate;
        record.appliedRate = appliedRate;
    }
    return cd_rate_restore_device(device, (int32_t)owner, &record, &core_audio_rate_operations, error);
}

static int restore_stream_formats(AudioDeviceID device, pid_t owner, const char *uid, CDError *error)
{
    CDRateRecord record = {0};
    CDError savedError = {0};
    if (!saved_rate_record(uid, &record, &savedError)) {
        if (savedError.code != 0) {
            if (error) *error = savedError;
            return savedError.code;
        }
        return CD_OK;
    }
    return cd_rate_restore_stream_formats(
        device, (int32_t)owner, &record, &core_audio_rate_operations, error);
}

static int restore_output_rates(bool recoveryOnly, CDError *error)
{
    CDRateRecord records[RATE_RECORD_CAPACITY];
    pthread_mutex_lock(&rate_records_lock);
    if (!load_rate_records_locked(error)) {
        pthread_mutex_unlock(&rate_records_lock);
        return CD_CORE_AUDIO_ERROR;
    }
    size_t count = 0;
    for (size_t i = 0; i < rate_record_count; ++i) {
        if (!recoveryOnly || rate_records[i].recoveryPending) records[count++] = rate_records[i];
    }
    pthread_mutex_unlock(&rate_records_lock);

    return cd_rate_restore_records(records, count, recoveryOnly, &core_audio_rate_operations, error);
}

int cd_audio_recover_output_rates(CDError *error)
{
    return restore_output_rates(true, error);
}

int cd_audio_restore_output_rates(CDError *error)
{
    return restore_output_rates(false, error);
}

int cd_audio_match_source_rate(CDOutputTarget target, const char *targetUID, double sourceRate,
                               CDDeviceInfo *info, CDError *error)
{
    AudioStreamID stream = kAudioObjectUnknown;
    int result = choose_device(target, targetUID, sourceRate, info, &stream, error);
    if (result != CD_OK) return result;
    if (!info->supportsSourceRate)
        return fail_source_rate(error, CD_FORMAT_UNAVAILABLE, "The ", target, info->name,
                                " does not support native ", sourceRate);
    if (owned_by_another_process(info->hogOwner))
        return fail_output(error, CD_OUTPUT_UNAVAILABLE, 0, "Another app has exclusive use of the ", target,
                           info->name, "");
    if (info->sampleRate == sourceRate) return CD_OK;
    /* Unlike Play's, this rate has no Stop to restore it, so quitting must be able to find the output. */
    char uid[256];
    OSStatus status = get_string(info->deviceID, kAudioDevicePropertyDeviceUID, uid, sizeof(uid));
    if (status != noErr || uid[0] == '\0')
        return fail_output(error, CD_CORE_AUDIO_ERROR, status, "Cannot identify the ", target, info->name, "");
    bool recorded = false;
    result = cd_rate_apply(info->deviceID, uid, info->sampleRate, sourceRate,
                           &core_audio_rate_operations, &recorded, error);
    if (result != CD_OK) {
        include_selected_output_name(error, target, info->name);
        return result;
    }
    (void)recorded;
    return describe_output(target, targetUID, info->deviceID, stream, sourceRate, info, error);
}

int cd_audio_restore_output_rate(CDOutputTarget target, const char *targetUID, double sourceRate,
                                 CDDeviceInfo *info, CDError *error)
{
    AudioStreamID stream = kAudioObjectUnknown;
    int result = choose_device(target, targetUID, sourceRate, info, &stream, error);
    if (result != CD_OK) return result;
    if (info->restoreRate == 0)
        return info->sampleRate == sourceRate
            ? fail_output(error, CD_FORMAT_UNAVAILABLE, 0, "The ", target, info->name,
                          " has no other sample rate to restore")
            : CD_OK;
    /* Without a UID nothing can be recorded, so the fallback rate is restored. */
    char uid[256] = {0};
    (void)get_string(info->deviceID, kAudioDevicePropertyDeviceUID, uid, sizeof(uid));
    result = restore_rate(info->deviceID, info->hogOwner, uid, info->restoreRate, sourceRate, error);
    if (result != CD_OK) {
        include_selected_output_name(error, target, info->name);
        return result;
    }
    return describe_output(target, targetUID, info->deviceID, stream, sourceRate, info, error);
}

CDOutputStreamTopology cd_audio_classify_output_stream_query(int32_t status, size_t byteCount)
{
    if (status != noErr || byteCount == 0 || byteCount % sizeof(AudioStreamID) != 0)
        return CD_STREAM_TOPOLOGY_QUERY_ERROR;
    return byteCount == sizeof(AudioStreamID)
        ? CD_STREAM_TOPOLOGY_SINGLE
        : CD_STREAM_TOPOLOGY_MULTIPLE;
}

bool cd_audio_format_supports_native_playback(CDSourceFormat source,
                                             const AudioStreamBasicDescription *virtualFormat,
                                             const AudioStreamBasicDescription *physicalFormat,
                                             bool channelMapped)
{
    if (!virtualFormat || !physicalFormat || !cd_source_format_supported(source)) return false;
    bool planar = (virtualFormat->mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0;
    UInt32 channels = virtualFormat->mChannelsPerFrame;
    return virtualFormat->mSampleRate == source.sampleRate && physicalFormat->mSampleRate == source.sampleRate &&
        virtualFormat->mFormatID == kAudioFormatLinearPCM &&
        (virtualFormat->mFormatFlags & kAudioFormatFlagIsFloat) &&
        !(virtualFormat->mFormatFlags & kAudioFormatFlagIsBigEndian) &&
        virtualFormat->mBitsPerChannel == 32 && channels >= source.channelsPerFrame &&
        (channelMapped || channels == source.channelsPerFrame) &&
        virtualFormat->mBytesPerFrame == sizeof(float) * (planar ? 1 : channels) &&
        virtualFormat->mFramesPerPacket == 1 &&
        physicalFormat->mFormatID == kAudioFormatLinearPCM &&
        physicalFormat->mBitsPerChannel >= source.bitsPerChannel && physicalFormat->mChannelsPerFrame >= channels;
}

static bool format_range_supports_rate(const AudioStreamRangedDescription *format, double rate)
{
    return isfinite(format->mSampleRateRange.mMinimum) &&
        isfinite(format->mSampleRateRange.mMaximum) &&
        format->mSampleRateRange.mMinimum <= rate && format->mSampleRateRange.mMaximum >= rate;
}

bool cd_audio_choose_stereo_formats(CDSourceFormat source,
                                    const AudioStreamRangedDescription *virtualFormats, size_t virtualCount,
                                    const AudioStreamRangedDescription *physicalFormats, size_t physicalCount,
                                    AudioStreamBasicDescription *virtualFormat,
                                    AudioStreamBasicDescription *physicalFormat)
{
    if (!virtualFormats || !physicalFormats || !virtualFormat || !physicalFormat ||
        !cd_source_format_supported(source))
        return false;
    for (size_t i = 0; i < virtualCount; ++i) {
        AudioStreamBasicDescription candidateVirtual = virtualFormats[i].mFormat;
        bool planar = (candidateVirtual.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0;
        if (!format_range_supports_rate(&virtualFormats[i], source.sampleRate) ||
            candidateVirtual.mFormatID != kAudioFormatLinearPCM ||
            !(candidateVirtual.mFormatFlags & kAudioFormatFlagIsFloat) ||
            (candidateVirtual.mFormatFlags & kAudioFormatFlagIsBigEndian) ||
            candidateVirtual.mBitsPerChannel != 32 || candidateVirtual.mChannelsPerFrame != source.channelsPerFrame ||
            candidateVirtual.mFramesPerPacket != 1 ||
            candidateVirtual.mBytesPerFrame != sizeof(float) * (planar ? 1 : source.channelsPerFrame))
            continue;
        candidateVirtual.mSampleRate = source.sampleRate;

        for (size_t j = 0; j < physicalCount; ++j) {
            AudioStreamBasicDescription candidatePhysical = physicalFormats[j].mFormat;
            if (!format_range_supports_rate(&physicalFormats[j], source.sampleRate) ||
                candidatePhysical.mFormatID != kAudioFormatLinearPCM ||
                !(candidatePhysical.mFormatFlags & kAudioFormatFlagIsSignedInteger) ||
                (candidatePhysical.mFormatFlags & (kAudioFormatFlagIsFloat | kAudioFormatFlagIsBigEndian)) ||
                candidatePhysical.mBitsPerChannel < source.bitsPerChannel ||
                candidatePhysical.mChannelsPerFrame != source.channelsPerFrame)
                continue;
            candidatePhysical.mSampleRate = source.sampleRate;
            *virtualFormat = candidateVirtual;
            *physicalFormat = candidatePhysical;
            return true;
        }
    }
    return false;
}

static int validate_format(CDPlayback *p, CDError *error)
{
    AudioStreamBasicDescription virtualFormat = {0}, physicalFormat = {0};
    OSStatus status = get_property(p->stream, kAudioStreamPropertyVirtualFormat,
                                    kAudioObjectPropertyScopeGlobal, &virtualFormat, sizeof(virtualFormat));
    if (status != noErr) return fail(error, CD_CORE_AUDIO_ERROR, status, "Cannot read the Core Audio virtual format");
    status = get_property(p->stream, kAudioStreamPropertyPhysicalFormat,
                           kAudioObjectPropertyScopeGlobal, &physicalFormat, sizeof(physicalFormat));
    if (status != noErr) return fail(error, CD_CORE_AUDIO_ERROR, status, "Cannot read the Core Audio physical format");
    if (!cd_audio_format_supports_native_playback(p->source.format, &virtualFormat, &physicalFormat,
                                                  p->channelMapped)) {
        char rateName[32];
        char after[192];
        rate_text(p->source.format.sampleRate, rateName, sizeof(rateName));
        snprintf(after, sizeof(after),
                 " must expose compatible Float32 and physical PCM at %s with at least two channels", rateName);
        return fail_output(error, CD_FORMAT_UNAVAILABLE, 0, "The ", p->target, p->outputName, after);
    }
    return CD_OK;
}

static uint32_t physical_output_bits(CDPlayback *p)
{
    AudioStreamBasicDescription physicalFormat = {0};
    if (!p->stream ||
        get_property(p->stream, kAudioStreamPropertyPhysicalFormat,
                     kAudioObjectPropertyScopeGlobal, &physicalFormat, sizeof(physicalFormat)) != noErr ||
        physicalFormat.mFormatID != kAudioFormatLinearPCM)
        return 0;
    return physicalFormat.mBitsPerChannel;
}

static int copy_available_stream_formats(AudioStreamID stream, AudioObjectPropertySelector selector,
                                         AudioStreamRangedDescription **formats, size_t *count,
                                         CDError *error)
{
    *formats = NULL;
    *count = 0;
    AudioObjectPropertyAddress property = address(selector, kAudioObjectPropertyScopeGlobal);
    UInt32 size = 0;
    OSStatus status = AudioObjectGetPropertyDataSize(stream, &property, 0, NULL, &size);
    if (status == kAudioHardwareUnknownPropertyError || status == kAudioHardwareUnsupportedOperationError)
        return CD_OK;
    if (status != noErr)
        return fail(error, CD_CORE_AUDIO_ERROR, status, "Cannot inspect available output stream formats");
    if (size == 0) return CD_OK;
    if (size % sizeof(AudioStreamRangedDescription) != 0)
        return fail(error, CD_CORE_AUDIO_ERROR, 0, "The output returned a malformed stream-format list");
    AudioStreamRangedDescription *values = malloc(size);
    if (!values) return fail(error, CD_OUT_OF_MEMORY, 0, "Cannot allocate output stream-format data");
    UInt32 actualSize = size;
    status = AudioObjectGetPropertyData(stream, &property, 0, NULL, &actualSize, values);
    if (status != noErr) {
        free(values);
        return fail(error, CD_CORE_AUDIO_ERROR, status, "Cannot read available output stream formats");
    }
    if (actualSize % sizeof(AudioStreamRangedDescription) != 0 || actualSize > size) {
        free(values);
        return fail(error, CD_CORE_AUDIO_ERROR, 0, "The output returned a malformed stream-format list");
    }
    *formats = values;
    *count = actualSize / sizeof(AudioStreamRangedDescription);
    return CD_OK;
}

static int choose_stereo_stream_formats(AudioStreamID stream, CDSourceFormat source,
                                        AudioStreamBasicDescription *originalVirtualFormat,
                                        AudioStreamBasicDescription *appliedVirtualFormat,
                                        AudioStreamBasicDescription *originalPhysicalFormat,
                                        AudioStreamBasicDescription *appliedPhysicalFormat,
                                        bool *found, CDError *error)
{
    *found = false;
    AudioStreamRangedDescription *virtualFormats = NULL, *physicalFormats = NULL;
    size_t virtualCount = 0, physicalCount = 0;
    int result = copy_available_stream_formats(stream, kAudioStreamPropertyAvailableVirtualFormats,
                                               &virtualFormats, &virtualCount, error);
    if (result == CD_OK)
        result = copy_available_stream_formats(stream, kAudioStreamPropertyAvailablePhysicalFormats,
                                               &physicalFormats, &physicalCount, error);
    if (result == CD_OK && virtualCount && physicalCount) {
        *found = cd_audio_choose_stereo_formats(source, virtualFormats, virtualCount, physicalFormats,
                                                physicalCount, appliedVirtualFormat, appliedPhysicalFormat);
    }
    free(virtualFormats);
    free(physicalFormats);
    if (result != CD_OK || !*found) return result;

    OSStatus status = get_property(stream, kAudioStreamPropertyVirtualFormat,
                                   kAudioObjectPropertyScopeGlobal, originalVirtualFormat,
                                   sizeof(*originalVirtualFormat));
    if (status != noErr)
        return fail(error, CD_CORE_AUDIO_ERROR, status, "Cannot save the original virtual stream format");
    status = get_property(stream, kAudioStreamPropertyPhysicalFormat,
                          kAudioObjectPropertyScopeGlobal, originalPhysicalFormat,
                          sizeof(*originalPhysicalFormat));
    if (status != noErr)
        return fail(error, CD_CORE_AUDIO_ERROR, status, "Cannot save the original physical stream format");
    return CD_OK;
}

static OSStatus property_changed(AudioObjectID object, UInt32 count,
                                 const AudioObjectPropertyAddress addresses[], void *context)
{
    (void)object;
    (void)count;
    (void)addresses;
    CDPlayback *p = context;
    atomic_store_explicit(&p->configurationChanged, true, memory_order_release);
    return noErr;
}

static int add_watches(CDPlayback *p, CDError *error)
{
    AudioObjectID objects[WATCH_COUNT] = {
        kAudioObjectSystemObject, kAudioObjectSystemObject, p->device, p->device, p->device,
        p->device, p->device, p->stream, p->stream
    };
    AudioObjectPropertySelector selectors[WATCH_COUNT] = {
        kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultOutputDevice,
        kAudioDevicePropertyNominalSampleRate, kAudioDevicePropertyDeviceIsAlive, kAudioDevicePropertyHogMode,
        kAudioDevicePropertyDataSource, kAudioDevicePropertyStreams,
        kAudioStreamPropertyVirtualFormat, kAudioStreamPropertyPhysicalFormat
    };
    for (size_t i = 0; i < WATCH_COUNT; ++i) {
        p->watches[i].object = objects[i];
        AudioObjectPropertyScope scope = selectors[i] == kAudioDevicePropertyDataSource ||
            selectors[i] == kAudioDevicePropertyStreams
            ? kAudioObjectPropertyScopeOutput : kAudioObjectPropertyScopeGlobal;
        p->watches[i].address = address(selectors[i], scope);
        if (selectors[i] == kAudioDevicePropertyDataSource &&
            !AudioObjectHasProperty(objects[i], &p->watches[i].address))
            continue;
        OSStatus status = AudioObjectAddPropertyListener(objects[i], &p->watches[i].address, property_changed, p);
        if (status != noErr) return fail(error, CD_CORE_AUDIO_ERROR, status, "Cannot monitor audio-device changes");
        p->watches[i].registered = true;
    }
    return CD_OK;
}

static void zero_output(AudioBufferList *output)
{
    for (UInt32 i = 0; i < output->mNumberBuffers; ++i)
        if (output->mBuffers[i].mData)
            memset(output->mBuffers[i].mData, 0, output->mBuffers[i].mDataByteSize);
}

static size_t buffer_target(const CDPlayback *p, uint64_t remaining)
{
    return remaining < p->prefillFrames ? (size_t)remaining : p->prefillFrames;
}

/* The frames in a callback's buffers, or 0 when the layout is invalid, which the PCM path reports. */
static size_t output_frames(const AudioBufferList *output)
{
    size_t frames = 0;
    for (UInt32 i = 0; i < output->mNumberBuffers; ++i) {
        const AudioBuffer *buffer = &output->mBuffers[i];
        UInt32 channels = buffer->mNumberChannels;
        if (channels == 0 || !buffer->mData || buffer->mDataByteSize % (channels * sizeof(float)) != 0)
            return 0;
        size_t count = buffer->mDataByteSize / (channels * sizeof(float));
        if (i == 0) frames = count;
        else if (count != frames) return 0;
    }
    return frames;
}

uint64_t cd_output_lead_in_frames(uint32_t transportType, double sourceRate)
{
    if (transportType != kAudioDeviceTransportTypeHDMI && transportType != kAudioDeviceTransportTypeDisplayPort)
        return 0;
    if (!(sourceRate > 0)) return 0;
    return (uint64_t)(sourceRate * CD_PLAYBACK_LEAD_IN_MILLISECONDS / 1000.0 + 0.5);
}

void cd_playback_set_lead_in_frames(CDPlayback *p, uint64_t frames)
{
    if (p) p->leadInFrames = frames;
}

void cd_playback_set_test_output_bits(CDPlayback *p, uint32_t bitsPerChannel)
{
    if (!p || p->producerStarted || p->running) return;
    p->hdcdOutputSupports20 = bitsPerChannel >= 20;
    atomic_store_explicit(&p->physicalOutputBits, bitsPerChannel, memory_order_release);
}

void cd_playback_memory(const CDPlayback *p, CDPlaybackMemory *memory)
{
    if (!p || !memory) return;
    memory->ring = cd_ring_page_usage(p->ring);
    memory->ringWide = cd_ring_is_wide(p->ring);
    memory->hdcdStartup = cd_page_buffer_usage(&p->hdcdStartup);
}

int cd_playback_set_hdcd_decode_enabled(CDPlayback *p, bool enabled, CDError *error)
{
    if (!p) return fail(error, CD_INVALID_ARGUMENT, 0, "A playback engine is required");
    if (p->producerStarted || p->running || p->ioProc || p->converter)
        return fail(error, CD_INVALID_ARGUMENT, 0, "Stop playback before changing the HDCD setting");
    p->hdcdDecodeEnabled = enabled;
    return CD_OK;
}

void cd_playback_render(CDPlayback *p, AudioBufferList *output)
{
    if (!atomic_load_explicit(&p->outputEnabled, memory_order_acquire) ||
        atomic_load_explicit(&p->readTimedOut, memory_order_acquire) ||
        atomic_load_explicit(&p->producerFailed, memory_order_acquire) ||
        atomic_load_explicit(&p->configurationChanged, memory_order_acquire)) {
        zero_output(output);
        return;
    }
    uint64_t before = atomic_load_explicit(&p->renderedFrames, memory_order_relaxed);
    uint64_t remaining = p->totalFrames - p->startFrame - before;
    if (remaining == 0) {
        zero_output(output);
        return;
    }
    /* The lead-in overlaps start-up buffering and leaves the source, clock and counters untouched. */
    uint64_t leadIn = atomic_load_explicit(&p->leadInRemaining, memory_order_relaxed);
    size_t leadInBlock = leadIn > 0 ? output_frames(output) : 0;
    if (leadInBlock > 0) {
        zero_output(output);
        atomic_store_explicit(&p->leadInRemaining, leadIn > leadInBlock ? leadIn - leadInBlock : 0,
                              memory_order_relaxed);
        if (atomic_load_explicit(&p->buffering, memory_order_acquire) &&
            cd_ring_available(p->ring) >= buffer_target(p, remaining))
            atomic_store_explicit(&p->buffering, false, memory_order_release);
        return;
    }
    if (atomic_load_explicit(&p->buffering, memory_order_acquire)) {
        if (cd_ring_available(p->ring) < buffer_target(p, remaining)) {
            zero_output(output);
            return;
        }
        atomic_store_explicit(&p->buffering, false, memory_order_release);
    }
    uint64_t checksum = atomic_load_explicit(&p->pcmChecksum, memory_order_relaxed);
    UInt32 outputChannels = 0;
    for (UInt32 i = 0; i < output->mNumberBuffers; ++i)
        outputChannels += output->mBuffers[i].mNumberChannels;
    CDRenderResult result = p->channelMapped && outputChannels > CD_PCM_CHANNELS
        ? cd_ring_render_mapped(p->ring, output, p->silentOutput, checksum,
                                p->preferredLeftChannel, p->preferredRightChannel)
        : cd_ring_render(p->ring, output, p->silentOutput, checksum);
    if (!result.validLayout) {
        atomic_store_explicit(&p->invalidOutput, true, memory_order_release);
        return;
    }
    if (!atomic_load_explicit(&p->outputEnabled, memory_order_acquire) ||
        atomic_load_explicit(&p->readTimedOut, memory_order_acquire) ||
        atomic_load_explicit(&p->producerFailed, memory_order_acquire) ||
        atomic_load_explicit(&p->configurationChanged, memory_order_acquire)) {
        zero_output(output);
        return;
    }
    if (p->silentOutput) zero_output(output);
    if (p->silentOutput && result.consumedFrames > 0) {
        atomic_store_explicit(&p->pcmChecksum, result.pcmChecksum, memory_order_release);
    }
    atomic_fetch_add_explicit(&p->renderedFrames, result.consumedFrames, memory_order_relaxed);
    size_t expected = remaining < result.requestedFrames ? (size_t)remaining : result.requestedFrames;
    if (result.consumedFrames < expected) {
        atomic_fetch_add_explicit(&p->underrunFrames, expected - result.consumedFrames, memory_order_relaxed);
        atomic_fetch_add_explicit(&p->bufferingEpoch, 1, memory_order_relaxed);
        atomic_store_explicit(&p->buffering, true, memory_order_release);
    }
}

static OSStatus render_audio(AudioDeviceID device, const AudioTimeStamp *now,
                             const AudioBufferList *input, const AudioTimeStamp *inputTime,
                             AudioBufferList *output, const AudioTimeStamp *outputTime, void *context)
{
    (void)device;
    (void)now;
    (void)input;
    (void)inputTime;
    (void)outputTime;
    cd_playback_render(context, output);
    return noErr;
}

/* The HAL output unit's render callback: the same samples, which macOS then converts. */
static OSStatus render_converted(void *context, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *time,
                                 UInt32 bus, UInt32 frames, AudioBufferList *output)
{
    (void)flags;
    (void)time;
    (void)bus;
    (void)frames;
    cd_playback_render(context, output);
    return noErr;
}

void cd_playback_enable_output(CDPlayback *p)
{
    atomic_store_explicit(&p->outputEnabled, true, memory_order_release);
}

void cd_playback_request_stop(CDPlayback *p)
{
    atomic_store_explicit(&p->outputEnabled, false, memory_order_release);
    /* Set under the lock, so a producer between its stop check and its wait cannot miss the signal. */
    pthread_mutex_lock(&p->producerWaitLock);
    atomic_store_explicit(&p->producerStop, true, memory_order_release);
    pthread_cond_broadcast(&p->producerWake);
    pthread_mutex_unlock(&p->producerWaitLock);
}

bool cd_playback_read_cancelled(const CDPlayback *p)
{
    return atomic_load_explicit(&p->producerStop, memory_order_acquire);
}

static void publish_hdcd_status(CDPlayback *p, CDHDCDStatus status)
{
    p->hdcdKnownStatus = status;
    atomic_store_explicit(&p->hdcdStatus, status, memory_order_release);
}

static void process_hdcd_samples(CDPlayback *p, const int16_t *input, size_t frames,
                                 int32_t *decoded)
{
    size_t sampleCount = frames * CD_PCM_CHANNELS;
    for (size_t i = 0; i < sampleCount; ++i) decoded[i] = input[i];
    hdcd_process(p->hdcd, (int *)decoded, (int)frames);
    if (UINT64_MAX - p->hdcdScannedFrames < frames) p->hdcdScannedFrames = UINT64_MAX;
    else p->hdcdScannedFrames += frames;
    int detected = hdcd_detected(p->hdcd);
    if (detected == HDCD_EFFECTUAL) {
        publish_hdcd_status(p, CD_HDCD_EFFECTUAL);
    } else if (detected == HDCD_NO_EFFECT && p->hdcdKnownStatus != CD_HDCD_EFFECTUAL) {
        publish_hdcd_status(p, CD_HDCD_NO_EFFECT);
    } else if (p->hdcdKnownStatus == CD_HDCD_DETECTING &&
               p->hdcdScannedFrames >= CD_PLAYBACK_PREFILL_FRAMES) {
        publish_hdcd_status(p, CD_HDCD_NONE);
    }
}

static bool write_output_frames(CDPlayback *p, const void *samples, size_t frames, bool decoded)
{
    size_t offset = 0;
    while (offset < frames && !atomic_load_explicit(&p->producerStop, memory_order_acquire)) {
        size_t writable = cd_ring_writable(p->ring);
        if (writable == 0) {
            sleep_milliseconds(1);
            continue;
        }
        size_t count = frames - offset;
        if (count > writable) count = writable;
        size_t written = decoded
            ? cd_ring_write_32(p->ring, (const int32_t *)samples + offset * CD_PCM_CHANNELS, count)
            : cd_ring_write(p->ring, (const int16_t *)samples + offset * CD_PCM_CHANNELS, count);
        if (written != count) return false;
        offset += count;
    }
    return offset == frames;
}

#define HDCD_STARTUP_SAMPLES ((size_t)CD_PLAYBACK_PREFILL_FRAMES * CD_PCM_CHANNELS)

static size_t hdcd_startup_decoded_offset(void)
{
    return cd_page_round(HDCD_STARTUP_SAMPLES * sizeof(int16_t));
}

static size_t hdcd_startup_bytes(void)
{
    return hdcd_startup_decoded_offset() + HDCD_STARTUP_SAMPLES * sizeof(int32_t);
}

static int16_t *hdcd_startup_raw(CDPlayback *p)
{
    return p->hdcdStartup.base;
}

static int32_t *hdcd_startup_decoded(CDPlayback *p)
{
    return (int32_t *)((char *)p->hdcdStartup.base + hdcd_startup_decoded_offset());
}

static bool flush_hdcd_startup(CDPlayback *p)
{
    bool written = p->hdcdDecodeActive
        ? write_output_frames(p, hdcd_startup_decoded(p), p->hdcdStartupFrames, true)
        : write_output_frames(p, hdcd_startup_raw(p), p->hdcdStartupFrames, false);
    /* The decision is final for this disc, so the start-up audio is not needed again. */
    (void)cd_page_buffer_claim(&p->hdcdStartup, 0);
    return written;
}

static void finalize_hdcd_detection(CDPlayback *p)
{
    if (p->hdcdKnownStatus == CD_HDCD_DETECTING) {
        int detected = hdcd_detected(p->hdcd);
        publish_hdcd_status(p, detected == HDCD_NO_EFFECT ? CD_HDCD_NO_EFFECT : CD_HDCD_NONE);
    }
}

static void finish_hdcd_decision(CDPlayback *p)
{
    finalize_hdcd_detection(p);
    p->hdcdDecisionMade = true;
    p->hdcdDecodeActive = p->hdcdDecodeEnabled && p->hdcdOutputSupports20 &&
        p->hdcdKnownStatus == CD_HDCD_EFFECTUAL;
    p->hdcdPendingDecode = false;
    atomic_store_explicit(&p->hdcdDecoded, p->hdcdDecodeActive, memory_order_release);
}

/* Paced reads wait about as long as the ring takes to play down to its watermark, rather than polling.
   The margin covers the output consuming whole buffers, so the producer seldom wakes just short of the
   watermark, and keeps a stalled output from waking it more often than every 5 ms. The ceiling notices
   a ring that drains faster than real time within 100 ms. */
#define PRODUCER_WAIT_MARGIN_NANOS (5u * 1000000u)
#define PRODUCER_MAX_WAIT_NANOS (100u * 1000000u)

static void producer_wait(CDPlayback *p, size_t frames)
{
    double nanos = (double)frames / p->source.format.sampleRate * 1e9 + PRODUCER_WAIT_MARGIN_NANOS;
    uint64_t wait = nanos >= PRODUCER_MAX_WAIT_NANOS ? PRODUCER_MAX_WAIT_NANOS : (uint64_t)nanos;
    struct timespec relative = {(time_t)(wait / 1000000000u), (long)(wait % 1000000000u)};
    pthread_mutex_lock(&p->producerWaitLock);
    if (!atomic_load_explicit(&p->producerStop, memory_order_acquire))
        pthread_cond_timedwait_relative_np(&p->producerWake, &p->producerWaitLock, &relative);
    pthread_mutex_unlock(&p->producerWaitLock);
}

static void *produce_audio(void *context)
{
    CDPlayback *p = context;
    int16_t samples[PRODUCER_CHUNK * CD_PCM_CHANNELS];
    int32_t decodedSamples[PRODUCER_CHUNK * CD_PCM_CHANNELS];
    uint64_t cursor = p->startFrame;
    size_t lowWatermark = p->bufferFrames - PRODUCER_CHUNK;
    if (p->source.readPacing == CD_READ_BURST) {
        lowWatermark = p->bufferFrames / 3;
        if (lowWatermark > CD_PLAYBACK_BURST_LOW_FRAMES)
            lowWatermark = CD_PLAYBACK_BURST_LOW_FRAMES;
    }
    if (lowWatermark < p->prefillFrames) lowWatermark = p->prefillFrames;
    bool refilling = true;
    while (cursor < p->totalFrames && !atomic_load_explicit(&p->producerStop, memory_order_acquire)) {
        if (p->source.readPacing != CD_READ_UNPACED && !refilling) {
            size_t available = cd_ring_available(p->ring);
            if (available > lowWatermark) {
                producer_wait(p, available - lowWatermark);
                continue;
            }
            refilling = true;
        }
        size_t writable = cd_ring_writable(p->ring);
        size_t count = writable;
        if (count > PRODUCER_CHUNK) count = PRODUCER_CHUNK;
        if (count > p->totalFrames - cursor) count = (size_t)(p->totalFrames - cursor);
        if (count == 0) {
            sleep_milliseconds(5);
            continue;
        }
        CDPCMReadContext request = {
            p, cd_ring_available(p->ring),
            atomic_load_explicit(&p->buffering, memory_order_acquire),
            cursor == p->startFrame
        };
        CDPCMReadResult reply = {0};
        CDError error = {0};
        int result = p->source.read(p->source.context, cursor, samples, count, &request, &reply, &error);
        size_t generated = reply.framesRead;
        if (atomic_load_explicit(&p->producerStop, memory_order_acquire)) break;
        if (result != CD_OK) {
            if (error.code == CD_OK)
                fail(&error, CD_PRODUCER_ERROR, result, "The PCM source failed without an error code");
            else if (!error.message[0])
                snprintf(error.message, sizeof(error.message), "The PCM source failed (code %d).", error.code);
        } else if (generated == 0 || generated > count) {
            result = fail(&error, CD_PRODUCER_ERROR, 0, "The PCM source returned an invalid frame count");
        } else if (p->source.hdcdEligible) {
            if (reply.trackNumber != 0 && p->hdcdTrackNumber != 0 &&
                reply.trackNumber != p->hdcdTrackNumber) {
                hdcd_reset(p->hdcd);
                if (p->hdcdPendingDecode && p->hdcdDecodeEnabled && p->hdcdOutputSupports20) {
                    p->hdcdDecodeActive = true;
                    p->hdcdPendingDecode = false;
                    atomic_store_explicit(&p->hdcdDecodeFrame, cursor, memory_order_release);
                    atomic_store_explicit(&p->hdcdDecoded, true, memory_order_release);
                }
            }
            if (reply.trackNumber != 0) p->hdcdTrackNumber = reply.trackNumber;
            size_t offset = 0;
            bool endOfSource = cursor + generated >= p->totalFrames;
            while (offset < generated && result == CD_OK) {
                if (!p->hdcdDecisionMade) {
                    size_t remaining = CD_PLAYBACK_PREFILL_FRAMES - p->hdcdStartupFrames;
                    size_t segment = generated - offset;
                    if (segment > remaining) segment = remaining;
                    process_hdcd_samples(p, samples + offset * CD_PCM_CHANNELS, segment, decodedSamples);
                    memcpy(hdcd_startup_raw(p) + p->hdcdStartupFrames * CD_PCM_CHANNELS,
                           samples + offset * CD_PCM_CHANNELS,
                           segment * CD_PCM_CHANNELS * sizeof(int16_t));
                    memcpy(hdcd_startup_decoded(p) + p->hdcdStartupFrames * CD_PCM_CHANNELS,
                           decodedSamples, segment * CD_PCM_CHANNELS * sizeof(int32_t));
                    p->hdcdStartupFrames += segment;
                    offset += segment;
                    if (p->hdcdStartupFrames == CD_PLAYBACK_PREFILL_FRAMES ||
                        (endOfSource && offset == generated)) {
                        finish_hdcd_decision(p);
                        if (!flush_hdcd_startup(p) &&
                            !atomic_load_explicit(&p->producerStop, memory_order_acquire))
                            result = fail(&error, CD_PRODUCER_ERROR, 0,
                                          "The HDCD startup buffer could not enter the PCM ring");
                    }
                } else {
                    size_t segment = generated - offset;
                    process_hdcd_samples(p, samples + offset * CD_PCM_CHANNELS, segment, decodedSamples);
                    if (p->hdcdDecodeEnabled && !p->hdcdDecodeActive && p->hdcdOutputSupports20 &&
                        p->hdcdKnownStatus == CD_HDCD_EFFECTUAL)
                        p->hdcdPendingDecode = true;
                    bool written = p->hdcdDecodeActive
                        ? write_output_frames(p, decodedSamples, segment, true)
                        : write_output_frames(p, samples + offset * CD_PCM_CHANNELS, segment, false);
                    if (!written && !atomic_load_explicit(&p->producerStop, memory_order_acquire))
                        result = fail(&error, CD_PRODUCER_ERROR, 0,
                                      "The PCM read-ahead buffer could not accept the source frames");
                    offset += segment;
                }
            }
            if (result == CD_OK && endOfSource) finalize_hdcd_detection(p);
        } else {
            if (!write_output_frames(p, samples, generated, false) &&
                !atomic_load_explicit(&p->producerStop, memory_order_acquire))
                result = fail(&error, CD_PRODUCER_ERROR, 0,
                              "The PCM read-ahead buffer could not accept the source frames");
        }
        if (result == CD_OK && p->levels &&
            !cd_level_table_record_block(
                p->levels, atomic_load_explicit(&p->levelRun, memory_order_acquire),
                cursor, samples, generated)) {
            result = fail(&error, CD_PRODUCER_ERROR, 0, "Cannot record source audio levels");
        }
        if (result != CD_OK) {
            error.message[sizeof(error.message) - 1] = '\0';
            p->producerError = error;
            atomic_store_explicit(&p->producerFailed, true, memory_order_release);
            break;
        }
        cursor += generated;
        atomic_fetch_add_explicit(&p->concealedSectors, reply.concealedSectors, memory_order_relaxed);
        if (reply.unverified) atomic_store_explicit(&p->unverified, true, memory_order_release);
        atomic_store_explicit(&p->producedFrames, cursor - p->startFrame, memory_order_release);
        if (generated == writable) refilling = false;
    }
    return NULL;
}

typedef struct {
    size_t trackCount;
    CDDemoTrack tracks[];
} CDDemoSource;

static int read_demo(void *context, uint64_t frame, int16_t *stereo,
                     size_t capacityFrames, const CDPCMReadContext *request,
                     CDPCMReadResult *result, CDError *error)
{
    (void)request;
    (void)error;
    CDDemoSource *source = context;
    result->framesRead = cd_demo_render(source->tracks, source->trackCount, frame, stereo, capacityFrames);
    return CD_OK;
}

CDPlayback *cd_playback_create(const CDDemoTrack *tracks, size_t trackCount,
                               size_t bufferFrames, CDError *error)
{
    return cd_playback_create_with_levels(tracks, trackCount, bufferFrames, NULL, error);
}

CDPlayback *cd_playback_create_with_levels(const CDDemoTrack *tracks, size_t trackCount,
                                           size_t bufferFrames, CDLevelTable *levels,
                                           CDError *error)
{
    if (!tracks || trackCount == 0 || trackCount > 99 || bufferFrames < PRODUCER_CHUNK) {
        fail(error, CD_INVALID_ARGUMENT, 0, "A disc and a buffer of at least 4096 frames are required");
        return NULL;
    }
    for (size_t i = 0; i < trackCount; ++i) {
        if (!tracks[i].frameCount || !isfinite(tracks[i].frequency) || tracks[i].frequency < 0 ||
            tracks[i].frequency >= CD_DA_SAMPLE_RATE / 2.0 || tracks[i].amplitude < 0) {
            fail(error, CD_INVALID_ARGUMENT, 0, "The simulated disc contains an invalid PCM track");
            return NULL;
        }
    }
    uint64_t total = cd_demo_total_frames(tracks, trackCount);
    if (!total) {
        fail(error, CD_INVALID_ARGUMENT, 0, "The simulated disc duration is invalid");
        return NULL;
    }
    CDDemoSource *demo = malloc(sizeof(*demo) + trackCount * sizeof(*tracks));
    if (!demo) {
        fail(error, CD_OUT_OF_MEMORY, 0, "Cannot allocate the simulated PCM source");
        return NULL;
    }
    demo->trackCount = trackCount;
    memcpy(demo->tracks, tracks, trackCount * sizeof(*tracks));
    CDPCMSource source = {
        .frameCount = total, .context = demo, .read = read_demo, .destroy = free,
        .readPacing = CD_READ_UNPACED, .format = cd_source_format_compact_disc()
    };
    CDPlayback *playback = cd_playback_create_source_with_levels(
        source, bufferFrames, false, levels, error);
    if (!playback) free(demo);
    return playback;
}

CDPlayback *cd_playback_create_source(CDPCMSource source, size_t bufferFrames,
                                      bool silentOutput, CDError *error)
{
    return cd_playback_create_source_with_levels(source, bufferFrames, silentOutput, NULL, error);
}

static void release_hdcd_storage(CDPlayback *p)
{
    if (p->hdcd) hdcd_free(p->hdcd);
    cd_page_buffer_unmap(&p->hdcdStartup);
}

CDPlayback *cd_playback_create_source_with_levels(CDPCMSource source, size_t bufferFrames,
                                                  bool silentOutput, CDLevelTable *levels,
                                                  CDError *error)
{
    if (!source.read || source.frameCount == 0 || bufferFrames < PRODUCER_CHUNK) {
        fail(error, CD_INVALID_ARGUMENT, 0, "A PCM source and a buffer of at least 4096 frames are required");
        return NULL;
    }
    if (source.readPacing != CD_READ_UNPACED && source.readPacing != CD_READ_STEADY &&
        source.readPacing != CD_READ_BURST) {
        fail(error, CD_INVALID_ARGUMENT, 0, "The PCM read pacing policy is invalid");
        return NULL;
    }
    if (!cd_source_format_supported(source.format)) {
        char message[sizeof(((CDError *)0)->message)];
        char rateName[32], supportedRateName[32];
        rate_text(source.format.sampleRate, rateName, sizeof(rateName));
        rate_text(CD_DA_SAMPLE_RATE, supportedRateName, sizeof(supportedRateName));
        snprintf(message, sizeof(message),
                 "This disc's audio (%s, %u-bit, %u channels) is not supported. "
                 "CD Player plays %s %u-bit stereo audio CDs",
                 rateName, source.format.bitsPerChannel, source.format.channelsPerFrame,
                 supportedRateName, CD_DA_BITS_PER_CHANNEL);
        fail(error, CD_FORMAT_UNAVAILABLE, 0, message);
        return NULL;
    }
    CDPlayback *p = calloc(1, sizeof(*p));
    if (!p) {
        fail(error, CD_OUT_OF_MEMORY, 0, "Cannot allocate the playback engine");
        return NULL;
    }
    p->ring = cd_ring_create(bufferFrames);
    if (!p->ring) {
        free(p);
        fail(error, CD_OUT_OF_MEMORY, 0, "Cannot allocate the PCM read-ahead buffer");
        return NULL;
    }
    p->source = source;
    p->totalFrames = source.frameCount;
    p->levels = levels;
    p->bufferFrames = bufferFrames;
    p->prefillFrames = bufferFrames < CD_PLAYBACK_PREFILL_FRAMES ? bufferFrames : CD_PLAYBACK_PREFILL_FRAMES;
    p->silentOutput = silentOutput;
    p->hdcdDecodeEnabled = true;
    p->hdcdKnownStatus = source.hdcdEligible ? CD_HDCD_DETECTING : CD_HDCD_NOT_APPLICABLE;
    if (source.hdcdEligible) {
        p->hdcd = hdcd_new();
        bool mapped = cd_page_buffer_map(&p->hdcdStartup, hdcd_startup_bytes());
        if (!p->hdcd || !mapped) {
            release_hdcd_storage(p);
            cd_ring_destroy(p->ring);
            free(p);
            fail(error, CD_OUT_OF_MEMORY, 0, "Cannot allocate the HDCD detection buffer");
            return NULL;
        }
        hdcd_logger_detach(p->hdcd);
    }
    atomic_init(&p->outputEnabled, false);
    atomic_init(&p->levelRun, 0);
    atomic_init(&p->buffering, true);
    atomic_init(&p->bufferingEpoch, 0);
    atomic_init(&p->producedFrames, 0);
    atomic_init(&p->readTimedOut, false);
    atomic_init(&p->producerStop, false);
    atomic_init(&p->producerFailed, false);
    atomic_init(&p->configurationChanged, false);
    atomic_init(&p->invalidOutput, false);
    atomic_init(&p->renderedFrames, 0);
    atomic_init(&p->underrunFrames, 0);
    atomic_init(&p->pcmChecksum, CD_PCM_CHECKSUM_INITIAL);
    atomic_init(&p->concealedSectors, 0);
    atomic_init(&p->unverified, false);
    atomic_init(&p->hdcdStatus, p->hdcdKnownStatus);
    atomic_init(&p->hdcdDecoded, false);
    atomic_init(&p->hdcdDecodeFrame, 0);
    atomic_init(&p->physicalOutputBits, 0);
    p->leadInFrames = 0;
    atomic_init(&p->leadInRemaining, 0);
    if (!atomic_is_lock_free(&p->pcmChecksum) || !atomic_is_lock_free(&p->levelRun) ||
        !atomic_is_lock_free(&p->hdcdStatus) || !atomic_is_lock_free(&p->hdcdDecoded) ||
        !atomic_is_lock_free(&p->hdcdDecodeFrame) || !atomic_is_lock_free(&p->physicalOutputBits)) {
        release_hdcd_storage(p);
        cd_ring_destroy(p->ring);
        free(p);
        fail(error, CD_CORE_AUDIO_ERROR, 0, "Lock-free playback tracking is unavailable");
        return NULL;
    }
    int waitStatus = pthread_mutex_init(&p->producerWaitLock, NULL);
    if (waitStatus == 0) {
        waitStatus = pthread_cond_init(&p->producerWake, NULL);
        if (waitStatus != 0) pthread_mutex_destroy(&p->producerWaitLock);
    }
    if (waitStatus != 0) {
        release_hdcd_storage(p);
        cd_ring_destroy(p->ring);
        free(p);
        fail(error, CD_PRODUCER_ERROR, waitStatus, "Cannot create the PCM producer's wait");
        return NULL;
    }
    return p;
}

static void remember_failure(int *result, CDError *error, OSStatus status, const char *message)
{
    if (*result == CD_OK) *result = fail(error, CD_CORE_AUDIO_ERROR, status, message);
}

static int stop_workers(CDPlayback *p, CDError *error)
{
    int result = CD_OK;
    cd_playback_request_stop(p);
    if (p->ioProc) {
        OSStatus status = AudioDeviceStop(p->device, p->ioProc);
        if (status != noErr && !object_gone(status))
            remember_failure(&result, error, status, "Cannot stop the Core Audio callback");
        status = AudioDeviceDestroyIOProcID(p->device, p->ioProc);
        if (status == noErr || object_gone(status)) {
            p->ioProc = NULL;
            p->running = false;
        } else {
            remember_failure(&result, error, status, "Cannot detach the Core Audio callback");
        }
    }
    if (p->converter) {
        /* Stopping waits for a callback in progress; disposing guarantees no later one. */
        OSStatus status = AudioOutputUnitStop(p->converter);
        if (status != noErr && !object_gone(status))
            remember_failure(&result, error, status, "Cannot stop the audio output unit");
        (void)AudioUnitUninitialize(p->converter);
        status = AudioComponentInstanceDispose(p->converter);
        if (status == noErr) {
            p->converter = NULL;
            p->running = false;
        } else {
            remember_failure(&result, error, status, "Cannot release the audio output unit");
        }
    }
    if (p->producerStarted) {
        int status = pthread_join(p->producer, NULL);
        if (status == 0) p->producerStarted = false;
        else remember_failure(&result, error, status, "Cannot join the PCM producer");
    }
    return result;
}

static void fill_snapshot(CDPlayback *p, CDPlaybackSnapshot *snapshot)
{
    if (!snapshot) return;
    snapshot->currentFrame = p->startFrame + atomic_load_explicit(&p->renderedFrames, memory_order_relaxed);
    snapshot->underrunFrames = atomic_load_explicit(&p->underrunFrames, memory_order_relaxed);
    snapshot->bufferedFrames = cd_ring_available(p->ring);
    snapshot->finished = snapshot->currentFrame == p->totalFrames;
    snapshot->leadIn = atomic_load_explicit(&p->leadInRemaining, memory_order_relaxed) > 0;
    snapshot->buffering = !snapshot->finished &&
        atomic_load_explicit(&p->outputEnabled, memory_order_acquire) &&
        atomic_load_explicit(&p->buffering, memory_order_acquire);
    snapshot->running = p->running;
    snapshot->concealedSectors = atomic_load_explicit(&p->concealedSectors, memory_order_acquire);
    snapshot->unverified = atomic_load_explicit(&p->unverified, memory_order_acquire);
    snapshot->pcmChecksum = atomic_load_explicit(&p->pcmChecksum, memory_order_acquire);
    snapshot->outputRestorePending = false;
    snapshot->hdcdStatus = (CDHDCDStatus)atomic_load_explicit(&p->hdcdStatus, memory_order_acquire);
    snapshot->hdcdDecoded = atomic_load_explicit(&p->hdcdDecoded, memory_order_acquire) &&
        snapshot->currentFrame >= atomic_load_explicit(&p->hdcdDecodeFrame, memory_order_acquire);
    snapshot->physicalOutputBits = atomic_load_explicit(&p->physicalOutputBits, memory_order_acquire);
}

static int check_read_progress(CDPlayback *p, const CDPlaybackSnapshot *snapshot, CDError *error)
{
    if (atomic_load_explicit(&p->readTimedOut, memory_order_acquire))
        return fail(error, CD_READ_TIMEOUT, 0, "The PCM source made no read progress for 10 seconds while buffering.");
    if (!snapshot->buffering || snapshot->bufferedFrames >= buffer_target(p, p->totalFrames - snapshot->currentFrame)) {
        p->waitStartedNanos = 0;
        return CD_OK;
    }
    uint64_t now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    uint64_t epoch = atomic_load_explicit(&p->bufferingEpoch, memory_order_acquire);
    uint64_t progress = atomic_load_explicit(&p->producedFrames, memory_order_acquire);
    /* A new wait cannot inherit time spent playing from an intentionally full buffer. */
    if (!p->waitStartedNanos || epoch != p->observedBufferingEpoch || progress != p->observedProducedFrames) {
        p->waitStartedNanos = now;
        p->observedBufferingEpoch = epoch;
        p->observedProducedFrames = progress;
    } else if (now - p->waitStartedNanos >= (uint64_t)CD_PLAYBACK_STALL_SECONDS * 1000000000u) {
        atomic_store_explicit(&p->readTimedOut, true, memory_order_release);
        cd_playback_request_stop(p);
        return fail(error, CD_READ_TIMEOUT, 0, "The PCM source made no read progress for 10 seconds while buffering.");
    }
    return CD_OK;
}

/* The record keeps the original rate and formats, so recovery after wake can still restore them;
   without one there is nothing to recover, and the failure stands. */
static bool restore_after_wake(const CDPlayback *p, CDPlaybackSnapshot *snapshot)
{
    CDRateRecord record = {0};
    CDError recordError = {0};
    if (!saved_rate_record(p->uid, &record, &recordError)) return false;
    if (mark_rate_for_recovery(p->uid, &recordError) != CD_OK) return false;
    if (snapshot) snapshot->outputRestorePending = true;
    return true;
}

static int stop_playback(CDPlayback *p, CDPlaybackSnapshot *snapshot, bool beforeSleep, CDError *error)
{
    if (!p) return fail(error, CD_INVALID_ARGUMENT, 0, "A playback engine is required");
    int result = stop_workers(p, error);
    if (!p->producerStarted && !p->ioProc && !p->converter) {
        /* Nothing writes or renders until the next prepare claims the memory again. */
        cd_ring_release(p->ring);
        (void)cd_page_buffer_claim(&p->hdcdStartup, 0);
    }
    fill_snapshot(p, snapshot);
    for (size_t i = 0; i < WATCH_COUNT; ++i) {
        CDPropertyWatch *watch = &p->watches[i];
        if (!watch->registered) continue;
        OSStatus status = AudioObjectRemovePropertyListener(watch->object, &watch->address, property_changed, p);
        if (status == noErr || object_gone(status)) watch->registered = false;
        else remember_failure(&result, error, status, "Cannot remove an audio-device listener");
    }
    if (p->device == kAudioObjectUnknown) return result;

    pid_t owner = -1;
    OSStatus status = read_hog_owner(p->device, &owner);
    if (object_gone(status)) {
        /* A crash record remains eligible for restoration when this output is reconnected. */
        if (p->changedRate || p->changedFormat) {
            CDError recoveryError = {0};
            int recoveryResult = mark_rate_for_recovery(p->uid, &recoveryError);
            if (recoveryResult != CD_OK && result == CD_OK) {
                include_selected_output_name(&recoveryError, p->target, p->outputName);
                result = recoveryResult;
                if (error) *error = recoveryError;
            }
        }
        p->hasOutput = false;
        p->changedRate = false;
        p->changedFormat = false;
        p->device = kAudioObjectUnknown;
        return result;
    }
    if (status != noErr) {
        remember_failure(&result, error, status, "Cannot inspect ownership while restoring the output");
        include_selected_output_name(error, p->target, p->outputName);
        return result;
    }
    if (p->changedRate) {
        CDError rateError = {0};
        int rateResult = restore_rate(
            p->device, owner, p->uid, p->originalRate, p->source.format.sampleRate, &rateError
        );
        if (rateResult != CD_OK && beforeSleep && restore_after_wake(p, snapshot)) rateResult = CD_OK;
        if (rateResult != CD_OK && result == CD_OK) {
            include_selected_output_name(&rateError, p->target, p->outputName);
            result = rateResult;
            if (error) *error = rateError;
        }
        p->changedRate = false;
        p->changedFormat = false;
    } else if (p->changedFormat) {
        CDError formatError = {0};
        int formatResult = restore_stream_formats(p->device, owner, p->uid, &formatError);
        if (formatResult != CD_OK && beforeSleep && restore_after_wake(p, snapshot)) formatResult = CD_OK;
        if (formatResult != CD_OK && result == CD_OK) {
            include_selected_output_name(&formatError, p->target, p->outputName);
            result = formatResult;
            if (error) *error = formatError;
        }
        p->changedFormat = false;
    }
    p->hasOutput = false;
    p->device = kAudioObjectUnknown;
    return result;
}

int cd_playback_stop(CDPlayback *p, CDPlaybackSnapshot *snapshot, CDError *error)
{
    return stop_playback(p, snapshot, false, error);
}

int cd_playback_stop_before_sleep(CDPlayback *p, CDPlaybackSnapshot *snapshot, CDError *error)
{
    return stop_playback(p, snapshot, true, error);
}

static int failed_start(CDPlayback *p, int result, CDError *error)
{
    include_selected_output_name(error, p->target, p->outputName);
    CDError cleanup = {0};
    if (cd_playback_stop(p, NULL, &cleanup) != CD_OK && error) {
        size_t used = strlen(error->message);
        snprintf(error->message + used, sizeof(error->message) - used,
                 " Cleanup: %.160s", cleanup.message);
    }
    return result;
}

int cd_playback_prepare(CDPlayback *p, uint64_t startFrame, CDError *error)
{
    if (!p || startFrame >= p->totalFrames)
        return fail(error, CD_INVALID_ARGUMENT, 0, "Playback must start within the disc");
    if (p->producerStarted || p->ioProc || p->converter)
        return fail(error, CD_INVALID_ARGUMENT, 0, "Stop playback before preparing another producer");
    /* Only HDCD decoding produces more than 16 bits, and only these settings let it begin. */
    bool decodingPossible = p->hdcd && p->hdcdDecodeEnabled && p->hdcdOutputSupports20;
    bool collectsHDCDStartup = decodingPossible && p->hdcdKnownStatus == CD_HDCD_DETECTING;
    if (!cd_ring_configure(p->ring, decodingPossible))
        return fail(error, CD_OUT_OF_MEMORY, errno, "Cannot reclaim the PCM read-ahead buffer");
    if (p->hdcd && !cd_page_buffer_claim(&p->hdcdStartup, collectsHDCDStartup ? hdcd_startup_bytes() : 0))
        return fail(error, CD_OUT_OF_MEMORY, errno, "Cannot reclaim the HDCD detection buffer");
    uint32_t levelRun = p->levels ? cd_level_table_begin_run(p->levels) : 0;
    if (p->levels && levelRun == 0)
        return fail(error, CD_PRODUCER_ERROR, 0, "Cannot start source audio-level tracking");
    p->startFrame = startFrame;
    atomic_store_explicit(&p->levelRun, levelRun, memory_order_release);
    atomic_store_explicit(&p->outputEnabled, false, memory_order_release);
    atomic_store_explicit(&p->buffering, true, memory_order_release);
    atomic_store_explicit(&p->bufferingEpoch, 0, memory_order_relaxed);
    atomic_store_explicit(&p->producedFrames, 0, memory_order_relaxed);
    atomic_store_explicit(&p->readTimedOut, false, memory_order_release);
    p->observedBufferingEpoch = 0;
    p->observedProducedFrames = 0;
    p->waitStartedNanos = 0;
    atomic_store_explicit(&p->producerStop, false, memory_order_release);
    atomic_store_explicit(&p->producerFailed, false, memory_order_release);
    memset(&p->producerError, 0, sizeof(p->producerError));
    atomic_store_explicit(&p->invalidOutput, false, memory_order_release);
    atomic_store_explicit(&p->renderedFrames, 0, memory_order_relaxed);
    atomic_store_explicit(&p->underrunFrames, 0, memory_order_relaxed);
    atomic_store_explicit(&p->pcmChecksum, CD_PCM_CHECKSUM_INITIAL, memory_order_release);
    atomic_store_explicit(&p->concealedSectors, 0, memory_order_relaxed);
    atomic_store_explicit(&p->unverified, false, memory_order_release);
    atomic_store_explicit(&p->leadInRemaining, p->leadInFrames, memory_order_relaxed);
    if (p->hdcd) {
        hdcd_reset(p->hdcd);
        p->hdcdStartupFrames = 0;
        p->hdcdScannedFrames = 0;
        p->hdcdTrackNumber = 0;
        p->hdcdPendingDecode = false;
        p->hdcdDecisionMade = !collectsHDCDStartup;
        p->hdcdDecodeActive = p->hdcdDecodeEnabled && p->hdcdOutputSupports20 &&
            p->hdcdKnownStatus == CD_HDCD_EFFECTUAL;
        atomic_store_explicit(&p->hdcdStatus, p->hdcdKnownStatus, memory_order_release);
        /* Decoding decided at start-up, or carried from an earlier run, covers the run from its first
           frame; only a later track boundary moves this. */
        atomic_store_explicit(&p->hdcdDecodeFrame, startFrame, memory_order_release);
        atomic_store_explicit(&p->hdcdDecoded, p->hdcdDecodeActive, memory_order_release);
    }
    int status = pthread_create(&p->producer, NULL, produce_audio, p);
    if (status != 0)
        return fail(error, CD_PRODUCER_ERROR, status, "Cannot start the PCM producer");
    p->producerStarted = true;
    return CD_OK;
}

uint32_t cd_playback_level_run(const CDPlayback *p)
{
    return p ? atomic_load_explicit(&p->levelRun, memory_order_acquire) : 0;
}

/* Plays through Apple's HAL output unit on the chosen device, which converts source-rate stereo Float32
   to whatever the device runs at. It maps the two channels to the device's first two. */
static int start_converter(CDPlayback *p, CDError *error)
{
    const char *name = p->target == CD_TARGET_DEVICE ? p->outputName : "default output";
    AudioComponentDescription description = {
        kAudioUnitType_Output, kAudioUnitSubType_HALOutput, kAudioUnitManufacturer_Apple, 0, 0
    };
    AudioComponent component = AudioComponentFindNext(NULL, &description);
    if (!component) return fail(error, CD_CORE_AUDIO_ERROR, 0, "The macOS audio output unit is unavailable");
    OSStatus status = AudioComponentInstanceNew(component, &p->converter);
    if (status != noErr) {
        p->converter = NULL;
        return fail(error, CD_CORE_AUDIO_ERROR, status, "Cannot create the macOS audio output unit");
    }
    status = AudioUnitSetProperty(p->converter, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global,
                                  0, &p->device, sizeof(p->device));
    if (status != noErr)
        return fail(error, CD_CORE_AUDIO_ERROR, status, "Cannot attach the audio output unit to the selected device");
    AudioStreamBasicDescription format = {
        .mSampleRate = p->source.format.sampleRate,
        .mFormatID = kAudioFormatLinearPCM,
        .mFormatFlags = kAudioFormatFlagsNativeFloatPacked,
        .mBytesPerPacket = sizeof(float) * CD_PCM_CHANNELS,
        .mFramesPerPacket = 1,
        .mBytesPerFrame = sizeof(float) * CD_PCM_CHANNELS,
        .mChannelsPerFrame = CD_PCM_CHANNELS,
        .mBitsPerChannel = 32
    };
    status = AudioUnitSetProperty(p->converter, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0,
                                  &format, sizeof(format));
    if (status != noErr) {
        char message[96];
        char rateName[32];
        rate_text(p->source.format.sampleRate, rateName, sizeof(rateName));
        snprintf(message, sizeof(message), "Cannot give the audio output unit %s stereo", rateName);
        return fail(error, CD_CORE_AUDIO_ERROR, status, message);
    }
    if (p->channelMapped) {
        AudioStreamBasicDescription outputFormat = {0};
        UInt32 size = sizeof(outputFormat);
        status = AudioUnitGetProperty(p->converter, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output,
                                      0, &outputFormat, &size);
        if (status != noErr)
            return fail(error, CD_CORE_AUDIO_ERROR, status, "Cannot inspect the selected device's output layout");
        UInt32 channels = outputFormat.mChannelsPerFrame;
        if (channels < CD_PCM_CHANNELS || p->preferredLeftChannel >= channels ||
            p->preferredRightChannel >= channels || p->preferredLeftChannel == p->preferredRightChannel)
            return fail(error, CD_FORMAT_UNAVAILABLE, 0,
                        "The selected device does not expose its preferred stereo channels to macOS");
        if (channels > UINT32_MAX / sizeof(SInt32))
            return fail(error, CD_OUT_OF_MEMORY, 0, "The selected device's channel map is too large");
        SInt32 *map = malloc((size_t)channels * sizeof(*map));
        if (!map) return fail(error, CD_OUT_OF_MEMORY, 0, "Cannot allocate the selected device's channel map");
        for (UInt32 i = 0; i < channels; ++i) map[i] = -1;
        map[p->preferredLeftChannel] = 0;
        map[p->preferredRightChannel] = 1;
        status = AudioUnitSetProperty(p->converter, kAudioOutputUnitProperty_ChannelMap,
                                      kAudioUnitScope_Output, 0, map, channels * sizeof(*map));
        free(map);
        if (status != noErr) {
            char message[384];
            snprintf(message, sizeof(message), "Cannot map stereo to the preferred channels of %s", name);
            return fail(error, CD_CORE_AUDIO_ERROR, status, message);
        }
    }
    AURenderCallbackStruct callback = {render_converted, p};
    status = AudioUnitSetProperty(p->converter, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0,
                                  &callback, sizeof(callback));
    if (status != noErr)
        return fail(error, CD_CORE_AUDIO_ERROR, status, "Cannot attach the audio output unit callback");
    status = AudioUnitInitialize(p->converter);
    if (status != noErr)
        return fail(error, CD_CORE_AUDIO_ERROR, status, "Cannot initialize the audio output unit");
    status = AudioOutputUnitStart(p->converter);
    if (status != noErr) {
        char message[384];
        snprintf(message, sizeof(message), "Cannot start %s", name);
        return fail(error, CD_CORE_AUDIO_ERROR, status, message);
    }
    return CD_OK;
}

int cd_playback_start(CDPlayback *p, uint64_t startFrame, CDOutputTarget target, const char *uid, bool decodeHDCD,
                      CDDeviceInfo *info, CDError *error)
{
    if (!p || !info || startFrame >= p->totalFrames)
        return fail(error, CD_INVALID_ARGUMENT, 0, "Playback must start within the disc");
    double sourceRate = p->source.format.sampleRate;
    if (target != CD_TARGET_BUILT_IN && target != CD_TARGET_SYSTEM_DEFAULT && target != CD_TARGET_DEVICE)
        return fail(error, CD_INVALID_ARGUMENT, 0, "Unknown audio output target");
    if (target == CD_TARGET_DEVICE && (!uid || !uid[0] || strlen(uid) >= sizeof(p->targetUID)))
        return fail(error, CD_INVALID_ARGUMENT, 0, "A valid wired output UID is required");
    int result = stop_workers(p, error);
    if (result != CD_OK) return failed_start(p, result, error);
    p->hdcdDecodeEnabled = decodeHDCD;
    /* Moving to another target releases the kept output first, restoring a rate playback changed. */
    bool targetChanged = p->target != target ||
        (target == CD_TARGET_DEVICE && strcmp(p->targetUID, uid) != 0);
    if (p->hasOutput && targetChanged) {
        result = cd_playback_stop(p, NULL, error);
        if (result != CD_OK) return result;
    }

    if (!p->hasOutput) {
        p->target = target;
        p->targetUID[0] = '\0';
        p->uid[0] = '\0';
        p->changedFormat = false;
        if (target == CD_TARGET_DEVICE) snprintf(p->targetUID, sizeof(p->targetUID), "%s", uid);
        p->converting = false;
        result = choose_device(target, p->targetUID, sourceRate, info, &p->stream, error);
        if (result != CD_OK) return result;
        snprintf(p->outputName, sizeof(p->outputName), "%s", info->name);
        p->leadInFrames = cd_output_lead_in_frames(info->transportType, sourceRate);
        p->channelMapped = target == CD_TARGET_DEVICE && info->outputChannels > CD_PCM_CHANNELS;
        preferred_stereo_channels(info->deviceID, info->outputChannels,
                                  &p->preferredLeftChannel, &p->preferredRightChannel);
        if ((target == CD_TARGET_BUILT_IN || target == CD_TARGET_DEVICE) && !info->supportsSourceRate)
            return fail_source_rate(error, CD_FORMAT_UNAVAILABLE, "The ", target, info->name,
                                    " does not support native ", sourceRate);
        if (owned_by_another_process(info->hogOwner))
            return fail_output(error, CD_OUTPUT_UNAVAILABLE, 0, "Another app has exclusive use of the ", target,
                               info->name, ". Close it, then try Play again.");
        p->device = info->deviceID;
        p->hasOutput = true;
        p->hasOutputDataSource = info->hasOutputDataSource;
        p->outputDataSource = info->outputDataSource;
        p->originalRate = info->sampleRate;
        if (info->supportsSourceRate) {
            AudioStreamID only = kAudioObjectUnknown;
            bool singleStream = false;
            OSStatus streamStatus = get_output_stream(p->device, &only, &singleStream);
            if (streamStatus != noErr)
                return failed_start(p, fail_output(error, CD_CORE_AUDIO_ERROR, streamStatus,
                                                   "Cannot inspect output streams for the ",
                                                   target, p->outputName, ""),
                                    error);

            AudioStreamBasicDescription originalVirtualFormat = {0}, appliedVirtualFormat = {0};
            AudioStreamBasicDescription originalPhysicalFormat = {0}, appliedPhysicalFormat = {0};
            bool applyStereoFormat = false;
            if (target == CD_TARGET_DEVICE && singleStream) {
                bool stereoFormatsAvailable = false;
                result = choose_stereo_stream_formats(
                    only, p->source.format, &originalVirtualFormat, &appliedVirtualFormat,
                    &originalPhysicalFormat, &appliedPhysicalFormat, &stereoFormatsAvailable, error);
                if (result != CD_OK) return failed_start(p, result, error);
                applyStereoFormat = stereoFormatsAvailable &&
                    (!cd_audio_stream_formats_equal(&originalVirtualFormat, &appliedVirtualFormat) ||
                     !cd_audio_stream_formats_equal(&originalPhysicalFormat, &appliedPhysicalFormat));
                if (applyStereoFormat) {
                    OSStatus uidStatus = get_string(
                        p->device, kAudioDevicePropertyDeviceUID, p->uid, sizeof(p->uid));
                    if (uidStatus != noErr || p->uid[0] == '\0')
                        return failed_start(p, fail(error, CD_CORE_AUDIO_ERROR, uidStatus,
                                                    "Cannot identify the output for stream-format recovery"), error);
                    result = cd_rate_remember_stream_formats(
                        p->uid, p->originalRate, sourceRate,
                        &originalVirtualFormat, &appliedVirtualFormat,
                        &originalPhysicalFormat, &appliedPhysicalFormat,
                        &core_audio_rate_operations, error);
                    if (result != CD_OK) return failed_start(p, result, error);
                    p->changedFormat = true;
                }
            }

            if (p->originalRate != sourceRate) {
                if (p->uid[0] == '\0') {
                    OSStatus uidStatus = get_string(
                        p->device, kAudioDevicePropertyDeviceUID, p->uid, sizeof(p->uid));
                    if (uidStatus != noErr || p->uid[0] == '\0')
                        return failed_start(p, fail(error, CD_CORE_AUDIO_ERROR, uidStatus,
                                                    "Cannot identify the output for sample-rate recovery"), error);
                }
                result = cd_rate_apply(p->device, p->uid, p->originalRate, sourceRate,
                                       &core_audio_rate_operations, &p->changedRate, error);
                if (result != CD_OK) return failed_start(p, result, error);
            } else {
                result = wait_for_rate(p->device, sourceRate, error);
                if (result != CD_OK) return failed_start(p, result, error);
            }

            if (applyStereoFormat) {
                result = cd_rate_apply_stream_formats(
                    only, p->uid, p->originalRate, sourceRate,
                    &originalVirtualFormat, &appliedVirtualFormat,
                    &originalPhysicalFormat, &appliedPhysicalFormat,
                    &core_audio_rate_operations, error);
                if (result != CD_OK) return failed_start(p, result, error);
            }

            if (target == CD_TARGET_SYSTEM_DEFAULT && !singleStream) {
                /* System Default converts a successfully identified multi-stream layout. */
                p->converting = true;
            } else if (target == CD_TARGET_DEVICE && !singleStream) {
                /* AUHAL can address a multi-stream device as a whole; the chosen rate stays the source's. */
                p->converting = true;
            } else if (target == CD_TARGET_BUILT_IN && !singleStream) {
                return failed_start(p, fail_output(error, CD_FORMAT_UNAVAILABLE, 0,
                                                   "The ", target, p->outputName,
                                                   " no longer exposes a single output stream"),
                                    error);
            } else {
                CDError formatError = {0};
                result = validate_format(p, &formatError);
                if (target == CD_TARGET_SYSTEM_DEFAULT && result == CD_FORMAT_UNAVAILABLE) {
                    p->converting = true;
                } else if (result != CD_OK) {
                    if (error) *error = formatError;
                    return failed_start(p, result, error);
                } else {
                    p->converting = false;
                }
            }
        } else {
            p->converting = true;
        }
        atomic_store_explicit(&p->configurationChanged, false, memory_order_release);
        result = add_watches(p, error);
        if (result != CD_OK) return failed_start(p, result, error);
    }

    if (!p->converting) {
        result = validate_format(p, error);
        if (result != CD_OK) return failed_start(p, result, error);
    }
    pid_t owner = -1;
    OSStatus status = read_hog_owner(p->device, &owner);
    if (status != noErr)
        return failed_start(p, fail_output(error, CD_CORE_AUDIO_ERROR, status, "Cannot inspect the ",
                                           p->target, p->outputName, ""),
                            error);
    if (owned_by_another_process(owner))
        return failed_start(p, fail_output(error, CD_OUTPUT_UNAVAILABLE, 0, "Another app took exclusive use of the ",
                                           p->target, p->outputName, ". Close it, then try Play again."),
                            error);

    uint32_t outputBits = physical_output_bits(p);
    p->hdcdOutputSupports20 = outputBits >= 20;
    atomic_store_explicit(&p->physicalOutputBits, outputBits, memory_order_release);
    result = cd_playback_prepare(p, startFrame, error);
    if (result != CD_OK) return failed_start(p, result, error);
    if (p->converting) {
        result = start_converter(p, error);
        if (result != CD_OK) return failed_start(p, result, error);
    } else {
        status = AudioDeviceCreateIOProcID(p->device, render_audio, p, &p->ioProc);
        if (status != noErr)
            return failed_start(p, fail(error, CD_CORE_AUDIO_ERROR, status, "Cannot create the Core Audio callback"),
                                error);
        status = AudioDeviceStart(p->device, p->ioProc);
        if (status != noErr)
            return failed_start(p, fail_output(error, CD_CORE_AUDIO_ERROR, status, "Cannot start the ",
                                               p->target, p->outputName, ""),
                                error);
    }
    p->running = true;
    result = inspect_device(p->device, p->stream, sourceRate, info, error);
    if (result != CD_OK) return failed_start(p, result, error);
    info->converts = target == CD_TARGET_SYSTEM_DEFAULT && p->converting;
    return CD_OK;
}

int cd_playback_snapshot(CDPlayback *p, CDPlaybackSnapshot *snapshot, CDError *error)
{
    if (!p || !snapshot) return fail(error, CD_INVALID_ARGUMENT, 0, "A playback snapshot destination is required");
    fill_snapshot(p, snapshot);
    if (atomic_load_explicit(&p->producerFailed, memory_order_acquire)) {
        if (error) *error = p->producerError;
        return p->producerError.code;
    }
    int progressResult = check_read_progress(p, snapshot, error);
    if (progressResult != CD_OK) return progressResult;
    if (atomic_load_explicit(&p->invalidOutput, memory_order_acquire))
        return fail(error, CD_FORMAT_UNAVAILABLE, 0, "Core Audio supplied an unsupported output layout");
    if (p->running && atomic_load_explicit(&p->configurationChanged, memory_order_acquire)) {
        CDDeviceInfo selected;
        int result = choose_device(p->target, p->targetUID, p->source.format.sampleRate, &selected, NULL, error);
        if (result != CD_OK) return result;
        if (p->target == CD_TARGET_SYSTEM_DEFAULT && selected.deviceID != p->device)
            return fail(error, CD_DEFAULT_OUTPUT_CHANGED, 0, "macOS changed its default output.");
        /* Through the output unit, macOS follows rate and format changes itself. */
        if (selected.deviceID != p->device ||
            (!p->converting && selected.sampleRate != p->source.format.sampleRate) ||
            owned_by_another_process(selected.hogOwner) ||
            selected.hasOutputDataSource != p->hasOutputDataSource ||
            (p->hasOutputDataSource && selected.outputDataSource != p->outputDataSource))
            return fail(error, CD_CONFIGURATION_CHANGED, 0,
                        "The audio route, sample rate or availability changed. Press Play to reconnect.");
        if (!p->converting) {
            result = validate_format(p, error);
            if (result != CD_OK) return result;
        }
        atomic_store_explicit(&p->configurationChanged, false, memory_order_release);
    }
    return CD_OK;
}

int cd_playback_destroy(CDPlayback *p, CDError *error)
{
    if (!p) return CD_OK;
    int result = cd_playback_stop(p, NULL, error);
    if (result != CD_OK) return result;
    cd_ring_destroy(p->ring);
    release_hdcd_storage(p);
    if (p->source.destroy) p->source.destroy(p->source.context);
    pthread_cond_destroy(&p->producerWake);
    pthread_mutex_destroy(&p->producerWaitLock);
    free(p);
    return CD_OK;
}
