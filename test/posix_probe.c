#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

static const char *root;

static void path(char *buffer, size_t size, const char *name) {
    if (snprintf(buffer, size, "%s/%s", root, name) >= (int)size) abort();
}

static int hard_links(void) {
    char first[4096], second[4096];
    path(first, sizeof(first), "posix-link-a");
    path(second, sizeof(second), "posix-link-b");
    int fd = open(first, O_CREAT | O_EXCL | O_RDWR, 0600);
    if (fd < 0 || write(fd, "data", 4) != 4 || close(fd) != 0) return -1;
    if (link(first, second) != 0) return -1;
    struct stat a, b;
    if (stat(first, &a) != 0 || stat(second, &b) != 0) return -1;
    if (a.st_dev != b.st_dev || a.st_ino != b.st_ino || a.st_nlink != 2 || b.st_nlink != 2) {
        errno = EPROTO;
        return -1;
    }
    if (rename(first, second) != 0 || stat(first, &a) != 0 || stat(second, &b) != 0 ||
        a.st_nlink != 2 || b.st_nlink != 2) {
        errno = EPROTO;
        return -1;
    }
    fd = open(first, O_RDONLY);
    if (fd < 0 || unlink(first) != 0 || fstat(fd, &a) != 0 || a.st_nlink != 1 ||
        unlink(second) != 0 || fstat(fd, &a) != 0 || a.st_nlink != 0 || close(fd) != 0) {
        errno = EPROTO;
        return -1;
    }
    path(first, sizeof(first), "posix-link-directory");
    struct stat root_before, root_after;
    if (stat(root, &root_before) != 0) return -1;
    if (mkdir(first, 0700) != 0) return -1;
    errno = 0;
    if (link(first, second) != -1 || errno != EPERM || stat(root, &root_after) != 0 ||
        root_after.st_nlink != root_before.st_nlink + 1) {
        errno = EPROTO;
        return -1;
    }
    if (rename(first, first) != 0) return -1;
    path(second, sizeof(second), "posix-link-directory/child");
    if (mkdir(second, 0700) != 0 || stat(first, &a) != 0 || a.st_nlink != 3 ||
        rmdir(second) != 0 || stat(first, &a) != 0 || a.st_nlink != 2 || rmdir(first) != 0)
        return -1;
    return 0;
}

static int fifo_nodes(void) {
    char name[4096];
    path(name, sizeof(name), "posix-fifo");
    if (mkfifo(name, 0600) != 0) return -1;
    struct stat st;
    if (lstat(name, &st) != 0 || !S_ISFIFO(st.st_mode)) {
        errno = EPROTO;
        return -1;
    }
    int reader = open(name, O_RDONLY | O_NONBLOCK);
    int writer = open(name, O_WRONLY | O_NONBLOCK);
    if (reader < 0 || writer < 0) return -1;
    char actual[4];
    if (write(writer, "fifo", 4) != 4 || read(reader, actual, 4) != 4 || memcmp(actual, "fifo", 4) != 0) {
        errno = EPROTO;
        return -1;
    }
    if (close(writer) != 0 || close(reader) != 0) return -1;
    return 0;
}

static int shared_mmap(void) {
    char name[4096];
    path(name, sizeof(name), "posix-mmap");
    int fd = open(name, O_CREAT | O_EXCL | O_RDWR, 0600);
    if (fd < 0 || ftruncate(fd, 4096) != 0) return -1;
    char *mapping = mmap(NULL, 4096, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (mapping == MAP_FAILED) return -1;
    memcpy(mapping, "mapped", 6);
    if (msync(mapping, 4096, MS_SYNC) != 0) return -1;
    char actual[6];
    if (pread(fd, actual, sizeof(actual), 0) != sizeof(actual) || memcmp(actual, "mapped", 6) != 0) {
        errno = EPROTO;
        return -1;
    }
    if (munmap(mapping, 4096) != 0 || close(fd) != 0) return -1;
    return 0;
}

static int record_locks(void) {
    char name[4096];
    path(name, sizeof(name), "posix-lock");
    int fd = open(name, O_CREAT | O_EXCL | O_RDWR, 0600);
    if (fd < 0) return -1;
    struct flock lock = {.l_type = F_WRLCK, .l_whence = SEEK_SET, .l_start = 0, .l_len = 1};
    if (fcntl(fd, F_SETLK, &lock) != 0) return -1;
    pid_t child = fork();
    if (child < 0) return -1;
    if (child == 0) {
        int child_fd = open(name, O_RDWR);
        if (child_fd < 0) _exit(2);
        struct flock child_lock = {.l_type = F_WRLCK, .l_whence = SEEK_SET, .l_start = 0, .l_len = 1};
        int result = fcntl(child_fd, F_SETLK, &child_lock);
        _exit(result == -1 && (errno == EACCES || errno == EAGAIN) ? 0 : 3);
    }
    int status;
    if (waitpid(child, &status, 0) != child || !WIFEXITED(status) || WEXITSTATUS(status) != 0) {
        errno = EPROTO;
        return -1;
    }
    lock.l_type = F_UNLCK;
    if (fcntl(fd, F_SETLK, &lock) != 0 || close(fd) != 0) return -1;
    return 0;
}

static int dynamic_append(void) {
    char name[4096];
    path(name, sizeof(name), "posix-append-flags");
    int fd = open(name, O_CREAT | O_EXCL | O_RDWR | O_APPEND, 0600);
    if (fd < 0 || write(fd, "a", 1) != 1) return -1;
    int flags = fcntl(fd, F_GETFL);
    if (flags < 0 || fcntl(fd, F_SETFL, flags & ~O_APPEND) != 0) return -1;
    if (lseek(fd, 0, SEEK_SET) != 0 || write(fd, "b", 1) != 1) return -1;
    char actual[2] = {0};
    if (pread(fd, actual, sizeof(actual), 0) != 1 || actual[0] != 'b') {
        errno = EPROTO;
        return -1;
    }
    if (close(fd) != 0) return -1;
    return 0;
}

static int run(const char *name, int (*test)(void)) {
    errno = 0;
    if (test() == 0) {
        printf("PASS %s\n", name);
        return 0;
    }
    printf("FAIL %s: %s\n", name, strerror(errno));
    return 1;
}

int main(int argc, char **argv) {
    if (argc != 2) return 2;
    root = argv[1];
    int failures = 0;
    failures += run("hard-links", hard_links);
    failures += run("fifo", fifo_nodes);
    failures += run("shared-mmap", shared_mmap);
    failures += run("record-locks", record_locks);
    failures += run("dynamic-append", dynamic_append);
    return failures == 0 ? 0 : 1;
}
