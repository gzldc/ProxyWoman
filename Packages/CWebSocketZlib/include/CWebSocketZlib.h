// SPDX-License-Identifier: Apache-2.0
#ifndef C_WEBSOCKET_ZLIB_H
#define C_WEBSOCKET_ZLIB_H
#include <stddef.h>
#include <stdint.h>
#include <zlib.h>
typedef struct PWWSInflater PWWSInflater;
typedef void *(*PWWSAlloc)(void *context, size_t bytes);
typedef void (*PWWSFree)(void *context, void *pointer, size_t bytes);
PWWSInflater *pwws_create(int window_bits, void *context, PWWSAlloc alloc, PWWSFree free_fn, int *status);
int pwws_inflate(PWWSInflater *, const uint8_t *, size_t, size_t *consumed, uint8_t *, size_t, size_t *produced);
int pwws_get_dictionary(PWWSInflater *, uint8_t *out, size_t capacity, size_t *count);
// Read-only Z_BLOCK boundary observation; no native processing work.
int pwws_at_block_boundary(const PWWSInflater *);
int pwws_reset(PWWSInflater *);
int pwws_set_dictionary(PWWSInflater *, const uint8_t *, size_t);
void pwws_destroy(PWWSInflater *);
#endif
