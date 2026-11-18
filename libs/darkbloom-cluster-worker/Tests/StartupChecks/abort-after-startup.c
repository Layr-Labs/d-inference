// abort-after-startup /ABS/PATH/binary [arguments...]
//
// Starts the binary holding an exception handler for every exception type,
// with DARKBLOOM_STARTUP_HARDENING_HOLD=1 so it prints its own startup record
// and waits, then ends it with SIGABRT. Prints the record and whether any
// exception message reached the handler (destroyed unread). Exit 0 only when
// the record shows the handler reached the binary and the hardening applied
// cleanly, no message arrived and SIGABRT ended it.
#include <fcntl.h>
#include <poll.h>
#include <mach/mach.h>
#include <signal.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

extern char **environ;

int main(int argc, char **argv) {
    if (argc < 2 || argv[1][0] != '/') {
        fprintf(stderr, "usage: %s /ABS/PATH/binary [arguments...]\n", argv[0]);
        return 2;
    }
    if (setenv("DARKBLOOM_STARTUP_HARDENING_HOLD", "1", 1) != 0) return 2;
    mach_port_t port = MACH_PORT_NULL;
    if (mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &port) != KERN_SUCCESS ||
        mach_port_insert_right(mach_task_self(), port, port, MACH_MSG_TYPE_MAKE_SEND) != KERN_SUCCESS) return 2;
    posix_spawnattr_t attributes;
    posix_spawnattr_init(&attributes);
    sigset_t unblocked, defaults;
    sigemptyset(&unblocked);
    sigemptyset(&defaults);
    sigaddset(&defaults, SIGABRT);
    if (posix_spawnattr_setexceptionports_np(&attributes, EXC_MASK_ALL | EXC_MASK_CRASH | EXC_MASK_CORPSE_NOTIFY, port,
                                             (exception_behavior_t)(EXCEPTION_IDENTITY_PROTECTED | MACH_EXCEPTION_CODES),
                                             THREAD_STATE_NONE) != 0 ||
        posix_spawnattr_setflags(&attributes, POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF) != 0 ||
        posix_spawnattr_setsigmask(&attributes, &unblocked) != 0 ||
        posix_spawnattr_setsigdefault(&attributes, &defaults) != 0) return 2;
    int output[2];
    if (pipe(output) != 0) return 2;
    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0);
    posix_spawn_file_actions_adddup2(&actions, output[1], STDOUT_FILENO);
    posix_spawn_file_actions_addclose(&actions, output[0]);
    posix_spawn_file_actions_addclose(&actions, output[1]);
    pid_t pid;
    int spawned = posix_spawn(&pid, argv[1], &actions, &attributes, argv + 1, environ);
    close(output[1]);
    if (spawned != 0) { fprintf(stderr, "posix_spawn: %d\n", spawned); return 2; }

    // The record line, bounded at 60 s.
    char record[1024] = {0};
    size_t used = 0;
    time_t line_deadline = time(NULL) + 60;
    while (used + 1 < sizeof record) {
        struct pollfd ready = {.fd = output[0], .events = POLLIN};
        int left = (int)(line_deadline - time(NULL));
        if (left <= 0 || poll(&ready, 1, left * 1000) <= 0) {
            fprintf(stdout, "no startup record within 60 s\n");
            kill(pid, SIGKILL);
            mach_port_mod_refs(mach_task_self(), port, MACH_PORT_RIGHT_RECEIVE, -1);
            waitpid(pid, NULL, 0);
            return 1;
        }
        ssize_t n = read(output[0], record + used, 1);
        if (n <= 0 || record[used] == '\n') break;
        used++;
    }
    record[used] = 0;
    kill(pid, SIGABRT);

    int delivered = 0, status = 0, exited = 0;
    time_t deadline = time(NULL) + 30;
    while (!exited && time(NULL) < deadline) {
        struct { mach_msg_header_t header; char body[4096]; } message;
        memset(&message, 0, sizeof message);
        if (port != MACH_PORT_NULL &&
            mach_msg(&message.header, MACH_RCV_MSG | MACH_RCV_TIMEOUT, 0, sizeof message, port, 100,
                     MACH_PORT_NULL) == MACH_MSG_SUCCESS) {
            delivered++;
            fprintf(stdout, "delivered: msgh_id=%d\n", message.header.msgh_id);
            mach_msg_destroy(&message.header);
            // The child waits for the handler's answer; without the port it goes on.
            mach_port_mod_refs(mach_task_self(), port, MACH_PORT_RIGHT_RECEIVE, -1);
            port = MACH_PORT_NULL;
        }
        exited = waitpid(pid, &status, WNOHANG) == pid;
        if (port == MACH_PORT_NULL && !exited) usleep(100000);
    }
    if (!exited) {
        kill(pid, SIGKILL);
        waitpid(pid, &status, 0);
    }
    int aborted = WIFSIGNALED(status) && WTERMSIG(status) == SIGABRT;
    // Keys are sorted in the record (ProcessStartupHardening.report).
    int clean = strstr(record, "\"applied\":true,\"clean\":true") != NULL;
    // The handler reached the binary: its record of what it started with, or what it still holds.
    const char *seen = strstr(record, "\"inherited_task\":");
    if (seen == NULL) seen = strstr(record, "\"remaining_task\":");
    long mask = seen ? strtol(strchr(seen, ':') + 1, NULL, 10) : 0;
    long every = EXC_MASK_ALL | EXC_MASK_CRASH | EXC_MASK_CORPSE_NOTIFY;
    int reached = (mask & every) == every;
    printf("record: %s\nhandler reached the binary: %s\ndelivered: %d\nended by SIGABRT: %s\n", record,
           reached ? "yes" : "no", delivered, aborted ? "yes" : "no");
    return (reached && clean && delivered == 0 && aborted) ? 0 : 1;
}
