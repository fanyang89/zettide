#include "iscsi_export.h"

#include "spdk/iscsi.h"
#include "spdk/thread.h"

#include <assert.h>
#include <errno.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>

#define ZETTIDE_ISCSI_NAME_MAX 223
#define ZETTIDE_ISCSI_BDEV_NAME_MAX 255
#define ZETTIDE_ISCSI_ADDR_MAX 256
#define ZETTIDE_ISCSI_PORT_MAX 32

struct zettide_spdk_iscsi_service {
	struct zettide_spdk_runtime *runtime;
	struct spdk_thread *owner;
	char *traddr;
	char *trsvcid;
	char *initiator_name;
	char *netmask;
	int32_t portal_group_tag;
	int32_t initiator_group_tag;
	size_t active_exports;
	bool portal_created;
	bool initiator_group_created;
};

struct zettide_spdk_iscsi_export {
	struct zettide_spdk_iscsi_service *service;
	char *target_name;
	char *bdev_name;
	int32_t lun;
	int32_t queue_depth;
};

struct iscsi_command {
	pthread_mutex_t mutex;
	pthread_cond_t condition;
	bool completed;
	int status;
	struct zettide_spdk_iscsi_service *service;
	struct zettide_spdk_iscsi_export *export_handle;
};

static bool
valid_string(const char *value, size_t max_length)
{
	size_t length;

	if (value == NULL) {
		return false;
	}
	length = strnlen(value, max_length + 1);
	return length != 0 && length <= max_length;
}

static void
complete_command(struct iscsi_command *command, int status)
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

static int
dispatch_command(struct iscsi_command *command, spdk_msg_fn function)
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
	rc = spdk_thread_send_msg(command->service->owner, function, command);
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
free_service(struct zettide_spdk_iscsi_service *service)
{
	free(service->netmask);
	free(service->initiator_name);
	free(service->trsvcid);
	free(service->traddr);
	free(service);
}

static void
free_export(struct zettide_spdk_iscsi_export *export_handle)
{
	free(export_handle->bdev_name);
	free(export_handle->target_name);
	free(export_handle);
}

static void
run_service_create(void *context)
{
	struct iscsi_command *command = context;
	struct zettide_spdk_iscsi_service *service = command->service;
	int rc;

	rc = spdk_iscsi_portal_group_create(service->portal_group_tag,
			service->traddr, service->trsvcid);
	if (rc != 0) {
		complete_command(command, rc);
		return;
	}
	service->portal_created = true;
	rc = spdk_iscsi_initiator_group_create(service->initiator_group_tag,
			service->initiator_name, service->netmask);
	if (rc != 0) {
		int rollback_rc = spdk_iscsi_portal_group_delete(service->portal_group_tag);

		assert(rollback_rc == 0);
		service->portal_created = false;
		complete_command(command, rc);
		return;
	}
	service->initiator_group_created = true;
	complete_command(command, 0);
}

static void
run_service_close(void *context)
{
	struct iscsi_command *command = context;
	struct zettide_spdk_iscsi_service *service = command->service;
	int rc;

	if (service->active_exports != 0) {
		complete_command(command, -EBUSY);
		return;
	}
	if (service->initiator_group_created) {
		rc = spdk_iscsi_initiator_group_delete(service->initiator_group_tag);
		if (rc != 0 && rc != -ENOENT) {
			complete_command(command, rc);
			return;
		}
		service->initiator_group_created = false;
	}
	if (service->portal_created) {
		rc = spdk_iscsi_portal_group_delete(service->portal_group_tag);
		if (rc != 0 && rc != -ENOENT) {
			complete_command(command, rc);
			return;
		}
		service->portal_created = false;
	}
	complete_command(command, 0);
}

static void
run_export_create(void *context)
{
	struct iscsi_command *command = context;
	struct zettide_spdk_iscsi_export *export_handle = command->export_handle;
	struct zettide_spdk_iscsi_service *service = export_handle->service;
	struct spdk_iscsi_target_opts opts;
	int rc;

	spdk_iscsi_target_opts_init(&opts, sizeof(opts));
	opts.name = export_handle->target_name;
	opts.bdev_name = export_handle->bdev_name;
	opts.portal_group_tag = service->portal_group_tag;
	opts.initiator_group_tag = service->initiator_group_tag;
	opts.lun_id = export_handle->lun;
	opts.queue_depth = export_handle->queue_depth;
	rc = spdk_iscsi_target_create(&opts);
	if (rc == 0) {
		service->active_exports++;
	}
	complete_command(command, rc);
}

static void
export_deleted(void *context, int status)
{
	struct iscsi_command *command = context;

	if (status == -ENOENT) {
		status = 0;
	}
	if (status == 0) {
		assert(command->service->active_exports > 0);
		command->service->active_exports--;
	}
	complete_command(command, status);
}

static void
run_export_close(void *context)
{
	struct iscsi_command *command = context;

	spdk_iscsi_target_delete(command->export_handle->target_name,
			export_deleted, command);
}

void
zettide_spdk_iscsi_service_opts_init(
		struct zettide_spdk_iscsi_service_opts *opts, size_t opts_size)
{
	if (opts == NULL || opts_size == 0) {
		return;
	}
	memset(opts, 0, opts_size);
	if (opts_size >= sizeof(*opts)) {
		opts->opts_size = opts_size;
		opts->portal_group_tag = 1;
		opts->initiator_group_tag = 1;
	}
}

void
zettide_spdk_iscsi_export_opts_init(
		struct zettide_spdk_iscsi_export_opts *opts, size_t opts_size)
{
	if (opts == NULL || opts_size == 0) {
		return;
	}
	memset(opts, 0, opts_size);
	if (opts_size >= sizeof(*opts)) {
		opts->opts_size = opts_size;
		opts->lun = 0;
		opts->queue_depth = 64;
	}
}

int
zettide_spdk_iscsi_service_create(struct zettide_spdk_runtime *runtime,
		const struct zettide_spdk_iscsi_service_opts *opts,
		struct zettide_spdk_iscsi_service **service_out)
{
	struct zettide_spdk_iscsi_service *service;
	struct iscsi_command command = {0};
	struct spdk_thread *owner;
	int status;

	if (runtime == NULL || opts == NULL || service_out == NULL ||
	    opts->opts_size != sizeof(*opts) ||
	    !valid_string(opts->traddr, ZETTIDE_ISCSI_ADDR_MAX) ||
	    !valid_string(opts->trsvcid, ZETTIDE_ISCSI_PORT_MAX) ||
	    !valid_string(opts->initiator_name, ZETTIDE_ISCSI_NAME_MAX) ||
	    !valid_string(opts->netmask, ZETTIDE_ISCSI_ADDR_MAX) ||
	    opts->portal_group_tag < 0 || opts->initiator_group_tag < 0) {
		return -EINVAL;
	}
	*service_out = NULL;
	status = zettide_spdk_runtime_acquire(runtime, &owner);
	if (status != 0) {
		return status;
	}
	service = calloc(1, sizeof(*service));
	if (service == NULL) {
		zettide_spdk_runtime_release(runtime);
		return -ENOMEM;
	}
	service->runtime = runtime;
	service->owner = owner;
	service->traddr = strdup(opts->traddr);
	service->trsvcid = strdup(opts->trsvcid);
	service->initiator_name = strdup(opts->initiator_name);
	service->netmask = strdup(opts->netmask);
	service->portal_group_tag = opts->portal_group_tag;
	service->initiator_group_tag = opts->initiator_group_tag;
	if (service->traddr == NULL || service->trsvcid == NULL ||
	    service->initiator_name == NULL || service->netmask == NULL) {
		free_service(service);
		zettide_spdk_runtime_release(runtime);
		return -ENOMEM;
	}
	command.service = service;
	status = dispatch_command(&command, run_service_create);
	if (status != 0) {
		free_service(service);
		zettide_spdk_runtime_release(runtime);
		return status;
	}
	*service_out = service;
	return 0;
}

int
zettide_spdk_iscsi_service_close(struct zettide_spdk_iscsi_service *service)
{
	struct iscsi_command command = { .service = service };
	int status;

	if (service == NULL) {
		return -EINVAL;
	}
	status = dispatch_command(&command, run_service_close);
	if (status == 0) {
		zettide_spdk_runtime_release(service->runtime);
		free_service(service);
	}
	return status;
}

int
zettide_spdk_iscsi_export_create(
		struct zettide_spdk_iscsi_service *service,
		const struct zettide_spdk_iscsi_export_opts *opts,
		struct zettide_spdk_iscsi_export **export_out)
{
	struct zettide_spdk_iscsi_export *export_handle;
	struct iscsi_command command = { .service = service };
	int status;

	if (service == NULL || opts == NULL || export_out == NULL ||
	    opts->opts_size != sizeof(*opts) ||
	    !valid_string(opts->target_name, ZETTIDE_ISCSI_NAME_MAX) ||
	    !valid_string(opts->bdev_name, ZETTIDE_ISCSI_BDEV_NAME_MAX) ||
	    opts->lun < 0 || opts->queue_depth <= 0) {
		return -EINVAL;
	}
	*export_out = NULL;
	export_handle = calloc(1, sizeof(*export_handle));
	if (export_handle == NULL) {
		return -ENOMEM;
	}
	export_handle->service = service;
	export_handle->target_name = strdup(opts->target_name);
	export_handle->bdev_name = strdup(opts->bdev_name);
	export_handle->lun = opts->lun;
	export_handle->queue_depth = opts->queue_depth;
	if (export_handle->target_name == NULL || export_handle->bdev_name == NULL) {
		free_export(export_handle);
		return -ENOMEM;
	}
	command.export_handle = export_handle;
	status = dispatch_command(&command, run_export_create);
	if (status != 0) {
		free_export(export_handle);
		return status;
	}
	*export_out = export_handle;
	return 0;
}

int
zettide_spdk_iscsi_export_close(
		struct zettide_spdk_iscsi_export *export_handle)
{
	struct iscsi_command command;
	int status;

	if (export_handle == NULL) {
		return -EINVAL;
	}
	memset(&command, 0, sizeof(command));
	command.service = export_handle->service;
	command.export_handle = export_handle;
	status = dispatch_command(&command, run_export_close);
	if (status == 0) {
		free_export(export_handle);
	}
	return status;
}
