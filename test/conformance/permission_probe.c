#include <errno.h>
#include <fcntl.h>
#include <grp.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

enum {
    test_uid = 65534,
    other_uid = 65533,
    test_gid = 65534,
    other_gid = 65533,
};

static const char *test_root;
static char first_path[4096];
static char second_path[4096];
static char third_path[4096];

static int make_path(char *buffer, size_t size, const char *name) {
    int length = snprintf(buffer, size, "%s/%s", test_root, name);
    if (length < 0 || (size_t)length >= size) {
        errno = ENAMETOOLONG;
        return -1;
    }
    return 0;
}

static int create_file(const char *path, mode_t mode) {
    int fd = open(path, O_CREAT | O_EXCL | O_WRONLY, mode);
    if (fd < 0) return -1;
    return close(fd);
}

static int child_failure(const char *operation) {
    dprintf(STDERR_FILENO, "%s failed: %s\n", operation, strerror(errno));
    return -1;
}

static int wait_for_child(pid_t child) {
    int status;
    if (waitpid(child, &status, 0) != child) return -1;
    if (!WIFEXITED(status) || WEXITSTATUS(status) != 0) {
        errno = EPROTO;
        return -1;
    }
    return 0;
}

static int run_unprivileged(int (*operation)(void)) {
    pid_t child = fork();
    if (child < 0) return -1;
    if (child == 0) {
        if (setgroups(0, NULL) != 0 || setresgid(test_gid, test_gid, test_gid) != 0 ||
            setresuid(test_uid, test_uid, test_uid) != 0) {
            dprintf(STDERR_FILENO, "identity switch failed: %s\n", strerror(errno));
            _exit(125);
        }
        _exit(operation() == 0 ? 0 : 1);
    }
    return wait_for_child(child);
}

static int expect_permission_denied(int result) {
    return result == -1 && (errno == EACCES || errno == EPERM) ? 0 : -1;
}

static int sticky_child(void) {
    if (create_file(third_path, 0600) != 0 || unlink(third_path) != 0)
        return child_failure("sticky-directory control create/unlink");
    if (expect_permission_denied(unlink(first_path)) != 0)
        return child_failure("sticky-directory unauthorized unlink expectation");
    if (expect_permission_denied(rename(second_path, first_path)) != 0)
        return child_failure("sticky-directory unauthorized rename expectation");
    return 0;
}

static int sticky_directory_protection(void) {
    char directory[4096];
    if (make_path(directory, sizeof(directory), "sticky") != 0 || mkdir(directory, 01777) != 0 ||
        chown(directory, other_uid, other_gid) != 0 || chmod(directory, 01777) != 0)
        return -1;
    if (snprintf(first_path, sizeof(first_path), "%s/victim", directory) >= (int)sizeof(first_path) ||
        snprintf(second_path, sizeof(second_path), "%s/source", directory) >= (int)sizeof(second_path) ||
        snprintf(third_path, sizeof(third_path), "%s/control", directory) >= (int)sizeof(third_path)) {
        errno = ENAMETOOLONG;
        return -1;
    }
    if (create_file(first_path, 0644) != 0 || create_file(second_path, 0644) != 0 ||
        chown(first_path, other_uid, other_gid) != 0 || chown(second_path, other_uid, other_gid) != 0)
        return -1;
    return run_unprivileged(sticky_child);
}

static int ownership_child(void) {
    errno = 0;
    if (chown(first_path, other_uid, test_gid) != -1 || errno != EPERM)
        return child_failure("unauthorized chown expectation");
    errno = 0;
    if (chown(first_path, (uid_t)-1, other_gid) != -1 || errno != EPERM)
        return child_failure("unauthorized chgrp expectation");
    return 0;
}

static int unauthorized_ownership_changes(void) {
    if (make_path(first_path, sizeof(first_path), "ownership") != 0 || create_file(first_path, 0600) != 0 ||
        chown(first_path, test_uid, test_gid) != 0)
        return -1;
    return run_unprivileged(ownership_child);
}

static int setid_child(void) {
    int fd = open(first_path, O_WRONLY);
    if (fd < 0) return child_failure("set-id write open");
    int result = write(fd, "x", 1) == 1 && close(fd) == 0 ? 0 : -1;
    if (result != 0) return child_failure("set-id write");
    return result;
}

static int setid_clearing(void) {
    struct stat status;
    if (make_path(first_path, sizeof(first_path), "setid") != 0 || create_file(first_path, 0777) != 0 ||
        chown(first_path, other_uid, other_gid) != 0 || chmod(first_path, 06777) != 0 ||
        run_unprivileged(setid_child) != 0 || stat(first_path, &status) != 0)
        return -1;
    if ((status.st_mode & (S_ISUID | S_ISGID)) != 0) {
        errno = EPROTO;
        return -1;
    }
    return 0;
}

static int inheritance_child(void) {
    if (create_file(first_path, 0666) != 0 || mkdir(second_path, 0777) != 0)
        return child_failure("setgid inheritance create");
    return 0;
}

static int setgid_inheritance(void) {
    char directory[4096];
    struct stat file_status, directory_status;
    if (make_path(directory, sizeof(directory), "setgid-directory") != 0 || mkdir(directory, 0777) != 0 ||
        chown(directory, 0, other_gid) != 0 || chmod(directory, 02777) != 0)
        return -1;
    if (snprintf(first_path, sizeof(first_path), "%s/file", directory) >= (int)sizeof(first_path) ||
        snprintf(second_path, sizeof(second_path), "%s/directory", directory) >= (int)sizeof(second_path)) {
        errno = ENAMETOOLONG;
        return -1;
    }
    if (run_unprivileged(inheritance_child) != 0 || stat(first_path, &file_status) != 0 ||
        stat(second_path, &directory_status) != 0)
        return -1;
    if (file_status.st_gid != other_gid || directory_status.st_gid != other_gid ||
        (directory_status.st_mode & S_ISGID) == 0) {
        errno = EPROTO;
        return -1;
    }
    return 0;
}

static int run_test(const char *name, int (*test)(void)) {
    errno = 0;
    if (test() == 0) {
        printf("PASS %s\n", name);
        return 0;
    }
    printf("FAIL %s: %s\n", name, strerror(errno));
    return 1;
}

int main(int argc, char **argv) {
    if (argc != 2 || geteuid() != 0) return 2;
    test_root = argv[1];
    int failures = 0;
    failures += run_test("sticky-directory-protection", sticky_directory_protection);
    failures += run_test("unauthorized-chown-chgrp", unauthorized_ownership_changes);
    failures += run_test("set-id-clearing", setid_clearing);
    failures += run_test("setgid-directory-inheritance", setgid_inheritance);
    return failures == 0 ? 0 : 1;
}
