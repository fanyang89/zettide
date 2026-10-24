#include "spdk/nvmf_tcp_export.h"
#include "spdk/nvme_controller.h"
#include "spdk/runtime.h"

#include <errno.h>
#include <stdint.h>

/* These requests must fail before SPDK startup or runtime-lease acquisition. */
int
main(void)
{
	struct zettide_spdk_runtime_opts runtime_opts;
	struct zettide_spdk_runtime *runtime = NULL;
	struct zettide_spdk_nvmf_tcp_export_opts export_opts;
	struct zettide_spdk_nvmf_tcp_export *export_handle = NULL;
	struct zettide_spdk_nvme_controller_opts controller_opts;
	struct zettide_spdk_nvme_controller *controller = NULL;
	const char *retired_paths[] = {"", "/run/retired-vhost"};
	const unsigned retired_transports[] = {1, 99};
	size_t index;

	zettide_spdk_runtime_opts_init(&runtime_opts, sizeof(runtime_opts));
	runtime_opts.name = "must-not-start";
	for (index = 0; index < sizeof(retired_paths) / sizeof(retired_paths[0]); index++) {
		runtime_opts.retired_vhost_socket_path = retired_paths[index];
		if (zettide_spdk_runtime_start(&runtime_opts, &runtime) != -EINVAL || runtime != NULL) {
			return 1;
		}
	}
	zettide_spdk_nvmf_tcp_export_opts_init(&export_opts, sizeof(export_opts));
	export_opts.nqn = "nqn.2026-08.io.zettide:must-not-export";
	export_opts.bdev_name = "must-not-open";
	export_opts.traddr = "127.0.0.1";
	export_opts.trsvcid = "4420";
	export_opts.allow_any_host = true;
	zettide_spdk_nvme_controller_opts_init(&controller_opts, sizeof(controller_opts));
	controller_opts.name = "must-not-attach";
	controller_opts.transport_address = "127.0.0.1";
	controller_opts.subsystem_nqn = export_opts.nqn;
	for (index = 0; index < sizeof(retired_transports) / sizeof(retired_transports[0]); index++) {
		export_opts.transport = (enum zettide_spdk_nvmf_transport)retired_transports[index];
		controller_opts.transport = (enum zettide_spdk_nvme_transport)retired_transports[index];
		if (zettide_spdk_nvme_controller_attach((void *)(uintptr_t)1,
				&controller_opts, &controller) != -EINVAL || controller != NULL) {
			return 1;
		}
		/* A dummy non-NULL runtime catches accidentally proceeding past validation. */
		if (zettide_spdk_nvmf_tcp_export_create((void *)(uintptr_t)1,
				&export_opts, &export_handle) != -EINVAL || export_handle != NULL) {
			return 1;
		}
	}
	return 0;
}
