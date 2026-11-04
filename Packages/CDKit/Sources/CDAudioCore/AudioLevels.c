#include "CDAudioCore.h"
#include <stdatomic.h>
#include <stdlib.h>

#define CD_LEVEL_SLOT_INDEX_MASK (CD_LEVEL_SLOT_COUNT - 1u)
#define CD_LEVEL_SLOT_TAG_MASK UINT64_C(0xFFFFFF)
#define CD_LEVEL_RUN_TAG_MASK UINT32_C(0xFF)
#define CD_LEVEL_MAX_SLOT CD_LEVEL_SLOT_TAG_MASK

struct CDLevelTable {
    _Atomic uint64_t slots[CD_LEVEL_SLOT_COUNT];
    _Atomic uint32_t currentRun;
};

static uint16_t sample_magnitude(int16_t sample)
{
    return (uint16_t)(sample < 0 ? -(int32_t)sample : sample);
}

static uint64_t pack_slot(uint32_t run, uint64_t slot, uint16_t left, uint16_t right)
{
    return ((uint64_t)(run & CD_LEVEL_RUN_TAG_MASK) << 56) |
        ((slot & CD_LEVEL_SLOT_TAG_MASK) << 32) |
        ((uint64_t)left << 16) | right;
}

static bool matches_slot(uint64_t packed, uint32_t run, uint64_t slot)
{
    return (uint32_t)(packed >> 56) == (run & CD_LEVEL_RUN_TAG_MASK) &&
        ((packed >> 32) & CD_LEVEL_SLOT_TAG_MASK) == slot;
}

CDLevelTable *cd_level_table_create(void)
{
    CDLevelTable *table = calloc(1, sizeof(*table));
    if (!table) return NULL;

    atomic_init(&table->currentRun, 0);
    for (size_t i = 0; i < CD_LEVEL_SLOT_COUNT; ++i)
        atomic_init(&table->slots[i], 0);

    if (!atomic_is_lock_free(&table->currentRun) || !atomic_is_lock_free(&table->slots[0])) {
        free(table);
        return NULL;
    }
    return table;
}

void cd_level_table_destroy(CDLevelTable *table)
{
    free(table);
}

uint32_t cd_level_table_begin_run(CDLevelTable *table)
{
    if (!table) return 0;

    uint32_t previous = atomic_load_explicit(&table->currentRun, memory_order_relaxed);
    uint32_t run = previous + 1;
    if (run == 0 || (run & CD_LEVEL_RUN_TAG_MASK) == 0) {
        for (size_t i = 0; i < CD_LEVEL_SLOT_COUNT; ++i)
            atomic_store_explicit(&table->slots[i], 0, memory_order_relaxed);
        if (run == 0) run = 1;
        else run++;
    }
    atomic_store_explicit(&table->currentRun, run, memory_order_release);
    return run;
}

bool cd_level_table_record_block(CDLevelTable *table, uint32_t run,
                                 uint64_t startFrame, const int16_t *stereo,
                                 size_t frameCount)
{
    if (!table || !stereo || frameCount == 0 || frameCount > SIZE_MAX / CD_PCM_CHANNELS || run == 0 ||
        atomic_load_explicit(&table->currentRun, memory_order_acquire) != run ||
        (uint64_t)(frameCount - 1) > UINT64_MAX - startFrame)
        return false;

    uint64_t lastFrame = startFrame + frameCount - 1;
    if (lastFrame / CD_LEVEL_SLOT_FRAMES > CD_LEVEL_MAX_SLOT) return false;

    size_t offset = 0;
    while (offset < frameCount) {
        uint64_t frame = startFrame + offset;
        uint64_t slot = frame / CD_LEVEL_SLOT_FRAMES;
        size_t inSlot = (size_t)(frame % CD_LEVEL_SLOT_FRAMES);
        size_t count = CD_LEVEL_SLOT_FRAMES - inSlot;
        if (count > frameCount - offset) count = frameCount - offset;

        uint16_t left = 0, right = 0;
        for (size_t i = 0; i < count; ++i) {
            size_t sample = (offset + i) * CD_PCM_CHANNELS;
            uint16_t leftSample = sample_magnitude(stereo[sample]);
            uint16_t rightSample = sample_magnitude(stereo[sample + 1]);
            if (leftSample > left) left = leftSample;
            if (rightSample > right) right = rightSample;
        }

        _Atomic uint64_t *entry = &table->slots[slot & CD_LEVEL_SLOT_INDEX_MASK];
        uint64_t existing = atomic_load_explicit(entry, memory_order_relaxed);
        if (matches_slot(existing, run, slot)) {
            uint16_t oldLeft = (uint16_t)(existing >> 16);
            uint16_t oldRight = (uint16_t)existing;
            if (oldLeft > left) left = oldLeft;
            if (oldRight > right) right = oldRight;
        }
        atomic_store_explicit(entry, pack_slot(run, slot, left, right), memory_order_release);
        offset += count;
    }
    return atomic_load_explicit(&table->currentRun, memory_order_acquire) == run;
}

bool cd_level_table_read(const CDLevelTable *table, uint32_t run,
                         uint64_t frame, CDLevelPeaks *peaks)
{
    if (!table || !peaks || run == 0 ||
        atomic_load_explicit(&table->currentRun, memory_order_acquire) != run)
        return false;

    uint64_t slot = frame / CD_LEVEL_SLOT_FRAMES;
    if (slot > CD_LEVEL_MAX_SLOT) return false;
    uint64_t packed = atomic_load_explicit(
        &table->slots[slot & CD_LEVEL_SLOT_INDEX_MASK], memory_order_acquire);
    if (!matches_slot(packed, run, slot) ||
        atomic_load_explicit(&table->currentRun, memory_order_acquire) != run)
        return false;

    peaks->leftPeak = (uint16_t)(packed >> 16);
    peaks->rightPeak = (uint16_t)packed;
    return true;
}

uint32_t cd_level_table_current_run(const CDLevelTable *table)
{
    return table ? atomic_load_explicit(&table->currentRun, memory_order_acquire) : 0;
}
