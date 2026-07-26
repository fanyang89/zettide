#ifndef ZETTIDE_FUSE_SHIM_H
#define ZETTIDE_FUSE_SHIM_H

#include <stdint.h>
#include <time.h>
#include <fuse3/fuse_lowlevel.h>

int zettide_fuse_get_flags(const struct fuse_file_info *file_info);
uint64_t zettide_fuse_get_handle(const struct fuse_file_info *file_info);
void zettide_fuse_set_handle(struct fuse_file_info *file_info, uint64_t handle);
void zettide_fuse_set_direct_io(struct fuse_file_info *file_info);
int zettide_fuse_configure_connection(struct fuse_conn_info *connection);
int zettide_fuse_main(int argc, char *argv[], const struct fuse_lowlevel_ops *operations, void *user_data);

#endif
