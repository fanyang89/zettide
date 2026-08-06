// SPDX-License-Identifier: LGPL-3.0-or-later
#include "config.h"

#include <errno.h>
#include <inttypes.h>
#include <string.h>

#include "FSAL/fsal_commonlib.h"
#include "FSAL/fsal_config.h"
#include "export_mgr.h"
#include "fsal_convert.h"
#include "nfs_exports.h"
#include "zettide_fsal.h"

static void zettide_release_export(struct fsal_export *exp_hdl)
{
	struct zettide_fsal_export *export =
		container_of(exp_hdl, struct zettide_fsal_export, export);

	LogEvent(COMPONENT_FSAL,
		 "zettide_write_metrics stable_writes=%" PRIu64
		 " unstable_writes=%" PRIu64 " stable_batches=%" PRIu64
		 " stable_joins=%" PRIu64 " stable_syncs=%" PRIu64
		 " commit_calls=%" PRIu64,
		 export->stable_writes, export->unstable_writes,
		 export->stable_batches, export->stable_joins,
		 export->stable_syncs, export->commit_calls);

	if (export->backend != NULL) {
		int status = zettide_nfs_export_close(export->backend);
		if (status != ZETTIDE_NFS_OK) {
			LogMajor(COMPONENT_FSAL,
				 "Closing Zettide export failed with status %d",
				 status);
		}
		export->backend = NULL;
	}

	fsal_detach_export(exp_hdl->fsal, &exp_hdl->exports);
	pthread_cond_destroy(&export->stable_cond);
	pthread_mutex_destroy(&export->stable_mutex);
	free_export_ops(exp_hdl);
	gsh_free(export->target);
	gsh_free(export);
}

static fsal_status_t zettide_lookup_path(struct fsal_export *exp_hdl,
					 const char *path,
					 struct fsal_obj_handle **handle,
					 struct fsal_attrlist *attrs_out)
{
	struct zettide_fsal_export *export =
		container_of(exp_hdl, struct zettide_fsal_export, export);
	struct zettide_nfs_handle wire;
	struct zettide_nfs_attributes attributes;
	struct zettide_fsal_handle *result;
	int status;

	(void)path;
	*handle = NULL;
	status = zettide_nfs_root(export->backend, &wire, &attributes);
	if (status != ZETTIDE_NFS_OK)
		return zettide_status(status);

	result = zettide_alloc_handle(export, &wire, &attributes);
	*handle = &result->obj_handle;
	if (attrs_out != NULL)
		zettide_fill_attrs(&wire, &attributes, attrs_out);
	return fsalstat(ERR_FSAL_NO_ERROR, 0);
}

static fsal_status_t zettide_wire_to_host(struct fsal_export *exp_hdl,
					  fsal_digesttype_t in_type,
					  struct gsh_buffdesc *fh_desc,
					  int flags)
{
	(void)exp_hdl;
	(void)flags;
	if (in_type != FSAL_DIGEST_NFSV3 && in_type != FSAL_DIGEST_NFSV4)
		return fsalstat(ERR_FSAL_SERVERFAULT, EINVAL);
	if (fh_desc->len != ZETTIDE_NFS_HANDLE_SIZE)
		return fsalstat(ERR_FSAL_BADHANDLE, EINVAL);
	return fsalstat(ERR_FSAL_NO_ERROR, 0);
}

static fsal_status_t zettide_create_handle(struct fsal_export *exp_hdl,
					   struct gsh_buffdesc *fh_desc,
					   struct fsal_obj_handle **handle,
					   struct fsal_attrlist *attrs_out)
{
	struct zettide_fsal_export *export =
		container_of(exp_hdl, struct zettide_fsal_export, export);
	struct zettide_nfs_handle wire;
	struct zettide_nfs_attributes attributes;
	struct zettide_fsal_handle *result;
	int status;

	*handle = NULL;
	if (fh_desc->len != sizeof(wire))
		return fsalstat(ERR_FSAL_BADHANDLE, EINVAL);
	memcpy(&wire, fh_desc->addr, sizeof(wire));
	status = zettide_nfs_getattr(export->backend, &wire, &attributes);
	if (status != ZETTIDE_NFS_OK)
		return zettide_status(status);

	result = zettide_alloc_handle(export, &wire, &attributes);
	*handle = &result->obj_handle;
	if (attrs_out != NULL)
		zettide_fill_attrs(&wire, &attributes, attrs_out);
	return fsalstat(ERR_FSAL_NO_ERROR, 0);
}

static fsal_status_t zettide_get_dynamic_info(struct fsal_export *exp_hdl,
					      struct fsal_obj_handle *obj_hdl,
					      fsal_dynamicfsinfo_t *info)
{
	struct zettide_fsal_export *export =
		container_of(exp_hdl, struct zettide_fsal_export, export);
	struct zettide_nfs_filesystem_info backend_info;
	int status;

	(void)obj_hdl;
	status = zettide_nfs_statfs(export->backend, &backend_info);
	if (status != ZETTIDE_NFS_OK)
		return zettide_status(status);

	memset(info, 0, sizeof(*info));
	info->total_bytes = backend_info.total_bytes;
	info->free_bytes = backend_info.free_bytes;
	info->avail_bytes = backend_info.available_bytes;
	info->time_delta.tv_nsec = FSAL_DEFAULT_TIME_DELTA_NSEC;
	return fsalstat(ERR_FSAL_NO_ERROR, 0);
}

static void zettide_export_ops_init(struct export_ops *ops)
{
	ops->release = zettide_release_export;
	ops->lookup_path = zettide_lookup_path;
	ops->wire_to_host = zettide_wire_to_host;
	ops->create_handle = zettide_create_handle;
	ops->get_fs_dynamic_info = zettide_get_dynamic_info;
}

static struct config_item zettide_export_params[] = {
	CONF_ITEM_NOOP("name"),
	CONF_ITEM_STR("Target", 1, MAXPATHLEN, NULL, zettide_fsal_export,
		      target),
	CONF_ITEM_BOOL("Writable", false, zettide_fsal_export, writable),
	CONF_ITEM_UI32("Stable_Write_Batch_Us", 0, 999999, 1000,
		       zettide_fsal_export, stable_write_batch_us),
	CONFIG_EOL,
};

static struct config_block zettide_export_block = {
	.dbus_interface_name = "org.ganesha.nfsd.config.fsal.zettide-export%d",
	.blk_desc.name = "FSAL",
	.blk_desc.type = CONFIG_BLOCK,
	.blk_desc.u.blk.init = noop_conf_init,
	.blk_desc.u.blk.params = zettide_export_params,
	.blk_desc.u.blk.commit = noop_conf_commit,
};

fsal_status_t zettide_create_export(struct fsal_module *fsal_hdl,
				    void *parse_node,
				    struct config_error_type *err_type,
				    const struct fsal_up_vector *up_ops)
{
	struct zettide_fsal_export *export = gsh_calloc(1, sizeof(*export));
	fsal_status_t result;
	int status;
	bool mutex_initialized = false;
	bool cond_initialized = false;

	fsal_export_init(&export->export);
	zettide_export_ops_init(&export->export.exp_ops);
	status = pthread_mutex_init(&export->stable_mutex, NULL);
	if (status != 0) {
		result = posix2fsal_status(status);
		goto fail;
	}
	mutex_initialized = true;
	status = pthread_cond_init(&export->stable_cond, NULL);
	if (status != 0) {
		result = posix2fsal_status(status);
		goto fail;
	}
	cond_initialized = true;

	if (load_config_from_node(parse_node, &zettide_export_block, export,
				  true, err_type) != 0) {
		result = fsalstat(ERR_FSAL_INVAL, EINVAL);
		goto fail;
	}

	status = zettide_nfs_export_open(export->target, export->writable,
					 &export->backend);
	if (status != ZETTIDE_NFS_OK) {
		result = zettide_status(status);
		goto fail;
	}

	status = fsal_attach_export(fsal_hdl, &export->export.exports);
	if (status != 0) {
		result = posix2fsal_status(status);
		goto fail_backend;
	}

	export->export.fsal = fsal_hdl;
	export->export.up_ops = up_ops;
	op_ctx->fsal_export = &export->export;
	LogEvent(COMPONENT_FSAL, "Opened Zettide target %s (%s)",
		 export->target, export->writable ? "writable" : "read-only");
	return fsalstat(ERR_FSAL_NO_ERROR, 0);

fail_backend:
	(void)zettide_nfs_export_close(export->backend);
	export->backend = NULL;
fail:
	if (cond_initialized)
		pthread_cond_destroy(&export->stable_cond);
	if (mutex_initialized)
		pthread_mutex_destroy(&export->stable_mutex);
	free_export_ops(&export->export);
	gsh_free(export->target);
	gsh_free(export);
	return result;
}
