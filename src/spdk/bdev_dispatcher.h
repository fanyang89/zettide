#ifndef ZETTIDE_SPDK_BDEV_DISPATCHER_H
#define ZETTIDE_SPDK_BDEV_DISPATCHER_H

#include "bdev_endpoint.h"
#include "runtime.h"

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

struct zettide_spdk_bdev_dispatcher;

struct zettide_spdk_bdev_dispatcher_read {
	void *buffer;
	uint64_t offset;
	uint64_t length;
};

typedef void (*zettide_spdk_bdev_dispatcher_batch_cb)(void *callback_context, bool direct);

/*
 * These blocking calls must only be made from non-SPDK threads. The owner must
 * remain alive and polling until every call and dispatcher close has returned.
 */
int zettide_spdk_bdev_dispatcher_open(struct zettide_spdk_runtime *runtime,
		const char *name, bool writable,
		struct zettide_spdk_bdev_dispatcher **dispatcher_out);
/* Low-level entry point for tests that already own an SPDK application thread. */
int zettide_spdk_bdev_dispatcher_open_on_thread(struct spdk_thread *owner, const char *name,
		bool writable, struct zettide_spdk_bdev_dispatcher **dispatcher_out);
int zettide_spdk_bdev_dispatcher_get_geometry(
		struct zettide_spdk_bdev_dispatcher *dispatcher,
		struct zettide_spdk_bdev_geometry *geometry_out);
/* The caller owns name_out with free() after a successful call. */
int zettide_spdk_bdev_dispatcher_get_name(
		struct zettide_spdk_bdev_dispatcher *dispatcher, char **name_out);
int zettide_spdk_bdev_dispatcher_read(struct zettide_spdk_bdev_dispatcher *dispatcher,
		void *buffer, uint64_t offset, uint64_t length);
/*
 * The reads name their final destinations. The owner submits the entire batch
 * directly only when every destination is fully DMA-capable; otherwise it uses
 * one internal DMA bounce buffer. On success, each status is filled and callback
 * is called exactly once on the SPDK owner thread with the selected path. The
 * callback must not block or reenter the dispatcher. The caller must keep the
 * destinations, statuses, and callback context alive until it returns.
 */
int zettide_spdk_bdev_dispatcher_submit_read_many(
		struct zettide_spdk_bdev_dispatcher *dispatcher,
		const struct zettide_spdk_bdev_dispatcher_read *reads, size_t read_count,
		int *statuses, zettide_spdk_bdev_dispatcher_batch_cb callback,
		void *callback_context);
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
