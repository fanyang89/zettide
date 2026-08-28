#include "spdk/bdev_dispatcher.h"

#include "spdk/bdev.h"
#include "spdk/bdev_module.h"
#include "spdk/env.h"
#include "spdk/event.h"
#include "spdk/thread.h"

#include <errno.h>
#include <pthread.h>
#include <sched.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
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
	test_alignment_shift = 12,
	mock_region_capacity = 4,
};

struct mock_region {
	uintptr_t start;
	uintptr_t end;
};

static struct mock_region g_mock_regions[mock_region_capacity];
static size_t g_mock_region_count;
static uint64_t g_mock_translation_limit;
static atomic_bool g_mock_translation_enabled = ATOMIC_VAR_INIT(false);
static atomic_bool g_track_dma_allocations = ATOMIC_VAR_INIT(false);
static atomic_uint g_dma_allocations = ATOMIC_VAR_INIT(0);

uint64_t __real_spdk_vtophys(const void *buffer, uint64_t *size);
void *__real_spdk_dma_malloc(size_t size, size_t alignment, uint64_t *unused);

uint64_t
__wrap_spdk_vtophys(const void *buffer, uint64_t *size)
{
	uintptr_t address;
	size_t index;

	if (!atomic_load_explicit(&g_mock_translation_enabled, memory_order_acquire)) {
		return __real_spdk_vtophys(buffer, size);
	}
	address = (uintptr_t)buffer;
	for (index = 0; index < g_mock_region_count; index++) {
		const struct mock_region *region = &g_mock_regions[index];
		uint64_t translated;

		if (address < region->start || address >= region->end) {
			continue;
		}
		translated = region->end - address;
		if (size != NULL) {
			if (translated > *size) {
				translated = *size;
			}
			if (g_mock_translation_limit != 0 && translated > g_mock_translation_limit) {
				translated = g_mock_translation_limit;
			}
			*size = translated;
		}
		return address;
	}
	return SPDK_VTOPHYS_ERROR;
}

void *
__wrap_spdk_dma_malloc(size_t size, size_t alignment, uint64_t *unused)
{
	if (atomic_load_explicit(&g_track_dma_allocations, memory_order_relaxed)) {
		atomic_fetch_add_explicit(&g_dma_allocations, 1, memory_order_relaxed);
	}
	return __real_spdk_dma_malloc(size, alignment, unused);
}

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

struct batch_completion {
	pthread_mutex_t mutex;
	pthread_cond_t condition;
	bool completed;
	bool direct;
};

static void
batch_complete(void *context, bool direct)
{
	struct batch_completion *completion = context;

	if (pthread_mutex_lock(&completion->mutex) != 0) {
		abort();
	}
	completion->direct = direct;
	completion->completed = true;
	if (pthread_cond_signal(&completion->condition) != 0 ||
		pthread_mutex_unlock(&completion->mutex) != 0) {
		abort();
	}
}

static int
submit_read_batch(struct test_context *test,
		const struct zettide_spdk_bdev_dispatcher_read *reads, size_t read_count,
		int *statuses, bool *direct)
{
	struct batch_completion completion = {0};
	int status;

	status = pthread_mutex_init(&completion.mutex, NULL);
	if (status != 0) {
		return -status;
	}
	status = pthread_cond_init(&completion.condition, NULL);
	if (status != 0) {
		(void)pthread_mutex_destroy(&completion.mutex);
		return -status;
	}
	status = zettide_spdk_bdev_dispatcher_submit_read_many(test->dispatcher,
			reads, read_count, statuses, batch_complete, &completion);
	if (status == 0) {
		status = pthread_mutex_lock(&completion.mutex);
		if (status == 0) {
			while (!completion.completed) {
				status = pthread_cond_wait(&completion.condition, &completion.mutex);
				if (status != 0) {
					break;
				}
			}
			if (status == 0) {
				*direct = completion.direct;
			}
			if (pthread_mutex_unlock(&completion.mutex) != 0 && status == 0) {
				status = EIO;
			}
		}
	}
	if (pthread_cond_destroy(&completion.condition) != 0 && status == 0) {
		status = EIO;
	}
	if (pthread_mutex_destroy(&completion.mutex) != 0 && status == 0) {
		status = EIO;
	}
	return status > 0 ? -status : status;
}

static void
mock_begin(const struct mock_region *regions, size_t region_count, uint64_t translation_limit)
{
	if (region_count > 0) {
		memcpy(g_mock_regions, regions, region_count * sizeof(*regions));
	}
	g_mock_region_count = region_count;
	g_mock_translation_limit = translation_limit;
	atomic_store_explicit(&g_dma_allocations, 0, memory_order_relaxed);
	atomic_store_explicit(&g_track_dma_allocations, true, memory_order_release);
	atomic_store_explicit(&g_mock_translation_enabled, true, memory_order_release);
}

static unsigned
mock_end(void)
{
	unsigned allocations;

	atomic_store_explicit(&g_mock_translation_enabled, false, memory_order_release);
	atomic_store_explicit(&g_track_dma_allocations, false, memory_order_release);
	allocations = atomic_load_explicit(&g_dma_allocations, memory_order_relaxed);
	return allocations;
}

static int
run_batch_case(struct test_context *test,
		const struct zettide_spdk_bdev_dispatcher_read *reads, size_t read_count,
		const int *expected_statuses, const struct mock_region *regions, size_t region_count,
		uint64_t translation_limit, bool expected_direct, unsigned expected_allocations)
{
	int statuses[2] = {0};
	bool direct = false;
	unsigned allocations;
	size_t index;
	int status;

	if (read_count > 2 || region_count > mock_region_capacity) {
		return -EINVAL;
	}
	mock_begin(regions, region_count, translation_limit);
	status = submit_read_batch(test, reads, read_count, statuses, &direct);
	allocations = mock_end();
	if (status != 0 || direct != expected_direct || allocations != expected_allocations) {
		return status != 0 ? status : -EIO;
	}
	for (index = 0; index < read_count; index++) {
		if (statuses[index] != expected_statuses[index]) {
			return -EIO;
		}
	}
	return 0;
}

static bool
buffer_is_byte(const uint8_t *buffer, size_t length, uint8_t value)
{
	size_t index;

	for (index = 0; index < length; index++) {
		if (buffer[index] != value) {
			return false;
		}
	}
	return true;
}

static int
run_batch_tests(struct test_context *test)
{
	const size_t io_size = (size_t)test->geometry.logical_block_size *
			test->geometry.write_unit_blocks;
	const size_t alignment = test->geometry.buffer_alignment;
	struct zettide_spdk_bdev_dispatcher_read reads[2];
	struct mock_region regions[2];
	const int success_statuses[2] = {0, 0};
	const int partial_error_statuses[2] = {-ERANGE, 0};
	uint8_t *write_buffer = NULL;
	uint8_t *first = NULL;
	uint8_t *second = NULL;
	size_t index;
	int status = 0;

	if (io_size == 0 || io_size > SIZE_MAX / 2 || alignment < sizeof(void *)) {
		return -EOVERFLOW;
	}
	write_buffer = zettide_spdk_dma_malloc(io_size * 2, alignment);
	if (write_buffer == NULL || posix_memalign((void **)&first, alignment, io_size + 1) != 0 ||
		posix_memalign((void **)&second, alignment, io_size + 1) != 0) {
		status = -ENOMEM;
		goto done;
	}
	for (index = 0; index < io_size * 2; index++) {
		write_buffer[index] = (uint8_t)(index * 43u + 19u);
	}
	status = zettide_spdk_bdev_dispatcher_write(test->dispatcher, write_buffer, 0, io_size * 2);
	if (status != 0) {
		goto done;
	}
	status = zettide_spdk_bdev_dispatcher_flush(test->dispatcher, 0, io_size * 2);
	if (status != 0) {
		goto done;
	}

	reads[0] = (struct zettide_spdk_bdev_dispatcher_read){
		.buffer = first, .offset = 0, .length = io_size,
	};
	reads[1] = (struct zettide_spdk_bdev_dispatcher_read){
		.buffer = second, .offset = io_size, .length = io_size,
	};
	regions[0] = (struct mock_region){(uintptr_t)first, (uintptr_t)first + io_size};
	regions[1] = (struct mock_region){(uintptr_t)second, (uintptr_t)second + io_size};
	memset(first, 0, io_size);
	memset(second, 0, io_size);
	status = run_batch_case(test, reads, 2, success_statuses, regions, 2,
			io_size / 2, true, 0);
	if (status != 0 || memcmp(first, write_buffer, io_size) != 0 ||
		memcmp(second, write_buffer + io_size, io_size) != 0) {
		status = status != 0 ? status : -EIO;
		goto done;
	}

	memset(first, 0, io_size);
	memset(second, 0, io_size);
	status = run_batch_case(test, reads, 2, success_statuses, NULL, 0, 0, false, 1);
	if (status != 0 || memcmp(first, write_buffer, io_size) != 0 ||
		memcmp(second, write_buffer + io_size, io_size) != 0) {
		status = status != 0 ? status : -EIO;
		goto done;
	}

	memset(first, 0, io_size);
	memset(second, 0, io_size);
	status = run_batch_case(test, reads, 2, success_statuses, regions, 1, 0, false, 1);
	if (status != 0 || memcmp(first, write_buffer, io_size) != 0 ||
		memcmp(second, write_buffer + io_size, io_size) != 0) {
		status = status != 0 ? status : -EIO;
		goto done;
	}

	reads[0].buffer = first + 1;
	regions[0] = (struct mock_region){(uintptr_t)(first + 1), (uintptr_t)(first + 1) + io_size};
	memset(first + 1, 0, io_size);
	memset(second, 0, io_size);
	status = run_batch_case(test, reads, 2, success_statuses, regions, 2, 0, false, 1);
	if (status != 0 || memcmp(first + 1, write_buffer, io_size) != 0 ||
		memcmp(second, write_buffer + io_size, io_size) != 0) {
		status = status != 0 ? status : -EIO;
		goto done;
	}

	reads[0].buffer = first;
	regions[0] = (struct mock_region){(uintptr_t)first, (uintptr_t)first + io_size / 2};
	memset(first, 0, io_size);
	memset(second, 0, io_size);
	status = run_batch_case(test, reads, 2, success_statuses, regions, 2, 0, false, 1);
	if (status != 0 || memcmp(first, write_buffer, io_size) != 0 ||
		memcmp(second, write_buffer + io_size, io_size) != 0) {
		status = status != 0 ? status : -EIO;
		goto done;
	}

	regions[0] = (struct mock_region){(uintptr_t)first, (uintptr_t)first + io_size};
	reads[0].offset = test->geometry.capacity_bytes;
	memset(first, 0xa5, io_size);
	memset(second, 0, io_size);
	status = run_batch_case(test, reads, 2, partial_error_statuses, regions, 2, 0, true, 0);
	if (status != 0 || !buffer_is_byte(first, io_size, 0xa5) ||
		memcmp(second, write_buffer + io_size, io_size) != 0) {
		status = status != 0 ? status : -EIO;
	}

done:
	free(second);
	free(first);
	zettide_spdk_dma_free(write_buffer);
	return status;
}

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

	status = zettide_spdk_bdev_dispatcher_open_on_thread(test->owner, "ZettideDispatch0",
			true, &test->dispatcher);
	if (status != 0) {
		finish_coordinator(test, status);
		return NULL;
	}
	status = zettide_spdk_bdev_dispatcher_get_geometry(test->dispatcher, &test->geometry);
	if (status != 0 || test->geometry.logical_block_size != 4096 ||
		test->geometry.buffer_alignment != (1u << test_alignment_shift) ||
		(test->geometry.flags & ZETTIDE_SPDK_BDEV_FLUSH_SUPPORTED) == 0) {
		status = status != 0 ? status : -EINVAL;
		goto close;
	}
	{
		char *name = NULL;

		status = zettide_spdk_bdev_dispatcher_get_name(test->dispatcher, &name);
		if (status != 0 || name == NULL || strcmp(name, "ZettideDispatch0") != 0) {
			status = status != 0 ? status : -EINVAL;
			free(name);
			goto close;
		}
		free(name);
	}
	status = run_batch_tests(test);
	if (status != 0) {
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
	struct spdk_bdev *bdev;
	struct zettide_spdk_bdev_dispatcher *unexpected = NULL;
	int status;

	test->owner = spdk_get_thread();
	bdev = spdk_bdev_get_by_name("ZettideDispatch0");
	if (bdev == NULL) {
		test->status = -ENODEV;
		spdk_app_stop(test->status);
		return;
	}
	bdev->required_alignment = test_alignment_shift;
	status = zettide_spdk_bdev_dispatcher_open_on_thread(test->owner, "ZettideDispatch0",
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
