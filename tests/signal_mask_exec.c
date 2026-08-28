#define _POSIX_C_SOURCE 200809L

#include <signal.h>
#include <unistd.h>

int main(int argc, char **argv) {
    sigset_t set;

    if (argc < 2 || sigemptyset(&set) != 0 ||
        sigaddset(&set, SIGINT) != 0 || sigaddset(&set, SIGTERM) != 0 ||
        sigprocmask(SIG_BLOCK, &set, NULL) != 0)
        return 2;
    execv(argv[1], &argv[1]);
    return 3;
}
