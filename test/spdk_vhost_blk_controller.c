#include "spdk/runtime.h"
#include "spdk/vhost_blk_controller.h"

#include <errno.h>
#include <limits.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>

static const char bdev_config[] =
	"{\"subsystems\":[{\"subsystem\":\"bdev\",\"config\":["
	"{\"method\":\"bdev_set_options\",\"params\":{\"bdev_io_pool_size\":1024,"
	"\"bdev_io_cache_size\":32}},"
	"{\"method\":\"bdev_malloc_create\",\"params\":{\"name\":\"ZettideVhost0\","
	"\"num_blocks\":256,\"block_size\":4096}}]}]}";

static int
expect_status(const char *operation, int actual, int expected)
{
	if (actual == expected) {
		return 0;
	}
	fprintf(stderr, "%s returned %d, expected %d\n", operation, actual, expected);
	return -EIO;
}

int
main(int argc, char **argv)
{
	struct zettide_spdk_vhost_blk_controller *controller = NULL;
	struct zettide_spdk_vhost_blk_controller *unexpected = NULL;
	struct zettide_spdk_vhost_blk_controller_opts controller_opts;
	struct zettide_spdk_runtime_opts invalid_runtime_opts;
	struct zettide_spdk_runtime_opts runtime_opts;
	struct zettide_spdk_runtime *runtime = NULL;
	const char *socket_path;
	char expected_socket_path[PATH_MAX];
	struct stat socket_status;
	int status;

	if (argc != 2) {
		fprintf(stderr, "usage: %s SOCKET_DIRECTORY\n", argv[0]);
		return 2;
	}
	zettide_spdk_runtime_opts_init(&runtime_opts, sizeof(runtime_opts));
	runtime_opts.name = "zettide_spdk_vhost_test";
	runtime_opts.reactor_mask = "0x1";
	runtime_opts.json_data = bdev_config;
	runtime_opts.json_data_size = strlen(bdev_config);
	runtime_opts.mem_size_mb = 320;
	runtime_opts.no_pci = true;
	runtime_opts.no_huge = true;
	runtime_opts.disable_cpumask_locks = true;
	runtime_opts.vhost_socket_path = argv[1];
	invalid_runtime_opts = runtime_opts;
	invalid_runtime_opts.vhost_socket_path = "";
	status = expect_status("empty vhost socket path",
			zettide_spdk_runtime_start(&invalid_runtime_opts, &runtime), -EINVAL);
	if (status != 0 || runtime != NULL) {
		return 1;
	}
	status = zettide_spdk_runtime_start(&runtime_opts, &runtime);
	if (status != 0) {
		fprintf(stderr, "runtime start failed: %d\n", status);
		return 1;
	}

	zettide_spdk_vhost_blk_controller_opts_init(&controller_opts, sizeof(controller_opts));
	controller_opts.cpumask = "0x1";
	controller_opts.name = "invalid/name";
	controller_opts.bdev_name = "ZettideVhost0";
	status = expect_status("invalid controller create",
			zettide_spdk_vhost_blk_controller_create(runtime, &controller_opts, &unexpected),
			-EINVAL);
	if (status != 0 || unexpected != NULL) {
		goto cleanup;
	}
	controller_opts.name = "zettide-vhost-0";
	controller_opts.bdev_name = "MissingBdev";
	status = zettide_spdk_vhost_blk_controller_create(runtime, &controller_opts, &unexpected);
	if (status >= 0 || unexpected != NULL) {
		fprintf(stderr, "missing bdev controller create unexpectedly succeeded\n");
		status = -EIO;
		goto cleanup;
	}
	controller_opts.bdev_name = "ZettideVhost0";
	status = zettide_spdk_vhost_blk_controller_create(runtime, &controller_opts, &controller);
	if (status != 0) {
		fprintf(stderr, "controller create failed: %d\n", status);
		goto cleanup;
	}
	socket_path = zettide_spdk_vhost_blk_controller_get_socket_path(controller);
	if (socket_path == NULL || snprintf(expected_socket_path, sizeof(expected_socket_path),
			"%s/%s", argv[1], controller_opts.name) >= (int)sizeof(expected_socket_path)) {
		status = -ENAMETOOLONG;
		goto cleanup;
	}
	if (strcmp(socket_path, expected_socket_path) != 0 ||
		!zettide_spdk_vhost_blk_controller_is_ready(controller) ||
		lstat(socket_path, &socket_status) != 0 || !S_ISSOCK(socket_status.st_mode)) {
		fprintf(stderr, "vhost socket is not ready\n");
		status = -EIO;
		goto cleanup;
	}
	status = zettide_spdk_vhost_blk_controller_create(runtime, &controller_opts, &unexpected);
	if (status >= 0 || unexpected != NULL) {
		fprintf(stderr, "duplicate controller create unexpectedly succeeded\n");
		status = -EIO;
		goto cleanup;
	}
	status = expect_status("runtime stop with controller",
			zettide_spdk_runtime_stop(runtime), -EBUSY);
	if (status != 0) {
		goto cleanup;
	}
	status = zettide_spdk_vhost_blk_controller_remove(controller);
	if (status != 0) {
		fprintf(stderr, "controller remove failed: %d\n", status);
		goto cleanup;
	}
	controller = NULL;
	if (lstat(expected_socket_path, &socket_status) == 0 || errno != ENOENT) {
		fprintf(stderr, "vhost socket remains after controller removal\n");
		status = -EIO;
		goto cleanup;
	}

cleanup:
	if (controller != NULL) {
		int remove_status = zettide_spdk_vhost_blk_controller_remove(controller);

		if (status == 0) {
			status = remove_status;
		}
	}
	if (runtime != NULL) {
		int stop_status = zettide_spdk_runtime_stop(runtime);
		int destroy_status = stop_status == 0 ? zettide_spdk_runtime_destroy(runtime) : 0;

		if (status == 0) {
			status = stop_status != 0 ? stop_status : destroy_status;
		}
	}
	return status == 0 ? 0 : 1;
}
