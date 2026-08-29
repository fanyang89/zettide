#include "nvme_controller.h"

#include "bdev_nvme.h"
#include "spdk/module/bdev/nvme.h"
#include "spdk/nvme.h"
#include "spdk/thread.h"

#include <assert.h>
#include <errno.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#define ZETTIDE_SPDK_NVME_CONTROLLER_NAME_MAX 512
#define ZETTIDE_SPDK_NVME_DEFAULT_NAMESPACE_CAPACITY 128

struct zettide_spdk_nvme_controller {
	struct zettide_spdk_runtime *runtime;
	struct spdk_thread *owner;
	char *name;
	const char **namespace_names;
	size_t namespace_count;
	uint32_t namespace_name_capacity;
	bool namespace_names_truncated;
	struct spdk_nvme_path_id path_id;
	struct spdk_nvme_ctrlr_opts driver_options;
	struct spdk_bdev_nvme_ctrlr_opts bdev_options;
};

struct controller_command {
	pthread_mutex_t mutex;
	pthread_cond_t condition;
	bool completed;
	bool owner_active;
	int status;
	struct zettide_spdk_nvme_controller *controller;
};

static void
complete_command(struct controller_command *command, int status)
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
owner_done(struct controller_command *command)
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
attach_complete(void *context, size_t bdev_count, int status)
{
	struct controller_command *command = context;
	struct zettide_spdk_nvme_controller *controller = command->controller;

	if (status == -ERANGE) {
		controller->namespace_count = controller->namespace_name_capacity;
		controller->namespace_names_truncated = true;
		status = 0;
	} else if (status == 0) {
		controller->namespace_count = bdev_count;
	}
	complete_command(command, status);
}

static void
run_attach(void *context)
{
	struct controller_command *command = context;
	struct zettide_spdk_nvme_controller *controller = command->controller;
	int status;

	status = spdk_bdev_nvme_create(&controller->path_id.trid, controller->name,
			controller->namespace_names, controller->namespace_name_capacity,
			attach_complete, command, &controller->driver_options,
			&controller->bdev_options);
	if (status != 0) {
		complete_command(command, status);
	}
	owner_done(command);
}

static void
detach_complete(void *context, int status)
{
	complete_command(context, status);
}

static void
run_detach(void *context)
{
	struct controller_command *command = context;
	struct zettide_spdk_nvme_controller *controller = command->controller;
	int status;

	status = spdk_bdev_nvme_delete(controller->name, &controller->path_id,
			detach_complete, command);
	if (status != 0) {
		complete_command(command, status);
	}
	owner_done(command);
}

static int
dispatch_command(struct controller_command *command, spdk_msg_fn function)
{
	int ignored_cancel_state;
	int old_cancel_state;
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
	command->owner_active = true;
	command->status = 0;
	rc = spdk_thread_send_msg(command->controller->owner, function, command);
	if (rc != 0) {
		status = rc;
		goto cleanup;
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

cleanup:
	rc = pthread_cond_destroy(&command->condition);
	assert(rc == 0);
	rc = pthread_mutex_destroy(&command->mutex);
	assert(rc == 0);
	rc = pthread_setcancelstate(old_cancel_state, &ignored_cancel_state);
	assert(rc == 0);
	return status;
}

static int
copy_required_string(char *destination, size_t destination_size, const char *source)
{
	size_t length;

	if (source == NULL) {
		return -EINVAL;
	}
	length = strnlen(source, destination_size);
	if (length == 0 || length == destination_size) {
		return -EINVAL;
	}
	memcpy(destination, source, length + 1);
	return 0;
}

static int
initialize_controller(struct zettide_spdk_nvme_controller *controller,
		const struct zettide_spdk_nvme_controller_opts *opts)
{
	struct spdk_nvme_transport_id *transport_id = &controller->path_id.trid;
	int status;

	spdk_nvme_ctrlr_get_default_ctrlr_opts(&controller->driver_options,
			sizeof(controller->driver_options));
	spdk_bdev_nvme_get_default_ctrlr_opts(&controller->bdev_options);
	controller->bdev_options.multipath = false;
	controller->driver_options.fabrics_connect_timeout_us = opts->connect_timeout_us;

	switch (opts->transport) {
	case ZETTIDE_SPDK_NVME_TRANSPORT_TCP:
		transport_id->trtype = SPDK_NVME_TRANSPORT_TCP;
		break;
	case ZETTIDE_SPDK_NVME_TRANSPORT_RDMA:
		transport_id->trtype = SPDK_NVME_TRANSPORT_RDMA;
		break;
	default:
		return -EINVAL;
	}
	switch (opts->address_family) {
	case ZETTIDE_SPDK_NVME_ADDRESS_FAMILY_UNSPECIFIED:
		transport_id->adrfam = SPDK_NVMF_ADRFAM_NOT_SPECIFIED;
		break;
	case ZETTIDE_SPDK_NVME_ADDRESS_FAMILY_IPV4:
		transport_id->adrfam = SPDK_NVMF_ADRFAM_IPV4;
		break;
	case ZETTIDE_SPDK_NVME_ADDRESS_FAMILY_IPV6:
		transport_id->adrfam = SPDK_NVMF_ADRFAM_IPV6;
		break;
	default:
		return -EINVAL;
	}
	status = copy_required_string(transport_id->traddr, sizeof(transport_id->traddr),
			opts->transport_address);
	if (status != 0) {
		return status;
	}
	status = copy_required_string(transport_id->trsvcid, sizeof(transport_id->trsvcid),
			opts->transport_service_id);
	if (status != 0) {
		return status;
	}
	status = copy_required_string(transport_id->subnqn, sizeof(transport_id->subnqn),
			opts->subsystem_nqn);
	if (status != 0) {
		return status;
	}
	if (opts->host_nqn != NULL) {
		status = copy_required_string(controller->driver_options.hostnqn,
				sizeof(controller->driver_options.hostnqn), opts->host_nqn);
		if (status != 0) {
			return status;
		}
	}
	return 0;
}

static void
free_controller(struct zettide_spdk_nvme_controller *controller)
{
	free(controller->namespace_names);
	free(controller->name);
	free(controller);
}

void
zettide_spdk_nvme_controller_opts_init(struct zettide_spdk_nvme_controller_opts *opts,
		size_t opts_size)
{
	if (opts == NULL || opts_size == 0) {
		return;
	}
	memset(opts, 0, opts_size);
	if (opts_size >= sizeof(*opts)) {
		opts->opts_size = opts_size;
		opts->transport = ZETTIDE_SPDK_NVME_TRANSPORT_TCP;
		opts->address_family = ZETTIDE_SPDK_NVME_ADDRESS_FAMILY_IPV4;
		opts->transport_service_id = "4420";
		opts->connect_timeout_us = 10000000;
		opts->namespace_name_capacity = ZETTIDE_SPDK_NVME_DEFAULT_NAMESPACE_CAPACITY;
	}
}

int
zettide_spdk_nvme_controller_attach(struct zettide_spdk_runtime *runtime,
		const struct zettide_spdk_nvme_controller_opts *opts,
		struct zettide_spdk_nvme_controller **controller_out)
{
	struct zettide_spdk_nvme_controller *controller;
	struct controller_command command = {0};
	struct spdk_thread *owner;
	size_t name_length;
	int status;

	if (runtime == NULL || opts == NULL || controller_out == NULL ||
		opts->opts_size != sizeof(*opts) || opts->name == NULL ||
		opts->namespace_name_capacity == 0) {
		return -EINVAL;
	}
	*controller_out = NULL;
	name_length = strnlen(opts->name, ZETTIDE_SPDK_NVME_CONTROLLER_NAME_MAX);
	if (name_length == 0 || name_length == ZETTIDE_SPDK_NVME_CONTROLLER_NAME_MAX) {
		return -EINVAL;
	}
	controller = calloc(1, sizeof(*controller));
	if (controller == NULL) {
		return -ENOMEM;
	}
	controller->name = strdup(opts->name);
	controller->namespace_names = calloc(opts->namespace_name_capacity,
			sizeof(*controller->namespace_names));
	if (controller->name == NULL || controller->namespace_names == NULL) {
		free_controller(controller);
		return -ENOMEM;
	}
	controller->runtime = runtime;
	controller->namespace_name_capacity = opts->namespace_name_capacity;
	status = initialize_controller(controller, opts);
	if (status != 0) {
		free_controller(controller);
		return status;
	}
	status = zettide_spdk_runtime_acquire(runtime, &owner);
	if (status != 0) {
		free_controller(controller);
		return status;
	}
	controller->owner = owner;
	command.controller = controller;
	status = dispatch_command(&command, run_attach);
	if (status != 0) {
		zettide_spdk_runtime_release(runtime);
		free_controller(controller);
		return status;
	}
	*controller_out = controller;
	return 0;
}

int
zettide_spdk_nvme_controller_detach(struct zettide_spdk_nvme_controller *controller)
{
	struct controller_command command = {0};
	int status;

	if (controller == NULL) {
		return -EINVAL;
	}
	command.controller = controller;
	status = dispatch_command(&command, run_detach);
	if (status == 0) {
		zettide_spdk_runtime_release(controller->runtime);
		free_controller(controller);
	}
	return status;
}

size_t
zettide_spdk_nvme_controller_get_namespace_count(
		const struct zettide_spdk_nvme_controller *controller)
{
	return controller == NULL ? 0 : controller->namespace_count;
}

bool
zettide_spdk_nvme_controller_namespace_names_truncated(
		const struct zettide_spdk_nvme_controller *controller)
{
	return controller != NULL && controller->namespace_names_truncated;
}

const char *
zettide_spdk_nvme_controller_get_namespace_name(
		const struct zettide_spdk_nvme_controller *controller, size_t index)
{
	if (controller == NULL || index >= controller->namespace_count) {
		return NULL;
	}
	return controller->namespace_names[index];
}
