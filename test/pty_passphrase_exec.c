#define _GNU_SOURCE

#include <ctype.h>
#include <errno.h>
#include <poll.h>
#include <pty.h>
#include <signal.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <sys/uio.h>
#include <time.h>
#include <unistd.h>

enum { output_capacity = 64 * 1024 };

static long long monotonic_milliseconds(void) {
    struct timespec now;
    if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) return -1;
    return (long long)now.tv_sec * 1000 + now.tv_nsec / 1000000;
}

static char *find_prompt(char *start, char *end) {
    static const char prompt[] = "passphrase: ";
    const size_t length = sizeof(prompt) - 1;
    for (char *position = start; position + length <= end; position++) {
        size_t index = 0;
        while (index < length && tolower((unsigned char)position[index]) == prompt[index]) index++;
        if (index == length) return position;
    }
    return NULL;
}

static int write_response(int fd, const char *response) {
    struct iovec parts[] = {
        { .iov_base = (char *)response, .iov_len = strlen(response) },
        { .iov_base = "\n", .iov_len = 1 },
    };
    const size_t expected = parts[0].iov_len + parts[1].iov_len;
    return writev(fd, parts, 2) == (ssize_t)expected ? 0 : -1;
}

int main(int argc, char **argv) {
    if (argc < 5) return 2;
    char *end = NULL;
    const long response_count_long = strtol(argv[1], &end, 10);
    if (*end != '\0' || response_count_long < 1 || response_count_long > 8) return 2;
    const size_t response_count = (size_t)response_count_long;
    const size_t command_index = 2 + response_count;
    if (command_index >= (size_t)argc || strcmp(argv[command_index], "--") != 0 ||
        command_index + 1 >= (size_t)argc) return 2;

    int master = -1;
    const pid_t child = forkpty(&master, NULL, NULL, NULL);
    if (child < 0) {
        perror("forkpty");
        return 2;
    }
    if (child == 0) {
        execvp(argv[command_index + 1], &argv[command_index + 1]);
        perror("execvp");
        _exit(127);
    }

    char output[output_capacity];
    size_t output_length = 0;
    size_t scan_offset = 0;
    size_t response_index = 0;
    bool output_overflow = false;
    bool timed_out = false;
    const long long deadline = monotonic_milliseconds() + 30000;
    while (output_length < sizeof(output)) {
        const long long remaining = deadline - monotonic_milliseconds();
        if (remaining <= 0) {
            timed_out = true;
            kill(child, SIGKILL);
            break;
        }
        struct pollfd descriptor = { .fd = master, .events = POLLIN };
        const int ready = poll(&descriptor, 1, remaining > 30000 ? 30000 : (int)remaining);
        if (ready < 0) {
            if (errno == EINTR) continue;
            perror("poll");
            kill(child, SIGKILL);
            break;
        }
        if (ready == 0) {
            fprintf(stderr, "passphrase prompt timed out\n");
            timed_out = true;
            kill(child, SIGKILL);
            break;
        }
        const ssize_t count = read(master, output + output_length, sizeof(output) - output_length);
        if (count < 0) {
            if (errno == EINTR) continue;
            if (errno == EIO) break;
            perror("read");
            kill(child, SIGKILL);
            break;
        }
        if (count == 0) break;
        output_length += (size_t)count;
        while (response_index < response_count) {
            char *prompt = find_prompt(output + scan_offset, output + output_length);
            if (prompt == NULL) break;
            scan_offset = (size_t)(prompt - output) + strlen("passphrase: ");
            if (write_response(master, argv[2 + response_index]) != 0) {
                perror("write");
                kill(child, SIGKILL);
                break;
            }
            response_index++;
        }
    }
    if (output_length == sizeof(output)) {
        output_overflow = true;
        kill(child, SIGKILL);
    }
    close(master);

    int status = 0;
    if (waitpid(child, &status, 0) < 0) {
        perror("waitpid");
        return 2;
    }
    if (write(STDOUT_FILENO, output, output_length) < 0) return 2;
    if (timed_out) return 124;
    if (output_overflow) return 2;
    if (response_index != response_count) return 2;
    for (size_t index = 0; index < response_count; index++) {
        if (memmem(output, output_length, argv[2 + index], strlen(argv[2 + index])) != NULL) {
            fprintf(stderr, "passphrase was echoed by the child terminal\n");
            return 2;
        }
    }
    if (WIFEXITED(status)) return WEXITSTATUS(status);
    if (WIFSIGNALED(status)) return 128 + WTERMSIG(status);
    return 2;
}
