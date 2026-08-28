#include "bdev_provider.h"

#include "spdk/bdev_module.h"
#include "spdk/thread.h"

#include <assert.h>
#include <errno.h>
#include <pthread.h>
#include <sched.h>
#include <stdbool.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/uio.h>
#include <time.h>

struct zettide_spdk_bdev_provider {
	struct spdk_bdev bdev;
	struct zettide_spdk_runtime *runtime;
	void *backend_context;
	zettide_spdk_bdev_provider_submit submit;
	bool read_buffers_unchanged;
};

struct provider_io {
	struct spdk_bdev_io *bdev_io;
	struct spdk_thread *submit_thread;
	struct provider_io *next_complete;
	struct provider_io *next_complete_group;
	void *buffer;
	uint64_t length;
	int status;
	bool owns_buffer;
	enum zettide_spdk_bdev_provider_operation operation;
};

enum provider_command_operation {
	PROVIDER_CREATE,
};

struct provider_command {
	pthread_mutex_t mutex;
	pthread_cond_t condition;
	bool completed;
	bool owner_active;
	int status;
	enum provider_command_operation operation;
	struct spdk_thread *owner;
	struct zettide_spdk_runtime *runtime;
	const struct zettide_spdk_bdev_provider_opts *opts;
	struct zettide_spdk_bdev_provider *provider;
};

struct provider_delete {
	struct zettide_spdk_bdev_provider *provider;
	struct zettide_spdk_runtime *runtime;
	zettide_spdk_bdev_provider_delete_complete complete;
	void *complete_context;
	bool free_request;
};

struct provider_delete_waiter {
	atomic_bool completed;
	int status;
};

static int provider_module_init(void);
static void provider_module_fini(void);
static int provider_get_ctx_size(void);
static void provider_start_delete(void *context);
static int submit_provider_delete(struct provider_delete *request, bool retry_allocation);

static struct spdk_bdev_module provider_module = {
	.name = "zettide_provider",
	.module_init = provider_module_init,
	.module_fini = provider_module_fini,
	.async_fini = true,
	.get_ctx_size = provider_get_ctx_size,
};

SPDK_BDEV_MODULE_REGISTER(zettide_provider, &provider_module)

static int
provider_channel_create(void *io_device, void *context)
{
	(void)io_device;
	(void)context;
	return 0;
}

static void
provider_channel_destroy(void *io_device, void *context)
{
	(void)io_device;
	(void)context;
}

static int
provider_module_init(void)
{
	spdk_io_device_register(&provider_module, provider_channel_create,
			provider_channel_destroy, 0, "zettide_provider");
	return 0;
}

static void
provider_module_fini_done(void *io_device)
{
	(void)io_device;
	spdk_bdev_module_fini_done();
}

static void
provider_module_fini(void)
{
	spdk_io_device_unregister(&provider_module, provider_module_fini_done);
}

static int
provider_get_ctx_size(void)
{
	return sizeof(struct provider_io);
}

static bool
copy_from_iovs(void *destination, uint64_t length, const struct iovec *iovs, int iov_count)
{
	uint8_t *output = destination;
	uint64_t copied = 0;
	int index;

	for (index = 0; index < iov_count && copied < length; index++) {
		uint64_t amount = iovs[index].iov_len;

		if (amount > length - copied) {
			amount = length - copied;
		}
		memcpy(output + copied, iovs[index].iov_base, (size_t)amount);
		copied += amount;
	}
	return copied == length;
}

static bool
copy_to_iovs(struct iovec *iovs, int iov_count, const void *source, uint64_t length)
{
	const uint8_t *input = source;
	uint64_t copied = 0;
	int index;

	for (index = 0; index < iov_count && copied < length; index++) {
		uint64_t amount = iovs[index].iov_len;

		if (amount > length - copied) {
			amount = length - copied;
		}
		memcpy(iovs[index].iov_base, input + copied, (size_t)amount);
		copied += amount;
	}
	return copied == length;
}

static void *
single_iov_buffer(struct spdk_bdev_io *bdev_io, uint64_t length)
{
	if (bdev_io->u.bdev.iovcnt != 1 ||
		bdev_io->u.bdev.iovs[0].iov_len < length) {
		return NULL;
	}
	return bdev_io->u.bdev.iovs[0].iov_base;
}

static void
complete_provider_io(struct provider_io *io)
{
	struct zettide_spdk_bdev_provider *provider = io->bdev_io->bdev->ctxt;
	bool copied = true;

	assert(spdk_get_thread() == io->submit_thread);
	if (io->status == 0 && io->owns_buffer &&
		io->operation == ZETTIDE_SPDK_BDEV_PROVIDER_READ &&
		!provider->read_buffers_unchanged) {
		copied = copy_to_iovs(io->bdev_io->u.bdev.iovs,
				io->bdev_io->u.bdev.iovcnt, io->buffer, io->length);
	}
	if (io->owns_buffer) {
		free(io->buffer);
	}
	spdk_bdev_io_complete(io->bdev_io,
			io->status == 0 && copied ? SPDK_BDEV_IO_STATUS_SUCCESS :
			SPDK_BDEV_IO_STATUS_FAILED);
}

static void
complete_provider_io_batch(void *context)
{
	struct provider_io *io = context;

	while (io != NULL) {
		struct provider_io *next = io->next_complete;

		complete_provider_io(io);
		io = next;
	}
}

void
zettide_spdk_bdev_provider_complete_batch(
		const struct zettide_spdk_bdev_provider_completion *completions,
		size_t count)
{
	struct provider_io *groups = NULL;
	size_t index;

	assert(completions != NULL || count == 0);
	for (index = 0; index < count; index++) {
		struct provider_io *io = completions[index].context;
		struct provider_io *head;

		assert(io != NULL);
		io->status = completions[index].status;
		io->next_complete = NULL;
		io->next_complete_group = NULL;
		for (head = groups; head != NULL; head = head->next_complete_group) {
			if (head->submit_thread == io->submit_thread) {
				io->next_complete = head->next_complete;
				head->next_complete = io;
				break;
			}
		}
		if (head == NULL) {
			io->next_complete_group = groups;
			groups = io;
		}
	}
	while (groups != NULL) {
		struct provider_io *head = groups;
		int rc;

		groups = head->next_complete_group;
		if (spdk_get_thread() == head->submit_thread) {
			complete_provider_io_batch(head);
			continue;
		}
		rc = spdk_thread_send_msg(head->submit_thread,
				complete_provider_io_batch, head);
		assert(rc == 0);
	}
}

static void
provider_backend_complete(void *context, int status)
{
	const struct zettide_spdk_bdev_provider_completion completion = {
		.context = context,
		.status = status,
	};

	zettide_spdk_bdev_provider_complete_batch(&completion, 1);
}

static void
submit_provider_io(struct spdk_bdev_io *bdev_io,
		enum zettide_spdk_bdev_provider_operation operation)
{
	struct zettide_spdk_bdev_provider *provider = bdev_io->bdev->ctxt;
	struct provider_io *io;
	uint64_t offset = 0;
	uint64_t length = 0;
	int status;

	if (operation != ZETTIDE_SPDK_BDEV_PROVIDER_RESET) {
		if (bdev_io->u.bdev.num_blocks > UINT64_MAX / bdev_io->bdev->blocklen ||
			bdev_io->u.bdev.offset_blocks > UINT64_MAX / bdev_io->bdev->blocklen) {
			spdk_bdev_io_complete(bdev_io, SPDK_BDEV_IO_STATUS_FAILED);
			return;
		}
		offset = bdev_io->u.bdev.offset_blocks * bdev_io->bdev->blocklen;
		length = bdev_io->u.bdev.num_blocks * bdev_io->bdev->blocklen;
	}
	if (length > SIZE_MAX) {
		spdk_bdev_io_complete(bdev_io, SPDK_BDEV_IO_STATUS_FAILED);
		return;
	}
	io = (struct provider_io *)bdev_io->driver_ctx;
	io->bdev_io = bdev_io;
	io->submit_thread = spdk_bdev_io_get_thread(bdev_io);
	io->next_complete = NULL;
	io->next_complete_group = NULL;
	io->buffer = NULL;
	io->length = length;
	io->status = 0;
	io->owns_buffer = false;
	io->operation = operation;
	if (operation == ZETTIDE_SPDK_BDEV_PROVIDER_READ ||
		operation == ZETTIDE_SPDK_BDEV_PROVIDER_WRITE) {
		io->buffer = single_iov_buffer(bdev_io, length);
		if (io->buffer == NULL) {
			io->buffer = malloc((size_t)length);
			if (io->buffer == NULL) {
				spdk_bdev_io_complete(bdev_io, SPDK_BDEV_IO_STATUS_NOMEM);
				return;
			}
			io->owns_buffer = true;
		}
	}
	if (operation == ZETTIDE_SPDK_BDEV_PROVIDER_WRITE && io->owns_buffer &&
		!copy_from_iovs(io->buffer, length, bdev_io->u.bdev.iovs,
			bdev_io->u.bdev.iovcnt)) {
		free(io->buffer);
		spdk_bdev_io_complete(bdev_io, SPDK_BDEV_IO_STATUS_FAILED);
		return;
	}
	status = provider->submit(provider->backend_context, operation, offset,
			io->buffer, length, provider_backend_complete, io);
	if (status != 0) {
		provider_backend_complete(io, status);
	}
}

static void
provider_read_get_buf(struct spdk_io_channel *channel, struct spdk_bdev_io *bdev_io,
		bool success)
{
	(void)channel;
	if (!success) {
		spdk_bdev_io_complete(bdev_io, SPDK_BDEV_IO_STATUS_NOMEM);
		return;
	}
	submit_provider_io(bdev_io, ZETTIDE_SPDK_BDEV_PROVIDER_READ);
}

static void
provider_submit_request(struct spdk_io_channel *channel, struct spdk_bdev_io *bdev_io)
{
	(void)channel;
	switch (bdev_io->type) {
	case SPDK_BDEV_IO_TYPE_READ:
		spdk_bdev_io_get_buf(bdev_io, provider_read_get_buf,
				bdev_io->u.bdev.num_blocks * bdev_io->bdev->blocklen);
		break;
	case SPDK_BDEV_IO_TYPE_WRITE:
		submit_provider_io(bdev_io, ZETTIDE_SPDK_BDEV_PROVIDER_WRITE);
		break;
	case SPDK_BDEV_IO_TYPE_FLUSH:
		submit_provider_io(bdev_io, ZETTIDE_SPDK_BDEV_PROVIDER_FLUSH);
		break;
	case SPDK_BDEV_IO_TYPE_RESET:
		submit_provider_io(bdev_io, ZETTIDE_SPDK_BDEV_PROVIDER_RESET);
		break;
	default:
		spdk_bdev_io_complete(bdev_io, SPDK_BDEV_IO_STATUS_FAILED);
		break;
	}
}

static bool
provider_io_type_supported(void *context, enum spdk_bdev_io_type type)
{
	(void)context;
	switch (type) {
	case SPDK_BDEV_IO_TYPE_READ:
	case SPDK_BDEV_IO_TYPE_WRITE:
	case SPDK_BDEV_IO_TYPE_FLUSH:
	case SPDK_BDEV_IO_TYPE_RESET:
		return true;
	default:
		return false;
	}
}

static struct spdk_io_channel *
provider_get_io_channel(void *context)
{
	(void)context;
	return spdk_get_io_channel(&provider_module);
}

static int
provider_destruct(void *context)
{
	struct zettide_spdk_bdev_provider *provider = context;

	free(provider->bdev.name);
	free(provider);
	return 0;
}

static const struct spdk_bdev_fn_table provider_fn_table = {
	.destruct = provider_destruct,
	.submit_request = provider_submit_request,
	.io_type_supported = provider_io_type_supported,
	.get_io_channel = provider_get_io_channel,
};

static int
create_provider(const struct zettide_spdk_bdev_provider_opts *opts,
		struct zettide_spdk_runtime *runtime,
		struct zettide_spdk_bdev_provider **provider_out)
{
	struct zettide_spdk_bdev_provider *provider;
	int status;

	provider = calloc(1, sizeof(*provider));
	if (provider == NULL) {
		return -ENOMEM;
	}
	provider->bdev.name = strdup(opts->name);
	if (provider->bdev.name == NULL) {
		free(provider);
		return -ENOMEM;
	}
	provider->bdev.product_name = "Zettide catalog volume";
	provider->bdev.write_cache = 1;
	provider->bdev.blocklen = opts->block_size;
	provider->bdev.phys_blocklen = opts->block_size;
	provider->bdev.blockcnt = opts->block_count;
	provider->bdev.write_unit_size = opts->write_unit_blocks;
	provider->bdev.max_rw_size = opts->max_io_blocks;
	provider->bdev.ctxt = provider;
	provider->bdev.fn_table = &provider_fn_table;
	provider->bdev.module = &provider_module;
	provider->runtime = runtime;
	provider->backend_context = opts->backend_context;
	provider->submit = opts->submit;
	provider->read_buffers_unchanged = opts->read_buffers_unchanged;
	status = spdk_bdev_register(&provider->bdev);
	if (status != 0) {
		free(provider->bdev.name);
		free(provider);
		return status;
	}
	*provider_out = provider;
	return 0;
}

static void
complete_command(struct provider_command *command, int status)
{
	int rc;

	rc = pthread_mutex_lock(&command->mutex);
	assert(rc == 0);
	assert(!command->completed);
	command->status = status;
	command->completed = true;
	if (!command->owner_active) {
		rc = pthread_cond_signal(&command->condition);
		assert(rc == 0);
	}
	rc = pthread_mutex_unlock(&command->mutex);
	assert(rc == 0);
}

static void
owner_done(struct provider_command *command)
{
	int rc;

	rc = pthread_mutex_lock(&command->mutex);
	assert(rc == 0);
	command->owner_active = false;
	if (command->completed) {
		rc = pthread_cond_signal(&command->condition);
		assert(rc == 0);
	}
	rc = pthread_mutex_unlock(&command->mutex);
	assert(rc == 0);
}

static void
run_provider_command(void *context)
{
	struct provider_command *command = context;
	int status;

	switch (command->operation) {
	case PROVIDER_CREATE:
		status = create_provider(command->opts, command->runtime, &command->provider);
		complete_command(command, status);
		break;
	default:
		complete_command(command, -EINVAL);
		break;
	}
	owner_done(command);
}

static int
dispatch_provider_command(struct provider_command *command)
{
	int rc;
	int old_cancel_state;
	int ignored_cancel_state;
	int status;

	if (spdk_get_thread() != NULL) {
		return -EDEADLK;
	}
	rc = pthread_setcancelstate(PTHREAD_CANCEL_DISABLE, &old_cancel_state);
	if (rc != 0) {
		return -rc;
	}
	rc = pthread_mutex_init(&command->mutex, NULL);
	if (rc != 0) {
		(void)pthread_setcancelstate(old_cancel_state, &ignored_cancel_state);
		return -rc;
	}
	rc = pthread_cond_init(&command->condition, NULL);
	if (rc != 0) {
		(void)pthread_mutex_destroy(&command->mutex);
		(void)pthread_setcancelstate(old_cancel_state, &ignored_cancel_state);
		return -rc;
	}
	command->completed = false;
	command->owner_active = true;
	command->status = 0;
	rc = spdk_thread_send_msg(command->owner, run_provider_command, command);
	if (rc != 0) {
		abort();
	}
	rc = pthread_mutex_lock(&command->mutex);
	assert(rc == 0);
	while (!command->completed || command->owner_active) {
		rc = pthread_cond_wait(&command->condition, &command->mutex);
		assert(rc == 0);
	}
	status = command->status;
	rc = pthread_mutex_unlock(&command->mutex);
	assert(rc == 0);
	rc = pthread_cond_destroy(&command->condition);
	assert(rc == 0);
	rc = pthread_mutex_destroy(&command->mutex);
	assert(rc == 0);
	rc = pthread_setcancelstate(old_cancel_state, &ignored_cancel_state);
	assert(rc == 0);
	return status;
}

void
zettide_spdk_bdev_provider_opts_init(struct zettide_spdk_bdev_provider_opts *opts,
		size_t opts_size)
{
	if (opts == NULL || opts_size == 0) {
		return;
	}
	memset(opts, 0, opts_size);
	if (opts_size >= sizeof(*opts)) {
		opts->opts_size = opts_size;
		opts->block_size = 4096;
		opts->write_unit_blocks = 1;
		opts->max_io_blocks = 256;
	}
}

int
zettide_spdk_bdev_provider_create(struct zettide_spdk_runtime *runtime,
		const struct zettide_spdk_bdev_provider_opts *opts,
		struct zettide_spdk_bdev_provider **provider_out)
{
	struct provider_command command = {0};
	struct spdk_thread *owner;
	uint64_t maximum_blocks;
	int status;

	if (runtime == NULL || opts == NULL || provider_out == NULL ||
		opts->opts_size != sizeof(*opts) || opts->name == NULL || opts->submit == NULL ||
		opts->block_size < 512 || (opts->block_size & (opts->block_size - 1)) != 0 ||
		opts->block_count == 0 || opts->write_unit_blocks == 0 || opts->max_io_blocks == 0) {
		return -EINVAL;
	}
	maximum_blocks = SIZE_MAX / opts->block_size;
	if (opts->block_count > UINT64_MAX / opts->block_size ||
		opts->max_io_blocks > maximum_blocks || opts->write_unit_blocks > opts->block_count) {
		return -EINVAL;
	}
	*provider_out = NULL;
	status = zettide_spdk_runtime_acquire(runtime, &owner);
	if (status != 0) {
		return status;
	}
	command.operation = PROVIDER_CREATE;
	command.owner = owner;
	command.runtime = runtime;
	command.opts = opts;
	status = dispatch_provider_command(&command);
	if (status != 0) {
		zettide_spdk_runtime_release(runtime);
		return status;
	}
	*provider_out = command.provider;
	return 0;
}

int
zettide_spdk_bdev_provider_delete(struct zettide_spdk_bdev_provider *provider,
		zettide_spdk_bdev_provider_delete_complete complete,
		void *complete_context)
{
	struct provider_delete *request;
	int status;

	if (provider == NULL || spdk_get_thread() != NULL) {
		return provider == NULL ? -EINVAL : -EDEADLK;
	}
	request = calloc(1, sizeof(*request));
	if (request == NULL) {
		return -ENOMEM;
	}
	request->provider = provider;
	request->runtime = provider->runtime;
	request->complete = complete;
	request->complete_context = complete_context;
	request->free_request = true;
	status = submit_provider_delete(request, false);
	if (status != 0) {
		free(request);
	}
	return status;
}

static void
provider_delete_wait_complete(void *context, int status)
{
	struct provider_delete_waiter *waiter = context;

	waiter->status = status;
	atomic_store_explicit(&waiter->completed, true, memory_order_release);
}

int
zettide_spdk_bdev_provider_delete_wait(struct zettide_spdk_bdev_provider *provider)
{
	struct provider_delete request = {0};
	struct provider_delete_waiter waiter = {0};
	int old_cancel_state;
	int ignored_cancel_state;
	int status;
	int rc;

	if (provider == NULL || spdk_get_thread() != NULL) {
		return provider == NULL ? -EINVAL : -EDEADLK;
	}
	rc = pthread_setcancelstate(PTHREAD_CANCEL_DISABLE, &old_cancel_state);
	assert(rc == 0);
	request.provider = provider;
	request.runtime = provider->runtime;
	request.complete = provider_delete_wait_complete;
	request.complete_context = &waiter;
	request.free_request = false;
	status = submit_provider_delete(&request, true);
	if (status == 0) {
		const struct timespec delay = { .tv_sec = 0, .tv_nsec = 1000000 };

		while (!atomic_load_explicit(&waiter.completed, memory_order_acquire)) {
			(void)nanosleep(&delay, NULL);
		}
		status = waiter.status;
	}
	rc = pthread_setcancelstate(old_cancel_state, &ignored_cancel_state);
	assert(rc == 0);
	return status;
}

static int
submit_provider_delete(struct provider_delete *request, bool retry_allocation)
{
	struct spdk_thread *owner;
	int status;

	status = zettide_spdk_runtime_acquire(request->runtime, &owner);
	if (status != 0) {
		return status;
	}
	do {
		status = spdk_thread_send_msg(owner, provider_start_delete, request);
		if (status == -ENOMEM && retry_allocation) {
			sched_yield();
		}
	} while (status == -ENOMEM && retry_allocation);
	if (status != 0) {
		zettide_spdk_runtime_release(request->runtime);
	}
	return status;
}

static void
provider_delete_done(void *context, int status)
{
	struct provider_delete *request = context;
	struct zettide_spdk_runtime *runtime = request->runtime;
	const bool free_request = request->free_request;

	zettide_spdk_runtime_release(runtime);
	zettide_spdk_runtime_release(runtime);
	if (request->complete != NULL) {
		request->complete(request->complete_context, status);
	}
	if (free_request) {
		free(request);
	}
}

static void
provider_start_delete(void *context)
{
	struct provider_delete *request = context;

	spdk_bdev_unregister(&request->provider->bdev, provider_delete_done, request);
}
