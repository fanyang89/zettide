#ifndef ZETTIDE_TEST_SPDK_RUNTIME_H
#define ZETTIDE_TEST_SPDK_RUNTIME_H

#include <stddef.h>

struct spdk_thread;

typedef int (*zettide_spdk_test_fn)(struct spdk_thread *owner, void *context);

int zettide_spdk_test_run(const char *name, const char *json_data,
		size_t json_data_size, zettide_spdk_test_fn test_fn, void *test_context);

#endif
