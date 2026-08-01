#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

static const char written[] = "written before crash";
static const char mapped[] = "mapped before crash";
static const char data_synced[] = "data synced before crash";

static void fail(const char *message) {
    perror(message);
    exit(1);
}

static void ready_and_pause(const char *ready) {
    int ready_fd = open(ready, O_CREAT | O_EXCL | O_WRONLY, 0600);
    if (ready_fd < 0 || close(ready_fd) != 0) fail("create durability marker");
    for (;;) pause();
}

static void sync_parent(const char *path) {
    char parent[4096];
    size_t length = strlen(path);
    if (length >= sizeof(parent)) {
        errno = ENAMETOOLONG;
        fail("durability parent path");
    }
    memcpy(parent, path, length + 1);
    char *slash = strrchr(parent, '/');
    if (slash == NULL) strcpy(parent, ".");
    else if (slash == parent) slash[1] = '\0';
    else *slash = '\0';
    int fd = open(parent, O_RDONLY | O_DIRECTORY);
    if (fd < 0 || fsync(fd) != 0 || close(fd) != 0) fail("sync durability parent");
}

static void prepare_fsync(const char *path, const char *ready) {
    int fd = open(path, O_CREAT | O_EXCL | O_RDWR, 0644);
    if (fd < 0) fail("open durability file");
    if (ftruncate(fd, 8192) != 0) fail("truncate durability file");
    if (pwrite(fd, written, sizeof(written), 0) != sizeof(written)) fail("write durability file");
    char *mapping = mmap(NULL, 8192, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (mapping == MAP_FAILED) fail("mmap durability file");
    memcpy(mapping + 4096, mapped, sizeof(mapped));
    if (msync(mapping + 4096, 4096, MS_SYNC) != 0) fail("msync durability file");
    if (fsync(fd) != 0) fail("fsync durability file");
    ready_and_pause(ready);
}

static void verify_fsync(const char *path) {
    int fd = open(path, O_RDONLY);
    if (fd < 0) fail("reopen durability file");
    char actual_written[sizeof(written)];
    char actual_mapped[sizeof(mapped)];
    if (pread(fd, actual_written, sizeof(actual_written), 0) != sizeof(actual_written) ||
        pread(fd, actual_mapped, sizeof(actual_mapped), 4096) != sizeof(actual_mapped) ||
        memcmp(actual_written, written, sizeof(written)) != 0 ||
        memcmp(actual_mapped, mapped, sizeof(mapped)) != 0) {
        fprintf(stderr, "durability data mismatch\n");
        exit(1);
    }
    if (close(fd) != 0) fail("close durability file");
}

static void prepare_fdatasync(const char *path, const char *ready) {
    int fd = open(path, O_CREAT | O_EXCL | O_RDWR, 0644);
    if (fd < 0 || ftruncate(fd, 4096) != 0 || fsync(fd) != 0) fail("create fdatasync file");
    sync_parent(path);
    if (pwrite(fd, data_synced, sizeof(data_synced), 0) != sizeof(data_synced))
        fail("write fdatasync file");
    if (fdatasync(fd) != 0) fail("fdatasync durability file");
    ready_and_pause(ready);
}

static void verify_fdatasync(const char *path) {
    int fd = open(path, O_RDONLY);
    char actual[sizeof(data_synced)];
    if (fd < 0 || pread(fd, actual, sizeof(actual), 0) != sizeof(actual) ||
        memcmp(actual, data_synced, sizeof(data_synced)) != 0) {
        errno = EPROTO;
        fail("verify fdatasync file");
    }
    if (close(fd) != 0) fail("close fdatasync file");
}

static void prepare_directory(const char *path, const char *ready) {
    if (mkdir(path, 0755) != 0) fail("create durability directory");
    sync_parent(path);
    char entry[4096];
    if (snprintf(entry, sizeof(entry), "%s/entry", path) >= (int)sizeof(entry)) {
        errno = ENAMETOOLONG;
        fail("durability entry path");
    }
    int entry_fd = open(entry, O_CREAT | O_EXCL | O_RDWR, 0644);
    int directory_fd = open(path, O_RDONLY | O_DIRECTORY);
    if (entry_fd < 0 || directory_fd < 0 || fsync(directory_fd) != 0)
        fail("sync durability directory");
    ready_and_pause(ready);
}

static void verify_directory(const char *path) {
    char entry[4096];
    struct stat st;
    if (snprintf(entry, sizeof(entry), "%s/entry", path) >= (int)sizeof(entry) ||
        stat(entry, &st) != 0 || !S_ISREG(st.st_mode)) {
        errno = EPROTO;
        fail("verify durability directory");
    }
}

int main(int argc, char **argv) {
    if (argc == 5 && strcmp(argv[1], "prepare") == 0) {
        if (strcmp(argv[2], "fsync") == 0) prepare_fsync(argv[3], argv[4]);
        else if (strcmp(argv[2], "fdatasync") == 0) prepare_fdatasync(argv[3], argv[4]);
        else if (strcmp(argv[2], "directory") == 0) prepare_directory(argv[3], argv[4]);
        else return 2;
        return 0;
    }
    if (argc == 4 && strcmp(argv[1], "verify") == 0) {
        if (strcmp(argv[2], "fsync") == 0) verify_fsync(argv[3]);
        else if (strcmp(argv[2], "fdatasync") == 0) verify_fdatasync(argv[3]);
        else if (strcmp(argv[2], "directory") == 0) verify_directory(argv[3]);
        else return 2;
        return 0;
    }
    fprintf(stderr, "usage: durability-probe prepare MODE PATH READY | verify MODE PATH\n");
    return 2;
}
