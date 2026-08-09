#ifndef ZETTIDE_SPDK_NVMF_TCP_EXPORT_H
#define ZETTIDE_SPDK_NVMF_TCP_EXPORT_H

#include "runtime.h"

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

struct zettide_spdk_nvmf_tcp_export;

enum zettide_spdk_nvmf_transport {
	ZETTIDE_SPDK_NVMF_TRANSPORT_TCP = 0,
	ZETTIDE_SPDK_NVMF_TRANSPORT_RDMA = 1,
};

struct zettide_spdk_nvmf_tcp_export_opts {
	size_t opts_size;
	const char *target_name;
	const char *nqn;
	const char *bdev_name;
	const char *serial_number;
	const char *model_number;
	/* Access control identifier only; it does not authenticate a host. */
	const char *host_nqn;
	const char *traddr;
	const char *trsvcid;
	uint32_t nsid;
	bool allow_any_host;
	enum zettide_spdk_nvmf_transport transport;
};

void zettide_spdk_nvmf_tcp_export_opts_init(
		struct zettide_spdk_nvmf_tcp_export_opts *opts, size_t opts_size);

/* Blocking lifecycle calls must only be made from non-SPDK threads. */
int zettide_spdk_nvmf_tcp_export_create(struct zettide_spdk_runtime *runtime,
		const struct zettide_spdk_nvmf_tcp_export_opts *opts,
		struct zettide_spdk_nvmf_tcp_export **export_out);

/* Calls operating on the same export must be externally serialized. */
int zettide_spdk_nvmf_tcp_export_close(
		struct zettide_spdk_nvmf_tcp_export *export_handle);

#ifdef __cplusplus
}
#endif

#endif
