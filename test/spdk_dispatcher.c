#include "spdk/bdev_dispatcher.h"

#include "spdk/event.h"
#include "spdk/thread.h"

#include <errno.h>
#include <pthread.h>
#include <sched.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

static const char malloc_bdev_config[] =
	"{\"subsystems\":[{\"subsystem\":\"bdev\",\"config\":["
	"{\"method\":\"bdev_set_options\",\"params\":{\"bdev_io_pool_size\":1024,"
	"\"bdev_io_cache_size\":32}},"
	"{\"method\":\"bdev_malloc_create\",\"params\":{\"name\":\"ZettideDispatch0\","
	"\"num_blocks\":256,\"block_size\":4096}}]}]}";

enum {
	worker_count = 4,
	iteration_count = 32,
};

struct test_context {
	struct spdk_thread *owner;
	struct zettide_spdk_bdev_dispatcher *dispatcher;
	struct zettide_spdk_bdev_geometry geometry;
	pthread_t coordinator;
	bool coordinator_started;
	int status;
};

struct worker_context {
	struct test_context *test;
	uint32_t index;
	int status;
};

static void
stop_test(void *context)
{
	struct test_context *test = context;

	spdk_app_stop(test->status);
}

static void
finish_coordinator(struct test_context *test, int status)
{
	test->status = status;
	(void)spdk_thread_send_msg(test->owner, stop_test, test);
}

static void *
run_worker(void *context)
{
	struct worker_context *worker = context;
	struct test_context *test = worker->test;
	uint64_t io_size = (uint64_t)test->geometry.logical_block_size *
			test->geometry.write_unit_blocks;
	uint64_t offset = io_size * worker->index;
	uint8_t *write_buffer;
	uint8_t *read_buffer;
	uint32_t iteration;
	uint64_t byte;
	int status = 0;

	write_buffer = zettide_spdk_dma_zmalloc(io_size, test->geometry.buffer_alignment);
	read_buffer = zettide_spdk_dma_zmalloc(io_size, test->geometry.buffer_alignment);
	if (write_buffer == NULL || read_buffer == NULL) {
		status = -ENOMEM;
		goto done;
	}
	for (iteration = 0; iteration < iteration_count; iteration++) {
		for (byte = 0; byte < io_size; byte++) {
			write_buffer[byte] = (uint8_t)(worker->index * 67u + iteration * 29u + byte);
		}
		memset(read_buffer, 0, io_size);
		status = zettide_spdk_bdev_dispatcher_write(test->dispatcher,
				write_buffer, offset, io_size);
		if (status != 0) {
			break;
		}
		status = zettide_spdk_bdev_dispatcher_flush(test->dispatcher, offset, io_size);
		if (status != 0) {
			break;
		}
		status = zettide_spdk_bdev_dispatcher_read(test->dispatcher,
				read_buffer, offset, io_size);
		if (status != 0 || memcmp(write_buffer, read_buffer, io_size) != 0) {
			status = status != 0 ? status : -EIO;
			break;
		}
	}

done:
	zettide_spdk_dma_free(read_buffer);
	zettide_spdk_dma_free(write_buffer);
	worker->status = status;
	return NULL;
}

static void *
run_coordinator(void *context)
{
	struct test_context *test = context;
	struct worker_context workers[worker_count] = {0};
	pthread_t threads[worker_count];
	uint32_t started = 0;
	uint32_t index;
	int status;

	status = zettide_spdk_bdev_dispatcher_open(test->owner, "ZettideDispatch0",
			true, &test->dispatcher);
	if (status != 0) {
		finish_coordinator(test, status);
		return NULL;
	}
	status = zettide_spdk_bdev_dispatcher_get_geometry(test->dispatcher, &test->geometry);
	if (status != 0 || test->geometry.logical_block_size != 4096 ||
		(test->geometry.flags & ZETTIDE_SPDK_BDEV_FLUSH_SUPPORTED) == 0) {
		status = status != 0 ? status : -EINVAL;
		goto close;
	}
	for (index = 0; index < worker_count; index++) {
		workers[index].test = test;
		workers[index].index = index;
		status = pthread_create(&threads[index], NULL, run_worker, &workers[index]);
		if (status != 0) {
			status = -status;
			break;
		}
		started++;
	}
	for (index = 0; index < started; index++) {
		int join_status = pthread_join(threads[index], NULL);

		if (status == 0 && join_status != 0) {
			status = -join_status;
		}
		if (status == 0 && workers[index].status != 0) {
			status = workers[index].status;
		}
	}

close:
	{
		int close_status = zettide_spdk_bdev_dispatcher_close(test->dispatcher);

		if (close_status == 0) {
			test->dispatcher = NULL;
		} else {
			fprintf(stderr, "dispatcher close failed: %d\n", close_status);
		}
		if (status == 0) {
			status = close_status;
		}
	}
	finish_coordinator(test, status);
	return NULL;
}

static void
start_test(void *context)
{
	struct test_context *test = context;
	struct zettide_spdk_bdev_dispatcher *unexpected = NULL;
	int status;

	test->owner = spdk_get_thread();
	status = zettide_spdk_bdev_dispatcher_open(test->owner, "ZettideDispatch0",
			true, &unexpected);
	if (status != -EDEADLK || unexpected != NULL) {
		test->status = status == 0 ? -EIO : status;
		spdk_app_stop(test->status);
		return;
	}
	status = pthread_create(&test->coordinator, NULL, run_coordinator, test);
	if (status != 0) {
		test->status = -status;
		spdk_app_stop(test->status);
	} else {
		test->coordinator_started = true;
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
main(void)
{
	struct spdk_app_opts options = {0};
	struct test_context test = {0};
	char reactor_mask[32];
	int cpu = first_allowed_cpu();
	int status;

	if (cpu < 0 || snprintf(reactor_mask, sizeof(reactor_mask), "[%d]", cpu) < 0) {
		return 1;
	}
	spdk_app_opts_init(&options, sizeof(options));
	options.name = "zettide_spdk_dispatcher_test";
	options.rpc_addr = NULL;
	options.reactor_mask = reactor_mask;
	options.mem_size = 320;
	options.no_pci = true;
	options.no_huge = true;
	options.disable_signal_handlers = true;
	options.disable_cpumask_locks = true;
	options.json_data = (void *)malloc_bdev_config;
	options.json_data_size = sizeof(malloc_bdev_config) - 1;
	status = spdk_app_start(&options, start_test, &test);
	if (test.coordinator_started) {
		int join_status = pthread_join(test.coordinator, NULL);

		if (status == 0 && join_status != 0) {
			status = -join_status;
		}
	}
	spdk_app_fini();
	return status == 0 && test.status == 0 ? 0 : 1;
}
