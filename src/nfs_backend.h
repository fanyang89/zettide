#ifndef ZETTIDE_NFS_BACKEND_H
#define ZETTIDE_NFS_BACKEND_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define ZETTIDE_NFS_HANDLE_SIZE 44
#define ZETTIDE_NFS_NAME_CAPACITY 256

struct zettide_nfs_export;
struct zettide_nfs_directory;

enum zettide_nfs_status {
    ZETTIDE_NFS_OK = 0,
    ZETTIDE_NFS_INVALID_ARGUMENT = 1,
    ZETTIDE_NFS_NO_ENTRY = 2,
    ZETTIDE_NFS_STALE = 3,
    ZETTIDE_NFS_NOT_DIRECTORY = 4,
    ZETTIDE_NFS_IS_DIRECTORY = 5,
    ZETTIDE_NFS_EXISTS = 6,
    ZETTIDE_NFS_READ_ONLY = 7,
    ZETTIDE_NFS_NO_SPACE = 8,
    ZETTIDE_NFS_IO = 9,
    ZETTIDE_NFS_NOT_SUPPORTED = 10,
    ZETTIDE_NFS_INTERNAL = 11,
    ZETTIDE_NFS_PERMISSION_DENIED = 12,
    ZETTIDE_NFS_DIRECTORY_NOT_EMPTY = 13,
    ZETTIDE_NFS_TOO_MANY_LINKS = 14,
};

enum zettide_nfs_node_kind {
    ZETTIDE_NFS_FILE = 1,
    ZETTIDE_NFS_DIRECTORY = 2,
    ZETTIDE_NFS_SYMLINK = 3,
    ZETTIDE_NFS_FIFO = 4,
};

struct zettide_nfs_handle {
    uint8_t bytes[ZETTIDE_NFS_HANDLE_SIZE];
};

struct zettide_nfs_attributes {
    uint8_t kind;
    uint8_t reserved[3];
    uint32_t mode;
    uint32_t uid;
    uint32_t gid;
    uint64_t size;
    uint64_t allocated_bytes;
    uint64_t nlink;
    int64_t atime_ns;
    int64_t mtime_ns;
    int64_t ctime_ns;
    int64_t birthtime_ns;
};

struct zettide_nfs_directory_entry {
    char name[ZETTIDE_NFS_NAME_CAPACITY];
    uint32_t next_cookie;
    struct zettide_nfs_handle handle;
    struct zettide_nfs_attributes attributes;
};

int zettide_nfs_export_open(
    const char *target,
    bool writable,
    struct zettide_nfs_export **out_export);
int zettide_nfs_export_close(struct zettide_nfs_export *export_handle);
int zettide_nfs_root(
    struct zettide_nfs_export *export_handle,
    struct zettide_nfs_handle *out_handle,
    struct zettide_nfs_attributes *out_attributes);
int zettide_nfs_lookup(
    struct zettide_nfs_export *export_handle,
    const struct zettide_nfs_handle *parent,
    const char *name,
    size_t name_length,
    struct zettide_nfs_handle *out_handle,
    struct zettide_nfs_attributes *out_attributes);
int zettide_nfs_getattr(
    struct zettide_nfs_export *export_handle,
    const struct zettide_nfs_handle *handle,
    struct zettide_nfs_attributes *out_attributes);
int zettide_nfs_read(
    struct zettide_nfs_export *export_handle,
    const struct zettide_nfs_handle *handle,
    uint64_t offset,
    void *buffer,
    size_t buffer_length,
    size_t *out_read);
int zettide_nfs_create(
    struct zettide_nfs_export *export_handle,
    const struct zettide_nfs_handle *parent,
    const char *name,
    size_t name_length,
    uint32_t mode,
    uint32_t uid,
    uint32_t gid,
    struct zettide_nfs_handle *out_handle,
    struct zettide_nfs_attributes *out_attributes);
int zettide_nfs_write(
    struct zettide_nfs_export *export_handle,
    const struct zettide_nfs_handle *handle,
    uint64_t offset,
    const void *data,
    size_t data_length,
    size_t *out_written);
int zettide_nfs_sync(struct zettide_nfs_export *export_handle);
int zettide_nfs_mkdir(
    struct zettide_nfs_export *export_handle,
    const struct zettide_nfs_handle *parent,
    const char *name,
    size_t name_length,
    uint32_t mode,
    uint32_t uid,
    uint32_t gid,
    struct zettide_nfs_handle *out_handle,
    struct zettide_nfs_attributes *out_attributes);
int zettide_nfs_symlink(
    struct zettide_nfs_export *export_handle,
    const struct zettide_nfs_handle *parent,
    const char *name,
    size_t name_length,
    const char *target,
    size_t target_length,
    uint32_t uid,
    uint32_t gid,
    struct zettide_nfs_handle *out_handle,
    struct zettide_nfs_attributes *out_attributes);
int zettide_nfs_readlink(
    struct zettide_nfs_export *export_handle,
    const struct zettide_nfs_handle *handle,
    void *buffer,
    size_t buffer_length,
    size_t *out_read);
int zettide_nfs_link(
    struct zettide_nfs_export *export_handle,
    const struct zettide_nfs_handle *source,
    const struct zettide_nfs_handle *parent,
    const char *name,
    size_t name_length,
    struct zettide_nfs_handle *out_handle,
    struct zettide_nfs_attributes *out_attributes);
int zettide_nfs_remove(
    struct zettide_nfs_export *export_handle,
    const struct zettide_nfs_handle *parent,
    const char *name,
    size_t name_length);
int zettide_nfs_rename(
    struct zettide_nfs_export *export_handle,
    const struct zettide_nfs_handle *old_parent,
    const char *old_name,
    size_t old_name_length,
    const struct zettide_nfs_handle *new_parent,
    const char *new_name,
    size_t new_name_length,
    bool no_replace);
int zettide_nfs_directory_open(
    struct zettide_nfs_export *export_handle,
    const struct zettide_nfs_handle *handle,
    uint32_t cookie,
    struct zettide_nfs_directory **out_directory);
int zettide_nfs_directory_read(
    struct zettide_nfs_directory *directory,
    struct zettide_nfs_directory_entry *out_entry,
    bool *out_has_entry);
int zettide_nfs_directory_close(struct zettide_nfs_directory *directory);

#ifdef __cplusplus
}
#endif

#endif
