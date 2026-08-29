#include "bdev_dispatcher.h"

#include "spdk/thread.h"

#include <assert.h>
#include <errno.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

struct zettide_spdk_bdev_dispatcher {
	struct spdk_thread *owner;
	struct zettide_spdk_runtime *runtime;
	struct zettide_spdk_bdev_endpoint *endpoint;
};

enum dispatcher_operation {
	DISPATCHER_OPEN,
	DISPATCHER_GET_GEOMETRY,
	DISPATCHER_GET_NAME,
	DISPATCHER_READ,
	DISPATCHER_WRITE,
	DISPATCHER_FLUSH,
	DISPATCHER_CLOSE,
};

struct dispatcher_command {
	pthread_mutex_t mutex;
	pthread_cond_t condition;
	bool completed;
	bool owner_active;
	int status;
	enum dispatcher_operation operation;
	struct zettide_spdk_bdev_dispatcher *dispatcher;
	union {
		struct {
			const char *name;
			bool writable;
		} open;
		struct zettide_spdk_bdev_geometry geometry;
		char *name;
		struct {
			void *buffer;
			uint64_t offset;
			uint64_t length;
		} io;
		struct {
			uint64_t offset;
			uint64_t length;
		} flush;
	} arguments;
};

struct dispatcher_read_batch;

struct dispatcher_read_item {
	struct dispatcher_read_batch *batch;
	struct zettide_spdk_bdev_dispatcher_read read;
	void *io_buffer;
	size_t bounce_offset;
};

struct dispatcher_read_batch {
	struct zettide_spdk_bdev_dispatcher *dispatcher;
	size_t item_count;
	size_t remaining;
	bool submitting;
	bool direct;
	void *bounce_buffer;
	int *statuses;
	zettide_spdk_bdev_dispatcher_batch_cb callback;
	void *callback_context;
	struct dispatcher_read_item items[];
};

static void
complete_command(struct dispatcher_command *command, int status)
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
owner_done(struct dispatcher_command *command)
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
io_complete(void *context, int status)
{
	complete_command(context, status);
}

static void
finish_read_batch(struct dispatcher_read_batch *batch)
{
	zettide_spdk_bdev_dispatcher_batch_cb callback = batch->callback;
	void *callback_context = batch->callback_context;
	bool direct = batch->direct;
	size_t index;

	if (!direct && batch->bounce_buffer != NULL) {
		for (index = 0; index < batch->item_count; index++) {
			struct dispatcher_read_item *item = &batch->items[index];

			if (batch->statuses[index] == 0) {
				memcpy(item->read.buffer, item->io_buffer, (size_t)item->read.length);
			}
		}
		zettide_spdk_dma_free(batch->bounce_buffer);
	}
	free(batch);
	callback(callback_context, direct);
}

static void
read_batch_item_complete(void *context, int status)
{
	struct dispatcher_read_item *item = context;
	struct dispatcher_read_batch *batch = item->batch;
	size_t index = (size_t)(item - batch->items);

	assert(batch->remaining > 0);
	batch->statuses[index] = status;
	batch->remaining--;
	if (batch->remaining == 0 && !batch->submitting) {
		finish_read_batch(batch);
	}
}

static int
prepare_read_batch(struct dispatcher_read_batch *batch)
{
	const struct zettide_spdk_bdev_geometry *geometry;
	size_t alignment;
	size_t bounce_size = 0;
	size_t index;

	batch->direct = true;
	for (index = 0; index < batch->item_count; index++) {
		struct dispatcher_read_item *item = &batch->items[index];

		if (!zettide_spdk_bdev_buffer_is_dma_capable(batch->dispatcher->endpoint,
				item->read.buffer, item->read.length)) {
			batch->direct = false;
			break;
		}
	}
	if (batch->direct) {
		for (index = 0; index < batch->item_count; index++) {
			batch->items[index].io_buffer = batch->items[index].read.buffer;
		}
		return 0;
	}

	geometry = zettide_spdk_bdev_get_geometry(batch->dispatcher->endpoint);
	if (geometry == NULL || geometry->buffer_alignment == 0) {
		return -ENODEV;
	}
	alignment = geometry->buffer_alignment;
	for (index = 0; index < batch->item_count; index++) {
		struct dispatcher_read_item *item = &batch->items[index];
		size_t length = (size_t)item->read.length;
		size_t remainder = bounce_size % alignment;

		if (remainder != 0) {
			size_t padding = alignment - remainder;

			if (bounce_size > SIZE_MAX - padding) {
				return -EOVERFLOW;
			}
			bounce_size += padding;
		}
		item->bounce_offset = bounce_size;
		if (bounce_size > SIZE_MAX - length) {
			return -EOVERFLOW;
		}
		bounce_size += length;
	}
	batch->bounce_buffer = zettide_spdk_dma_malloc(bounce_size, alignment);
	if (batch->bounce_buffer == NULL) {
		return -ENOMEM;
	}
	for (index = 0; index < batch->item_count; index++) {
		batch->items[index].io_buffer =
			(uint8_t *)batch->bounce_buffer + batch->items[index].bounce_offset;
	}
	return 0;
}

static void
run_read_batch(void *context)
{
	struct dispatcher_read_batch *batch = context;
	size_t index;
	int status;

	status = prepare_read_batch(batch);
	if (status != 0) {
		for (index = 0; index < batch->item_count; index++) {
			batch->statuses[index] = status;
		}
		batch->remaining = 0;
		batch->submitting = false;
		finish_read_batch(batch);
		return;
	}
	for (index = 0; index < batch->item_count; index++) {
		struct dispatcher_read_item *item = &batch->items[index];

		status = zettide_spdk_bdev_read(batch->dispatcher->endpoint,
				item->io_buffer, item->read.offset, item->read.length,
				read_batch_item_complete, item);
		if (status != 0) {
			read_batch_item_complete(item, status);
		}
	}
	batch->submitting = false;
	if (batch->remaining == 0) {
		finish_read_batch(batch);
	}
}

static void
run_command(void *context)
{
	struct dispatcher_command *command = context;
	struct zettide_spdk_bdev_dispatcher *dispatcher = command->dispatcher;
	const struct zettide_spdk_bdev_geometry *geometry;
	int status;

	switch (command->operation) {
	case DISPATCHER_OPEN:
		status = zettide_spdk_bdev_open(command->arguments.open.name,
				command->arguments.open.writable, NULL, NULL, &dispatcher->endpoint);
		complete_command(command, status);
		break;
	case DISPATCHER_GET_GEOMETRY:
		geometry = zettide_spdk_bdev_get_geometry(dispatcher->endpoint);
		if (geometry == NULL) {
			complete_command(command, -ENODEV);
		} else {
			command->arguments.geometry = *geometry;
			complete_command(command, 0);
		}
		break;
	case DISPATCHER_GET_NAME: {
		const char *name = zettide_spdk_bdev_get_name(dispatcher->endpoint);

		if (name == NULL) {
			complete_command(command, -ENODEV);
		} else {
			command->arguments.name = strdup(name);
			complete_command(command, command->arguments.name == NULL ? -ENOMEM : 0);
		}
		break;
	}
	case DISPATCHER_READ:
		status = zettide_spdk_bdev_read(dispatcher->endpoint,
				command->arguments.io.buffer, command->arguments.io.offset,
				command->arguments.io.length, io_complete, command);
		if (status != 0) {
			complete_command(command, status);
		}
		break;
	case DISPATCHER_WRITE:
		status = zettide_spdk_bdev_write(dispatcher->endpoint,
				command->arguments.io.buffer, command->arguments.io.offset,
				command->arguments.io.length, io_complete, command);
		if (status != 0) {
			complete_command(command, status);
		}
		break;
	case DISPATCHER_FLUSH:
		status = zettide_spdk_bdev_flush(dispatcher->endpoint,
				command->arguments.flush.offset, command->arguments.flush.length,
				io_complete, command);
		if (status != 0) {
			complete_command(command, status);
		}
		break;
	case DISPATCHER_CLOSE:
		status = zettide_spdk_bdev_close(dispatcher->endpoint);
		if (status == 0) {
			dispatcher->endpoint = NULL;
		}
		complete_command(command, status);
		break;
	default:
		complete_command(command, -EINVAL);
		break;
	}
	owner_done(command);
}

static int
dispatch_command(struct dispatcher_command *command)
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
	rc = spdk_thread_send_msg(command->dispatcher->owner, run_command, command);
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

static int
open_on_owner(struct spdk_thread *owner, struct zettide_spdk_runtime *runtime,
		const char *name,
		bool writable, struct zettide_spdk_bdev_dispatcher **dispatcher_out)
{
	struct zettide_spdk_bdev_dispatcher *dispatcher;
	struct dispatcher_command command = {0};
	int status;

	if (owner == NULL || name == NULL || dispatcher_out == NULL) {
		return -EINVAL;
	}
	*dispatcher_out = NULL;
	dispatcher = calloc(1, sizeof(*dispatcher));
	if (dispatcher == NULL) {
		return -ENOMEM;
	}
	dispatcher->owner = owner;
	dispatcher->runtime = runtime;
	command.operation = DISPATCHER_OPEN;
	command.dispatcher = dispatcher;
	command.arguments.open.name = name;
	command.arguments.open.writable = writable;
	status = dispatch_command(&command);
	if (status != 0) {
		free(dispatcher);
		return status;
	}
	*dispatcher_out = dispatcher;
	return 0;
}

int
zettide_spdk_bdev_dispatcher_open(struct zettide_spdk_runtime *runtime,
		const char *name, bool writable,
		struct zettide_spdk_bdev_dispatcher **dispatcher_out)
{
	struct spdk_thread *owner;
	int status;

	if (runtime == NULL || dispatcher_out == NULL) {
		return -EINVAL;
	}
	*dispatcher_out = NULL;
	status = zettide_spdk_runtime_acquire_dispatcher(runtime, &owner);
	if (status != 0) {
		return status;
	}
	status = open_on_owner(owner, runtime, name, writable, dispatcher_out);
	if (status != 0) {
		zettide_spdk_runtime_release(runtime);
	}
	return status;
}

int
zettide_spdk_bdev_dispatcher_open_on_thread(struct spdk_thread *owner, const char *name,
		bool writable, struct zettide_spdk_bdev_dispatcher **dispatcher_out)
{
	return open_on_owner(owner, NULL, name, writable, dispatcher_out);
}

int
zettide_spdk_bdev_dispatcher_get_geometry(
		struct zettide_spdk_bdev_dispatcher *dispatcher,
		struct zettide_spdk_bdev_geometry *geometry_out)
{
	struct dispatcher_command command = {0};
	int status;

	if (dispatcher == NULL || geometry_out == NULL) {
		return -EINVAL;
	}
	command.operation = DISPATCHER_GET_GEOMETRY;
	command.dispatcher = dispatcher;
	status = dispatch_command(&command);
	if (status == 0) {
		*geometry_out = command.arguments.geometry;
	}
	return status;
}

int
zettide_spdk_bdev_dispatcher_get_name(
		struct zettide_spdk_bdev_dispatcher *dispatcher, char **name_out)
{
	struct dispatcher_command command = {0};
	int status;

	if (dispatcher == NULL || name_out == NULL) {
		return -EINVAL;
	}
	*name_out = NULL;
	command.operation = DISPATCHER_GET_NAME;
	command.dispatcher = dispatcher;
	status = dispatch_command(&command);
	if (status == 0) {
		*name_out = command.arguments.name;
	}
	return status;
}

static int
dispatch_io(struct zettide_spdk_bdev_dispatcher *dispatcher,
		enum dispatcher_operation operation, void *buffer,
		uint64_t offset, uint64_t length)
{
	struct dispatcher_command command = {0};

	if (dispatcher == NULL) {
		return -EINVAL;
	}
	command.operation = operation;
	command.dispatcher = dispatcher;
	command.arguments.io.buffer = buffer;
	command.arguments.io.offset = offset;
	command.arguments.io.length = length;
	return dispatch_command(&command);
}

int
zettide_spdk_bdev_dispatcher_read(struct zettide_spdk_bdev_dispatcher *dispatcher,
		void *buffer, uint64_t offset, uint64_t length)
{
	return dispatch_io(dispatcher, DISPATCHER_READ, buffer, offset, length);
}

int
zettide_spdk_bdev_dispatcher_submit_read_many(
		struct zettide_spdk_bdev_dispatcher *dispatcher,
		const struct zettide_spdk_bdev_dispatcher_read *reads, size_t read_count,
		int *statuses, zettide_spdk_bdev_dispatcher_batch_cb callback,
		void *callback_context)
{
	struct dispatcher_read_batch *batch;
	size_t allocation_size;
	size_t index;
	int status;

	if (dispatcher == NULL || reads == NULL || read_count == 0 || statuses == NULL ||
		callback == NULL) {
		return -EINVAL;
	}
	if (spdk_get_thread() != NULL) {
		return -EDEADLK;
	}
	if (read_count > (SIZE_MAX - sizeof(*batch)) / sizeof(*batch->items)) {
		return -EOVERFLOW;
	}
	for (index = 0; index < read_count; index++) {
		if (reads[index].buffer == NULL || reads[index].length == 0) {
			return -EINVAL;
		}
		if (reads[index].length > SIZE_MAX) {
			return -EOVERFLOW;
		}
	}
	allocation_size = sizeof(*batch) + read_count * sizeof(*batch->items);
	batch = calloc(1, allocation_size);
	if (batch == NULL) {
		return -ENOMEM;
	}
	batch->dispatcher = dispatcher;
	batch->item_count = read_count;
	batch->remaining = read_count;
	batch->submitting = true;
	batch->statuses = statuses;
	batch->callback = callback;
	batch->callback_context = callback_context;
	for (index = 0; index < read_count; index++) {
		batch->items[index].batch = batch;
		batch->items[index].read = reads[index];
	}
	status = spdk_thread_send_msg(dispatcher->owner, run_read_batch, batch);
	if (status != 0) {
		free(batch);
	}
	return status;
}

int
zettide_spdk_bdev_dispatcher_write(struct zettide_spdk_bdev_dispatcher *dispatcher,
		const void *buffer, uint64_t offset, uint64_t length)
{
	return dispatch_io(dispatcher, DISPATCHER_WRITE, (void *)buffer, offset, length);
}

int
zettide_spdk_bdev_dispatcher_flush(struct zettide_spdk_bdev_dispatcher *dispatcher,
		uint64_t offset, uint64_t length)
{
	struct dispatcher_command command = {0};

	if (dispatcher == NULL) {
		return -EINVAL;
	}
	command.operation = DISPATCHER_FLUSH;
	command.dispatcher = dispatcher;
	command.arguments.flush.offset = offset;
	command.arguments.flush.length = length;
	return dispatch_command(&command);
}

int
zettide_spdk_bdev_dispatcher_close(struct zettide_spdk_bdev_dispatcher *dispatcher)
{
	struct dispatcher_command command = {0};
	int status;

	if (dispatcher == NULL) {
		return -EINVAL;
	}
	command.operation = DISPATCHER_CLOSE;
	command.dispatcher = dispatcher;
	status = dispatch_command(&command);
	if (status == 0) {
		if (dispatcher->runtime != NULL) {
			zettide_spdk_runtime_release(dispatcher->runtime);
		}
		free(dispatcher);
	}
	return status;
}
