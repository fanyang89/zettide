#include "spdk_runtime.h"

#include <errno.h>
#include <sched.h>
#include <stdio.h>

int
zettide_spdk_test_reactor_mask(char *buffer, size_t buffer_size)
{
	cpu_set_t allowed;
	int cpu;
	int length;

	if (buffer == NULL || buffer_size == 0 ||
		sched_getaffinity(0, sizeof(allowed), &allowed) != 0) {
		return -EINVAL;
	}
	for (cpu = 0; cpu < CPU_SETSIZE; cpu++) {
		if (!CPU_ISSET(cpu, &allowed)) {
			continue;
		}
		length = snprintf(buffer, buffer_size, "[%d]", cpu);
		return length < 0 || (size_t)length >= buffer_size ? -ENOSPC : 0;
	}
	return -ENODEV;
}
