#include "vhost_blk_controller.h"

#include "spdk/json.h"
#include "spdk/thread.h"
#include "spdk/vhost.h"

#include <assert.h>
#include <errno.h>
#include <limits.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

#define ZETTIDE_SPDK_VHOST_NAME_MAX 256

struct zettide_spdk_vhost_blk_controller {
	struct zettide_spdk_runtime *runtime;
	struct spdk_thread *owner;
	char *name;
	char *bdev_name;
	char *cpumask;
	char *socket_path;
	bool readonly;
};

struct controller_command {
	pthread_mutex_t mutex;
	pthread_cond_t condition;
	bool completed;
	int status;
	struct zettide_spdk_vhost_blk_controller *controller;
	uint32_t coalescing_delay_base_us;
	uint32_t coalescing_iops_threshold;
};

static void
complete_command(struct controller_command *command, int status)
{
	int rc = pthread_mutex_lock(&command->mutex);

	assert(rc == 0);
	command->status = status;
	command->completed = true;
	rc = pthread_cond_signal(&command->condition);
	assert(rc == 0);
	rc = pthread_mutex_unlock(&command->mutex);
	assert(rc == 0);
}

static void
run_create(void *context)
{
	struct controller_command *command = context;
	struct zettide_spdk_vhost_blk_controller *controller = command->controller;
	struct spdk_json_val params[] = {
		{ .len = 2, .type = SPDK_JSON_VAL_OBJECT_BEGIN },
		{ .start = "readonly", .len = sizeof("readonly") - 1, .type = SPDK_JSON_VAL_NAME },
		{ .type = controller->readonly ? SPDK_JSON_VAL_TRUE : SPDK_JSON_VAL_FALSE },
		{ .type = SPDK_JSON_VAL_OBJECT_END },
	};

	complete_command(command, spdk_vhost_blk_construct(controller->name,
			controller->cpumask, controller->bdev_name, NULL, params));
}

static void
run_remove(void *context)
{
	struct controller_command *command = context;
	struct zettide_spdk_vhost_blk_controller *controller = command->controller;
	struct spdk_vhost_dev *device;
	int status;

	spdk_vhost_lock();
	device = spdk_vhost_dev_find(controller->name);
	spdk_vhost_unlock();
	status = device == NULL ? -ENODEV : spdk_vhost_dev_remove(device);
	complete_command(command, status);
}

static void
run_set_coalescing(void *context)
{
	struct controller_command *command = context;
	struct zettide_spdk_vhost_blk_controller *controller = command->controller;
	struct spdk_vhost_dev *device;
	int status;

	spdk_vhost_lock();
	device = spdk_vhost_dev_find(controller->name);
	status = device == NULL ? -ENODEV : spdk_vhost_set_coalescing(device,
			command->coalescing_delay_base_us, command->coalescing_iops_threshold);
	spdk_vhost_unlock();
	complete_command(command, status);
}

static int
dispatch_command(struct controller_command *command, spdk_msg_fn function)
{
	int old_cancel_state;
	int ignored_cancel_state;
	int status;
	int rc;

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
	command->status = 0;
	rc = spdk_thread_send_msg(command->controller->owner, function, command);
	if (rc != 0) {
		status = rc;
		goto cleanup;
	}
	rc = pthread_mutex_lock(&command->mutex);
	assert(rc == 0);
	while (!command->completed) {
		rc = pthread_cond_wait(&command->condition, &command->mutex);
		assert(rc == 0);
	}
	status = command->status;
	rc = pthread_mutex_unlock(&command->mutex);
	assert(rc == 0);

cleanup:
	rc = pthread_cond_destroy(&command->condition);
	assert(rc == 0);
	rc = pthread_mutex_destroy(&command->mutex);
	assert(rc == 0);
	rc = pthread_setcancelstate(old_cancel_state, &ignored_cancel_state);
	assert(rc == 0);
	return status;
}

static void
free_controller(struct zettide_spdk_vhost_blk_controller *controller)
{
	free(controller->socket_path);
	free(controller->cpumask);
	free(controller->bdev_name);
	free(controller->name);
	free(controller);
}

static bool
valid_name(const char *name)
{
	size_t length;

	if (name == NULL) {
		return false;
	}
	length = strnlen(name, ZETTIDE_SPDK_VHOST_NAME_MAX);
	return length != 0 && length != ZETTIDE_SPDK_VHOST_NAME_MAX &&
			strchr(name, '/') == NULL && strcmp(name, ".") != 0 && strcmp(name, "..") != 0;
}

void
zettide_spdk_vhost_blk_controller_opts_init(
		struct zettide_spdk_vhost_blk_controller_opts *opts, size_t opts_size)
{
	if (opts == NULL || opts_size == 0) {
		return;
	}
	memset(opts, 0, opts_size);
	if (opts_size >= sizeof(*opts)) {
		opts->opts_size = opts_size;
	}
}

static int
create_controller(struct zettide_spdk_runtime *runtime,
		const struct zettide_spdk_vhost_blk_controller_opts *opts,
		struct zettide_spdk_vhost_blk_controller **controller_out)
{
	struct zettide_spdk_vhost_blk_controller *controller;
	struct controller_command command = {0};
	struct spdk_thread *owner;
	const char *socket_directory;
	int socket_length;
	int status;

	if (runtime == NULL || opts == NULL || controller_out == NULL ||
		opts->opts_size != sizeof(*opts) || !valid_name(opts->name) ||
		opts->bdev_name == NULL || opts->bdev_name[0] == '\0') {
		return -EINVAL;
	}
	*controller_out = NULL;
	status = zettide_spdk_runtime_acquire(runtime, &owner);
	if (status != 0) {
		return status;
	}
	socket_directory = zettide_spdk_runtime_get_vhost_socket_path(runtime);
	if (socket_directory == NULL) {
		zettide_spdk_runtime_release(runtime);
		return -EINVAL;
	}
	controller = calloc(1, sizeof(*controller));
	if (controller == NULL) {
		zettide_spdk_runtime_release(runtime);
		return -ENOMEM;
	}
	controller->runtime = runtime;
	controller->name = strdup(opts->name);
	controller->bdev_name = strdup(opts->bdev_name);
	controller->cpumask = opts->cpumask == NULL ? NULL : strdup(opts->cpumask);
	controller->readonly = opts->readonly;
	controller->socket_path = malloc(PATH_MAX);
	if (controller->name == NULL || controller->bdev_name == NULL ||
		(opts->cpumask != NULL && controller->cpumask == NULL) ||
		controller->socket_path == NULL) {
		free_controller(controller);
		zettide_spdk_runtime_release(runtime);
		return -ENOMEM;
	}
	socket_length = snprintf(controller->socket_path, PATH_MAX,
			socket_directory[strlen(socket_directory) - 1] == '/' ? "%s%s" : "%s/%s",
			socket_directory, controller->name);
	if (socket_length < 0 || socket_length >= PATH_MAX) {
		free_controller(controller);
		zettide_spdk_runtime_release(runtime);
		return -ENAMETOOLONG;
	}
	controller->owner = owner;
	command.controller = controller;
	status = dispatch_command(&command, run_create);
	if (status != 0) {
		zettide_spdk_runtime_release(runtime);
		free_controller(controller);
		return status;
	}
	*controller_out = controller;
	return 0;
}

int
zettide_spdk_vhost_blk_controller_create(struct zettide_spdk_runtime *runtime,
		const struct zettide_spdk_vhost_blk_controller_opts *opts,
		struct zettide_spdk_vhost_blk_controller **controller_out)
{
	int old_cancel_state;
	int ignored_cancel_state;
	int status;
	int rc;

	rc = pthread_setcancelstate(PTHREAD_CANCEL_DISABLE, &old_cancel_state);
	if (rc != 0) {
		return -rc;
	}
	status = create_controller(runtime, opts, controller_out);
	rc = pthread_setcancelstate(old_cancel_state, &ignored_cancel_state);
	assert(rc == 0);
	return status;
}

static int
remove_controller(struct zettide_spdk_vhost_blk_controller *controller)
{
	struct controller_command command = {0};
	int status;

	if (controller == NULL) {
		return -EINVAL;
	}
	command.controller = controller;
	status = dispatch_command(&command, run_remove);
	if (status == 0) {
		zettide_spdk_runtime_release(controller->runtime);
		free_controller(controller);
	}
	return status;
}

int
zettide_spdk_vhost_blk_controller_remove(
		struct zettide_spdk_vhost_blk_controller *controller)
{
	int old_cancel_state;
	int ignored_cancel_state;
	int status;
	int rc;

	rc = pthread_setcancelstate(PTHREAD_CANCEL_DISABLE, &old_cancel_state);
	if (rc != 0) {
		return -rc;
	}
	status = remove_controller(controller);
	rc = pthread_setcancelstate(old_cancel_state, &ignored_cancel_state);
	assert(rc == 0);
	return status;
}

int
zettide_spdk_vhost_blk_controller_set_coalescing(
		struct zettide_spdk_vhost_blk_controller *controller,
		uint32_t delay_base_us, uint32_t iops_threshold)
{
	struct controller_command command = {
		.controller = controller,
		.coalescing_delay_base_us = delay_base_us,
		.coalescing_iops_threshold = iops_threshold,
	};
	int old_cancel_state;
	int ignored_cancel_state;
	int status;
	int rc;

	if (controller == NULL) {
		return -EINVAL;
	}
	rc = pthread_setcancelstate(PTHREAD_CANCEL_DISABLE, &old_cancel_state);
	if (rc != 0) {
		return -rc;
	}
	status = dispatch_command(&command, run_set_coalescing);
	rc = pthread_setcancelstate(old_cancel_state, &ignored_cancel_state);
	assert(rc == 0);
	return status;
}

const char *
zettide_spdk_vhost_blk_controller_get_socket_path(
		const struct zettide_spdk_vhost_blk_controller *controller)
{
	return controller == NULL ? NULL : controller->socket_path;
}

bool
zettide_spdk_vhost_blk_controller_is_ready(
		const struct zettide_spdk_vhost_blk_controller *controller)
{
	struct stat status;

	return controller != NULL && lstat(controller->socket_path, &status) == 0 &&
			S_ISSOCK(status.st_mode);
}
