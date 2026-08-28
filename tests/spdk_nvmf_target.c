#include "spdk/runtime.h"
#include "spdk_runtime.h"

#include <fcntl.h>
#include <pthread.h>
#include <signal.h>
#include <stddef.h>
#include <unistd.h>

static const char g_target_config[] =
	"{\"subsystems\":["
	"{\"subsystem\":\"bdev\",\"config\":["
	"{\"method\":\"bdev_set_options\",\"params\":{\"bdev_io_pool_size\":4096,"
	"\"bdev_io_cache_size\":64}},"
	"{\"method\":\"bdev_malloc_create\",\"params\":{\"name\":\"ZettideTarget0\","
	"\"num_blocks\":4096,\"block_size\":4096}},"
	"{\"method\":\"bdev_malloc_create\",\"params\":{\"name\":\"ZettideTarget1\","
	"\"num_blocks\":4096,\"block_size\":4096}}]},"
	"{\"subsystem\":\"nvmf\",\"config\":["
	"{\"method\":\"nvmf_create_transport\",\"params\":{\"trtype\":\"TCP\"}},"
	"{\"method\":\"nvmf_create_subsystem\",\"params\":{"
	"\"nqn\":\"nqn.2026-07.io.zettide:test\",\"allow_any_host\":true,"
	"\"serial_number\":\"ZETTIDETEST000001\","
	"\"model_number\":\"Zettide Test Controller\"}},"
	"{\"method\":\"nvmf_subsystem_add_ns\",\"params\":{"
	"\"nqn\":\"nqn.2026-07.io.zettide:test\",\"namespace\":{"
	"\"nsid\":1,\"bdev_name\":\"ZettideTarget0\"}}},"
	"{\"method\":\"nvmf_subsystem_add_ns\",\"params\":{"
	"\"nqn\":\"nqn.2026-07.io.zettide:test\",\"namespace\":{"
	"\"nsid\":2,\"bdev_name\":\"ZettideTarget1\"}}},"
	"{\"method\":\"nvmf_subsystem_add_listener\",\"params\":{"
	"\"nqn\":\"nqn.2026-07.io.zettide:test\",\"listen_address\":{"
	"\"trtype\":\"TCP\",\"adrfam\":\"IPv4\",\"traddr\":\"127.0.0.1\","
	"\"trsvcid\":\"44219\"}}}]}]}";

int
main(int argc, char **argv)
{
	struct zettide_spdk_runtime_opts options;
	struct zettide_spdk_runtime *runtime = NULL;
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
	if (status != 0) {
		return 1;
	}
	status = zettide_spdk_test_reactor_mask(reactor_mask, sizeof(reactor_mask));
	if (status != 0) {
		return 1;
	}
	zettide_spdk_runtime_opts_init(&options, sizeof(options));
	options.name = "zettide_spdk_nvmf_target";
	options.reactor_mask = reactor_mask;
	options.json_data = g_target_config;
	options.json_data_size = sizeof(g_target_config) - 1;
	options.mem_size_mb = 512;
	options.no_pci = true;
	options.no_huge = true;
	options.disable_cpumask_locks = true;
	status = zettide_spdk_runtime_start(&options, &runtime);
	if (status != 0) {
		return 1;
	}
	ready_fd = open(argv[1], O_WRONLY | O_CREAT | O_EXCL, 0600);
	if (ready_fd < 0 || close(ready_fd) != 0) {
		(void)zettide_spdk_runtime_stop(runtime);
		(void)zettide_spdk_runtime_destroy(runtime);
		return 1;
	}
	status = sigwait(&signals, &signal_number);
	if (status == 0) {
		status = zettide_spdk_runtime_stop(runtime);
	}
	if (status == 0) {
		status = zettide_spdk_runtime_destroy(runtime);
	}
	return status == 0 ? 0 : 1;
}
