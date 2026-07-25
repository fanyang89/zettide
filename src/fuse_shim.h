#ifndef DEVDRIVE_FUSE_SHIM_H
#define DEVDRIVE_FUSE_SHIM_H

#include <stdint.h>
#include <time.h>
#include <fuse3/fuse.h>

int devdrive_fuse_get_flags(const struct fuse_file_info *file_info);
uint64_t devdrive_fuse_get_handle(const struct fuse_file_info *file_info);
void devdrive_fuse_set_handle(struct fuse_file_info *file_info, uint64_t handle);
void devdrive_fuse_set_direct_io(struct fuse_file_info *file_info);
int devdrive_fuse_main(int argc, char *argv[], const struct fuse_operations *operations, void *user_data);

#endif
