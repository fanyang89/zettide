#define _GNU_SOURCE
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/statvfs.h>
#include <sys/syscall.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

static void fail(const char *message) {
    perror(message);
    exit(1);
}

static void make_path(char *out, size_t size, const char *root, const char *name) {
    if (snprintf(out, size, "%s/%s", root, name) >= (int)size) {
        errno = ENAMETOOLONG;
        fail("path");
    }
}

static void write_all(int fd, const void *data, size_t size) {
    const char *cursor = data;
    while (size != 0) {
        ssize_t amount = write(fd, cursor, size);
        if (amount < 0) fail("write");
        cursor += amount;
        size -= (size_t)amount;
    }
}

static void expect_contents(const char *path, const char *expected) {
    char buffer[256] = {0};
    int fd = open(path, O_RDONLY);
    if (fd < 0) fail("open expected contents");
    ssize_t amount = read(fd, buffer, sizeof(buffer) - 1);
    if (amount < 0) fail("read expected contents");
    if (close(fd) != 0) fail("close expected contents");
    if ((size_t)amount != strlen(expected) || memcmp(buffer, expected, (size_t)amount) != 0) {
        fprintf(stderr, "unexpected contents for %s\n", path);
        exit(1);
    }
}

static void test_unlink_open(const char *root) {
    char path[4096];
    make_path(path, sizeof(path), root, "open-unlink");
    int old_fd = open(path, O_CREAT | O_EXCL | O_RDWR, 0644);
    if (old_fd < 0) fail("create open-unlink");
    write_all(old_fd, "old", 3);
    if (fsync(old_fd) != 0) fail("fsync old");
    if (unlink(path) != 0) fail("unlink open file");

    struct stat st;
    if (fstat(old_fd, &st) != 0) fail("fstat unlinked file");
    if (st.st_size != 3 || st.st_nlink != 0) {
        fprintf(stderr, "wrong unlinked stat\n");
        exit(1);
    }
    if (lseek(old_fd, 0, SEEK_SET) != 0) fail("seek old");
    char old_data[3];
    if (read(old_fd, old_data, sizeof(old_data)) != 3 || memcmp(old_data, "old", 3) != 0) {
        fprintf(stderr, "unlinked descriptor lost data\n");
        exit(1);
    }

    int new_fd = open(path, O_CREAT | O_EXCL | O_RDWR, 0644);
    if (new_fd < 0) fail("replace unlinked path");
    write_all(new_fd, "new", 3);
    if (fsync(new_fd) != 0) fail("fsync new");
    if (close(new_fd) != 0) fail("close new");
    if (close(old_fd) != 0) fail("close old");
    expect_contents(path, "new");
}

static void test_unlink_opath(const char *root) {
    char path[4096];
    make_path(path, sizeof(path), root, "opath-unlink");
    int fd = open(path, O_CREAT | O_EXCL | O_WRONLY, 0644);
    if (fd < 0) fail("create O_PATH file");
    write_all(fd, "path", 4);
    if (close(fd) != 0) fail("close O_PATH file");

    int path_fd = open(path, O_PATH);
    if (path_fd < 0) fail("open O_PATH file");
    if (unlink(path) != 0) fail("unlink O_PATH file");
    struct stat st;
    if (fstat(path_fd, &st) != 0) fail("fstat unlinked O_PATH file");
    if (st.st_size != 4 || st.st_nlink != 0) {
        fprintf(stderr, "wrong unlinked O_PATH stat\n");
        exit(1);
    }
    if (close(path_fd) != 0) fail("close O_PATH file reference");
}

static void test_unlinked_directories(const char *root) {
    char source[4096], target[4096];
    make_path(source, sizeof(source), root, "removed-open-directory");
    if (mkdir(source, 0755) != 0) fail("mkdir removed open directory");
    int directory_fd = open(source, O_RDONLY | O_DIRECTORY);
    if (directory_fd < 0) fail("open removed directory");
    if (rmdir(source) != 0) fail("rmdir open directory");
    struct stat st;
    if (fstat(directory_fd, &st) != 0) fail("fstat removed directory");
    if (st.st_nlink != 0) {
        fprintf(stderr, "removed directory retained links\n");
        exit(1);
    }
    if (close(directory_fd) != 0) fail("close removed directory");

    make_path(source, sizeof(source), root, "rename-directory-source");
    make_path(target, sizeof(target), root, "rename-directory-victim");
    if (mkdir(source, 0755) != 0 || mkdir(target, 0755) != 0) fail("mkdir rename directories");
    directory_fd = open(target, O_RDONLY | O_DIRECTORY);
    if (directory_fd < 0) fail("open rename directory victim");
    if (rename(source, target) != 0) fail("rename over open directory");
    if (fstat(directory_fd, &st) != 0) fail("fstat renamed directory victim");
    if (st.st_nlink != 0) {
        fprintf(stderr, "renamed directory victim retained links\n");
        exit(1);
    }
    if (close(directory_fd) != 0) fail("close renamed directory victim");
    if (rmdir(target) != 0) fail("remove renamed directory");
}

static void test_rename_open(const char *root) {
    char source[4096], target[4096];
    make_path(source, sizeof(source), root, "rename-source");
    make_path(target, sizeof(target), root, "rename-target");
    int source_fd = open(source, O_CREAT | O_EXCL | O_RDWR, 0644);
    int target_fd = open(target, O_CREAT | O_EXCL | O_RDWR, 0644);
    if (source_fd < 0 || target_fd < 0) fail("create rename files");
    write_all(source_fd, "source", 6);
    write_all(target_fd, "target", 6);
    if (fsync(source_fd) != 0 || fsync(target_fd) != 0) fail("fsync rename files");
    if (rename(source, target) != 0) fail("rename over open target");
    expect_contents(target, "source");
    if (lseek(target_fd, 0, SEEK_SET) != 0) fail("seek old target");
    char data[6];
    if (read(target_fd, data, sizeof(data)) != 6 || memcmp(data, "target", 6) != 0) {
        fprintf(stderr, "overwritten target descriptor changed identity\n");
        exit(1);
    }
    if (close(source_fd) != 0) fail("close renamed source descriptor");
    if (close(target_fd) != 0) fail("close overwritten target descriptor");
}

static void append_worker(const char *path, char tag) {
    int fd = open(path, O_CREAT | O_WRONLY | O_APPEND, 0644);
    if (fd < 0) fail("open append");
    char record[32];
    memset(record, tag, sizeof(record));
    record[sizeof(record) - 1] = '\n';
    for (int i = 0; i < 100; ++i) write_all(fd, record, sizeof(record));
    if (fsync(fd) != 0) fail("fsync append");
    if (close(fd) != 0) fail("close append");
    _exit(0);
}

static void test_append(const char *root) {
    char path[4096];
    make_path(path, sizeof(path), root, "append-records");
    pid_t first = fork();
    if (first < 0) fail("fork first");
    if (first == 0) append_worker(path, 'A');
    pid_t second = fork();
    if (second < 0) fail("fork second");
    if (second == 0) append_worker(path, 'B');
    int status;
    if (waitpid(first, &status, 0) < 0 || !WIFEXITED(status) || WEXITSTATUS(status) != 0) fail("first append worker");
    if (waitpid(second, &status, 0) < 0 || !WIFEXITED(status) || WEXITSTATUS(status) != 0) fail("second append worker");

    int fd = open(path, O_RDONLY);
    if (fd < 0) fail("open appended output");
    char record[32];
    int counts[2] = {0, 0};
    for (;;) {
        ssize_t amount = read(fd, record, sizeof(record));
        if (amount < 0) fail("read append record");
        if (amount == 0) break;
        if (amount != sizeof(record) || record[31] != '\n') {
            fprintf(stderr, "torn append record\n");
            exit(1);
        }
        char tag = record[0];
        if (tag != 'A' && tag != 'B') {
            fprintf(stderr, "invalid append tag\n");
            exit(1);
        }
        for (int i = 0; i < 31; ++i) {
            if (record[i] != tag) {
                fprintf(stderr, "interleaved append record\n");
                exit(1);
            }
        }
        counts[tag == 'A' ? 0 : 1]++;
    }
    if (close(fd) != 0) fail("close appended output");
    if (counts[0] != 100 || counts[1] != 100) {
        fprintf(stderr, "lost append records: %d %d\n", counts[0], counts[1]);
        exit(1);
    }
}

static void test_truncate(const char *root) {
    char path[4096];
    make_path(path, sizeof(path), root, "truncate");
    int fd = open(path, O_CREAT | O_EXCL | O_RDWR, 0644);
    if (fd < 0) fail("create truncate");
    write_all(fd, "abcdef", 6);
    if (ftruncate(fd, 3) != 0) fail("shrink truncate");
    if (ftruncate(fd, 4097) != 0) fail("extend truncate");
    char zero[64];
    ssize_t amount = pread(fd, zero, sizeof(zero), 3);
    if (amount < 0) fail("read truncate extension");
    if (amount != sizeof(zero)) {
        fprintf(stderr, "short truncate extension read: %zd\n", amount);
        exit(1);
    }
    for (size_t i = 0; i < sizeof(zero); ++i) {
        if (zero[i] != 0) {
            fprintf(stderr, "truncate extension is not zero-filled\n");
            exit(1);
        }
    }
    if (fsync(fd) != 0 || close(fd) != 0) fail("sync truncate");
}

static void test_large_sparse(const char *root) {
    char path[PATH_MAX];
    make_path(path, sizeof(path), root, "large-sparse");
    int fd = open(path, O_CREAT | O_RDWR | O_EXCL, 0644);
    if (fd < 0) fail("create large sparse");

    const off_t distant = (off_t)4 * 1024 * 1024 * 1024 + 123;
    if (pwrite(fd, "right", 5, distant) != 5) fail("large sparse pwrite");
    struct stat st;
    if (fstat(fd, &st) != 0) fail("large sparse fstat");
    if (st.st_size != distant + 5) {
        fprintf(stderr, "wrong large sparse size: %lld\n", (long long)st.st_size);
        exit(1);
    }
    if (st.st_blocks > 4096) {
        fprintf(stderr, "large sparse hole was allocated: %lld blocks\n", (long long)st.st_blocks);
        exit(1);
    }

    unsigned char boundary[8];
    const unsigned char expected[8] = {0, 0, 0, 'r', 'i', 'g', 'h', 't'};
    if (pread(fd, boundary, sizeof(boundary), distant - 3) != (ssize_t)sizeof(boundary))
        fail("large sparse pread");
    if (memcmp(boundary, expected, sizeof(expected)) != 0) {
        fprintf(stderr, "large sparse boundary mismatch\n");
        exit(1);
    }

    const off_t huge = (off_t)8 * 1024 * 1024 * 1024 * 1024;
    if (ftruncate(fd, huge) != 0) fail("large sparse grow");
    if (fstat(fd, &st) != 0 || st.st_size != huge) fail("large sparse grown size");
    if (st.st_blocks > 4096) {
        fprintf(stderr, "large truncate allocated its hole\n");
        exit(1);
    }

    if (ftruncate(fd, distant + 2) != 0) fail("large sparse shrink");
    if (ftruncate(fd, distant + 5) != 0) fail("large sparse regrow");
    unsigned char regrown[5];
    const unsigned char expected_regrown[5] = {'r', 'i', 0, 0, 0};
    if (pread(fd, regrown, sizeof(regrown), distant) != (ssize_t)sizeof(regrown))
        fail("large sparse regrown pread");
    if (memcmp(regrown, expected_regrown, sizeof(expected_regrown)) != 0) {
        fprintf(stderr, "truncated data reappeared after sparse regrow\n");
        exit(1);
    }
    if (fsync(fd) != 0 || close(fd) != 0) fail("sync large sparse");
}

static void test_rename_noreplace(const char *root) {
    char source[4096], target[4096];
    make_path(source, sizeof(source), root, "noreplace-source");
    make_path(target, sizeof(target), root, "noreplace-target");
    int source_fd = open(source, O_CREAT | O_EXCL | O_WRONLY, 0644);
    int target_fd = open(target, O_CREAT | O_EXCL | O_WRONLY, 0644);
    if (source_fd < 0 || target_fd < 0) fail("create noreplace files");
    write_all(source_fd, "source", 6);
    write_all(target_fd, "target", 6);
    if (close(source_fd) != 0 || close(target_fd) != 0) fail("close noreplace files");
    errno = 0;
    if (syscall(SYS_renameat2, AT_FDCWD, source, AT_FDCWD, target, RENAME_NOREPLACE) != -1 || errno != EEXIST) {
        fprintf(stderr, "RENAME_NOREPLACE did not return EEXIST\n");
        exit(1);
    }
    expect_contents(source, "source");
    expect_contents(target, "target");
}

static void test_directory_iteration(const char *root) {
    char directory[4096], path[4096];
    make_path(directory, sizeof(directory), root, "many-entries");
    if (mkdir(directory, 0755) != 0) fail("create many-entries");
    for (int i = 0; i < 300; ++i) {
        char name[32];
        snprintf(name, sizeof(name), "entry-%03d", i);
        make_path(path, sizeof(path), directory, name);
        int fd = open(path, O_CREAT | O_EXCL | O_WRONLY, 0644);
        if (fd < 0 || close(fd) != 0) fail("create directory entry");
    }
    DIR *stream = opendir(directory);
    if (stream == NULL) fail("opendir many-entries");
    int count = 0;
    struct dirent *entry;
    while ((entry = readdir(stream)) != NULL) {
        if (strcmp(entry->d_name, ".") != 0 && strcmp(entry->d_name, "..") != 0) count++;
    }
    if (closedir(stream) != 0) fail("closedir many-entries");
    if (count != 300) {
        fprintf(stderr, "readdir returned %d of 300 entries\n", count);
        exit(1);
    }
}

static void test_statfs_and_hardlink(const char *root) {
    struct statvfs stats;
    if (statvfs(root, &stats) != 0) fail("statvfs");
    if (stats.f_bsize == 0 || stats.f_blocks == 0 || stats.f_bfree > stats.f_blocks || stats.f_namemax != 255) {
        fprintf(stderr, "invalid statvfs result\n");
        exit(1);
    }
    char source[4096], target[4096];
    make_path(source, sizeof(source), root, "hello.txt");
    make_path(target, sizeof(target), root, "supported-hardlink");
    if (link(source, target) != 0) fail("hard link");
    struct stat source_stat, target_stat;
    if (stat(source, &source_stat) != 0 || stat(target, &target_stat) != 0) fail("stat hard links");
    if (source_stat.st_ino != target_stat.st_ino || source_stat.st_nlink != 2 || target_stat.st_nlink != 2) {
        fprintf(stderr, "hard links do not share identity and link count\n");
        exit(1);
    }
    if (unlink(target) != 0) fail("unlink hard link");
}

static void test_timestamps(const char *root) {
    char path[4096];
    make_path(path, sizeof(path), root, "timestamp");
    int fd = open(path, O_CREAT | O_EXCL | O_RDWR, 0644);
    if (fd < 0) fail("create timestamp");
    write_all(fd, "x", 1);
    if (close(fd) != 0) fail("close timestamp");

    struct timespec times[2] = {
        {.tv_sec = 1000000000, .tv_nsec = 123},
        {.tv_sec = 1000001000, .tv_nsec = 456},
    };
    if (utimensat(AT_FDCWD, path, times, 0) != 0) fail("set timestamp baseline");
    fd = open(path, O_RDONLY);
    if (fd < 0) fail("open timestamp read");
    char byte;
    if (read(fd, &byte, 1) != 1 || close(fd) != 0) fail("read timestamp");
    struct stat after_read;
    if (stat(path, &after_read) != 0) fail("stat timestamp after read");
    if (after_read.st_atim.tv_sec < times[1].tv_sec) {
        fprintf(stderr, "relatime did not advance atime after read\n");
        exit(1);
    }

    struct timespec omit[2] = {
        {.tv_sec = 0, .tv_nsec = UTIME_OMIT},
        {.tv_sec = 0, .tv_nsec = UTIME_OMIT},
    };
    struct stat before_omit, after_omit;
    if (stat(path, &before_omit) != 0) fail("stat before UTIME_OMIT");
    if (utimensat(AT_FDCWD, path, omit, 0) != 0) fail("UTIME_OMIT");
    if (stat(path, &after_omit) != 0) fail("stat after UTIME_OMIT");
    if (before_omit.st_atim.tv_sec != after_omit.st_atim.tv_sec ||
        before_omit.st_atim.tv_nsec != after_omit.st_atim.tv_nsec ||
        before_omit.st_mtim.tv_sec != after_omit.st_mtim.tv_sec ||
        before_omit.st_mtim.tv_nsec != after_omit.st_mtim.tv_nsec ||
        before_omit.st_ctim.tv_sec != after_omit.st_ctim.tv_sec ||
        before_omit.st_ctim.tv_nsec != after_omit.st_ctim.tv_nsec) {
        fprintf(stderr, "UTIME_OMIT changed timestamps\n");
        exit(1);
    }
}

static void test_permissions(const char *root) {
    char path[4096];
    make_path(path, sizeof(path), root, "umask-file");
    mode_t previous = umask(0027);
    int fd = open(path, O_CREAT | O_EXCL | O_WRONLY, 0666);
    umask(previous);
    if (fd < 0 || close(fd) != 0) fail("create umask file");
    struct stat st;
    if (stat(path, &st) != 0) fail("stat umask file");
    if ((st.st_mode & 0777) != 0640) {
        fprintf(stderr, "umask was not applied: %o\n", st.st_mode & 0777);
        exit(1);
    }

    if (geteuid() != 0) {
        if (chmod(path, 0000) != 0) fail("chmod denied file");
        errno = 0;
        fd = open(path, O_RDONLY);
        if (fd != -1 || errno != EACCES) {
            fprintf(stderr, "mode 000 file did not deny open\n");
            exit(1);
        }
    }
}

static void test_chown_sentinels(const char *root) {
    char path[4096];
    make_path(path, sizeof(path), root, "chown-sentinels");
    int fd = open(path, O_CREAT | O_EXCL | O_RDWR, 0644);
    if (fd < 0) fail("create chown sentinel file");
    struct stat before, after;
    if (fstat(fd, &before) != 0) fail("stat before chown sentinels");
    if (fchown(fd, (uid_t)-1, getegid()) != 0) fail("fchown uid sentinel");
    if (fstat(fd, &after) != 0) fail("stat after uid sentinel");
    if (after.st_uid != before.st_uid || after.st_gid != getegid()) {
        fprintf(stderr, "uid sentinel changed the wrong ownership field\n");
        exit(1);
    }
    if (fchown(fd, geteuid(), (gid_t)-1) == 0) {
        if (fstat(fd, &after) != 0) fail("stat after gid sentinel");
        if (after.st_uid != geteuid() || after.st_gid != getegid()) {
            fprintf(stderr, "gid sentinel changed the wrong ownership field\n");
            exit(1);
        }
    } else if (errno != EPERM) {
        fail("fchown gid sentinel");
    }
    if (close(fd) != 0) fail("close chown sentinel file");
}

static void test_setgid_inheritance(const char *root) {
    char parent[4096], regular[4096], directory[4096], link[4096], fifo[4096];
    make_path(parent, sizeof(parent), root, "setgid-parent");
    make_path(regular, sizeof(regular), parent, "regular");
    make_path(directory, sizeof(directory), parent, "directory");
    make_path(link, sizeof(link), parent, "link");
    make_path(fifo, sizeof(fifo), parent, "fifo");
    if (mkdir(parent, 0775) != 0) fail("mkdir setgid parent");

    gid_t inherited_gid = getegid();
    int group_count = getgroups(0, NULL);
    if (group_count < 0) fail("count supplementary groups");
    if (group_count != 0) {
        gid_t *groups = calloc((size_t)group_count, sizeof(*groups));
        if (groups == NULL) fail("allocate supplementary groups");
        if (getgroups(group_count, groups) != group_count) fail("read supplementary groups");
        for (int i = 0; i < group_count; ++i) {
            if (groups[i] != getegid()) {
                inherited_gid = groups[i];
                break;
            }
        }
        free(groups);
    }
    if (chown(parent, (uid_t)-1, inherited_gid) != 0) fail("chgrp setgid parent");
    if (chmod(parent, 02775) != 0) fail("chmod setgid parent");

    int fd = open(regular, O_CREAT | O_EXCL | O_WRONLY, 0664);
    if (fd < 0 || close(fd) != 0) fail("create setgid regular child");
    if (mkdir(directory, 0755) != 0) fail("create setgid directory child");
    if (symlink("regular", link) != 0) fail("create setgid symlink child");
    if (mkfifo(fifo, 0660) != 0) fail("create setgid FIFO child");

    struct stat st;
    if (stat(regular, &st) != 0 || st.st_gid != inherited_gid || (st.st_mode & S_ISGID) != 0) {
        fprintf(stderr, "regular child did not inherit only the parent gid\n");
        exit(1);
    }
    if (stat(directory, &st) != 0 || st.st_gid != inherited_gid || (st.st_mode & S_ISGID) == 0) {
        fprintf(stderr, "directory child did not inherit gid and setgid\n");
        exit(1);
    }
    if (lstat(link, &st) != 0 || st.st_gid != inherited_gid || (st.st_mode & S_ISGID) != 0) {
        fprintf(stderr, "symlink child did not inherit only the parent gid\n");
        exit(1);
    }
    if (stat(fifo, &st) != 0 || st.st_gid != inherited_gid || (st.st_mode & S_ISGID) != 0) {
        fprintf(stderr, "FIFO child did not inherit only the parent gid\n");
        exit(1);
    }
}

int main(int argc, char **argv) {
    if (argc != 2) {
        fprintf(stderr, "usage: fs-probe MOUNTPOINT\n");
        return 2;
    }
    test_unlink_open(argv[1]);
    test_unlink_opath(argv[1]);
    test_unlinked_directories(argv[1]);
    test_rename_open(argv[1]);
    test_append(argv[1]);
    test_truncate(argv[1]);
    test_large_sparse(argv[1]);
    test_rename_noreplace(argv[1]);
    test_directory_iteration(argv[1]);
    test_statfs_and_hardlink(argv[1]);
    test_timestamps(argv[1]);
    test_permissions(argv[1]);
    test_chown_sentinels(argv[1]);
    test_setgid_inheritance(argv[1]);
    return 0;
}
