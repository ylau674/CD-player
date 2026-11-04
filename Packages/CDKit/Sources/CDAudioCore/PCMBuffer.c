#include "CDAudioCore.h"
#include "PageBuffer.h"
#include <limits.h>
#include <math.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

struct CDRingBuffer {
    size_t capacity;
    /* Changed only while the producer and consumer are stopped. */
    bool wide;
    CDPageBuffer storage;
    _Atomic uint64_t readPosition;
    _Atomic uint64_t writePosition;
};

static size_t ring_bytes(size_t capacity, bool wide)
{
    return capacity * CD_PCM_CHANNELS * (wide ? sizeof(int32_t) : sizeof(int16_t));
}

CDRingBuffer *cd_ring_create(size_t capacityFrames)
{
    if (capacityFrames == 0 || capacityFrames > SIZE_MAX / (sizeof(int32_t) * CD_PCM_CHANNELS))
        return NULL;
    CDRingBuffer *ring = calloc(1, sizeof(*ring));
    if (!ring) return NULL;
    atomic_init(&ring->readPosition, 0);
    atomic_init(&ring->writePosition, 0);
    if (!atomic_is_lock_free(&ring->readPosition) || !atomic_is_lock_free(&ring->writePosition)) {
        free(ring);
        return NULL;
    }
    ring->capacity = capacityFrames;
    if (!cd_page_buffer_map(&ring->storage, ring_bytes(capacityFrames, true))) {
        free(ring);
        return NULL;
    }
    if (!cd_ring_configure(ring, true)) {
        cd_ring_destroy(ring);
        return NULL;
    }
    return ring;
}

static uint64_t checksum_sample32(uint64_t checksum, int32_t sample)
{
    uint32_t bits = (uint32_t)sample;
    for (unsigned int shift = 0; shift < 32; shift += 8)
        checksum = (checksum ^ (uint8_t)(bits >> shift)) * CD_PCM_CHECKSUM_PRIME;
    return checksum;
}

void cd_ring_destroy(CDRingBuffer *ring)
{
    if (!ring) return;
    cd_page_buffer_unmap(&ring->storage);
    free(ring);
}

void cd_pcm32_to_float32(const int32_t *input, float *output, size_t sampleCount)
{
    for (size_t i = 0; i < sampleCount; ++i) output[i] = input[i] * (1.0f / 2147483648.0f);
}

void cd_ring_reset(CDRingBuffer *ring)
{
    atomic_store_explicit(&ring->readPosition, 0, memory_order_relaxed);
    atomic_store_explicit(&ring->writePosition, 0, memory_order_relaxed);
}

bool cd_ring_configure(CDRingBuffer *ring, bool wideSamples)
{
    cd_ring_reset(ring);
    if (!cd_page_buffer_claim(&ring->storage, ring_bytes(ring->capacity, wideSamples))) return false;
    ring->wide = wideSamples;
    return true;
}

void cd_ring_release(CDRingBuffer *ring)
{
    (void)cd_page_buffer_claim(&ring->storage, 0);
}

bool cd_ring_is_wide(const CDRingBuffer *ring)
{
    return ring->wide;
}

CDPageUsage cd_ring_page_usage(const CDRingBuffer *ring)
{
    return cd_page_buffer_usage(&ring->storage);
}

size_t cd_ring_available(const CDRingBuffer *ring)
{
    uint64_t read = atomic_load_explicit(&ring->readPosition, memory_order_acquire);
    uint64_t write = atomic_load_explicit(&ring->writePosition, memory_order_acquire);
    size_t available = (size_t)(write - read);
    return available < ring->capacity ? available : ring->capacity;
}

size_t cd_ring_writable(const CDRingBuffer *ring)
{
    return ring->capacity - cd_ring_available(ring);
}

size_t cd_ring_write(CDRingBuffer *ring, const int16_t *stereo, size_t frames)
{
    uint64_t write = atomic_load_explicit(&ring->writePosition, memory_order_relaxed);
    uint64_t read = atomic_load_explicit(&ring->readPosition, memory_order_acquire);
    size_t freeFrames = ring->capacity - (size_t)(write - read);
    size_t count = frames < freeFrames ? frames : freeFrames;
    int32_t *wide = ring->storage.base;
    int16_t *narrow = ring->storage.base;
    for (size_t i = 0; i < count; ++i) {
        size_t target = (size_t)((write + i) % ring->capacity) * CD_PCM_CHANNELS;
        if (ring->wide) {
            wide[target] = (int32_t)stereo[i * CD_PCM_CHANNELS] * 65536;
            wide[target + 1] = (int32_t)stereo[i * CD_PCM_CHANNELS + 1] * 65536;
        } else {
            narrow[target] = stereo[i * CD_PCM_CHANNELS];
            narrow[target + 1] = stereo[i * CD_PCM_CHANNELS + 1];
        }
    }
    atomic_store_explicit(&ring->writePosition, write + count, memory_order_release);
    return count;
}

size_t cd_ring_write_32(CDRingBuffer *ring, const int32_t *stereo, size_t frames)
{
    if (!ring->wide) return 0;
    uint64_t write = atomic_load_explicit(&ring->writePosition, memory_order_relaxed);
    uint64_t read = atomic_load_explicit(&ring->readPosition, memory_order_acquire);
    size_t freeFrames = ring->capacity - (size_t)(write - read);
    size_t count = frames < freeFrames ? frames : freeFrames;
    int32_t *samples = ring->storage.base;
    for (size_t i = 0; i < count; ++i) {
        size_t target = (size_t)((write + i) % ring->capacity) * CD_PCM_CHANNELS;
        samples[target] = stereo[i * CD_PCM_CHANNELS];
        samples[target + 1] = stereo[i * CD_PCM_CHANNELS + 1];
    }
    atomic_store_explicit(&ring->writePosition, write + count, memory_order_release);
    return count;
}

void cd_pcm16_to_float32(const int16_t *input, float *output, size_t sampleCount)
{
    /* Every Int16 value divided by a power of two is exact in Float32. */
    for (size_t i = 0; i < sampleCount; ++i) output[i] = input[i] * (1.0f / 32768.0f);
}

static bool output_channel(AudioBufferList *output, UInt32 channel, float **samples,
                           size_t *stride, size_t *localChannel, size_t *frameCount)
{
    UInt32 first = 0;
    for (UInt32 i = 0; i < output->mNumberBuffers; ++i) {
        AudioBuffer *buffer = &output->mBuffers[i];
        UInt32 channels = buffer->mNumberChannels;
        if (channels == 0 || !buffer->mData || buffer->mDataByteSize % (channels * sizeof(float)) != 0)
            return false;
        size_t frames = buffer->mDataByteSize / (channels * sizeof(float));
        if (i == 0) *frameCount = frames;
        else if (*frameCount != frames) return false;
        if (channel >= first && channel < first + channels) {
            *samples = buffer->mData;
            *stride = channels;
            *localChannel = channel - first;
        }
        first += channels;
    }
    return *samples != NULL;
}

CDRenderResult cd_ring_render_mapped(CDRingBuffer *ring, AudioBufferList *output,
                                     bool checksumPCM, uint64_t initialChecksum,
                                     uint32_t leftChannel, uint32_t rightChannel)
{
    CDRenderResult result = {0, 0, false, initialChecksum};
    if (!output) return result;
    for (UInt32 i = 0; i < output->mNumberBuffers; ++i) {
        if (output->mBuffers[i].mData)
            memset(output->mBuffers[i].mData, 0, output->mBuffers[i].mDataByteSize);
    }

    float *left = NULL, *right = NULL;
    size_t leftStride = 0, rightStride = 0, leftOffset = 0, rightOffset = 0, frames = 0;
    if (leftChannel == rightChannel ||
        !output_channel(output, leftChannel, &left, &leftStride, &leftOffset, &frames) ||
        !output_channel(output, rightChannel, &right, &rightStride, &rightOffset, &frames)) {
        return result;
    }
    result.validLayout = true;
    result.requestedFrames = frames;
    uint64_t read = atomic_load_explicit(&ring->readPosition, memory_order_relaxed);
    uint64_t write = atomic_load_explicit(&ring->writePosition, memory_order_acquire);
    size_t available = (size_t)(write - read);
    result.consumedFrames = result.requestedFrames < available ? result.requestedFrames : available;
    const bool wide = ring->wide;
    const int32_t *wideSamples = ring->storage.base;
    const int16_t *narrowSamples = ring->storage.base;
    for (size_t i = 0; i < result.consumedFrames; ++i) {
        size_t source = (size_t)((read + i) % ring->capacity) * CD_PCM_CHANNELS;
        /* A 16-bit sample scaled by 65536 gives the same float and checksum as a wide ring. */
        int32_t leftSample = wide ? wideSamples[source] : (int32_t)narrowSamples[source] * 65536;
        int32_t rightSample = wide ? wideSamples[source + 1] : (int32_t)narrowSamples[source + 1] * 65536;
        left[i * leftStride + leftOffset] = leftSample * (1.0f / 2147483648.0f);
        right[i * rightStride + rightOffset] = rightSample * (1.0f / 2147483648.0f);
        if (checksumPCM) {
            result.pcmChecksum = checksum_sample32(result.pcmChecksum, leftSample);
            result.pcmChecksum = checksum_sample32(result.pcmChecksum, rightSample);
        }
    }
    atomic_store_explicit(&ring->readPosition, read + result.consumedFrames, memory_order_release);
    return result;
}

CDRenderResult cd_ring_render(CDRingBuffer *ring, AudioBufferList *output,
                              bool checksumPCM, uint64_t initialChecksum)
{
    return cd_ring_render_mapped(ring, output, checksumPCM, initialChecksum, 0, 1);
}

uint64_t cd_demo_total_frames(const CDDemoTrack *tracks, size_t trackCount)
{
    uint64_t total = 0;
    for (size_t i = 0; i < trackCount; ++i) {
        if (UINT64_MAX - total < tracks[i].frameCount) return 0;
        total += tracks[i].frameCount;
    }
    return total;
}

size_t cd_demo_render(const CDDemoTrack *tracks, size_t trackCount,
                      uint64_t startFrame, int16_t *stereo, size_t frames)
{
    size_t written = 0;
    uint64_t trackStart = 0;
    const double twoPi = 6.28318530717958647692;
    for (size_t track = 0; track < trackCount && written < frames; ++track) {
        uint64_t trackEnd = trackStart + tracks[track].frameCount;
        if (startFrame < trackEnd) {
            uint64_t offset = startFrame > trackStart ? startFrame - trackStart : 0;
            uint64_t remaining = tracks[track].frameCount - offset;
            size_t count = remaining < frames - written ? (size_t)remaining : frames - written;
            for (size_t i = 0; i < count; ++i) {
                double phase = twoPi * tracks[track].frequency * (double)(offset + i) / CD_DA_SAMPLE_RATE;
                int16_t sample = (int16_t)lrint(sin(phase) * tracks[track].amplitude);
                stereo[(written + i) * CD_PCM_CHANNELS] = sample;
                stereo[(written + i) * CD_PCM_CHANNELS + 1] = sample;
            }
            written += count;
            startFrame += count;
        }
        trackStart = trackEnd;
    }
    return written;
}
