#include "spdk/nvmf_tcp_export.h"
#include "spdk/runtime.h"
#include "spdk_runtime.h"

#include <errno.h>
#include <stddef.h>

static const char g_config[] =
	"{\"subsystems\":["
	"{\"subsystem\":\"bdev\",\"config\":["
	"{\"method\":\"bdev_malloc_create\",\"params\":{\"name\":\"NvmfExportBdev\","
	"\"num_blocks\":4096,\"block_size\":4096}},"
	"{\"method\":\"bdev_malloc_create\",\"params\":{\"name\":\"NvmfSharedBdev\","
	"\"num_blocks\":4096,\"block_size\":4096}}]},"
	"{\"subsystem\":\"nvmf\",\"config\":["
	"{\"method\":\"nvmf_create_transport\",\"params\":{\"trtype\":\"TCP\"}}]}]}";

int zettide_spdk_nvmf_zig_export_test(void *runtime);

static int
run_export_lifecycle(struct zettide_spdk_runtime *runtime)
{
	struct zettide_spdk_nvmf_tcp_export_opts options;
	struct zettide_spdk_nvmf_tcp_export *export_handle = NULL;
	struct zettide_spdk_nvmf_tcp_export *duplicate = NULL;
	struct zettide_spdk_nvmf_tcp_export *shared_listener = NULL;
	int status;

	zettide_spdk_nvmf_tcp_export_opts_init(&options, sizeof(options));
	options.nqn = "nqn.2026-08.io.zettide:managed-test";
	options.bdev_name = "NvmfExportBdev";
	options.serial_number = "ZETTIDETEST000001";
	options.model_number = "Zettide Managed Test";
	options.traddr = "127.0.0.1";
	options.trsvcid = "44229";
	options.allow_any_host = true;
	options.transport = (enum zettide_spdk_nvmf_transport)99;
	status = zettide_spdk_nvmf_tcp_export_create(runtime, &options, &export_handle);
	if (status != -EINVAL || export_handle != NULL) {
		return 1;
	}
	options.transport = ZETTIDE_SPDK_NVMF_TRANSPORT_TCP;
	status = zettide_spdk_nvmf_tcp_export_create(runtime, &options, &export_handle);
	if (status != 0 || export_handle == NULL) {
		return 1;
	}
	status = zettide_spdk_nvmf_tcp_export_create(runtime, &options, &duplicate);
	if (status != -EEXIST || duplicate != NULL) {
		(void)zettide_spdk_nvmf_tcp_export_close(export_handle);
		return 1;
	}
	options.nqn = "nqn.2026-08.io.zettide:shared-listener-test";
	options.bdev_name = "NvmfSharedBdev";
	status = zettide_spdk_nvmf_tcp_export_create(runtime, &options, &shared_listener);
	if (status != 0 || shared_listener == NULL) {
		(void)zettide_spdk_nvmf_tcp_export_close(export_handle);
		return 1;
	}
	status = zettide_spdk_nvmf_tcp_export_close(export_handle);
	if (status != 0) {
		(void)zettide_spdk_nvmf_tcp_export_close(shared_listener);
		return 1;
	}
	if (zettide_spdk_nvmf_tcp_export_close(shared_listener) != 0) {
		return 1;
	}
	if (zettide_spdk_nvmf_zig_export_test(runtime) != 0) {
		return 1;
	}
	options.nqn = "nqn.2026-08.io.zettide:managed-test";
	options.bdev_name = "NvmfExportBdev";
	status = zettide_spdk_nvmf_tcp_export_create(runtime, &options, &export_handle);
	if (status != 0 || export_handle == NULL) {
		return 1;
	}
	return zettide_spdk_nvmf_tcp_export_close(export_handle) == 0 ? 0 : 1;
}

int
main(void)
{
	struct zettide_spdk_runtime_opts options;
	struct zettide_spdk_runtime *runtime = NULL;
	char reactor_mask[32];
	int status;

	status = zettide_spdk_test_reactor_mask(reactor_mask, sizeof(reactor_mask));
	if (status != 0) {
		return 1;
	}
	zettide_spdk_runtime_opts_init(&options, sizeof(options));
	options.name = "zettide_spdk_nvmf_export_test";
	options.reactor_mask = reactor_mask;
	options.json_data = g_config;
	options.json_data_size = sizeof(g_config) - 1;
	options.mem_size_mb = 512;
	options.no_pci = true;
	options.no_huge = true;
	options.disable_cpumask_locks = true;
	status = zettide_spdk_runtime_start(&options, &runtime);
	if (status == 0) {
		status = run_export_lifecycle(runtime);
	}
	if (runtime != NULL && zettide_spdk_runtime_stop(runtime) != 0) {
		status = 1;
	}
	if (runtime != NULL && zettide_spdk_runtime_destroy(runtime) != 0) {
		status = 1;
	}
	return status == 0 ? 0 : 1;
}
