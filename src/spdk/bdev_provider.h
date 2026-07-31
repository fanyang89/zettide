#ifndef ZETTIDE_SPDK_BDEV_PROVIDER_H
#define ZETTIDE_SPDK_BDEV_PROVIDER_H

#include "runtime.h"

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

struct zettide_spdk_bdev_provider;

enum zettide_spdk_bdev_provider_operation {
	ZETTIDE_SPDK_BDEV_PROVIDER_READ,
	ZETTIDE_SPDK_BDEV_PROVIDER_WRITE,
	ZETTIDE_SPDK_BDEV_PROVIDER_FLUSH,
	ZETTIDE_SPDK_BDEV_PROVIDER_RESET,
};

typedef void (*zettide_spdk_bdev_provider_complete)(void *context, int status);
typedef void (*zettide_spdk_bdev_provider_delete_complete)(void *context, int status);

/*
 * Submit must not block. A zero return transfers completion ownership to the
 * backend, which may invoke complete from any thread. A nonzero return means
 * complete was not invoked and the request was rejected synchronously.
 */
typedef int (*zettide_spdk_bdev_provider_submit)(
		void *backend_context,
		enum zettide_spdk_bdev_provider_operation operation,
		uint64_t offset,
		void *buffer,
		uint64_t length,
		zettide_spdk_bdev_provider_complete complete,
		void *complete_context);

struct zettide_spdk_bdev_provider_opts {
	size_t opts_size;
	const char *name;
	uint32_t block_size;
	uint64_t block_count;
	uint32_t write_unit_blocks;
	uint32_t max_io_blocks;
	void *backend_context;
	zettide_spdk_bdev_provider_submit submit;
};

void zettide_spdk_bdev_provider_opts_init(
		struct zettide_spdk_bdev_provider_opts *opts,
		size_t opts_size);

int zettide_spdk_bdev_provider_create(
		struct zettide_spdk_runtime *runtime,
		const struct zettide_spdk_bdev_provider_opts *opts,
		struct zettide_spdk_bdev_provider **provider_out);

/* A zero return transfers provider ownership; completion may wait for open consumers to close. */
int zettide_spdk_bdev_provider_delete(
		struct zettide_spdk_bdev_provider *provider,
		zettide_spdk_bdev_provider_delete_complete complete,
		void *complete_context);

#ifdef __cplusplus
}
#endif

#endif
