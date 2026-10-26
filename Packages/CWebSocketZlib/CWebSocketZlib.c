// SPDX-License-Identifier: Apache-2.0
// Original adapter for the public system zlib API. No vendored implementation.
#include "CWebSocketZlib.h"
#include <limits.h>
#include <string.h>
struct PWWSInflater {
    z_stream stream;
    void *context;
    PWWSAlloc alloc;
    PWWSFree free_fn;
};
// malloc alignment is preserved for zlib, and the header itself is budgeted.
typedef union { max_align_t alignment; size_t bytes; } PWWSAllocation;
static voidpf allocate_block(voidpf opaque, uInt items, uInt size) {
    PWWSInflater *owner = opaque;
    if (size && items > SIZE_MAX / size) return NULL;
    size_t bytes = (size_t)items * size;
    if (bytes > SIZE_MAX - sizeof(PWWSAllocation)) return NULL;
    bytes += sizeof(PWWSAllocation);
    PWWSAllocation *block = owner->alloc(owner->context, bytes);
    if (!block) return NULL;
    block->bytes = bytes;
    return block + 1;
}
static void free_block(voidpf opaque, voidpf pointer) {
    if (!pointer) return;
    PWWSInflater *owner = opaque;
    PWWSAllocation *block = (PWWSAllocation *)pointer - 1;
    owner->free_fn(owner->context, block, block->bytes);
}
PWWSInflater *pwws_create(int bits, void *context, PWWSAlloc alloc, PWWSFree free_fn, int *status) {
    if (!status) return NULL;
    *status = Z_STREAM_ERROR;
    if (bits < 8 || bits > 15 || !alloc || !free_fn) return NULL;
    PWWSInflater *owner = alloc(context, sizeof(*owner));
    if (!owner) { *status = Z_MEM_ERROR; return NULL; }
    memset(owner, 0, sizeof(*owner));
    owner->context = context; owner->alloc = alloc; owner->free_fn = free_fn;
    owner->stream.zalloc = allocate_block; owner->stream.zfree = free_block; owner->stream.opaque = owner;
    *status = inflateInit2_(&owner->stream, -bits, ZLIB_VERSION, sizeof(z_stream));
    if (*status != Z_OK) { free_fn(context, owner, sizeof(*owner)); return NULL; }
    return owner;
}
int pwws_inflate(PWWSInflater *owner, const uint8_t *input, size_t count, size_t *consumed,
                 uint8_t *output, size_t capacity, size_t *produced) {
    if (!consumed || !produced) return Z_STREAM_ERROR;
    *consumed = 0; *produced = 0;
    if (!owner || count > UINT_MAX || capacity > UINT_MAX || (count && !input) || !output || !capacity) return Z_STREAM_ERROR;
    owner->stream.next_in = (Bytef *)input; owner->stream.avail_in = (uInt)count;
    owner->stream.next_out = output; owner->stream.avail_out = (uInt)capacity;
    // Stop at block boundaries so empty-block floods consume native-operation tokens.
    int status = inflate(&owner->stream, Z_BLOCK);
    *consumed = count - owner->stream.avail_in; *produced = capacity - owner->stream.avail_out;
    owner->stream.next_in = NULL; owner->stream.avail_in = 0;
    owner->stream.next_out = NULL; owner->stream.avail_out = 0;
    return status;
}
int pwws_get_dictionary(PWWSInflater *owner, uint8_t *out, size_t capacity, size_t *count) {
    if (!owner || !out || !count || capacity < 32768) return Z_STREAM_ERROR;
    uInt length = 0;
    int status = inflateGetDictionary(&owner->stream, out, &length);
    *count = length; return status;
}
int pwws_at_block_boundary(const PWWSInflater *owner) {
    return owner && (owner->stream.data_type & 128) != 0;
}
int pwws_reset(PWWSInflater *owner) { return owner ? inflateReset(&owner->stream) : Z_STREAM_ERROR; }
int pwws_set_dictionary(PWWSInflater *owner, const uint8_t *dictionary, size_t count) {
    if (!owner || count > 32768 || (count && !dictionary)) return Z_STREAM_ERROR;
    return inflateSetDictionary(&owner->stream, dictionary, (uInt)count);
}
void pwws_destroy(PWWSInflater *owner) {
    if (!owner) return;
    inflateEnd(&owner->stream);
    owner->free_fn(owner->context, owner, sizeof(*owner));
}
