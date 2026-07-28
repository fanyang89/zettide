#include "bdev_dispatcher.h"

#include "spdk/thread.h"

#include <assert.h>
#include <errno.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>

struct zettide_spdk_bdev_dispatcher {
	struct spdk_thread *owner;
	struct zettide_spdk_bdev_endpoint *endpoint;
};

enum dispatcher_operation {
	DISPATCHER_OPEN,
	DISPATCHER_GET_GEOMETRY,
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

int
zettide_spdk_bdev_dispatcher_open(struct spdk_thread *owner, const char *name,
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
		free(dispatcher);
	}
	return status;
}
