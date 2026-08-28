#include "spdk/bdev_dispatcher.h"
#include "spdk/bdev_provider.h"

#include "spdk/bdev.h"
#include "spdk/thread.h"

#include <assert.h>
#include <errno.h>
#include <pthread.h>
#include <sched.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/uio.h>

enum {
	block_size = 4096,
	block_count = 64,
};

static const char bdev_config[] =
	"{\"subsystems\":[{\"subsystem\":\"bdev\",\"config\":["
	"{\"method\":\"bdev_set_options\",\"params\":{\"bdev_io_pool_size\":1024,"
	"\"bdev_io_cache_size\":32}}]}]}";

struct backend_request {
	enum zettide_spdk_bdev_provider_operation operation;
	uint64_t offset;
	void *buffer;
	uint64_t length;
	zettide_spdk_bdev_provider_complete complete;
	void *complete_context;
	struct backend_request *next;
};

struct test_backend {
	pthread_mutex_t mutex;
	pthread_cond_t condition;
	pthread_t worker;
	struct backend_request *head;
	struct backend_request *tail;
	uint8_t *data;
	uint64_t capacity;
	uint64_t flush_count;
	void *last_read_buffer;
	void *last_write_buffer;
	bool stopping;
	bool fail_next;
	bool complete_inline;
	bool reject_next;
};

struct delete_waiter {
	pthread_mutex_t mutex;
	pthread_cond_t condition;
	bool completed;
	int status;
};

struct readv_waiter {
	pthread_mutex_t mutex;
	pthread_cond_t condition;
	const char *bdev_name;
	struct iovec *iovs;
	int iov_count;
	uint64_t offset;
	uint64_t length;
	struct spdk_bdev_desc *descriptor;
	struct spdk_io_channel *channel;
	bool completed;
	int status;
};

static void
readv_finish(struct readv_waiter *waiter, int status)
{
	int rc;

	if (waiter->channel != NULL) {
		spdk_put_io_channel(waiter->channel);
		waiter->channel = NULL;
	}
	if (waiter->descriptor != NULL) {
		spdk_bdev_close(waiter->descriptor);
		waiter->descriptor = NULL;
	}
	rc = pthread_mutex_lock(&waiter->mutex);
	assert(rc == 0);
	waiter->status = status;
	waiter->completed = true;
	rc = pthread_cond_signal(&waiter->condition);
	assert(rc == 0);
	rc = pthread_mutex_unlock(&waiter->mutex);
	assert(rc == 0);
}

static void
readv_complete(struct spdk_bdev_io *bdev_io, bool success, void *context)
{
	struct readv_waiter *waiter = context;

	spdk_bdev_free_io(bdev_io);
	readv_finish(waiter, success ? 0 : -EIO);
}

static void
readv_event(enum spdk_bdev_event_type type, struct spdk_bdev *bdev, void *context)
{
	(void)type;
	(void)bdev;
	(void)context;
}

static void
readv_start(void *context)
{
	struct readv_waiter *waiter = context;
	int status;

	status = spdk_bdev_open_ext(waiter->bdev_name, false, readv_event, NULL,
			&waiter->descriptor);
	if (status == 0) {
		waiter->channel = spdk_bdev_get_io_channel(waiter->descriptor);
		if (waiter->channel == NULL) {
			status = -ENOMEM;
		}
	}
	if (status == 0) {
		status = spdk_bdev_readv(waiter->descriptor, waiter->channel,
				waiter->iovs, waiter->iov_count, waiter->offset,
				waiter->length, readv_complete, waiter);
	}
	if (status != 0) {
		readv_finish(waiter, status);
	}
}

static int
provider_readv(struct zettide_spdk_runtime *runtime, const char *bdev_name,
		struct iovec *iovs, int iov_count, uint64_t offset, uint64_t length)
{
	struct readv_waiter waiter = {
		.bdev_name = bdev_name,
		.iovs = iovs,
		.iov_count = iov_count,
		.offset = offset,
		.length = length,
	};
	struct spdk_thread *owner;
	int status;
	int rc;

	rc = pthread_mutex_init(&waiter.mutex, NULL);
	if (rc != 0) {
		return -rc;
	}
	rc = pthread_cond_init(&waiter.condition, NULL);
	if (rc != 0) {
		(void)pthread_mutex_destroy(&waiter.mutex);
		return -rc;
	}
	status = zettide_spdk_runtime_acquire(runtime, &owner);
	if (status == 0) {
		rc = pthread_mutex_lock(&waiter.mutex);
		assert(rc == 0);
		status = spdk_thread_send_msg(owner, readv_start, &waiter);
		while (status == 0 && !waiter.completed) {
			rc = pthread_cond_wait(&waiter.condition, &waiter.mutex);
			assert(rc == 0);
		}
		if (status == 0) {
			status = waiter.status;
		}
		rc = pthread_mutex_unlock(&waiter.mutex);
		assert(rc == 0);
		zettide_spdk_runtime_release(runtime);
	}
	rc = pthread_cond_destroy(&waiter.condition);
	assert(rc == 0);
	rc = pthread_mutex_destroy(&waiter.mutex);
	assert(rc == 0);
	return status;
}

static int
execute_request(struct test_backend *backend,
		enum zettide_spdk_bdev_provider_operation operation,
		uint64_t offset, void *buffer, uint64_t length)
{
	if (operation != ZETTIDE_SPDK_BDEV_PROVIDER_RESET &&
		(offset > backend->capacity || length > backend->capacity - offset)) {
		return -ERANGE;
	}
	switch (operation) {
	case ZETTIDE_SPDK_BDEV_PROVIDER_READ:
		backend->last_read_buffer = buffer;
		memcpy(buffer, backend->data + offset, (size_t)length);
		break;
	case ZETTIDE_SPDK_BDEV_PROVIDER_WRITE:
		backend->last_write_buffer = buffer;
		memcpy(backend->data + offset, buffer, (size_t)length);
		break;
	case ZETTIDE_SPDK_BDEV_PROVIDER_FLUSH:
		backend->flush_count++;
		break;
	case ZETTIDE_SPDK_BDEV_PROVIDER_RESET:
		break;
	}
	return 0;
}

static void *
run_backend(void *context)
{
	struct test_backend *backend = context;

	for (;;) {
		struct backend_request *request;
		int status = 0;
		int rc = pthread_mutex_lock(&backend->mutex);

		if (rc != 0) {
			abort();
		}
		while (backend->head == NULL && !backend->stopping) {
			rc = pthread_cond_wait(&backend->condition, &backend->mutex);
			if (rc != 0) {
				abort();
			}
		}
		if (backend->head == NULL && backend->stopping) {
			(void)pthread_mutex_unlock(&backend->mutex);
			return NULL;
		}
		request = backend->head;
		backend->head = request->next;
		if (backend->head == NULL) {
			backend->tail = NULL;
		}
		if (backend->fail_next) {
			backend->fail_next = false;
			status = -EIO;
		}
		rc = pthread_mutex_unlock(&backend->mutex);
		if (rc != 0) {
			abort();
		}

		if (status == 0) {
			status = execute_request(backend, request->operation, request->offset,
					request->buffer, request->length);
		}
		{
			const struct zettide_spdk_bdev_provider_completion completion = {
				.context = request->complete_context,
				.status = status,
			};

			zettide_spdk_bdev_provider_complete_batch(&completion, 1);
		}
		free(request);
	}
}

static int
backend_submit(void *context, enum zettide_spdk_bdev_provider_operation operation,
		uint64_t offset, void *buffer, uint64_t length,
		zettide_spdk_bdev_provider_complete complete, void *complete_context)
{
	struct test_backend *backend = context;
	struct backend_request *request = calloc(1, sizeof(*request));
	bool complete_inline;
	bool reject;
	int rc;

	if (request == NULL) {
		return -ENOMEM;
	}
	request->operation = operation;
	request->offset = offset;
	request->buffer = buffer;
	request->length = length;
	request->complete = complete;
	request->complete_context = complete_context;
	rc = pthread_mutex_lock(&backend->mutex);
	if (rc != 0) {
		free(request);
		return -rc;
	}
	complete_inline = backend->complete_inline;
	reject = backend->reject_next;
	backend->complete_inline = false;
	backend->reject_next = false;
	if (!complete_inline && !reject && backend->tail == NULL) {
		backend->head = request;
	} else if (!complete_inline && !reject) {
		backend->tail->next = request;
	}
	if (!complete_inline && !reject) {
		backend->tail = request;
		rc = pthread_cond_signal(&backend->condition);
		if (rc != 0) {
			abort();
		}
	}
	rc = pthread_mutex_unlock(&backend->mutex);
	if (rc != 0) {
		abort();
	}
	if (reject) {
		free(request);
		return -EIO;
	}
	if (complete_inline) {
		int status = execute_request(backend, operation, offset, buffer, length);

		complete(complete_context, status);
		free(request);
	}
	return 0;
}

static int
backend_start(struct test_backend *backend)
{
	int rc;

	memset(backend, 0, sizeof(*backend));
	backend->capacity = (uint64_t)block_size * block_count;
	backend->data = calloc(1, (size_t)backend->capacity);
	if (backend->data == NULL) {
		return -ENOMEM;
	}
	rc = pthread_mutex_init(&backend->mutex, NULL);
	if (rc != 0) {
		free(backend->data);
		return -rc;
	}
	rc = pthread_cond_init(&backend->condition, NULL);
	if (rc != 0) {
		(void)pthread_mutex_destroy(&backend->mutex);
		free(backend->data);
		return -rc;
	}
	rc = pthread_create(&backend->worker, NULL, run_backend, backend);
	if (rc != 0) {
		(void)pthread_cond_destroy(&backend->condition);
		(void)pthread_mutex_destroy(&backend->mutex);
		free(backend->data);
		return -rc;
	}
	return 0;
}

static void
backend_stop(struct test_backend *backend)
{
	int rc = pthread_mutex_lock(&backend->mutex);

	if (rc != 0) {
		abort();
	}
	backend->stopping = true;
	rc = pthread_cond_signal(&backend->condition);
	if (rc != 0) {
		abort();
	}
	rc = pthread_mutex_unlock(&backend->mutex);
	if (rc != 0 || pthread_join(backend->worker, NULL) != 0 ||
		pthread_cond_destroy(&backend->condition) != 0 ||
		pthread_mutex_destroy(&backend->mutex) != 0) {
		abort();
	}
	free(backend->data);
}

static void
backend_next(struct test_backend *backend, bool fail, bool inline_completion, bool reject)
{
	int rc = pthread_mutex_lock(&backend->mutex);

	if (rc != 0) {
		abort();
	}
	backend->fail_next = fail;
	backend->complete_inline = inline_completion;
	backend->reject_next = reject;
	rc = pthread_mutex_unlock(&backend->mutex);
	if (rc != 0) {
		abort();
	}
}

static int
delete_waiter_init(struct delete_waiter *waiter)
{
	int rc;

	memset(waiter, 0, sizeof(*waiter));
	rc = pthread_mutex_init(&waiter->mutex, NULL);
	if (rc != 0) {
		return -rc;
	}
	rc = pthread_cond_init(&waiter->condition, NULL);
	if (rc != 0) {
		(void)pthread_mutex_destroy(&waiter->mutex);
		return -rc;
	}
	return 0;
}

static void
provider_deleted(void *context, int status)
{
	struct delete_waiter *waiter = context;
	int rc = pthread_mutex_lock(&waiter->mutex);

	if (rc != 0) {
		abort();
	}
	waiter->status = status;
	waiter->completed = true;
	rc = pthread_cond_signal(&waiter->condition);
	if (rc != 0) {
		abort();
	}
	rc = pthread_mutex_unlock(&waiter->mutex);
	if (rc != 0) {
		abort();
	}
}

static int
delete_waiter_wait(struct delete_waiter *waiter)
{
	int rc = pthread_mutex_lock(&waiter->mutex);
	int status;

	if (rc != 0) {
		abort();
	}
	while (!waiter->completed) {
		rc = pthread_cond_wait(&waiter->condition, &waiter->mutex);
		if (rc != 0) {
			abort();
		}
	}
	status = waiter->status;
	rc = pthread_mutex_unlock(&waiter->mutex);
	if (rc != 0 || pthread_cond_destroy(&waiter->condition) != 0 ||
		pthread_mutex_destroy(&waiter->mutex) != 0) {
		abort();
	}
	return status;
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
	struct zettide_spdk_runtime_opts runtime_opts;
	struct zettide_spdk_runtime *runtime = NULL;
	struct zettide_spdk_bdev_provider_opts provider_opts;
	struct zettide_spdk_bdev_provider *provider = NULL;
	struct zettide_spdk_bdev_provider *duplicate = NULL;
	struct zettide_spdk_bdev_dispatcher *dispatcher = NULL;
	struct zettide_spdk_bdev_geometry geometry;
	struct test_backend backend;
	struct delete_waiter delete_waiter;
	uint8_t *write_buffer = NULL;
	uint8_t *read_buffer = NULL;
	uint8_t *readv_buffer = NULL;
	struct iovec read_iovs[3];
	char reactor_mask[32];
	int cpu = first_allowed_cpu();
	int status;
	uint64_t index;

	if (cpu < 0 || snprintf(reactor_mask, sizeof(reactor_mask), "[%d]", cpu) < 0) {
		return 1;
	}
	status = backend_start(&backend);
	if (status != 0) {
		return 1;
	}
	zettide_spdk_runtime_opts_init(&runtime_opts, sizeof(runtime_opts));
	runtime_opts.name = "zettide_spdk_provider_test";
	runtime_opts.reactor_mask = reactor_mask;
	runtime_opts.json_data = bdev_config;
	runtime_opts.json_data_size = sizeof(bdev_config) - 1;
	runtime_opts.mem_size_mb = 320;
	runtime_opts.no_pci = true;
	runtime_opts.no_huge = true;
	runtime_opts.disable_cpumask_locks = true;
	status = zettide_spdk_runtime_start(&runtime_opts, &runtime);
	if (status != 0) {
		goto done;
	}
	zettide_spdk_bdev_provider_opts_init(&provider_opts, sizeof(provider_opts));
	provider_opts.name = "ZettideProvider0";
	provider_opts.block_count = block_count;
	provider_opts.backend_context = &backend;
	provider_opts.submit = backend_submit;
	status = zettide_spdk_bdev_provider_create(runtime, &provider_opts, &provider);
	if (status != 0) {
		goto done;
	}
	status = zettide_spdk_bdev_provider_create(runtime, &provider_opts, &duplicate);
	if (status == 0 || duplicate != NULL) {
		status = -EEXIST;
		goto done;
	}
	status = zettide_spdk_runtime_stop(runtime);
	if (status != -EBUSY) {
		status = status == 0 ? -EIO : status;
		goto done;
	}
	status = zettide_spdk_bdev_dispatcher_open(runtime, provider_opts.name, true, &dispatcher);
	if (status != 0) {
		goto done;
	}
	status = zettide_spdk_bdev_dispatcher_get_geometry(dispatcher, &geometry);
	if (status != 0 || geometry.logical_block_size != block_size ||
		geometry.block_count != block_count ||
		(geometry.flags & ZETTIDE_SPDK_BDEV_FLUSH_SUPPORTED) == 0) {
		status = status != 0 ? status : -EINVAL;
		goto done;
	}
	write_buffer = zettide_spdk_dma_zmalloc(2 * block_size, geometry.buffer_alignment);
	read_buffer = zettide_spdk_dma_zmalloc(2 * block_size, geometry.buffer_alignment);
	readv_buffer = zettide_spdk_dma_zmalloc(2 * block_size, geometry.buffer_alignment);
	if (write_buffer == NULL || read_buffer == NULL || readv_buffer == NULL) {
		status = -ENOMEM;
		goto done;
	}
	for (index = 0; index < 2 * block_size; index++) {
		write_buffer[index] = (uint8_t)(index * 17u + 3u);
	}
	status = zettide_spdk_bdev_dispatcher_write(dispatcher, write_buffer,
			3 * block_size, 2 * block_size);
	if (status == 0) {
		status = zettide_spdk_bdev_dispatcher_flush(dispatcher,
				3 * block_size, 2 * block_size);
	}
	if (status == 0) {
		status = zettide_spdk_bdev_dispatcher_read(dispatcher, read_buffer,
				3 * block_size, 2 * block_size);
	}
	if (status != 0 || memcmp(write_buffer, read_buffer, 2 * block_size) != 0 ||
		backend.last_write_buffer != write_buffer ||
		backend.last_read_buffer != read_buffer ||
		backend.flush_count != 1) {
		status = status != 0 ? status : -EIO;
		goto done;
	}
	read_iovs[0] = (struct iovec){ .iov_base = readv_buffer, .iov_len = 1024 };
	read_iovs[1] = (struct iovec){ .iov_base = readv_buffer + 1024, .iov_len = 3072 };
	read_iovs[2] = (struct iovec){ .iov_base = readv_buffer + block_size,
		.iov_len = block_size };
	memset(readv_buffer, 0, 2 * block_size);
	status = provider_readv(runtime, provider_opts.name, read_iovs, 3,
			3 * block_size, 2 * block_size);
	if (status != 0 || memcmp(write_buffer, readv_buffer, 2 * block_size) != 0 ||
		backend.last_read_buffer == readv_buffer) {
		status = status != 0 ? status : -EIO;
		goto done;
	}
	backend_next(&backend, false, true, false);
	status = zettide_spdk_bdev_dispatcher_read(dispatcher, read_buffer,
			3 * block_size, block_size);
	if (status != 0 || memcmp(write_buffer, read_buffer, block_size) != 0) {
		status = status != 0 ? status : -EIO;
		goto done;
	}
	backend_next(&backend, false, false, true);
	status = zettide_spdk_bdev_dispatcher_read(dispatcher, read_buffer, 0, block_size);
	if (status != -EIO) {
		status = status == 0 ? -EIO : status;
		goto done;
	}
	backend_next(&backend, true, false, false);
	status = zettide_spdk_bdev_dispatcher_read(dispatcher, read_buffer, 0, block_size);
	if (status != -EIO) {
		status = status == 0 ? -EIO : status;
		goto done;
	}
	status = 0;
	status = delete_waiter_init(&delete_waiter);
	if (status != 0) {
		goto done;
	}
	status = zettide_spdk_bdev_provider_delete(provider, provider_deleted, &delete_waiter);
	if (status != 0) {
		(void)pthread_cond_destroy(&delete_waiter.condition);
		(void)pthread_mutex_destroy(&delete_waiter.mutex);
		goto done;
	}
	provider = NULL;
	{
		int close_status = zettide_spdk_bdev_dispatcher_close(dispatcher);
		int delete_status;

		dispatcher = NULL;
		delete_status = delete_waiter_wait(&delete_waiter);
		status = close_status != 0 ? close_status : delete_status;
	}
	if (status == 0) {
		provider_opts.read_buffers_unchanged = true;
		status = zettide_spdk_bdev_provider_create(runtime, &provider_opts, &provider);
	}
	if (status == 0) {
		memset(readv_buffer, 0xa5, 2 * block_size);
		status = provider_readv(runtime, provider_opts.name, read_iovs, 3,
				3 * block_size, 2 * block_size);
		if (status == 0) {
			for (index = 0; index < 2 * block_size; index++) {
				if (readv_buffer[index] != 0xa5) {
					status = -EIO;
					break;
				}
			}
		}
	}
	if (status == 0) {
		status = zettide_spdk_bdev_provider_delete_wait(provider);
		if (status == 0) {
			provider = NULL;
		}
	}

done:
	zettide_spdk_dma_free(readv_buffer);
	zettide_spdk_dma_free(read_buffer);
	zettide_spdk_dma_free(write_buffer);
	if (dispatcher != NULL) {
		int close_status = zettide_spdk_bdev_dispatcher_close(dispatcher);

		if (status == 0) {
			status = close_status;
		}
	}
	if (provider != NULL) {
		struct delete_waiter cleanup_waiter;
		int delete_status = delete_waiter_init(&cleanup_waiter);

		if (delete_status == 0) {
			delete_status = zettide_spdk_bdev_provider_delete(provider,
					provider_deleted, &cleanup_waiter);
			if (delete_status == 0) {
				delete_status = delete_waiter_wait(&cleanup_waiter);
			} else {
				(void)pthread_cond_destroy(&cleanup_waiter.condition);
				(void)pthread_mutex_destroy(&cleanup_waiter.mutex);
			}
		}
		if (status == 0) {
			status = delete_status;
		}
	}
	if (runtime != NULL) {
		int stop_status = zettide_spdk_runtime_stop(runtime);
		int destroy_status = stop_status == 0 ? zettide_spdk_runtime_destroy(runtime) : 0;

		if (status == 0) {
			status = stop_status != 0 ? stop_status : destroy_status;
		}
	}
	backend_stop(&backend);
	return status == 0 ? 0 : 1;
}
