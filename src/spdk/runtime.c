#include "runtime.h"

#include "spdk/event.h"
#include "spdk/thread.h"

#include <assert.h>
#include <errno.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

enum runtime_state {
	RUNTIME_STARTING,
	RUNTIME_READY,
	RUNTIME_STOPPING,
	RUNTIME_STOPPED,
	RUNTIME_FAILED,
};

struct zettide_spdk_runtime {
	pthread_mutex_t mutex;
	pthread_cond_t condition;
	pthread_t thread;
	enum runtime_state state;
	struct spdk_thread *owner;
	size_t active_leases;
	int app_status;
	char *name;
	char *reactor_mask;
	void *json_data;
	size_t json_data_size;
	int mem_size_mb;
	bool no_pci;
	bool no_huge;
	bool disable_cpumask_locks;
};

static pthread_mutex_t g_runtime_mutex = PTHREAD_MUTEX_INITIALIZER;
static bool g_runtime_active;

static void
release_process_slot(void)
{
	int rc = pthread_mutex_lock(&g_runtime_mutex);

	assert(rc == 0);
	assert(g_runtime_active);
	g_runtime_active = false;
	rc = pthread_mutex_unlock(&g_runtime_mutex);
	assert(rc == 0);
}

static void
runtime_started(void *context)
{
	struct zettide_spdk_runtime *runtime = context;
	int rc;

	rc = pthread_mutex_lock(&runtime->mutex);
	assert(rc == 0);
	assert(runtime->state == RUNTIME_STARTING);
	runtime->owner = spdk_get_thread();
	runtime->state = RUNTIME_READY;
	rc = pthread_cond_broadcast(&runtime->condition);
	assert(rc == 0);
	rc = pthread_mutex_unlock(&runtime->mutex);
	assert(rc == 0);
}

static void *
run_runtime(void *context)
{
	struct zettide_spdk_runtime *runtime = context;
	struct spdk_app_opts options = {0};
	int status;
	int rc;

	spdk_app_opts_init(&options, sizeof(options));
	options.name = runtime->name;
	options.reactor_mask = runtime->reactor_mask;
	options.rpc_addr = NULL;
	options.json_data = runtime->json_data;
	options.json_data_size = runtime->json_data_size;
	options.mem_size = runtime->mem_size_mb;
	options.no_pci = runtime->no_pci;
	options.no_huge = runtime->no_huge;
	options.disable_signal_handlers = true;
	options.disable_cpumask_locks = runtime->disable_cpumask_locks;
	status = spdk_app_start(&options, runtime_started, runtime);
	rc = pthread_mutex_lock(&runtime->mutex);
	assert(rc == 0);
	runtime->app_status = status;
	runtime->owner = NULL;
	if (runtime->state == RUNTIME_STARTING) {
		runtime->state = RUNTIME_FAILED;
	} else if (runtime->state == RUNTIME_STOPPING) {
		/* The stopping thread owns join and publishes STOPPED. */
	} else {
		assert(runtime->state == RUNTIME_READY);
		runtime->state = RUNTIME_FAILED;
	}
	rc = pthread_cond_broadcast(&runtime->condition);
	assert(rc == 0);
	rc = pthread_mutex_unlock(&runtime->mutex);
	assert(rc == 0);
	spdk_app_fini();
	return NULL;
}

static void
stop_runtime(void *context)
{
	(void)context;
	spdk_app_stop(0);
}

static void
free_runtime_fields(struct zettide_spdk_runtime *runtime)
{
	free(runtime->json_data);
	free(runtime->reactor_mask);
	free(runtime->name);
}

static void
free_runtime(struct zettide_spdk_runtime *runtime)
{
	int rc;

	free_runtime_fields(runtime);
	rc = pthread_cond_destroy(&runtime->condition);
	assert(rc == 0);
	rc = pthread_mutex_destroy(&runtime->mutex);
	assert(rc == 0);
	free(runtime);
}

void
zettide_spdk_runtime_opts_init(struct zettide_spdk_runtime_opts *opts,
		size_t opts_size)
{
	if (opts == NULL || opts_size == 0) {
		return;
	}
	memset(opts, 0, opts_size);
	if (opts_size >= sizeof(*opts)) {
		opts->opts_size = opts_size;
		opts->disable_signal_handlers = true;
	}
}

int
zettide_spdk_runtime_start(const struct zettide_spdk_runtime_opts *opts,
		struct zettide_spdk_runtime **runtime_out)
{
	struct zettide_spdk_runtime *runtime;
	int status;
	int rc;
	int old_cancel_state;
	int ignored_cancel_state;

	if (opts == NULL || runtime_out == NULL || opts->opts_size != sizeof(*opts) ||
		opts->name == NULL || !opts->disable_signal_handlers ||
		(opts->json_data == NULL && opts->json_data_size != 0)) {
		return -EINVAL;
	}
	*runtime_out = NULL;
	rc = pthread_mutex_lock(&g_runtime_mutex);
	if (rc != 0) {
		return -rc;
	}
	if (g_runtime_active) {
		(void)pthread_mutex_unlock(&g_runtime_mutex);
		return -EBUSY;
	}
	g_runtime_active = true;
	rc = pthread_mutex_unlock(&g_runtime_mutex);
	assert(rc == 0);

	runtime = calloc(1, sizeof(*runtime));
	if (runtime == NULL) {
		release_process_slot();
		return -ENOMEM;
	}
	runtime->name = strdup(opts->name);
	runtime->reactor_mask = opts->reactor_mask == NULL ? NULL : strdup(opts->reactor_mask);
	if (opts->json_data_size != 0) {
		runtime->json_data = malloc(opts->json_data_size);
		if (runtime->json_data != NULL) {
			memcpy(runtime->json_data, opts->json_data, opts->json_data_size);
		}
	}
	if (runtime->name == NULL ||
		(opts->reactor_mask != NULL && runtime->reactor_mask == NULL) ||
		(opts->json_data_size != 0 && runtime->json_data == NULL)) {
		free_runtime_fields(runtime);
		free(runtime);
		release_process_slot();
		return -ENOMEM;
	}
	runtime->json_data_size = opts->json_data_size;
	runtime->mem_size_mb = opts->mem_size_mb;
	runtime->no_pci = opts->no_pci;
	runtime->no_huge = opts->no_huge;
	runtime->disable_cpumask_locks = opts->disable_cpumask_locks;
	runtime->state = RUNTIME_STARTING;
	rc = pthread_mutex_init(&runtime->mutex, NULL);
	if (rc != 0) {
		free_runtime_fields(runtime);
		free(runtime);
		release_process_slot();
		return -rc;
	}
	rc = pthread_cond_init(&runtime->condition, NULL);
	if (rc != 0) {
		(void)pthread_mutex_destroy(&runtime->mutex);
		free_runtime_fields(runtime);
		free(runtime);
		release_process_slot();
		return -rc;
	}
	rc = pthread_create(&runtime->thread, NULL, run_runtime, runtime);
	if (rc != 0) {
		free_runtime(runtime);
		release_process_slot();
		return -rc;
	}
	rc = pthread_setcancelstate(PTHREAD_CANCEL_DISABLE, &old_cancel_state);
	assert(rc == 0);
	rc = pthread_mutex_lock(&runtime->mutex);
	assert(rc == 0);
	while (runtime->state == RUNTIME_STARTING) {
		rc = pthread_cond_wait(&runtime->condition, &runtime->mutex);
		assert(rc == 0);
	}
	if (runtime->state == RUNTIME_READY) {
		*runtime_out = runtime;
		status = 0;
	} else {
		status = runtime->app_status != 0 ? runtime->app_status : -EIO;
	}
	rc = pthread_mutex_unlock(&runtime->mutex);
	assert(rc == 0);
	if (status != 0) {
		rc = pthread_join(runtime->thread, NULL);
		assert(rc == 0);
		free_runtime(runtime);
		release_process_slot();
	}
	rc = pthread_setcancelstate(old_cancel_state, &ignored_cancel_state);
	assert(rc == 0);
	return status;
}

int
zettide_spdk_runtime_stop(struct zettide_spdk_runtime *runtime)
{
	struct spdk_thread *owner;
	int rc;
	int old_cancel_state;
	int ignored_cancel_state;
	int status;

	if (runtime == NULL) {
		return -EINVAL;
	}
	if (pthread_equal(pthread_self(), runtime->thread)) {
		return -EDEADLK;
	}
	rc = pthread_setcancelstate(PTHREAD_CANCEL_DISABLE, &old_cancel_state);
	if (rc != 0) {
		return -rc;
	}
	rc = pthread_mutex_lock(&runtime->mutex);
	assert(rc == 0);
	if (runtime->state == RUNTIME_STOPPED) {
		(void)pthread_mutex_unlock(&runtime->mutex);
		status = 0;
		goto restore_cancel;
	}
	if (runtime->state == RUNTIME_FAILED) {
		if (runtime->active_leases != 0) {
			(void)pthread_mutex_unlock(&runtime->mutex);
			status = -EIO;
			goto restore_cancel;
		}
		runtime->state = RUNTIME_STOPPING;
		owner = NULL;
	} else if (runtime->state == RUNTIME_READY) {
		if (runtime->active_leases != 0) {
			(void)pthread_mutex_unlock(&runtime->mutex);
			status = -EBUSY;
			goto restore_cancel;
		}
		runtime->state = RUNTIME_STOPPING;
		owner = runtime->owner;
	} else {
		(void)pthread_mutex_unlock(&runtime->mutex);
		status = -EALREADY;
		goto restore_cancel;
	}
	rc = pthread_mutex_unlock(&runtime->mutex);
	assert(rc == 0);
	if (owner != NULL) {
		rc = spdk_thread_send_msg(owner, stop_runtime, runtime);
	} else {
		rc = 0;
	}
	if (rc != 0 && owner != NULL) {
		int lock_rc = pthread_mutex_lock(&runtime->mutex);

		assert(lock_rc == 0);
		runtime->state = RUNTIME_READY;
		lock_rc = pthread_mutex_unlock(&runtime->mutex);
		assert(lock_rc == 0);
		status = rc;
		goto restore_cancel;
	}
	rc = pthread_join(runtime->thread, NULL);
	assert(rc == 0);
	rc = pthread_mutex_lock(&runtime->mutex);
	assert(rc == 0);
	assert(runtime->state == RUNTIME_STOPPING);
	runtime->state = RUNTIME_STOPPED;
	status = runtime->app_status;
	rc = pthread_mutex_unlock(&runtime->mutex);
	assert(rc == 0);
	release_process_slot();

restore_cancel:
	rc = pthread_setcancelstate(old_cancel_state, &ignored_cancel_state);
	assert(rc == 0);
	return status;
}

int
zettide_spdk_runtime_destroy(struct zettide_spdk_runtime *runtime)
{
	int rc;

	if (runtime == NULL) {
		return -EINVAL;
	}
	rc = pthread_mutex_lock(&runtime->mutex);
	assert(rc == 0);
	if (runtime->state != RUNTIME_STOPPED) {
		(void)pthread_mutex_unlock(&runtime->mutex);
		return -EBUSY;
	}
	rc = pthread_mutex_unlock(&runtime->mutex);
	assert(rc == 0);
	free_runtime(runtime);
	return 0;
}

int
zettide_spdk_runtime_acquire(struct zettide_spdk_runtime *runtime,
		struct spdk_thread **owner_out)
{
	int rc;

	if (runtime == NULL || owner_out == NULL) {
		return -EINVAL;
	}
	*owner_out = NULL;
	rc = pthread_mutex_lock(&runtime->mutex);
	assert(rc == 0);
	if (runtime->state != RUNTIME_READY) {
		(void)pthread_mutex_unlock(&runtime->mutex);
		return -ESHUTDOWN;
	}
	runtime->active_leases++;
	*owner_out = runtime->owner;
	rc = pthread_mutex_unlock(&runtime->mutex);
	assert(rc == 0);
	return 0;
}

void
zettide_spdk_runtime_release(struct zettide_spdk_runtime *runtime)
{
	int rc;

	rc = pthread_mutex_lock(&runtime->mutex);
	assert(rc == 0);
	assert(runtime->active_leases > 0);
	runtime->active_leases--;
	rc = pthread_mutex_unlock(&runtime->mutex);
	assert(rc == 0);
}
