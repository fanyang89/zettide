#include "fuse_shim.h"

#include <stdlib.h>

int zettide_fuse_get_flags(const struct fuse_file_info *file_info) {
    return file_info->flags;
}

uint64_t zettide_fuse_get_handle(const struct fuse_file_info *file_info) {
    return file_info->fh;
}

void zettide_fuse_set_handle(struct fuse_file_info *file_info, uint64_t handle) {
    file_info->fh = handle;
}

void zettide_fuse_set_direct_io(struct fuse_file_info *file_info) {
    file_info->direct_io = 1;
}

int zettide_fuse_configure_connection(struct fuse_conn_info *connection) {
    connection->want &= ~(FUSE_CAP_POSIX_LOCKS | FUSE_CAP_FLOCK_LOCKS |
                          FUSE_CAP_HANDLE_KILLPRIV);
#ifdef FUSE_CAP_HANDLE_KILLPRIV_V2
    connection->want &= ~FUSE_CAP_HANDLE_KILLPRIV_V2;
#endif
    if ((connection->capable & FUSE_CAP_WRITEBACK_CACHE) == 0)
        return 0;
    connection->want |= FUSE_CAP_WRITEBACK_CACHE;
    return 1;
}

int zettide_fuse_main(int argc, char *argv[], const struct fuse_lowlevel_ops *operations, void *user_data) {
    struct fuse_args args = FUSE_ARGS_INIT(argc, argv);
    struct fuse_cmdline_opts options = {0};
    struct fuse_session *session = NULL;
    int mounted = 0;
    int signal_handlers = 0;
    int result = 1;

    if (fuse_parse_cmdline(&args, &options) != 0 || options.mountpoint == NULL)
        goto cleanup;
    session = fuse_session_new(&args, operations, sizeof(*operations), user_data);
    if (session == NULL)
        goto cleanup;
    if (fuse_set_signal_handlers(session) != 0)
        goto cleanup;
    signal_handlers = 1;
    if (fuse_session_mount(session, options.mountpoint) != 0)
        goto cleanup;
    mounted = 1;
    if (fuse_daemonize(options.foreground) != 0)
        goto cleanup;

    result = fuse_session_loop(session);
    if (result != 0)
        result = 1;

cleanup:
    if (mounted)
        fuse_session_unmount(session);
    if (signal_handlers)
        fuse_remove_signal_handlers(session);
    if (session != NULL)
        fuse_session_destroy(session);
    free(options.mountpoint);
    fuse_opt_free_args(&args);
    return result;
}
