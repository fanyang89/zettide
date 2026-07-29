#include "spdk_runtime.h"

#include "spdk/event.h"
#include "spdk/thread.h"

#include <errno.h>
#include <pthread.h>
#include <sched.h>
#include <stdbool.h>
#include <stdio.h>

struct test_runtime {
	struct spdk_thread *owner;
	zettide_spdk_test_fn test_fn;
	void *test_context;
	pthread_t coordinator;
	bool coordinator_started;
	int status;
};

static void
stop_test(void *context)
{
	struct test_runtime *runtime = context;

	spdk_app_stop(runtime->status);
}

static void *
run_test(void *context)
{
	struct test_runtime *runtime = context;

	runtime->status = runtime->test_fn(runtime->owner, runtime->test_context);
	(void)spdk_thread_send_msg(runtime->owner, stop_test, runtime);
	return NULL;
}

static void
start_test(void *context)
{
	struct test_runtime *runtime = context;
	int status;

	runtime->owner = spdk_get_thread();
	status = pthread_create(&runtime->coordinator, NULL, run_test, runtime);
	if (status != 0) {
		runtime->status = -status;
		spdk_app_stop(runtime->status);
	} else {
		runtime->coordinator_started = true;
	}
}

static int
first_allowed_cpu(void)
{
	cpu_set_t allowed;
	int cpu;

	if (sched_getaffinity(0, sizeof(allowed), &allowed) != 0) {
		return -1;
	}
	for (cpu = 0; cpu < CPU_SETSIZE; cpu++) {
		if (CPU_ISSET(cpu, &allowed)) {
			return cpu;
		}
	}
	return -1;
}

int
zettide_spdk_test_run(const char *name, const char *json_data,
		size_t json_data_size, zettide_spdk_test_fn test_fn, void *test_context)
{
	struct spdk_app_opts options = {0};
	struct test_runtime runtime = {
		.test_fn = test_fn,
		.test_context = test_context,
	};
	char reactor_mask[32];
	int cpu = first_allowed_cpu();
	int status;

	if (name == NULL || json_data == NULL || test_fn == NULL || cpu < 0 ||
		snprintf(reactor_mask, sizeof(reactor_mask), "[%d]", cpu) < 0) {
		return -EINVAL;
	}
	spdk_app_opts_init(&options, sizeof(options));
	options.name = name;
	options.rpc_addr = NULL;
	options.reactor_mask = reactor_mask;
	options.mem_size = 512;
	options.no_pci = true;
	options.no_huge = true;
	options.disable_signal_handlers = true;
	options.disable_cpumask_locks = true;
	options.json_data = (void *)json_data;
	options.json_data_size = json_data_size;
	status = spdk_app_start(&options, start_test, &runtime);
	if (runtime.coordinator_started) {
		int join_status = pthread_join(runtime.coordinator, NULL);

		if (status == 0 && join_status != 0) {
			status = -join_status;
		}
	}
	spdk_app_fini();
	return status != 0 ? status : runtime.status;
}
