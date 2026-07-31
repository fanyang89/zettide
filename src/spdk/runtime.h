#ifndef ZETTIDE_SPDK_RUNTIME_H
#define ZETTIDE_SPDK_RUNTIME_H

#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

struct spdk_thread;
struct zettide_spdk_runtime;

/*
 * Public calls require deferred pthread cancellation. Runtime shutdown is
 * exclusive: close every dispatcher, then call stop instead of spdk_app_stop.
 */

struct zettide_spdk_runtime_opts {
	size_t opts_size;
	const char *name;
	const char *reactor_mask;
	const void *json_data;
	size_t json_data_size;
	int mem_size_mb;
	bool no_pci;
	bool no_huge;
	bool disable_signal_handlers;
	bool disable_cpumask_locks;
	const char *vhost_socket_path;
};

void zettide_spdk_runtime_opts_init(struct zettide_spdk_runtime_opts *opts,
		size_t opts_size);
int zettide_spdk_runtime_start(const struct zettide_spdk_runtime_opts *opts,
		struct zettide_spdk_runtime **runtime_out);
int zettide_spdk_runtime_stop(struct zettide_spdk_runtime *runtime);
int zettide_spdk_runtime_destroy(struct zettide_spdk_runtime *runtime);

/* Used by clients to hold the runtime ready until asynchronous teardown succeeds. */
int zettide_spdk_runtime_acquire(struct zettide_spdk_runtime *runtime,
		struct spdk_thread **owner_out);
void zettide_spdk_runtime_release(struct zettide_spdk_runtime *runtime);
const char *zettide_spdk_runtime_get_vhost_socket_path(
		const struct zettide_spdk_runtime *runtime);

#ifdef __cplusplus
}
#endif

#endif
