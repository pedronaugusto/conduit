#define _DARWIN_C_SOURCE
#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <signal.h>
#include <spawn.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/event.h>
#include <sys/ioctl.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <termios.h>
#include <time.h>
#include <unistd.h>
#include <util.h>

extern char **environ;
extern int proc_listchildpids(pid_t ppid, void *buffer, int buffersize);

static int null_fd;
static char *program(const char *name, const char *fallback) {
    char *value = getenv(name);
    return value ? value : (char *)fallback;
}

static uint64_t now_ns(void) {
    static uint64_t smoke_ticks;
    if (getenv("SMOKE") && strcmp(getenv("SMOKE"), "1") == 0) return ++smoke_ticks;
    struct timespec ts;
    assert(clock_gettime(CLOCK_MONOTONIC, &ts) == 0);
    return (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
}

static void report(const char *side, const char *workload, const char *metric, double value, const char *unit) {
    printf("%s\t%s\t%s\t%.6f\t%s\n", side, workload, metric, value, unit);
}

static pid_t spawn_posix(char *const argv[], int out_fd) {
    posix_spawn_file_actions_t actions;
    assert(posix_spawn_file_actions_init(&actions) == 0);
    assert(posix_spawn_file_actions_adddup2(&actions, null_fd, STDIN_FILENO) == 0);
    assert(posix_spawn_file_actions_adddup2(&actions, out_fd, STDOUT_FILENO) == 0);
    assert(posix_spawn_file_actions_adddup2(&actions, null_fd, STDERR_FILENO) == 0);
    pid_t pid;
    int rc = posix_spawnp(&pid, argv[0], &actions, NULL, argv, environ);
    posix_spawn_file_actions_destroy(&actions);
    if (rc != 0) { errno = rc; perror("posix_spawn"); abort(); }
    return pid;
}

static pid_t spawn_fork(char *const argv[], int out_fd, int new_group) {
    pid_t pid = fork();
    assert(pid >= 0);
    if (pid == 0) {
        if (new_group && setpgid(0, 0) != 0) _exit(126);
        if (dup2(null_fd, STDIN_FILENO) < 0 || dup2(out_fd, STDOUT_FILENO) < 0 ||
            dup2(null_fd, STDERR_FILENO) < 0) _exit(126);
        execvp(argv[0], argv);
        _exit(127);
    }
    return pid;
}

static void reap_ok(pid_t pid) {
    int status;
    assert(waitpid(pid, &status, 0) == pid);
    assert(WIFEXITED(status) && WEXITSTATUS(status) == 0);
}

static void one_spawn_wait(int use_posix) {
    char *argv[] = {program("BENCH_TRUE", "true"), NULL};
    pid_t pid = use_posix ? spawn_posix(argv, null_fd) : spawn_fork(argv, null_fd, 0);
    reap_ok(pid);
}

static void spawn_wait(int n, int use_posix) {
    for (int i = 0; i < n && i < 10 && !(getenv("SMOKE") && !strcmp(getenv("SMOKE"), "1")); i++) one_spawn_wait(use_posix);
    uint64_t start = now_ns();
    for (int i = 0; i < n; i++) one_spawn_wait(use_posix);
    report(use_posix ? "c-posix_spawn" : "c-fork-exec", "SPAWN+WAIT", "latency",
           (double)(now_ns() - start) / n / 1e3, "us");
}

static void one_collect(int use_posix, const char *arg) {
    int fds[2];
    assert(pipe(fds) == 0);
    char *argv[] = {program("BENCH_ECHO", "echo"), (char *)arg, NULL};
    pid_t pid = use_posix ? spawn_posix(argv, fds[1]) : spawn_fork(argv, fds[1], 0);
    close(fds[1]);
    char buf[2048];
    size_t total = 0;
    for (;;) {
        ssize_t got = read(fds[0], buf + total, sizeof(buf) - total);
        if (got == 0) break;
        if (got < 0 && errno == EINTR) continue;
        assert(got > 0);
        total += (size_t)got;
    }
    close(fds[0]);
    reap_ok(pid);
    assert(total == 1025 && buf[1024] == '\n');
}

static void spawn_collect(int n, int use_posix, const unsigned char *input, size_t len) {
    assert(len == 1024);
    char arg[1025];
    memcpy(arg, input, len); arg[len] = 0;
    for (int i = 0; i < n && i < 5 && !(getenv("SMOKE") && !strcmp(getenv("SMOKE"), "1")); i++) one_collect(use_posix, arg);
    uint64_t start = now_ns();
    for (int i = 0; i < n; i++) one_collect(use_posix, arg);
    report(use_posix ? "c-posix_spawn" : "c-fork-exec", "SPAWN+COLLECT", "latency",
           (double)(now_ns() - start) / n / 1e3, "us");
}

static pid_t open_cat(int *master) {
    struct winsize ws = {.ws_row = 24, .ws_col = 80};
    pid_t pid = forkpty(master, NULL, NULL, &ws);
    assert(pid >= 0);
    if (pid == 0) {
        char *argv[] = {program("BENCH_CAT", "cat"), NULL};
        execvp(argv[0], argv);
        _exit(127);
    }
    struct termios term;
    assert(tcgetattr(*master, &term) == 0);
    cfmakeraw(&term);
    assert(tcsetattr(*master, TCSANOW, &term) == 0);
    return pid;
}

static size_t expected_pty(const unsigned char *input, size_t len) {
    (void)input;
    return len;
}

static uint64_t drain_exact(int fd, size_t wanted) {
    unsigned char buf[64 * 1024];
    size_t total = 0;
    uint64_t sum = 0;
    while (total < wanted) {
        size_t take = sizeof(buf) < wanted - total ? sizeof(buf) : wanted - total;
        ssize_t got = read(fd, buf, take);
        if (got < 0 && errno == EINTR) continue;
        assert(got > 0);
        for (ssize_t i = 0; i < got; i++) sum += buf[i];
        total += (size_t)got;
    }
    return sum;
}

static void write_all(int fd, const unsigned char *input, size_t len) {
    size_t at = 0;
    while (at < len) {
        ssize_t put = write(fd, input + at, len - at);
        if (put < 0 && errno == EINTR) continue;
        assert(put > 0);
        at += (size_t)put;
    }
}

static void one_pty(const unsigned char *input, size_t len) {
    int master;
    pid_t pid = open_cat(&master);
    write_all(master, input, len);
    assert(drain_exact(master, expected_pty(input, len)) != 0);
    assert(kill(pid, SIGKILL) == 0);
    int status; assert(waitpid(pid, &status, 0) == pid);
    close(master);
}

static void pty_spawn(int n, const unsigned char *input, size_t len) {
    assert(len == 1024);
    for (int i = 0; i < n && i < 3 && !(getenv("SMOKE") && !strcmp(getenv("SMOKE"), "1")); i++) one_pty(input, len);
    uint64_t start = now_ns();
    for (int i = 0; i < n; i++) one_pty(input, len);
    report("c-forkpty", "PTY SPAWN", "latency", (double)(now_ns() - start) / n / 1e3, "us");
}

struct writer_args { int fd; const unsigned char *data; size_t len; };
static void *writer_thread(void *opaque) {
    struct writer_args *args = opaque;
    write_all(args->fd, args->data, args->len);
    return NULL;
}

static void pty_throughput(const unsigned char *input, size_t len) {
    int master;
    pid_t pid = open_cat(&master);
    struct writer_args args = {.fd = master, .data = input, .len = len};
    pthread_t writer;
    uint64_t start = now_ns();
    assert(pthread_create(&writer, NULL, writer_thread, &args) == 0);
    assert(drain_exact(master, expected_pty(input, len)) != 0);
    assert(pthread_join(writer, NULL) == 0);
    double seconds = (double)(now_ns() - start) / 1e9;
    assert(kill(pid, SIGKILL) == 0);
    int status; assert(waitpid(pid, &status, 0) == pid);
    close(master);
    report("c-forkpty", "PTY THROUGHPUT", "throughput", (double)len / seconds / 1e6, "MB/s");
}

static double one_wait_timeout(void) {
    char *argv[] = {program("BENCH_SLEEP", "sleep"), "0.01", NULL};
    pid_t pid = spawn_posix(argv, null_fd);
    int kq = kqueue(); assert(kq >= 0);
    struct kevent change, event;
    EV_SET(&change, pid, EVFILT_PROC, EV_ADD | EV_ONESHOT, NOTE_EXIT, 0, NULL);
    struct timespec timeout = {.tv_sec = 1, .tv_nsec = 0};
    uint64_t start = now_ns();
    int rc;
    do { rc = kevent(kq, &change, 1, &event, 1, &timeout); } while (rc < 0 && errno == EINTR);
    assert(rc == 1);
    reap_ok(pid);
    uint64_t elapsed = now_ns() - start;
    close(kq);
    return (double)elapsed;
}

static void wait_timeout(int n) {
    for (int i = 0; i < n && i < 3 && !(getenv("SMOKE") && !strcmp(getenv("SMOKE"), "1")); i++) (void)one_wait_timeout();
    double total = 0;
    for (int i = 0; i < n; i++) total += one_wait_timeout();
    double over = total / n / 1e3 - 10000.0;
    report("c-kqueue", "WAIT-TIMEOUT", "overshoot", over > 0 ? over : 0, "us");
}

static int children_of(pid_t parent, pid_t *out, size_t cap) {
    int count = proc_listchildpids(parent, out, (int)(cap * sizeof(*out)));
    return count > 0 ? count : 0;
}

static int wait_for_children(pid_t parent, pid_t *out, size_t cap) {
    struct timespec pause = {.tv_sec = 0, .tv_nsec = 1000000};
    for (int i = 0; i < 1000; i++) {
        int n = children_of(parent, out, cap);
        if (n >= 2) return n;
        nanosleep(&pause, NULL);
    }
    abort();
}

static void confirm_gone(pid_t *pids, int count) {
    struct timespec pause = {.tv_sec = 0, .tv_nsec = 1000000};
    for (int attempt = 0; attempt < 1000; attempt++) {
        int any = 0;
        for (int i = 0; i < count; i++) if (kill(pids[i], 0) == 0) any = 1;
        if (!any) return;
        nanosleep(&pause, NULL);
    }
    abort();
}

static double one_tree_kill(void) {
    char *argv[] = {program("BENCH_SH", "sh"), "-c", "sleep 30 & sleep 30 & wait", NULL};
    pid_t pid = spawn_fork(argv, null_fd, 1);
    pid_t descendants[8];
    int count = wait_for_children(pid, descendants, 8);
    uint64_t start = now_ns();
    assert(kill(-pid, SIGKILL) == 0);
    int status; assert(waitpid(pid, &status, 0) == pid);
    double elapsed = (double)(now_ns() - start);
    confirm_gone(descendants, count);
    return elapsed;
}

static void tree_kill(int n) {
    for (int i = 0; i < n && i < 2 && !(getenv("SMOKE") && !strcmp(getenv("SMOKE"), "1")); i++) (void)one_tree_kill();
    double total = 0;
    for (int i = 0; i < n; i++) total += one_tree_kill();
    report("c-fork+killpg", "TREE KILL", "latency", total / n / 1e6, "ms");
}

#include "coverage.c"

static unsigned char *read_file(const char *path, size_t *len) {
    FILE *f = fopen(path, "rb"); assert(f);
    assert(fseek(f, 0, SEEK_END) == 0);
    long size = ftell(f); assert(size >= 0);
    rewind(f);
    unsigned char *data = malloc((size_t)size + 1); assert(data);
    assert(fread(data, 1, (size_t)size, f) == (size_t)size);
    fclose(f); data[size] = 0; *len = (size_t)size; return data;
}

int main(int argc, char **argv) {
    assert(argc == 4);
    int n = atoi(argv[2]); assert(n > 0);
    size_t len; unsigned char *input = read_file(argv[3], &len);
    null_fd = open("/dev/null", O_RDWR | O_CLOEXEC); assert(null_fd >= 0);
    if (!strcmp(argv[1], "posix_spawn_wait")) spawn_wait(n, 1);
    else if (!strcmp(argv[1], "fork_wait")) spawn_wait(n, 0);
    else if (!strcmp(argv[1], "posix_spawn_collect")) spawn_collect(n, 1, input, len);
    else if (!strcmp(argv[1], "fork_collect")) spawn_collect(n, 0, input, len);
    else if (!strcmp(argv[1], "pty_spawn")) pty_spawn(n, input, len);
    else if (!strcmp(argv[1], "pty_throughput")) pty_throughput(input, len);
    else if (!strcmp(argv[1], "wait_timeout")) wait_timeout(n);
    else if (!strcmp(argv[1], "tree_kill")) tree_kill(n);
    else if (!strcmp(argv[1], "exchange")) exchange(n, input, len);
    else if (!strcmp(argv[1], "collect")) collect_file(n, argv[3], input, len);
    else if (!strcmp(argv[1], "input_writer")) input_writer(n, input, len);
    else if (!strcmp(argv[1], "read_available")) read_available(n, input, len);
    else if (!strcmp(argv[1], "try_wait")) try_wait(n);
    else if (!strcmp(argv[1], "reaper_wait")) reaper_wait(n);
    else if (!strcmp(argv[1], "proxy")) proxy(n, argv[3], input, len);
    else if (!strcmp(argv[1], "shell_spawn")) shell_spawn(n);
    else if (!strcmp(argv[1], "pty_open")) pty_open(n);
    else if (!strcmp(argv[1], "tty_ops")) tty_ops(n);
    else if (!strcmp(argv[1], "process_identity")) process_identity(n);
    else abort();
    close(null_fd); free(input); return 0;
}
