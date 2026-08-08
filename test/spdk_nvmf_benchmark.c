#include "spdk/bdev_provider.h"
#include "spdk/nvmf_tcp_export.h"
#include "spdk/runtime.h"
#include "spdk_runtime.h"

#include <fcntl.h>
#include <pthread.h>
#include <signal.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>
#include <unistd.h>

#define BENCHMARK_BYTES (64ULL * 1024 * 1024 * 1024)
#define BLOCK_SIZE 4096U

static const char g_config[] =
	"{\"subsystems\":["
	"{\"subsystem\":\"bdev\",\"config\":["
	"{\"method\":\"bdev_set_options\",\"params\":{\"bdev_io_pool_size\":16384,"
	"\"bdev_io_cache_size\":256}}]},"
	"{\"subsystem\":\"nvmf\",\"config\":["
	"{\"method\":\"nvmf_create_transport\",\"params\":{\"trtype\":\"TCP\","
	"\"max_queue_depth\":256,\"max_io_size\":1048576}}]}]}";

static int
submit(void *backend_context, enum zettide_spdk_bdev_provider_operation operation,
		uint64_t offset, void *buffer, uint64_t length,
		zettide_spdk_bdev_provider_complete complete, void *complete_context)
{
	(void)backend_context;
	(void)offset;
	if (operation == ZETTIDE_SPDK_BDEV_PROVIDER_READ) {
		memset(buffer, 0x5a, length);
	}
	complete(complete_context, 0);
	return 0;
}

int
main(int argc, char **argv)
{
	struct zettide_spdk_runtime_opts runtime_options;
	struct zettide_spdk_bdev_provider_opts provider_options;
	struct zettide_spdk_nvmf_tcp_export_opts export_options;
	struct zettide_spdk_runtime *runtime = NULL;
	struct zettide_spdk_bdev_provider *provider = NULL;
	struct zettide_spdk_nvmf_tcp_export *export_handle = NULL;
	char reactor_mask[32];
	sigset_t signals;
	int ready_fd;
	int signal_number;
	int status;

	if (argc != 2) {
		return 2;
	}
	sigemptyset(&signals);
	sigaddset(&signals, SIGINT);
	sigaddset(&signals, SIGTERM);
	status = pthread_sigmask(SIG_BLOCK, &signals, NULL);
	if (status != 0 || zettide_spdk_test_reactor_mask(reactor_mask, sizeof(reactor_mask)) != 0) {
		return 1;
	}
	zettide_spdk_runtime_opts_init(&runtime_options, sizeof(runtime_options));
	runtime_options.name = "zettide_spdk_nvmf_benchmark";
	runtime_options.reactor_mask = reactor_mask;
	runtime_options.json_data = g_config;
	runtime_options.json_data_size = sizeof(g_config) - 1;
	runtime_options.mem_size_mb = 512;
	runtime_options.no_pci = true;
	runtime_options.no_huge = true;
	runtime_options.disable_cpumask_locks = true;
	status = zettide_spdk_runtime_start(&runtime_options, &runtime);
	if (status != 0) {
		return 1;
	}

	zettide_spdk_bdev_provider_opts_init(&provider_options, sizeof(provider_options));
	provider_options.name = "ZettideNvmfBenchmark0";
	provider_options.block_size = BLOCK_SIZE;
	provider_options.block_count = BENCHMARK_BYTES / BLOCK_SIZE;
	provider_options.max_io_blocks = 1048576 / BLOCK_SIZE;
	provider_options.submit = submit;
	status = zettide_spdk_bdev_provider_create(runtime, &provider_options, &provider);
	if (status != 0) {
		goto cleanup;
	}

	zettide_spdk_nvmf_tcp_export_opts_init(&export_options, sizeof(export_options));
	export_options.nqn = "nqn.2026-08.io.zettide:benchmark";
	export_options.bdev_name = "ZettideNvmfBenchmark0";
	export_options.serial_number = "ZETTIDEBENCH000001";
	export_options.model_number = "Zettide NVMe-oF Benchmark";
	export_options.traddr = "127.0.0.1";
	export_options.trsvcid = "44220";
	export_options.allow_any_host = true;
	status = zettide_spdk_nvmf_tcp_export_create(runtime, &export_options, &export_handle);
	if (status != 0) {
		goto cleanup;
	}

	ready_fd = open(argv[1], O_WRONLY | O_CREAT | O_EXCL, 0600);
	if (ready_fd < 0 || close(ready_fd) != 0) {
		status = 1;
		goto cleanup;
	}
	status = sigwait(&signals, &signal_number);

cleanup:
	if (export_handle != NULL && zettide_spdk_nvmf_tcp_export_close(export_handle) != 0) {
		status = 1;
	}
	if (provider != NULL && zettide_spdk_bdev_provider_delete_wait(provider) != 0) {
		status = 1;
	}
	if (runtime != NULL && zettide_spdk_runtime_stop(runtime) != 0) {
		status = 1;
	}
	if (runtime != NULL && zettide_spdk_runtime_destroy(runtime) != 0) {
		status = 1;
	}
	return status == 0 ? 0 : 1;
}
