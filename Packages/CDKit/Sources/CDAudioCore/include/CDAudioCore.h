#ifndef CD_AUDIO_CORE_H
#define CD_AUDIO_CORE_H

#include <CoreAudio/CoreAudio.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

/* Red Book CD-DA: the PCM of every audio track on a standard CD. A disc's table of contents marks
   each track as audio or data and as two- or four-channel; the standard fixes the rate and word
   length. CDKit describes the detected disc with a CDSourceFormat and playback follows that format. */
#define CD_DA_SAMPLE_RATE 44100u
#define CD_DA_BITS_PER_CHANNEL 16u
#define CD_DA_CHANNELS 2u
/* The read-ahead ring and render path carry interleaved stereo frames: signed 32-bit while HDCD
   decoding can apply, otherwise the source's signed 16-bit samples. */
#define CD_PCM_CHANNELS 2u
/* Buffer sizes in frames; their seconds are at the CD-DA rate, the only rate playback accepts. */
#define CD_PLAYBACK_BUFFER_FRAMES (15u * CD_DA_SAMPLE_RATE)
#define CD_PLAYBACK_PREFILL_FRAMES (2u * CD_DA_SAMPLE_RATE)
#define CD_PLAYBACK_BURST_LOW_FRAMES (10u * CD_DA_SAMPLE_RATE)
#define CD_PLAYBACK_STALL_SECONDS 10u
/* Silence before the first CD sample on HDMI and DisplayPort, where receivers mute while they lock. */
#define CD_PLAYBACK_LEAD_IN_MILLISECONDS 1000u
#define CD_PCM_CHECKSUM_INITIAL UINT64_C(14695981039346656037)
#define CD_PCM_CHECKSUM_PRIME UINT64_C(1099511628211)

typedef enum {
    CD_OK = 0,
    CD_INVALID_ARGUMENT,
    CD_OUT_OF_MEMORY,
    CD_NO_BUILT_IN_OUTPUT,
    CD_OUTPUT_UNAVAILABLE,
    CD_FORMAT_UNAVAILABLE,
    CD_CORE_AUDIO_ERROR,
    CD_CONFIGURATION_CHANGED,
    CD_BUFFER_UNDERRUN,
    CD_PRODUCER_ERROR,
    CD_DISC_REFUSED,
    CD_DISC_GONE,
    CD_DISC_READ_ERROR,
    CD_DISC_FAILED,
    CD_READ_TIMEOUT,
    /* Playing on System Default, macOS made another device its default output. */
    CD_DEFAULT_OUTPUT_CHANGED
} CDResult;

/* Which output inspection, the output-rate switch and playback act on. */
typedef enum {
    /* The 1.0.0 rule: the built-in output that is the default, else built-in headphones, else another. */
    CD_TARGET_BUILT_IN = 0,
    /* Whatever device macOS uses as its default output at that moment, played best effort. */
    CD_TARGET_SYSTEM_DEFAULT,
    /* A wired output, identified by its persistent Core Audio UID. */
    CD_TARGET_DEVICE
} CDOutputTarget;

typedef struct {
    int32_t code;
    int32_t systemStatus;
    char message[384];
} CDError;

/* The PCM format a source supplies, as detected from the disc. */
typedef struct {
    double sampleRate;
    uint32_t bitsPerChannel;
    uint32_t channelsPerFrame;
} CDSourceFormat;

/* Two-channel Red Book CD-DA: every standard audio CD and the simulated disc. */
CDSourceFormat cd_source_format_compact_disc(void);
/* Whether playback carries the format unchanged. The pipeline takes 16-bit stereo at the CD-DA
   rate, so any other format is refused before an output is touched. */
bool cd_source_format_supported(CDSourceFormat format);

typedef struct {
    char uid[256];
    double originalRate;
    double appliedRate;
    bool recoveryPending;
    bool hasFormatChange;
    AudioStreamBasicDescription originalVirtualFormat;
    AudioStreamBasicDescription appliedVirtualFormat;
    AudioStreamBasicDescription originalPhysicalFormat;
    AudioStreamBasicDescription appliedPhysicalFormat;
} CDRateRecord;

typedef struct {
    void *context;
    OSStatus (*resolveDevice)(void *context, const char *uid, AudioDeviceID *device);
    OSStatus (*readRate)(void *context, AudioDeviceID device, double *rate);
    OSStatus (*readHogOwner)(void *context, AudioDeviceID device, int32_t *owner);
    bool (*ownedByAnotherProcess)(void *context, int32_t owner);
    OSStatus (*setRate)(void *context, AudioDeviceID device, double rate);
    int (*waitForRate)(void *context, AudioDeviceID device, double rate, CDError *error);
    int (*rememberRate)(void *context, const char *uid, double originalRate, double appliedRate, CDError *error);
    OSStatus (*resolveSingleStream)(void *context, AudioDeviceID device, AudioStreamID *stream);
    OSStatus (*readStreamFormat)(void *context, AudioStreamID stream, bool physical,
                                 AudioStreamBasicDescription *format);
    OSStatus (*setStreamFormat)(void *context, AudioStreamID stream, bool physical,
                                const AudioStreamBasicDescription *format);
    int (*waitForStreamFormat)(void *context, AudioStreamID stream, bool physical,
                               const AudioStreamBasicDescription *format, CDError *error);
    int (*rememberFormats)(void *context, const char *uid, double originalRate, double appliedRate,
                           const AudioStreamBasicDescription *originalVirtualFormat,
                           const AudioStreamBasicDescription *appliedVirtualFormat,
                           const AudioStreamBasicDescription *originalPhysicalFormat,
                           const AudioStreamBasicDescription *appliedPhysicalFormat, CDError *error);
    int (*clearFormats)(void *context, const char *uid, CDError *error);
    int (*forgetRate)(void *context, const char *uid, CDError *error);
    bool (*objectGone)(void *context, OSStatus status);
} CDRateRecoveryOperations;

/* Shared by the Core Audio backend and its injected offline test backend. */
int cd_rate_apply(AudioDeviceID device, const char *uid, double originalRate, double appliedRate,
                  const CDRateRecoveryOperations *operations, bool *recorded, CDError *error);
int cd_rate_remember_stream_formats(const char *uid, double originalRate, double appliedRate,
                                    const AudioStreamBasicDescription *originalVirtualFormat,
                                    const AudioStreamBasicDescription *appliedVirtualFormat,
                                    const AudioStreamBasicDescription *originalPhysicalFormat,
                                    const AudioStreamBasicDescription *appliedPhysicalFormat,
                                    const CDRateRecoveryOperations *operations, CDError *error);
int cd_rate_apply_stream_formats(AudioStreamID stream, const char *uid, double originalRate, double appliedRate,
                                 const AudioStreamBasicDescription *originalVirtualFormat,
                                 const AudioStreamBasicDescription *appliedVirtualFormat,
                                 const AudioStreamBasicDescription *originalPhysicalFormat,
                                 const AudioStreamBasicDescription *appliedPhysicalFormat,
                                 const CDRateRecoveryOperations *operations, CDError *error);
bool cd_audio_stream_formats_equal(const AudioStreamBasicDescription *left,
                                   const AudioStreamBasicDescription *right);
int cd_rate_restore_device(AudioDeviceID device, int32_t owner, const CDRateRecord *record,
                           const CDRateRecoveryOperations *operations, CDError *error);
int cd_rate_restore_stream_formats(AudioDeviceID device, int32_t owner, const CDRateRecord *record,
                                   const CDRateRecoveryOperations *operations, CDError *error);
int cd_rate_restore_records(const CDRateRecord *records, size_t count, bool recoveryOnly,
                            const CDRateRecoveryOperations *operations, CDError *error);

typedef struct CDRingBuffer CDRingBuffer;

typedef struct {
    size_t requestedFrames;
    size_t consumedFrames;
    bool validLayout;
    uint64_t pcmChecksum;
} CDRenderResult;

/* Diagnostics for memory playback holds in pages it can hand back to macOS. */
typedef struct {
    size_t mappedBytes;
    /* The part in use; macOS may reclaim the rest at any time. */
    size_t claimedBytes;
    /* Pages macOS counts in the process footprint: resident or compressed, and not returned. */
    size_t footprintBytes;
} CDPageUsage;

/* A new ring holds 32-bit samples and is ready to write. Its storage is reserved address space;
   memory is used only as pages are written. */
CDRingBuffer *cd_ring_create(size_t capacityFrames);
void cd_ring_destroy(CDRingBuffer *ring);
/* Reset only while both the producer and consumer are stopped. */
void cd_ring_reset(CDRingBuffer *ring);
/* Empties the ring and claims the memory for 32-bit (wide) or 16-bit samples, returning the rest
   to macOS. Only while both the producer and consumer are stopped. Fails only if returned pages
   cannot be claimed. */
bool cd_ring_configure(CDRingBuffer *ring, bool wideSamples);
/* Returns all of the ring's memory to macOS, keeping its positions so availability still reads
   correctly. Only while both are stopped; configure again before writing. */
void cd_ring_release(CDRingBuffer *ring);
bool cd_ring_is_wide(const CDRingBuffer *ring);
CDPageUsage cd_ring_page_usage(const CDRingBuffer *ring);
size_t cd_ring_available(const CDRingBuffer *ring);
size_t cd_ring_writable(const CDRingBuffer *ring);
/* One producer and one consumer may operate concurrently. 16-bit frames are stored at the ring's
   width, scaled by 65536 in a wide ring. A 16-bit ring accepts no 32-bit frames. */
size_t cd_ring_write(CDRingBuffer *ring, const int16_t *stereo, size_t frames);
size_t cd_ring_write_32(CDRingBuffer *ring, const int32_t *stereo, size_t frames);
CDRenderResult cd_ring_render(CDRingBuffer *ring, AudioBufferList *output,
                              bool checksumPCM, uint64_t initialChecksum);
/* Renders stereo into the chosen zero-based output channels and leaves all others silent. */
CDRenderResult cd_ring_render_mapped(CDRingBuffer *ring, AudioBufferList *output,
                                     bool checksumPCM, uint64_t initialChecksum,
                                     uint32_t leftChannel, uint32_t rightChannel);
void cd_pcm16_to_float32(const int16_t *input, float *output, size_t sampleCount);
void cd_pcm32_to_float32(const int32_t *input, float *output, size_t sampleCount);

#define CD_LEVEL_SLOT_FRAMES 441u
#define CD_LEVEL_SLOT_COUNT 4096u

typedef struct CDLevelTable CDLevelTable;

typedef struct {
    uint16_t leftPeak;
    uint16_t rightPeak;
} CDLevelPeaks;

/* The table is shared by playback producers and UI readers. Destroy it only
   after every playback producer and reader has stopped. */
CDLevelTable *cd_level_table_create(void);
void cd_level_table_destroy(CDLevelTable *table);
/* Start only after the previous producer has stopped. Run IDs distinguish seeks
   and playback restarts; old slots are cleared before an 8-bit tag is reused. */
uint32_t cd_level_table_begin_run(CDLevelTable *table);
/* Records max absolute Int16 sample values in each intersected 441-frame slot.
   One producer may write while any number of readers call read. */
bool cd_level_table_record_block(CDLevelTable *table, uint32_t run,
                                 uint64_t startFrame, const int16_t *stereo,
                                 size_t frameCount);
/* Returns false when the slot is absent, overwritten, or belongs to another run. */
bool cd_level_table_read(const CDLevelTable *table, uint32_t run,
                         uint64_t frame, CDLevelPeaks *peaks);
/* Current source-peak run, or zero when no run has started. */
uint32_t cd_level_table_current_run(const CDLevelTable *table);

typedef struct {
    uint64_t frameCount;
    double frequency;
    int16_t amplitude;
} CDDemoTrack;

uint64_t cd_demo_total_frames(const CDDemoTrack *tracks, size_t trackCount);
size_t cd_demo_render(const CDDemoTrack *tracks, size_t trackCount,
                      uint64_t startFrame, int16_t *stereo, size_t frames);

typedef enum {
    CD_READ_UNPACED = 0,
    CD_READ_STEADY,
    CD_READ_BURST
} CDReadPacing;

typedef struct CDPlayback CDPlayback;

/* Pure validation of the formats used by the direct IOProc path: both run at the source's rate, and
   the physical format keeps at least the source's bits. An unsupported source matches nothing. */
bool cd_audio_format_supports_native_playback(CDSourceFormat source,
                                             const AudioStreamBasicDescription *virtualFormat,
                                             const AudioStreamBasicDescription *physicalFormat,
                                             bool channelMapped);
bool cd_audio_choose_stereo_formats(CDSourceFormat source,
                                    const AudioStreamRangedDescription *virtualFormats, size_t virtualCount,
                                    const AudioStreamRangedDescription *physicalFormats, size_t physicalCount,
                                    AudioStreamBasicDescription *virtualFormat,
                                    AudioStreamBasicDescription *physicalFormat);

typedef enum {
    CD_STREAM_TOPOLOGY_QUERY_ERROR = 0,
    CD_STREAM_TOPOLOGY_SINGLE,
    CD_STREAM_TOPOLOGY_MULTIPLE
} CDOutputStreamTopology;

/* Distinguishes a successful multi-stream query from a failed or malformed query. */
CDOutputStreamTopology cd_audio_classify_output_stream_query(int32_t status, size_t byteCount);

/* Valid only for the duration of a source read. Cancellation is an atomic
   query; source retries must check it between blocking operations. */
typedef struct {
    CDPlayback *playback;
    size_t bufferedFrames;
    bool buffering;
    bool beginsPlayback;
} CDPCMReadContext;

typedef struct {
    size_t framesRead;
    uint32_t trackNumber;
    uint64_t concealedSectors;
    bool unverified;
} CDPCMReadResult;

/* Blocking, seekable source of interleaved stereo Int16 PCM in the format it declares, which
   create_source checks and start uses to set the output rate.
   Read runs only on the producer thread, never the HAL callback. A successful
   read supplies 1..capacityFrames frames while inside frameCount; a short read
   is allowed, but zero before the declared end is an error. Fill error on
   failure. Context ownership transfers only when create_source succeeds;
   destroy runs after the producer is joined and the callback detached.
   With the standard ring, paced sources first fill it, then refill after one
   producer chunk (steady) or once a third of it remains, at most 10 s (burst).
   Smaller rings never idle below their startup/recovery gate.
   Pacing follows consumed frames, not a timer that could slow a struggling read. */
typedef struct {
    uint64_t frameCount;
    void *context;
    int (*read)(void *context, uint64_t frame, int16_t *stereo,
                size_t capacityFrames, const CDPCMReadContext *request,
                CDPCMReadResult *result, CDError *error);
    void (*destroy)(void *context);
    CDReadPacing readPacing;
    CDSourceFormat format;
    bool hdcdEligible;
} CDPCMSource;

typedef struct {
    AudioDeviceID deviceID;
    double sampleRate;
    /* Another process's exclusive (hog-mode) owner, or -1. Playback never takes hog mode. */
    int32_t hogOwner;
    /* The output offers the source rate the caller passed in. */
    bool supportsSourceRate;
    /* The system default output, which the volume keys and menu-bar slider control. */
    bool isDefaultOutput;
    bool usesSpeakers;
    bool hasOutputDataSource;
    uint32_t outputDataSource;
    bool isRunning;
    /* The rate the output-rate switch restores to an output at the source rate: the one recorded
       when playback or the switch replaced it, else 48 kHz; 0 when that rate is unsupported. */
    double restoreRate;
    /* System Default only: playback goes through Apple's HAL output unit, which converts the rate or
       channel layout inside macOS, because the device cannot take the source directly. Start
       reports the path it used; inspection predicts it from the current format. */
    bool converts;
    char name[256];
    char uid[256];
    uint32_t transportType;
    uint32_t outputChannels;
    uint32_t outputTerminalType;
    /* Stream latency in frames at the output's nominal sample rate, when available. */
    uint32_t streamLatencyFrames;
    bool hasStreamLatency;
    /* The output has a host volume the user can change, on its main element or channel 1 or 2;
       without one, volume is set on the device itself. Read only: the player never changes it. */
    bool hasVolumeControl;
} CDDeviceInfo;

typedef enum {
    CD_HDCD_NOT_APPLICABLE = 0,
    CD_HDCD_DETECTING,
    CD_HDCD_NONE,
    CD_HDCD_NO_EFFECT,
    CD_HDCD_EFFECTUAL
} CDHDCDStatus;

typedef struct {
    uint64_t currentFrame;
    uint64_t underrunFrames;
    size_t bufferedFrames;
    bool buffering;
    bool leadIn;
    bool finished;
    bool running;
    uint64_t concealedSectors;
    bool unverified;
    uint64_t pcmChecksum;
    /* Set only by cd_playback_stop_before_sleep: the output's restore did not finish and is left to
       cd_audio_recover_output_rates after wake. */
    bool outputRestorePending;
    CDHDCDStatus hdcdStatus;
    /* The audio at currentFrame is decoded; the producer may already be decoding frames beyond it. */
    bool hdcdDecoded;
    uint32_t physicalOutputBits;
} CDPlaybackSnapshot;

/* Inspection is read-only and reports whether the output offers sourceRate, the loaded source's
   sample rate. A device target is resolved by UID and must be a supported wired output.
   Starting playback uses the device and sets its nominal sample rate; outside playback, the
   output-rate switch below can set the rate too. The output stays shared, so the system volume keeps
   working and other apps can still play. */
int cd_audio_inspect(CDOutputTarget target, const char *uid, double sourceRate, CDDeviceInfo *info,
                     CDError *error);
/* Lists live output devices with a readable transport and output stream, each checked against
   sourceRate. The caller frees the returned array with cd_audio_free_output_devices; transport
   filtering is performed by CDKit. */
int cd_audio_copy_output_devices(double sourceRate, CDDeviceInfo **devices, size_t *count, CDError *error);
void cd_audio_free_output_devices(CDDeviceInfo *devices);
/* Restores crash-persisted rates for connected outputs and retains disconnected ones for reconnect. */
int cd_audio_recover_output_rates(CDError *error);
/* Ranks a live built-in stereo output; the highest rank is used. The system
   default output wins so the volume keys control the CD, then wired headphones. */
int cd_output_rank(bool isDefaultOutput, const char *name);
CDPlayback *cd_playback_create(const CDDemoTrack *tracks, size_t trackCount,
                               size_t bufferFrames, CDError *error);
CDPlayback *cd_playback_create_with_levels(const CDDemoTrack *tracks, size_t trackCount,
                                           size_t bufferFrames, CDLevelTable *levels,
                                           CDError *error);
/* silentOutput consumes and checksums source PCM in the callback, then writes only zeros
   to Core Audio. It is intended for explicit hardware validation, not normal playback. */
CDPlayback *cd_playback_create_source(CDPCMSource source, size_t bufferFrames,
                                      bool silentOutput, CDError *error);
CDPlayback *cd_playback_create_source_with_levels(CDPCMSource source, size_t bufferFrames,
                                                  bool silentOutput, CDLevelTable *levels,
                                                  CDError *error);
/* Prepares PCM on the producer thread without opening an audio device.
   The previous producer and callback must already be stopped. */
int cd_playback_prepare(CDPlayback *playback, uint64_t startFrame, CDError *error);
/* Offline only: configures HDCD decoding before prepare. Live playback supplies this on start. */
int cd_playback_set_hdcd_decode_enabled(CDPlayback *playback, bool enabled, CDError *error);
/* Current source-peak run, or zero when no run has started. */
uint32_t cd_playback_level_run(const CDPlayback *playback);
/* Resolves the target when no output is held, so System Default uses the default at that moment and
   a device target uses its UID. An output kept for an immediate track change is released first if
   the target differs. Built-in and wired targets require native stereo PCM at the source's rate;
   wired multichannel output uses its preferred stereo channels. System Default sets the source rate
   when it can and otherwise plays through the HAL output unit (info->converts). The app never adds
   gain. */
int cd_playback_start(CDPlayback *playback, uint64_t startFrame, CDOutputTarget target, const char *uid,
                      bool decodeHDCD,
                      CDDeviceInfo *info, CDError *error);
/* Start leaves output muted. Commit it only if the start request is still current.
   Request-stop is atomic and may run concurrently with any serialized lifecycle
   operation; it silences the callback before waiting for a blocked producer. */
void cd_playback_enable_output(CDPlayback *playback);
/* The silent lead-in frames at sourceRate for an output transport: CD_PLAYBACK_LEAD_IN_MILLISECONDS
   on HDMI and DisplayPort, otherwise none. Start sets it for the output it chooses; every prepare
   then plays it after output is enabled. It overlaps start-up buffering, is not an underrun, does not
   move currentFrame and is not part of the PCM checksum. */
uint64_t cd_output_lead_in_frames(uint32_t transportType, double sourceRate);
/* For offline rendering, which has no output to choose; call before prepare. */
void cd_playback_set_lead_in_frames(CDPlayback *playback, uint64_t frames);
/* Offline only: supplies the physical output depth before cd_playback_prepare. */
void cd_playback_set_test_output_bits(CDPlayback *playback, uint32_t bitsPerChannel);

typedef struct {
    CDPageUsage ring;
    /* The ring holds 32-bit samples because HDCD decoding may apply in this run. */
    bool ringWide;
    CDPageUsage hdcdStartup;
} CDPlaybackMemory;

/* Diagnostics for the read-ahead ring and HDCD start-up buffer. Stop returns both to macOS and
   prepare claims what the run needs; the start-up buffer is returned once detection decides.
   Safe to call while playing, but not concurrently with prepare. */
void cd_playback_memory(const CDPlayback *playback, CDPlaybackMemory *memory);
void cd_playback_request_stop(CDPlayback *playback);
bool cd_playback_read_cancelled(const CDPlayback *playback);
/* The HAL callback and offline renderer share this allocation-free path. */
void cd_playback_render(CDPlayback *playback, AudioBufferList *output);
/* Poll regularly while playing, including during buffering. This checks the
   monotonic read-progress deadline without waiting for a blocked source.
   Startup/recovery need 2 s, or the smaller buffer/remaining EOF tail.
   On System Default, a different default device is CD_DEFAULT_OUTPUT_CHANGED; the caller decides
   whether the user chose it or the previous one disappeared. */
int cd_playback_snapshot(CDPlayback *playback, CDPlaybackSnapshot *snapshot,
                         CDError *error);
int cd_playback_stop(CDPlayback *playback, CDPlaybackSnapshot *snapshot,
                     CDError *error);
/* Stop before system sleep. Once sleep begins, macOS can hold an output change until wake, so a
   rate or format restore that does not finish marks the output for recovery and sets
   snapshot->outputRestorePending instead of failing. */
int cd_playback_stop_before_sleep(CDPlayback *playback, CDPlaybackSnapshot *snapshot,
                                  CDError *error);
/* On cleanup failure the allocation is retained, preventing callback UAF. */
int cd_playback_destroy(CDPlayback *playback, CDError *error);
/* Call at quit, after every playback is stopped. Stop restores an output's original rate when it
   can; this restores each output it could not, such as one unplugged during playback, and each one
   the output-rate switch matched to the source, if it is connected and still at that rate. A rate
   chosen since is kept, and an output still unplugged cannot be changed. The first failure is
   reported after every output has been tried. */
int cd_audio_restore_output_rates(CDError *error);
/* The output-rate switch, only for use while no playback holds the output. Device targets resolve by
   UID. Both act on the output Play would choose and describe it in info afterward. Matching sets
   sourceRate and records the rate it replaced, so playback then leaves the rate as it is and quitting
   restores it. */
int cd_audio_match_source_rate(CDOutputTarget target, const char *uid, double sourceRate, CDDeviceInfo *info,
                               CDError *error);
/* Sets an output at sourceRate to its restore rate and forgets its recorded rate. An output already
   at another rate keeps it. */
int cd_audio_restore_output_rate(CDOutputTarget target, const char *uid, double sourceRate, CDDeviceInfo *info,
                                 CDError *error);

/* Raw audio-CD access through the whole disc's character device, opened
   read-only as the calling user. Nothing here mounts, ejects or changes access
   policy; a refusal is reported as CD_DISC_REFUSED and never worked around.
   Calls block on the drive, so make them off the main thread. */
#define CD_SECTOR_BYTES 2352u
#define CD_ERROR_FLAG_BYTES 294u
#define CD_MAX_READ_SECTORS 75u
#define CD_TOC_CAPACITY 4096u

/* bsdName is a whole disc such as "disk4"; "/dev/r" is prepended. */
int cd_disc_open(const char *bsdName, int *descriptor, CDError *error);
void cd_disc_close(int descriptor);
/* The full TOC (CDTOC), in the same format as the registry's TOC property. */
int cd_disc_read_toc(int descriptor, uint8_t *buffer, size_t capacity, size_t *length, CDError *error);
/* Reads 1-75 CD-DA sectors. With errorFlags, each sector's 2,352 audio bytes
   are followed by its 294 bytes of C2 error flags. */
int cd_disc_read(int descriptor, uint64_t firstSector, uint32_t sectorCount, bool errorFlags,
                 uint8_t *buffer, size_t capacity, CDError *error);
/* The SDK's kCDSpeedMin, in kB/s; it is a request, not a measured read rate. */
uint16_t cd_disc_min_speed(void);
uint32_t cd_disc_stream_accurate_mask(void);
int cd_disc_get_speed(int descriptor, uint16_t *kilobytesPerSecond, CDError *error);
int cd_disc_set_speed(int descriptor, uint16_t kilobytesPerSecond, CDError *error);
CDResult cd_disc_result_for_errno(int value);

#endif
