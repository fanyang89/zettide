#ifndef ZETTIDE_SPDK_BDEV_ENDPOINT_H
#define ZETTIDE_SPDK_BDEV_ENDPOINT_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define ZETTIDE_SPDK_BDEV_WRITABLE (1u << 0)
#define ZETTIDE_SPDK_BDEV_FLUSH_SUPPORTED (1u << 1)
#define ZETTIDE_SPDK_BDEV_WRITE_CACHE (1u << 2)

struct zettide_spdk_bdev_endpoint;

struct zettide_spdk_bdev_geometry {
	uint64_t capacity_bytes;
	uint64_t block_count;
	uint32_t logical_block_size;
	uint32_t write_unit_blocks;
	uint32_t buffer_alignment;
	uint32_t flags;
};

enum zettide_spdk_bdev_event {
	ZETTIDE_SPDK_BDEV_REMOVE = 1,
	ZETTIDE_SPDK_BDEV_RESIZE = 2,
};

typedef void (*zettide_spdk_bdev_io_cb)(void *callback_context, int status);
typedef void (*zettide_spdk_bdev_event_cb)(void *callback_context,
		struct zettide_spdk_bdev_endpoint *endpoint,
		enum zettide_spdk_bdev_event event);

/* Endpoint operations are confined to the SPDK thread that opens the endpoint. */
int zettide_spdk_bdev_open(const char *name, bool writable,
		zettide_spdk_bdev_event_cb event_cb, void *event_context,
		struct zettide_spdk_bdev_endpoint **endpoint_out);
int zettide_spdk_bdev_close(struct zettide_spdk_bdev_endpoint *endpoint);

const struct zettide_spdk_bdev_geometry *
zettide_spdk_bdev_get_geometry(const struct zettide_spdk_bdev_endpoint *endpoint);
const char *zettide_spdk_bdev_get_name(const struct zettide_spdk_bdev_endpoint *endpoint);
bool zettide_spdk_bdev_buffer_is_dma_capable(
		const struct zettide_spdk_bdev_endpoint *endpoint,
		const void *buffer, uint64_t length);

/*
 * Data buffers must remain fully DMA-capable until completion. They may come
 * from the DMA allocators below or from memory registered with SPDK. A
 * successful submission calls its callback exactly once.
 */
int zettide_spdk_bdev_read(struct zettide_spdk_bdev_endpoint *endpoint,
		void *buffer, uint64_t offset, uint64_t length,
		zettide_spdk_bdev_io_cb callback, void *callback_context);
int zettide_spdk_bdev_write(struct zettide_spdk_bdev_endpoint *endpoint,
		const void *buffer, uint64_t offset, uint64_t length,
		zettide_spdk_bdev_io_cb callback, void *callback_context);
int zettide_spdk_bdev_flush(struct zettide_spdk_bdev_endpoint *endpoint,
		uint64_t offset, uint64_t length,
		zettide_spdk_bdev_io_cb callback, void *callback_context);

void *zettide_spdk_dma_malloc(size_t size, size_t alignment);
void *zettide_spdk_dma_zmalloc(size_t size, size_t alignment);
void zettide_spdk_dma_free(void *buffer);

#ifdef __cplusplus
}
#endif

#endif
