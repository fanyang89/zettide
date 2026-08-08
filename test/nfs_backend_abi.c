#include "nfs_backend.h"

_Static_assert(sizeof(struct zettide_nfs_handle) == ZETTIDE_NFS_HANDLE_SIZE,
               "wire handle size changed");
_Static_assert(sizeof(((struct zettide_nfs_directory_entry *)0)->name) ==
                    ZETTIDE_NFS_NAME_CAPACITY,
               "directory name capacity changed");
_Static_assert(sizeof(struct zettide_nfs_set_attributes) == 48,
               "setattr ABI size changed");
_Static_assert(sizeof(struct zettide_nfs_filesystem_info) == 24,
               "statfs ABI size changed");
_Static_assert(sizeof(struct zettide_nfs_async_read_stats) == 32,
               "async read stats ABI size changed");

static void read_callback(int status, size_t bytes_read, void *context) {
    (void)status;
    (void)bytes_read;
    (void)context;
}

int main(void) {
    if (zettide_nfs_export_open(NULL, false, NULL) !=
        ZETTIDE_NFS_INVALID_ARGUMENT)
        return 1;
    if (zettide_nfs_export_close(NULL) != ZETTIDE_NFS_INVALID_ARGUMENT)
        return 1;
    if (zettide_nfs_get_async_read_stats(NULL, NULL) !=
        ZETTIDE_NFS_INVALID_ARGUMENT)
        return 1;
    if (zettide_nfs_read_async(NULL, NULL, 0, NULL, 0, NULL, NULL) !=
        ZETTIDE_NFS_INVALID_ARGUMENT)
        return 1;
    if (zettide_nfs_read_async((struct zettide_nfs_export *)1, NULL, 0,
                               NULL, 0, read_callback, NULL) !=
        ZETTIDE_NFS_INVALID_ARGUMENT)
        return 1;
    if (zettide_nfs_read_async((struct zettide_nfs_export *)1,
                               (const struct zettide_nfs_handle *)1, 0,
                               NULL, 4096, read_callback, NULL) !=
        ZETTIDE_NFS_INVALID_ARGUMENT)
        return 1;
    if (zettide_nfs_read_async((struct zettide_nfs_export *)1,
                               (const struct zettide_nfs_handle *)1, 0,
                               (void *)4096, 4096, NULL, NULL) !=
        ZETTIDE_NFS_INVALID_ARGUMENT)
        return 1;
    return 0;
}
