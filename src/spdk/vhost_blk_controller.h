#ifndef ZETTIDE_SPDK_VHOST_BLK_CONTROLLER_H
#define ZETTIDE_SPDK_VHOST_BLK_CONTROLLER_H

#include "runtime.h"

#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

struct zettide_spdk_vhost_blk_controller;

struct zettide_spdk_vhost_blk_controller_opts {
	size_t opts_size;
	const char *name;
	const char *bdev_name;
	const char *cpumask;
};

/* Calls that operate on the same controller must be externally serialized. */
void zettide_spdk_vhost_blk_controller_opts_init(
		struct zettide_spdk_vhost_blk_controller_opts *opts, size_t opts_size);
int zettide_spdk_vhost_blk_controller_create(struct zettide_spdk_runtime *runtime,
		const struct zettide_spdk_vhost_blk_controller_opts *opts,
		struct zettide_spdk_vhost_blk_controller **controller_out);
int zettide_spdk_vhost_blk_controller_remove(
		struct zettide_spdk_vhost_blk_controller *controller);
const char *zettide_spdk_vhost_blk_controller_get_socket_path(
		const struct zettide_spdk_vhost_blk_controller *controller);
bool zettide_spdk_vhost_blk_controller_is_ready(
		const struct zettide_spdk_vhost_blk_controller *controller);

#ifdef __cplusplus
}
#endif

#endif
