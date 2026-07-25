#include "fuse_shim.h"

int devdrive_fuse_get_flags(const struct fuse_file_info *file_info) {
    return file_info->flags;
}

uint64_t devdrive_fuse_get_handle(const struct fuse_file_info *file_info) {
    return file_info->fh;
}

void devdrive_fuse_set_handle(struct fuse_file_info *file_info, uint64_t handle) {
    file_info->fh = handle;
}

void devdrive_fuse_set_direct_io(struct fuse_file_info *file_info) {
    file_info->direct_io = 1;
}

int devdrive_fuse_main(int argc, char *argv[], const struct fuse_operations *operations, void *user_data) {
    return fuse_main(argc, argv, operations, user_data);
}
