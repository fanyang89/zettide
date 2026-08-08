// SPDX-License-Identifier: LGPL-3.0-or-later
#include "config.h"

#include <errno.h>
#include <limits.h>

#include "FSAL/fsal_init.h"
#include "fsal_convert.h"
#include "zettide_fsal.h"

#define ZETTIDE_SUPPORTED_ATTRIBUTES (ATTRS_POSIX)

struct zettide_fsal_module ZETTIDE = {
	.fsal = { .fs_info = {
		.maxfilesize = INT64_MAX,
		.maxlink = UINT32_MAX,
		.maxnamelen = ZETTIDE_NFS_NAME_CAPACITY - 1,
		.maxpathlen = MAXPATHLEN,
		.no_trunc = true,
		.chown_restricted = true,
		.case_insensitive = false,
		.case_preserving = true,
		.link_support = true,
		.symlink_support = true,
		.lock_support = false,
		.lock_support_async_block = false,
		.named_attr = false,
		.unique_handles = true,
		.acl_support = 0,
		.cansettime = true,
		.homogenous = true,
		.supported_attrs = ZETTIDE_SUPPORTED_ATTRIBUTES,
		.maxread = FSAL_MAXIOSIZE,
		.maxwrite = FSAL_MAXIOSIZE,
		.umask = 0,
		.auth_exportpath_xdev = false,
		.link_supports_permission_checks = false,
		.readdir_plus = true,
		.expire_time_parent = -1,
	} },
};

static fsal_status_t zettide_init_config(struct fsal_module *fsal_hdl,
					 config_file_t config_struct,
					 struct config_error_type *err_type)
{
	(void)config_struct;
	(void)err_type;
	display_fsinfo(fsal_hdl);
	return fsalstat(ERR_FSAL_NO_ERROR, 0);
}

MODULE_INIT void zettide_init(void)
{
	struct fsal_module *module = &ZETTIDE.fsal;

	if (register_fsal(module, "ZETTIDE", FSAL_MAJOR_VERSION,
			  FSAL_MINOR_VERSION, FSAL_ID_NO_PNFS) != 0) {
		LogCrit(COMPONENT_FSAL, "ZETTIDE module failed to register");
		return;
	}

	module->m_ops.create_export = zettide_create_export;
	module->m_ops.init_config = zettide_init_config;
	zettide_handle_ops_init(&ZETTIDE.handle_ops);
}

MODULE_FINI void zettide_finish(void)
{
	if (unregister_fsal(&ZETTIDE.fsal) != 0) {
		LogCrit(COMPONENT_FSAL, "ZETTIDE module failed to unregister");
	}
}

fsal_status_t zettide_status(int status)
{
	switch (status) {
	case ZETTIDE_NFS_OK:
		return fsalstat(ERR_FSAL_NO_ERROR, 0);
	case ZETTIDE_NFS_INVALID_ARGUMENT:
		return fsalstat(ERR_FSAL_INVAL, EINVAL);
	case ZETTIDE_NFS_NO_ENTRY:
		return fsalstat(ERR_FSAL_NOENT, ENOENT);
	case ZETTIDE_NFS_STALE:
		return fsalstat(ERR_FSAL_STALE, ESTALE);
	case ZETTIDE_NFS_NOT_DIRECTORY:
		return fsalstat(ERR_FSAL_NOTDIR, ENOTDIR);
	case ZETTIDE_NFS_IS_DIRECTORY:
		return fsalstat(ERR_FSAL_ISDIR, EISDIR);
	case ZETTIDE_NFS_EXISTS:
		return fsalstat(ERR_FSAL_EXIST, EEXIST);
	case ZETTIDE_NFS_READ_ONLY:
		return fsalstat(ERR_FSAL_ROFS, EROFS);
	case ZETTIDE_NFS_NO_SPACE:
		return fsalstat(ERR_FSAL_NOSPC, ENOSPC);
	case ZETTIDE_NFS_IO:
		return fsalstat(ERR_FSAL_IO, EIO);
	case ZETTIDE_NFS_NOT_SUPPORTED:
		return fsalstat(ERR_FSAL_NOTSUPP, ENOTSUP);
	case ZETTIDE_NFS_PERMISSION_DENIED:
		return fsalstat(ERR_FSAL_ACCESS, EACCES);
	case ZETTIDE_NFS_DIRECTORY_NOT_EMPTY:
		return fsalstat(ERR_FSAL_NOTEMPTY, ENOTEMPTY);
	case ZETTIDE_NFS_TOO_MANY_LINKS:
		return fsalstat(ERR_FSAL_MLINK, EMLINK);
	case ZETTIDE_NFS_FILE_TOO_LARGE:
		return fsalstat(ERR_FSAL_FBIG, EFBIG);
	case ZETTIDE_NFS_NAME_TOO_LONG:
		return fsalstat(ERR_FSAL_NAMETOOLONG, ENAMETOOLONG);
	case ZETTIDE_NFS_INTERNAL:
	default:
		return fsalstat(ERR_FSAL_SERVERFAULT, EIO);
	}
}
