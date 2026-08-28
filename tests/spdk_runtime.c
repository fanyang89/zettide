#include "spdk_runtime.h"

#include "spdk/env.h"
#include "spdk/runtime.h"
#include "spdk/thread.h"

#include <assert.h>
#include <errno.h>
#include <pthread.h>
#include <sched.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>

struct owner_core_command {
	pthread_mutex_t mutex;
	pthread_cond_t condition;
	uint32_t core;
	bool done;
};

static void
capture_owner_core(void *context)
{
	struct owner_core_command *command = context;
	int rc;

	rc = pthread_mutex_lock(&command->mutex);
	assert(rc == 0);
	command->core = spdk_env_get_current_core();
	command->done = true;
	rc = pthread_cond_signal(&command->condition);
	assert(rc == 0);
	rc = pthread_mutex_unlock(&command->mutex);
	assert(rc == 0);
}

static int
get_owner_core(struct spdk_thread *owner, uint32_t *core_out)
{
	struct owner_core_command command = {0};
	int status;
	int rc;

	rc = pthread_mutex_init(&command.mutex, NULL);
	if (rc != 0) {
		return -rc;
	}
	rc = pthread_cond_init(&command.condition, NULL);
	if (rc != 0) {
		(void)pthread_mutex_destroy(&command.mutex);
		return -rc;
	}
	rc = pthread_mutex_lock(&command.mutex);
	assert(rc == 0);
	status = spdk_thread_send_msg(owner, capture_owner_core, &command);
	while (status == 0 && !command.done) {
		rc = pthread_cond_wait(&command.condition, &command.mutex);
		assert(rc == 0);
	}
	if (status == 0) {
		*core_out = command.core;
	}
	rc = pthread_mutex_unlock(&command.mutex);
	assert(rc == 0);
	rc = pthread_cond_destroy(&command.condition);
	assert(rc == 0);
	rc = pthread_mutex_destroy(&command.mutex);
	assert(rc == 0);
	return status;
}

int
zettide_spdk_test_reactor_mask_count(char *buffer, size_t buffer_size,
		size_t count)
{
	cpu_set_t allowed;
	size_t available = 0;
	size_t selected = 0;
	size_t offset = 0;
	int cpu;
	int length;

	if (buffer == NULL || buffer_size == 0 || count == 0 ||
		sched_getaffinity(0, sizeof(allowed), &allowed) != 0) {
		return -EINVAL;
	}
	for (cpu = 0; cpu < CPU_SETSIZE; cpu++) {
		if (CPU_ISSET(cpu, &allowed)) {
			available++;
		}
	}
	if (available < count) {
		return -ENODEV;
	}
	length = snprintf(buffer, buffer_size, "[");
	if (length < 0 || (size_t)length >= buffer_size) {
		return -ENOSPC;
	}
	offset = (size_t)length;
	for (cpu = 0; cpu < CPU_SETSIZE; cpu++) {
		if (!CPU_ISSET(cpu, &allowed)) {
			continue;
		}
		length = snprintf(buffer + offset, buffer_size - offset,
				selected == 0 ? "%d" : ",%d", cpu);
		if (length < 0 || (size_t)length >= buffer_size - offset) {
			return -ENOSPC;
		}
		offset += (size_t)length;
		selected++;
		if (selected == count) {
			length = snprintf(buffer + offset, buffer_size - offset, "]");
			return length < 0 || (size_t)length >= buffer_size - offset ?
				-ENOSPC : 0;
		}
	}
	return -EINVAL;
}

int
zettide_spdk_test_reactor_mask(char *buffer, size_t buffer_size)
{
	return zettide_spdk_test_reactor_mask_count(buffer, buffer_size, 1);
}

int
zettide_spdk_test_dispatcher_owner_round_robin(
		struct zettide_spdk_runtime *runtime, size_t owner_count)
{
	struct spdk_thread *control = NULL;
	struct spdk_thread *owners[5] = {0};
	uint32_t cores[4];
	size_t acquired = 0;
	size_t index;
	size_t previous;
	int status;

	if (owner_count < 2 || owner_count > 4) {
		return -EINVAL;
	}
	status = zettide_spdk_runtime_acquire(runtime, &control);
	if (status != 0) {
		return status;
	}
	acquired++;
	for (index = 0; index <= owner_count; index++) {
		status = zettide_spdk_runtime_acquire_dispatcher(runtime, &owners[index]);
		if (status != 0) {
			goto done;
		}
		acquired++;
	}
	if (owners[0] != control || owners[owner_count] != owners[0]) {
		status = -EIO;
		goto done;
	}
	for (index = 0; index < owner_count; index++) {
		status = get_owner_core(owners[index], &cores[index]);
		if (status != 0) {
			goto done;
		}
		for (previous = 0; previous < index; previous++) {
			if (owners[index] == owners[previous] || cores[index] == cores[previous]) {
				status = -EIO;
				goto done;
			}
		}
	}

done:
	while (acquired > 0) {
		acquired--;
		zettide_spdk_runtime_release(runtime);
	}
	return status;
}
