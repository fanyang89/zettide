#ifndef ZETTIDE_TEST_SPDK_RUNTIME_H
#define ZETTIDE_TEST_SPDK_RUNTIME_H

#include <stddef.h>

int zettide_spdk_test_reactor_mask(char *buffer, size_t buffer_size);
int zettide_spdk_test_reactor_mask_count(
		char *buffer, size_t buffer_size, size_t count);

#endif
