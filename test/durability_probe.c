#define _GNU_SOURCE
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

static void fail(const char *message) {
    perror(message);
    exit(1);
}

static void prepare(const char *path, const char *ready) {
    int fd = open(path, O_CREAT | O_EXCL | O_RDWR, 0644);
    if (fd < 0) fail("open durability file");
    if (ftruncate(fd, 8192) != 0) fail("truncate durability file");
    if (pwrite(fd, written, sizeof(written), 0) != sizeof(written)) fail("write durability file");
    char *mapping = mmap(NULL, 8192, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (mapping == MAP_FAILED) fail("mmap durability file");
    memcpy(mapping + 4096, mapped, sizeof(mapped));
    if (msync(mapping + 4096, 4096, MS_SYNC) != 0) fail("msync durability file");
    if (fsync(fd) != 0) fail("fsync durability file");
    int ready_fd = open(ready, O_CREAT | O_EXCL | O_WRONLY, 0600);
    if (ready_fd < 0 || close(ready_fd) != 0) fail("create durability marker");
    for (;;) pause();
}

static void verify(const char *path) {
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

int main(int argc, char **argv) {
    if (argc == 4 && strcmp(argv[1], "prepare") == 0) {
        prepare(argv[2], argv[3]);
        return 0;
    }
    if (argc == 3 && strcmp(argv[1], "verify") == 0) {
        verify(argv[2]);
        return 0;
    }
    fprintf(stderr, "usage: durability-probe prepare FILE READY | verify FILE\n");
    return 2;
}
