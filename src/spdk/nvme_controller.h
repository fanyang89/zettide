#ifndef ZETTIDE_SPDK_NVME_CONTROLLER_H
#define ZETTIDE_SPDK_NVME_CONTROLLER_H

#include "runtime.h"

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

struct zettide_spdk_nvme_controller;

enum zettide_spdk_nvme_transport {
	ZETTIDE_SPDK_NVME_TRANSPORT_TCP,
	ZETTIDE_SPDK_NVME_TRANSPORT_RDMA,
};

enum zettide_spdk_nvme_address_family {
	ZETTIDE_SPDK_NVME_ADDRESS_FAMILY_UNSPECIFIED,
	ZETTIDE_SPDK_NVME_ADDRESS_FAMILY_IPV4,
	ZETTIDE_SPDK_NVME_ADDRESS_FAMILY_IPV6,
};

struct zettide_spdk_nvme_controller_opts {
	size_t opts_size;
	const char *name;
	enum zettide_spdk_nvme_transport transport;
	enum zettide_spdk_nvme_address_family address_family;
	const char *transport_address;
	const char *transport_service_id;
	const char *subsystem_nqn;
	const char *host_nqn;
	uint64_t connect_timeout_us;
	uint32_t namespace_name_capacity;
};

void zettide_spdk_nvme_controller_opts_init(
		struct zettide_spdk_nvme_controller_opts *opts, size_t opts_size);

/* Blocking lifecycle calls must only be made from non-SPDK threads. */
int zettide_spdk_nvme_controller_attach(struct zettide_spdk_runtime *runtime,
		const struct zettide_spdk_nvme_controller_opts *opts,
		struct zettide_spdk_nvme_controller **controller_out);
int zettide_spdk_nvme_controller_detach(struct zettide_spdk_nvme_controller *controller);

size_t zettide_spdk_nvme_controller_get_namespace_count(
		const struct zettide_spdk_nvme_controller *controller);
bool zettide_spdk_nvme_controller_namespace_names_truncated(
		const struct zettide_spdk_nvme_controller *controller);
/* The returned name remains valid until detach succeeds. */
const char *zettide_spdk_nvme_controller_get_namespace_name(
		const struct zettide_spdk_nvme_controller *controller, size_t index);

#ifdef __cplusplus
}
#endif

#endif
