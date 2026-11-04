#include "PageBuffer.h"
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <sys/mman.h>
#include <unistd.h>

/* Under AddressSanitizer, bytes outside the claim are poisoned, so a write to a returned page fails
   the sanitized tests instead of losing audio when macOS reclaims that page. */
#if defined(__has_feature)
#if __has_feature(address_sanitizer)
#include <sanitizer/asan_interface.h>
#define CD_PAGE_POISON(address, bytes) ASAN_POISON_MEMORY_REGION(address, bytes)
#define CD_PAGE_UNPOISON(address, bytes) ASAN_UNPOISON_MEMORY_REGION(address, bytes)
#endif
#endif
#ifndef CD_PAGE_POISON
#define CD_PAGE_POISON(address, bytes) ((void)(address), (void)(bytes))
#define CD_PAGE_UNPOISON(address, bytes) ((void)(address), (void)(bytes))
#endif

static size_t page_size(void)
{
    return (size_t)getpagesize();
}

size_t cd_page_round(size_t bytes)
{
    size_t page = page_size();
    if (bytes > SIZE_MAX - (page - 1)) return 0;
    return (bytes + page - 1) / page * page;
}

bool cd_page_buffer_map(CDPageBuffer *buffer, size_t bytes)
{
    buffer->base = NULL;
    buffer->mappedBytes = 0;
    atomic_init(&buffer->claimedBytes, 0);
    size_t mapped = cd_page_round(bytes);
    if (mapped == 0) return false;
    void *base = mmap(NULL, mapped, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
    if (base == MAP_FAILED) return false;
    buffer->base = base;
    buffer->mappedBytes = mapped;
    CD_PAGE_POISON(base, mapped);
    return true;
}

void cd_page_buffer_unmap(CDPageBuffer *buffer)
{
    if (!buffer->base) return;
    CD_PAGE_UNPOISON(buffer->base, buffer->mappedBytes);
    munmap(buffer->base, buffer->mappedBytes);
    buffer->base = NULL;
    buffer->mappedBytes = 0;
    atomic_store_explicit(&buffer->claimedBytes, 0, memory_order_relaxed);
}

bool cd_page_buffer_claim(CDPageBuffer *buffer, size_t bytes)
{
    if (!buffer->base || bytes > buffer->mappedBytes) return false;
    char *base = buffer->base;
    size_t wanted = cd_page_round(bytes);
    size_t claimed = atomic_load_explicit(&buffer->claimedBytes, memory_order_relaxed);
    if (wanted > claimed) {
        if (madvise(base + claimed, wanted - claimed, MADV_FREE_REUSE) != 0) return false;
        claimed = wanted;
    } else if (wanted < claimed) {
        /* Pages that cannot be returned stay claimed and counted, which is harmless. */
        if (madvise(base + wanted, claimed - wanted, MADV_FREE_REUSABLE) == 0) claimed = wanted;
    }
    atomic_store_explicit(&buffer->claimedBytes, claimed, memory_order_relaxed);
    CD_PAGE_UNPOISON(base, bytes);
    CD_PAGE_POISON(base + bytes, buffer->mappedBytes - bytes);
    return true;
}

CDPageUsage cd_page_buffer_usage(const CDPageBuffer *buffer)
{
    CDPageUsage usage = {
        buffer->mappedBytes, atomic_load_explicit(&buffer->claimedBytes, memory_order_relaxed), 0
    };
    size_t page = page_size();
    for (size_t offset = 0; offset < buffer->mappedBytes; offset += page) {
        integer_t disposition = 0, references = 0;
        mach_vm_offset_t address = (mach_vm_offset_t)(uintptr_t)((char *)buffer->base + offset);
        if (mach_vm_page_query(mach_task_self(), address, &disposition, &references) != KERN_SUCCESS)
            continue;
        if ((disposition & (VM_PAGE_QUERY_PAGE_PRESENT | VM_PAGE_QUERY_PAGE_PAGED_OUT)) &&
            !(disposition & VM_PAGE_QUERY_PAGE_REUSABLE))
            usage.footprintBytes += page;
    }
    return usage;
}
