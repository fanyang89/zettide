#include "spdk/stdinc.h"
#include "spdk/bdev.h"
#include "spdk/event.h"
#include "spdk/nvmf.h"

int
main(void)
{
	struct spdk_app_opts opts = {0};
	struct spdk_nvmf_transport_opts transport_opts = {0};

	spdk_app_opts_init(&opts, sizeof(opts));
	if (!spdk_nvmf_transport_opts_init("TCP", &transport_opts, sizeof(transport_opts))) {
		return 1;
	}
	if (!spdk_nvmf_transport_opts_init("RDMA", &transport_opts, sizeof(transport_opts))) {
		return 1;
	}
	return 0;
}
