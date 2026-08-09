#include "spdk_runtime.h"

#include <errno.h>
#include <sched.h>
#include <stdio.h>

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
