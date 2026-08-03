/* SPDX-License-Identifier: LGPL-3.0-or-later */
#ifndef FSAL_ZETTIDE_INTERNAL_H
#define FSAL_ZETTIDE_INTERNAL_H

#include "fsal.h"
#include "nfs_backend.h"

struct zettide_fsal_module {
	struct fsal_module fsal;
	struct fsal_obj_ops handle_ops;
};

struct zettide_fsal_export {
	struct fsal_export export;
	struct zettide_nfs_export *backend;
	char *target;
	bool writable;
};

struct zettide_fsal_handle {
	struct fsal_obj_handle obj_handle;
	struct zettide_fsal_export *export;
	struct zettide_nfs_handle wire;
};

extern struct zettide_fsal_module ZETTIDE;

fsal_status_t zettide_status(int status);
void zettide_fill_attrs(const struct zettide_nfs_handle *wire,
			const struct zettide_nfs_attributes *source,
			struct fsal_attrlist *target);
struct zettide_fsal_handle *
zettide_alloc_handle(struct zettide_fsal_export *export,
		     const struct zettide_nfs_handle *wire,
		     const struct zettide_nfs_attributes *attributes);
void zettide_handle_ops_init(struct fsal_obj_ops *ops);
fsal_status_t zettide_create_export(struct fsal_module *fsal_hdl,
				    void *parse_node,
				    struct config_error_type *err_type,
				    const struct fsal_up_vector *up_ops);

#endif
