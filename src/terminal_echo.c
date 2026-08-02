#define _POSIX_C_SOURCE 200809L

#include <signal.h>
#include <stdbool.h>
#include <string.h>
#include <termios.h>
#include <unistd.h>
#include <errno.h>

static const int handled_signals[] = { SIGHUP, SIGINT, SIGQUIT, SIGTERM, SIGTSTP };
static struct sigaction previous_actions[sizeof(handled_signals) / sizeof(handled_signals[0])];
static struct termios original_termios;
static struct termios hidden_termios;
static volatile sig_atomic_t active;
static int terminal_fd = -1;

int zettide_terminal_restore_echo(void);

static int set_termios(int fd, const struct termios *value) {
    int result;
    do {
        result = tcsetattr(fd, TCSANOW, value);
    } while (result != 0 && errno == EINTR);
    return result;
}

static void restore_and_exit(int signal_number) {
    if (active) (void)set_termios(terminal_fd, &original_termios);
    if (signal_number == SIGTSTP) {
        (void)kill(getpid(), SIGSTOP);
        if (active) (void)set_termios(terminal_fd, &hidden_termios);
        return;
    }
    _exit(128 + signal_number);
}

int zettide_terminal_hide_echo(int fd) {
    if (active || tcgetattr(fd, &original_termios) != 0) return -1;
    hidden_termios = original_termios;
    hidden_termios.c_lflag &= (tcflag_t)~(ECHO | ECHONL);

    struct sigaction action;
    memset(&action, 0, sizeof(action));
    action.sa_handler = restore_and_exit;
    sigemptyset(&action.sa_mask);
    for (size_t index = 0; index < sizeof(handled_signals) / sizeof(handled_signals[0]); index++) {
        if (sigaction(handled_signals[index], &action, &previous_actions[index]) != 0) {
            while (index > 0) {
                index--;
                (void)sigaction(handled_signals[index], &previous_actions[index], NULL);
            }
            return -1;
        }
    }
    terminal_fd = fd;
    active = true;
    if (set_termios(fd, &hidden_termios) == 0) return 0;
    (void)zettide_terminal_restore_echo();
    return -1;
}

int zettide_terminal_restore_echo(void) {
    if (!active) return 0;
    const int result = set_termios(terminal_fd, &original_termios);
    if (result != 0) return result;
    active = false;
    terminal_fd = -1;
    for (size_t index = 0; index < sizeof(handled_signals) / sizeof(handled_signals[0]); index++)
        (void)sigaction(handled_signals[index], &previous_actions[index], NULL);
    return result;
}
