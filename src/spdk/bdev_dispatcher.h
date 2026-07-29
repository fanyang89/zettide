#ifndef ZETTIDE_SPDK_BDEV_DISPATCHER_H
#define ZETTIDE_SPDK_BDEV_DISPATCHER_H

#include "bdev_endpoint.h"

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

struct spdk_thread;
struct zettide_spdk_bdev_dispatcher;

/*
 * These blocking calls must only be made from non-SPDK threads. The owner must
 * remain alive and polling until every call and dispatcher close has returned.
 */
int zettide_spdk_bdev_dispatcher_open(struct spdk_thread *owner, const char *name,
		bool writable, struct zettide_spdk_bdev_dispatcher **dispatcher_out);
int zettide_spdk_bdev_dispatcher_get_geometry(
		struct zettide_spdk_bdev_dispatcher *dispatcher,
		struct zettide_spdk_bdev_geometry *geometry_out);
/* The caller owns name_out with free() after a successful call. */
int zettide_spdk_bdev_dispatcher_get_name(
		struct zettide_spdk_bdev_dispatcher *dispatcher, char **name_out);
int zettide_spdk_bdev_dispatcher_read(struct zettide_spdk_bdev_dispatcher *dispatcher,
		void *buffer, uint64_t offset, uint64_t length);
int zettide_spdk_bdev_dispatcher_write(struct zettide_spdk_bdev_dispatcher *dispatcher,
		const void *buffer, uint64_t offset, uint64_t length);
int zettide_spdk_bdev_dispatcher_flush(struct zettide_spdk_bdev_dispatcher *dispatcher,
		uint64_t offset, uint64_t length);

/* The caller must stop and join every operation using this dispatcher first. */
int zettide_spdk_bdev_dispatcher_close(struct zettide_spdk_bdev_dispatcher *dispatcher);

#ifdef __cplusplus
}
#endif

#endif
