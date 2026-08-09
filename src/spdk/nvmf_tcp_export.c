#include "nvmf_tcp_export.h"

#include "spdk/nvme.h"
#include "spdk/nvmf.h"
#include "spdk/thread.h"

#include <assert.h>
#include <errno.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>

#define ZETTIDE_SPDK_NVMF_BDEV_NAME_MAX 255
#define ZETTIDE_SPDK_NVMF_NSID_MAX 65535

struct zettide_spdk_nvmf_tcp_export {
	struct zettide_spdk_runtime *runtime;
	struct spdk_thread *owner;
	struct spdk_nvmf_tgt *target;
	struct spdk_nvmf_subsystem *subsystem;
	struct spdk_nvme_transport_id trid;
	char *target_name;
	char *nqn;
	char *bdev_name;
	char *serial_number;
	char *model_number;
	char *host_nqn;
	uint32_t nsid;
	bool allow_any_host;
	bool target_listener_started;
	bool subsystem_listener_added;
	bool subsystem_stopped;
};

struct export_command {
	pthread_mutex_t mutex;
	pthread_cond_t condition;
	bool completed;
	int status;
	int create_status;
	struct zettide_spdk_nvmf_tcp_export *export_handle;
};

static void
complete_command(struct export_command *command, int status)
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
dispatch_command(struct export_command *command, spdk_msg_fn function)
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
	rc = spdk_thread_send_msg(command->export_handle->owner, function, command);
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
free_export(struct zettide_spdk_nvmf_tcp_export *export_handle)
{
	free(export_handle->host_nqn);
	free(export_handle->model_number);
	free(export_handle->serial_number);
	free(export_handle->bdev_name);
	free(export_handle->nqn);
	free(export_handle->target_name);
	free(export_handle);
}

static bool
valid_string(const char *value, size_t max_length, bool optional)
{
	size_t length;

	if (value == NULL) {
		return optional;
	}
	length = strnlen(value, max_length + 1);
	return length != 0 && length <= max_length;
}

static void rollback_create(struct export_command *command);

static void
create_destroyed(void *context)
{
	struct export_command *command = context;

	command->export_handle->subsystem = NULL;
	complete_command(command, command->create_status);
}

static void
finish_create_rollback(struct export_command *command)
{
	struct zettide_spdk_nvmf_tcp_export *export_handle = command->export_handle;
	int rc;

	if (export_handle->subsystem_listener_added) {
		rc = spdk_nvmf_subsystem_remove_listener(export_handle->subsystem,
				&export_handle->trid);
		if (rc != 0 && rc != -ENOENT) {
			abort();
		}
		export_handle->subsystem_listener_added = false;
	}
	if (export_handle->target_listener_started) {
		rc = spdk_nvmf_tgt_stop_listen(export_handle->target, &export_handle->trid);
		if (rc != 0 && rc != -ENOENT) {
			abort();
		}
		export_handle->target_listener_started = false;
	}
	rc = spdk_nvmf_subsystem_destroy(export_handle->subsystem, create_destroyed, command);
	if (rc == 0) {
		export_handle->subsystem = NULL;
		complete_command(command, command->create_status);
	} else if (rc != -EINPROGRESS) {
		abort();
	}
}

static void
create_rollback_stopped(struct spdk_nvmf_subsystem *subsystem, void *context, int status)
{
	struct export_command *command = context;

	(void)subsystem;
	if (status != 0) {
		abort();
	}
	finish_create_rollback(command);
}

static void
rollback_create(struct export_command *command)
{
	int rc = spdk_nvmf_subsystem_stop(command->export_handle->subsystem,
			create_rollback_stopped, command);

	if (rc != 0) {
		abort();
	}
}

static void
create_started(struct spdk_nvmf_subsystem *subsystem, void *context, int status)
{
	struct export_command *command = context;

	(void)subsystem;
	if (status == 0) {
		complete_command(command, 0);
		return;
	}
	command->create_status = status;
	rollback_create(command);
}

static void
create_listener_added(void *context, int status)
{
	struct export_command *command = context;
	struct zettide_spdk_nvmf_tcp_export *export_handle = command->export_handle;
	int rc;

	if (status != 0) {
		command->create_status = status;
		rollback_create(command);
		return;
	}
	export_handle->subsystem_listener_added = true;
	rc = spdk_nvmf_subsystem_start(export_handle->subsystem, create_started, command);
	if (rc != 0) {
		command->create_status = rc;
		rollback_create(command);
	}
}

static void
run_create(void *context)
{
	struct export_command *command = context;
	struct zettide_spdk_nvmf_tcp_export *export_handle = command->export_handle;
	struct spdk_nvmf_subsystem_opts subsystem_opts;
	struct spdk_nvmf_ns_opts namespace_opts;
	struct spdk_nvmf_listen_opts listen_opts;
	uint32_t nsid;
	int rc;

	export_handle->target = spdk_nvmf_get_tgt(export_handle->target_name);
	if (export_handle->target == NULL) {
		complete_command(command, -ENODEV);
		return;
	}
	if (spdk_nvmf_tgt_find_subsystem(export_handle->target, export_handle->nqn) != NULL) {
		complete_command(command, -EEXIST);
		return;
	}
	spdk_nvmf_subsystem_opts_init(SPDK_NVMF_SUBTYPE_NVME, &subsystem_opts,
			sizeof(subsystem_opts));
	subsystem_opts.max_namespaces = export_handle->nsid;
	if (export_handle->serial_number != NULL) {
		memcpy(subsystem_opts.sn, export_handle->serial_number,
				strlen(export_handle->serial_number) + 1);
	}
	if (export_handle->model_number != NULL) {
		memcpy(subsystem_opts.mn, export_handle->model_number,
				strlen(export_handle->model_number) + 1);
	}
	export_handle->subsystem = spdk_nvmf_subsystem_create_ext(export_handle->target,
			export_handle->nqn, SPDK_NVMF_SUBTYPE_NVME, &subsystem_opts);
	if (export_handle->subsystem == NULL) {
		complete_command(command, -EINVAL);
		return;
	}

	spdk_nvmf_ns_opts_get_defaults(&namespace_opts, sizeof(namespace_opts));
	namespace_opts.nsid = export_handle->nsid;
	nsid = spdk_nvmf_subsystem_add_ns_ext(export_handle->subsystem,
			export_handle->bdev_name, &namespace_opts, sizeof(namespace_opts), NULL);
	if (nsid != export_handle->nsid) {
		command->create_status = -ENODEV;
		rollback_create(command);
		return;
	}
	if (export_handle->allow_any_host) {
		rc = spdk_nvmf_subsystem_set_allow_any_host(export_handle->subsystem, true);
	} else {
		rc = spdk_nvmf_subsystem_add_host(export_handle->subsystem,
				export_handle->host_nqn, NULL);
	}
	if (rc != 0) {
		command->create_status = rc;
		rollback_create(command);
		return;
	}

	spdk_nvmf_listen_opts_init(&listen_opts, sizeof(listen_opts));
	rc = spdk_nvmf_tgt_listen_ext(export_handle->target, &export_handle->trid,
			&listen_opts);
	if (rc != 0) {
		command->create_status = rc;
		rollback_create(command);
		return;
	}
	export_handle->target_listener_started = true;
	spdk_nvmf_subsystem_add_listener(export_handle->subsystem, &export_handle->trid,
			create_listener_added, command);
}

static void
close_destroyed(void *context)
{
	struct export_command *command = context;

	command->export_handle->subsystem = NULL;
	complete_command(command, 0);
}

static void
continue_close(struct export_command *command)
{
	struct zettide_spdk_nvmf_tcp_export *export_handle = command->export_handle;
	int rc;

	if (export_handle->subsystem_listener_added) {
		rc = spdk_nvmf_subsystem_remove_listener(export_handle->subsystem,
				&export_handle->trid);
		if (rc != 0 && rc != -ENOENT) {
			complete_command(command, rc);
			return;
		}
		export_handle->subsystem_listener_added = false;
	}
	if (export_handle->target_listener_started) {
		rc = spdk_nvmf_tgt_stop_listen(export_handle->target, &export_handle->trid);
		if (rc != 0 && rc != -ENOENT) {
			complete_command(command, rc);
			return;
		}
		export_handle->target_listener_started = false;
	}
	if (export_handle->subsystem == NULL) {
		complete_command(command, 0);
		return;
	}
	rc = spdk_nvmf_subsystem_destroy(export_handle->subsystem, close_destroyed, command);
	if (rc == 0) {
		export_handle->subsystem = NULL;
		complete_command(command, 0);
	} else if (rc != -EINPROGRESS) {
		complete_command(command, rc);
	}
}

static void
close_stopped(struct spdk_nvmf_subsystem *subsystem, void *context, int status)
{
	struct export_command *command = context;

	(void)subsystem;
	if (status != 0) {
		complete_command(command, status);
		return;
	}
	command->export_handle->subsystem_stopped = true;
	continue_close(command);
}

static void
run_close(void *context)
{
	struct export_command *command = context;
	struct zettide_spdk_nvmf_tcp_export *export_handle = command->export_handle;
	int rc;

	if (export_handle->subsystem == NULL || export_handle->subsystem_stopped) {
		continue_close(command);
		return;
	}
	rc = spdk_nvmf_subsystem_stop(export_handle->subsystem,
			close_stopped, command);
	if (rc != 0) {
		complete_command(command, rc);
	}
}

void
zettide_spdk_nvmf_tcp_export_opts_init(
		struct zettide_spdk_nvmf_tcp_export_opts *opts, size_t opts_size)
{
	if (opts == NULL || opts_size == 0) {
		return;
	}
	memset(opts, 0, opts_size);
	if (opts_size >= sizeof(*opts)) {
		opts->opts_size = opts_size;
		opts->nsid = 1;
	}
}

static int
validate_opts(struct zettide_spdk_runtime *runtime,
		const struct zettide_spdk_nvmf_tcp_export_opts *opts,
		struct zettide_spdk_nvmf_tcp_export **export_out)
{
	if (runtime == NULL || opts == NULL || export_out == NULL ||
		opts->opts_size != sizeof(*opts) ||
		!valid_string(opts->target_name, NVMF_TGT_NAME_MAX_LENGTH - 1, true) ||
		!valid_string(opts->nqn, SPDK_NVMF_NQN_MAX_LEN, false) ||
		!valid_string(opts->bdev_name, ZETTIDE_SPDK_NVMF_BDEV_NAME_MAX, false) ||
		!valid_string(opts->serial_number, SPDK_NVME_CTRLR_SN_LEN, true) ||
		!valid_string(opts->model_number, SPDK_NVME_CTRLR_MN_LEN, true) ||
		!valid_string(opts->host_nqn, SPDK_NVMF_NQN_MAX_LEN, opts->allow_any_host) ||
		!valid_string(opts->traddr, SPDK_NVMF_TRADDR_MAX_LEN, false) ||
		!valid_string(opts->trsvcid, SPDK_NVMF_TRSVCID_MAX_LEN, false) ||
		opts->nsid == 0 || opts->nsid > ZETTIDE_SPDK_NVMF_NSID_MAX ||
		(opts->transport != ZETTIDE_SPDK_NVMF_TRANSPORT_TCP &&
		 opts->transport != ZETTIDE_SPDK_NVMF_TRANSPORT_RDMA) ||
		(opts->allow_any_host && opts->host_nqn != NULL)) {
		return -EINVAL;
	}
	return 0;
}

static int
create_export(struct zettide_spdk_runtime *runtime,
		const struct zettide_spdk_nvmf_tcp_export_opts *opts,
		struct zettide_spdk_nvmf_tcp_export **export_out)
{
	struct zettide_spdk_nvmf_tcp_export *export_handle;
	struct export_command command = {0};
	struct spdk_thread *owner;
	int status;

	status = validate_opts(runtime, opts, export_out);
	if (status != 0) {
		return status;
	}
	*export_out = NULL;
	if (spdk_get_thread() != NULL) {
		return -EDEADLK;
	}
	status = zettide_spdk_runtime_acquire(runtime, &owner);
	if (status != 0) {
		return status;
	}
	export_handle = calloc(1, sizeof(*export_handle));
	if (export_handle == NULL) {
		zettide_spdk_runtime_release(runtime);
		return -ENOMEM;
	}
	export_handle->runtime = runtime;
	export_handle->owner = owner;
	export_handle->target_name = opts->target_name == NULL ? NULL : strdup(opts->target_name);
	export_handle->nqn = strdup(opts->nqn);
	export_handle->bdev_name = strdup(opts->bdev_name);
	export_handle->serial_number = opts->serial_number == NULL ? NULL : strdup(opts->serial_number);
	export_handle->model_number = opts->model_number == NULL ? NULL : strdup(opts->model_number);
	export_handle->host_nqn = opts->host_nqn == NULL ? NULL : strdup(opts->host_nqn);
	if ((opts->target_name != NULL && export_handle->target_name == NULL) ||
		export_handle->nqn == NULL || export_handle->bdev_name == NULL ||
		(opts->serial_number != NULL && export_handle->serial_number == NULL) ||
		(opts->model_number != NULL && export_handle->model_number == NULL) ||
		(opts->host_nqn != NULL && export_handle->host_nqn == NULL)) {
		free_export(export_handle);
		zettide_spdk_runtime_release(runtime);
		return -ENOMEM;
	}
	export_handle->nsid = opts->nsid;
	export_handle->allow_any_host = opts->allow_any_host;
	spdk_nvme_trid_populate_transport(&export_handle->trid,
			opts->transport == ZETTIDE_SPDK_NVMF_TRANSPORT_RDMA ?
			SPDK_NVME_TRANSPORT_RDMA : SPDK_NVME_TRANSPORT_TCP);
	export_handle->trid.adrfam = SPDK_NVMF_ADRFAM_IPV4;
	memcpy(export_handle->trid.traddr, opts->traddr, strlen(opts->traddr) + 1);
	memcpy(export_handle->trid.trsvcid, opts->trsvcid, strlen(opts->trsvcid) + 1);
	command.export_handle = export_handle;
	status = dispatch_command(&command, run_create);
	if (status != 0) {
		zettide_spdk_runtime_release(runtime);
		free_export(export_handle);
		return status;
	}
	*export_out = export_handle;
	return 0;
}

int
zettide_spdk_nvmf_tcp_export_create(struct zettide_spdk_runtime *runtime,
		const struct zettide_spdk_nvmf_tcp_export_opts *opts,
		struct zettide_spdk_nvmf_tcp_export **export_out)
{
	int old_cancel_state;
	int ignored_cancel_state;
	int status;
	int rc;

	rc = pthread_setcancelstate(PTHREAD_CANCEL_DISABLE, &old_cancel_state);
	if (rc != 0) {
		return -rc;
	}
	status = create_export(runtime, opts, export_out);
	rc = pthread_setcancelstate(old_cancel_state, &ignored_cancel_state);
	assert(rc == 0);
	return status;
}

static int
close_export(struct zettide_spdk_nvmf_tcp_export *export_handle)
{
	struct export_command command = {0};
	int status;

	if (export_handle == NULL) {
		return -EINVAL;
	}
	if (spdk_get_thread() != NULL) {
		return -EDEADLK;
	}
	command.export_handle = export_handle;
	status = dispatch_command(&command, run_close);
	if (status == 0) {
		zettide_spdk_runtime_release(export_handle->runtime);
		free_export(export_handle);
	}
	return status;
}

int
zettide_spdk_nvmf_tcp_export_close(
		struct zettide_spdk_nvmf_tcp_export *export_handle)
{
	int old_cancel_state;
	int ignored_cancel_state;
	int status;
	int rc;

	rc = pthread_setcancelstate(PTHREAD_CANCEL_DISABLE, &old_cancel_state);
	if (rc != 0) {
		return -rc;
	}
	status = close_export(export_handle);
	rc = pthread_setcancelstate(old_cancel_state, &ignored_cancel_state);
	assert(rc == 0);
	return status;
}
