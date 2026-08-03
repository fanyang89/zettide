#include "nfs_backend.h"

_Static_assert(sizeof(struct zettide_nfs_handle) == ZETTIDE_NFS_HANDLE_SIZE,
               "wire handle size changed");
_Static_assert(sizeof(((struct zettide_nfs_directory_entry *)0)->name) ==
                    ZETTIDE_NFS_NAME_CAPACITY,
               "directory name capacity changed");
_Static_assert(sizeof(struct zettide_nfs_set_attributes) == 48,
               "setattr ABI size changed");

int main(void) {
    if (zettide_nfs_export_open(NULL, false, NULL) !=
        ZETTIDE_NFS_INVALID_ARGUMENT)
        return 1;
    if (zettide_nfs_export_close(NULL) != ZETTIDE_NFS_INVALID_ARGUMENT)
        return 1;
    return 0;
}
