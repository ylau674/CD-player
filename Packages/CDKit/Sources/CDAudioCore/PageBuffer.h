#ifndef CD_PAGE_BUFFER_H
#define CD_PAGE_BUFFER_H

#include "CDAudioCore.h"
#include <stdatomic.h>

/* Anonymous pages whose unused part is handed back to macOS while the mapping stays in place.
   macOS keeps freed malloc blocks in the process footprint; reusable pages leave it at once.
   Claimed bytes always start at the base. */
typedef struct {
    void *base;
    size_t mappedBytes;
    /* Written only by the buffer's single owner at any time; atomic so diagnostics can read it. */
    _Atomic size_t claimedBytes;
} CDPageBuffer;

size_t cd_page_round(size_t bytes);
bool cd_page_buffer_map(CDPageBuffer *buffer, size_t bytes);
void cd_page_buffer_unmap(CDPageBuffer *buffer);
/* Claims the first bytes for writing and returns the rest to macOS. Call it before writing to pages
   that were returned: macOS may discard a returned page's contents at any time, even after a write.
   Claiming zero returns the whole buffer. Returns false only when returned pages cannot be claimed. */
bool cd_page_buffer_claim(CDPageBuffer *buffer, size_t bytes);
CDPageUsage cd_page_buffer_usage(const CDPageBuffer *buffer);

#endif
