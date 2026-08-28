#ifndef ZETTIDE_TEST_SPDK_RUNTIME_H
#define ZETTIDE_TEST_SPDK_RUNTIME_H

#include <stddef.h>

struct zettide_spdk_runtime;

int zettide_spdk_test_reactor_mask(char *buffer, size_t buffer_size);
int zettide_spdk_test_reactor_mask_count(
		char *buffer, size_t buffer_size, size_t count);
int zettide_spdk_test_dispatcher_owner_round_robin(
		struct zettide_spdk_runtime *runtime, size_t owner_count);

#endif
