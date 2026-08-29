#ifndef ZETTIDE_SPDK_ISCSI_EXPORT_H
#define ZETTIDE_SPDK_ISCSI_EXPORT_H

#include "runtime.h"

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

struct zettide_spdk_iscsi_service;
struct zettide_spdk_iscsi_export;

struct zettide_spdk_iscsi_service_opts {
	size_t opts_size;
	const char *traddr;
	const char *trsvcid;
	const char *initiator_name;
	const char *netmask;
	int32_t portal_group_tag;
	int32_t initiator_group_tag;
};

struct zettide_spdk_iscsi_export_opts {
	size_t opts_size;
	const char *target_name;
	const char *bdev_name;
	int32_t lun;
	int32_t queue_depth;
};

void zettide_spdk_iscsi_service_opts_init(
		struct zettide_spdk_iscsi_service_opts *opts, size_t opts_size);
void zettide_spdk_iscsi_export_opts_init(
		struct zettide_spdk_iscsi_export_opts *opts, size_t opts_size);

/* Blocking lifecycle calls must only be made from non-SPDK threads. */
int zettide_spdk_iscsi_service_create(struct zettide_spdk_runtime *runtime,
		const struct zettide_spdk_iscsi_service_opts *opts,
		struct zettide_spdk_iscsi_service **service_out);
int zettide_spdk_iscsi_service_close(
		struct zettide_spdk_iscsi_service *service);
int zettide_spdk_iscsi_export_create(
		struct zettide_spdk_iscsi_service *service,
		const struct zettide_spdk_iscsi_export_opts *opts,
		struct zettide_spdk_iscsi_export **export_out);
int zettide_spdk_iscsi_export_close(
		struct zettide_spdk_iscsi_export *export_handle);

#ifdef __cplusplus
}
#endif

#endif
