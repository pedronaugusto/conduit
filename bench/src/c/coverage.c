/* The rest of conduit's operations, as the C library offers them. */
#include <libproc.h>
#include <poll.h>
#include <sys/proc_info.h>

static int smoke(void) { return getenv("SMOKE") && !strcmp(getenv("SMOKE"), "1"); }
static int warm(int n, int limit) { return smoke() ? 0 : (n < limit ? n : limit); }
static double count_d(int n) { return (double)n; }

static void agree(const char *side, const char *workload, const char *metric, size_t value, const char *unit) {
    printf("%s\t%s\t%s\t%zu\t%s\n", side, workload, metric, value, unit);
}

/* Per-operation latency and the bytes it moved per second. */
static void size_rows(const char *side, const char *workload, int n, double total_ns, size_t bytes) {
    report(side, workload, "latency", total_ns / n / 1e3, "us");
    report(side, workload, "throughput", (double)bytes * n / total_ns * 1e3, "MB/s");
    agree(side, workload, "bytes_out", bytes, "bytes");
}

static pid_t spawn_pipes(char *const argv[], int in_fd, int out_fd) {
    posix_spawn_file_actions_t actions;
    assert(posix_spawn_file_actions_init(&actions) == 0);
    assert(posix_spawn_file_actions_adddup2(&actions, in_fd, STDIN_FILENO) == 0);
    assert(posix_spawn_file_actions_adddup2(&actions, out_fd, STDOUT_FILENO) == 0);
    assert(posix_spawn_file_actions_adddup2(&actions, null_fd, STDERR_FILENO) == 0);
    pid_t pid;
    int rc = posix_spawnp(&pid, argv[0], &actions, NULL, argv, environ);
    posix_spawn_file_actions_destroy(&actions);
    if (rc != 0) { errno = rc; perror("posix_spawn"); abort(); }
    return pid;
}

struct buffer { unsigned char *data; size_t len, cap; };
static void read_all(int fd, struct buffer *out) {
    for (;;) {
        if (out->cap - out->len < 65536) {
            out->cap = out->cap * 2 + 65536;
            out->data = realloc(out->data, out->cap);
            assert(out->data);
        }
        ssize_t got = read(fd, out->data + out->len, out->cap - out->len);
        if (got == 0) return;
        if (got < 0 && errno == EINTR) continue;
        assert(got > 0);
        out->len += (size_t)got;
    }
}

static void cloexec_pipe(int fds[2]) {
    assert(pipe(fds) == 0);
    assert(fcntl(fds[0], F_SETFD, FD_CLOEXEC) == 0 && fcntl(fds[1], F_SETFD, FD_CLOEXEC) == 0);
}

static void *write_then_close(void *opaque) {
    struct writer_args *args = opaque;
    write_all(args->fd, args->data, args->len);
    close(args->fd);
    return NULL;
}

/* `cat` given the input from a writer thread and its output read here. */
static double one_exchange(const unsigned char *input, size_t len) {
    int in[2], out[2];
    uint64_t start = now_ns();
    cloexec_pipe(in); cloexec_pipe(out);
    char *argv[] = {program("BENCH_CAT", "cat"), NULL};
    pid_t pid = spawn_pipes(argv, in[0], out[1]);
    close(in[0]); close(out[1]);
    struct writer_args args = {.fd = in[1], .data = input, .len = len};
    pthread_t writer;
    assert(pthread_create(&writer, NULL, write_then_close, &args) == 0);
    struct buffer got = {0};
    read_all(out[0], &got);
    assert(pthread_join(writer, NULL) == 0);
    close(out[0]);
    reap_ok(pid);
    double elapsed = (double)(now_ns() - start);
    assert(got.len == len && memcmp(got.data, input, len) == 0);
    free(got.data);
    return elapsed;
}

static void exchange(int n, const unsigned char *input, size_t len) {
    for (int i = 0; i < warm(n, 3); i++) one_exchange(input, len);
    double total = 0;
    for (int i = 0; i < n; i++) total += one_exchange(input, len);
    size_rows("c-posix_spawn", "EXCHANGE", n, total, len);
}

static double one_collect_file(const char *path, const unsigned char *input, size_t len) {
    int out[2];
    uint64_t start = now_ns();
    cloexec_pipe(out);
    char *argv[] = {program("BENCH_CAT", "cat"), (char *)path, NULL};
    pid_t pid = spawn_pipes(argv, null_fd, out[1]);
    close(out[1]);
    struct buffer got = {0};
    read_all(out[0], &got);
    close(out[0]);
    reap_ok(pid);
    double elapsed = (double)(now_ns() - start);
    assert(got.len == len && memcmp(got.data, input, len) == 0);
    free(got.data);
    return elapsed;
}

static void collect_file(int n, const char *path, const unsigned char *input, size_t len) {
    for (int i = 0; i < warm(n, 3); i++) one_collect_file(path, input, len);
    double total = 0;
    for (int i = 0; i < n; i++) total += one_collect_file(path, input, len);
    size_rows("c-posix_spawn", "COLLECT", n, total, len);
}

/* No queue in libc: a writer thread writes the input 64 bytes per write,
 * the floor of the per-chunk writes the queueing sides make. */
static void *chunk_writer(void *opaque) {
    struct writer_args *args = opaque;
    for (size_t at = 0; at < args->len; at += 64) {
        size_t take = args->len - at < 64 ? args->len - at : 64;
        write_all(args->fd, args->data + at, take);
    }
    close(args->fd);
    return NULL;
}

static double one_input_writer(const unsigned char *input, size_t len) {
    int in[2], out[2];
    uint64_t start = now_ns();
    cloexec_pipe(in); cloexec_pipe(out);
    char *argv[] = {program("BENCH_CAT", "cat"), NULL};
    pid_t pid = spawn_pipes(argv, in[0], out[1]);
    close(in[0]); close(out[1]);
    struct writer_args args = {.fd = in[1], .data = input, .len = len};
    pthread_t writer;
    assert(pthread_create(&writer, NULL, chunk_writer, &args) == 0);
    struct buffer got = {0};
    read_all(out[0], &got);
    assert(pthread_join(writer, NULL) == 0);
    close(out[0]);
    reap_ok(pid);
    double elapsed = (double)(now_ns() - start);
    assert(got.len == len && memcmp(got.data, input, len) == 0);
    free(got.data);
    return elapsed;
}

static void input_writer(int n, const unsigned char *input, size_t len) {
    for (int i = 0; i < warm(n, 2); i++) one_input_writer(input, len);
    double total = 0;
    for (int i = 0; i < n; i++) total += one_input_writer(input, len);
    size_rows("c-pthread-write", "INPUT WRITER", n, total, len);
}

/* What an ended `echo` left in its pipe, read without waiting: a
 * non-blocking descriptor read to EAGAIN or end of file; only reads timed. */
static double one_read_available(const char *arg, size_t len) {
    int out[2];
    cloexec_pipe(out);
    char *argv[] = {program("BENCH_ECHO", "echo"), (char *)arg, NULL};
    pid_t pid = spawn_pipes(argv, null_fd, out[1]);
    close(out[1]);
    reap_ok(pid);
    unsigned char buf[4096];
    size_t total = 0;
    uint64_t start = now_ns();
    assert(fcntl(out[0], F_SETFL, fcntl(out[0], F_GETFL) | O_NONBLOCK) == 0);
    for (;;) {
        ssize_t got = read(out[0], buf, sizeof(buf));
        if (got == 0 || (got < 0 && errno == EAGAIN)) break;
        if (got < 0 && errno == EINTR) continue;
        assert(got > 0);
        total += (size_t)got;
    }
    double elapsed = (double)(now_ns() - start);
    close(out[0]);
    assert(total == len + 1);
    return elapsed;
}

static void read_available(int n, const unsigned char *input, size_t len) {
    assert(len == 1024);
    char arg[1025];
    memcpy(arg, input, len); arg[len] = 0;
    for (int i = 0; i < warm(n, 5); i++) one_read_available(arg, len);
    double total = 0;
    for (int i = 0; i < n; i++) total += one_read_available(arg, len);
    report("c-nonblock-read", "READ AVAILABLE", "latency", total / n / 1e3, "us");
    agree("c-nonblock-read", "READ AVAILABLE", "bytes_out", len + 1, "bytes");
}

static void try_wait(int n) {
    char *argv[] = {program("BENCH_SLEEP", "sleep"), "30", NULL};
    pid_t pid = spawn_posix(argv, null_fd);
    int status;
    for (int i = 0; i < warm(n, 1000); i++) assert(waitpid(pid, &status, WNOHANG) == 0);
    uint64_t start = now_ns();
    for (int i = 0; i < n; i++) assert(waitpid(pid, &status, WNOHANG) == 0);
    double elapsed = (double)(now_ns() - start);
    assert(kill(pid, SIGKILL) == 0);
    assert(waitpid(pid, &status, 0) == pid);
    report("c-waitpid-wnohang", "TRY WAIT", "call", elapsed / n, "ns");
}

static void *waiter(void *opaque) {
    pid_t pid = *(pid_t *)opaque;
    reap_ok(pid);
    return NULL;
}

/* `true` spawned and its waitpid put on a thread of its own, joined. */
static double one_reaper_wait(void) {
    uint64_t start = now_ns();
    char *argv[] = {program("BENCH_TRUE", "true"), NULL};
    pid_t pid = spawn_posix(argv, null_fd);
    pthread_t thread;
    assert(pthread_create(&thread, NULL, waiter, &pid) == 0);
    assert(pthread_join(thread, NULL) == 0);
    return (double)(now_ns() - start);
}

static void reaper_wait(int n) {
    for (int i = 0; i < warm(n, 10); i++) one_reaper_wait();
    double total = 0;
    for (int i = 0; i < n; i++) total += one_reaper_wait();
    report("c-pthread-waitpid", "REAPER WAIT", "latency", total / n / 1e3, "us");
}

struct drain_args { int fd; size_t total, returns; };
static void *drain_thread(void *opaque) {
    struct drain_args *args = opaque;
    unsigned char buf[64 * 1024];
    for (;;) {
        ssize_t got = read(args->fd, buf, sizeof(buf));
        if (got == 0) return NULL;
        if (got < 0 && errno == EINTR) continue;
        assert(got > 0);
        args->total += (size_t)got;
        for (ssize_t i = 0; i < got; i++) args->returns += buf[i] == '\r';
    }
}

/* `cat FILE` on a pair in its default mode, both directions moved by one
 * poll loop with 32 KiB buffers (the master to a pipe another thread
 * drains, and an input pipe that never speaks): spawn to every byte out
 * and reap. */
static double one_proxy(const char *path, const unsigned char *input, size_t len) {
    int in[2], out[2];
    cloexec_pipe(in); cloexec_pipe(out);
    struct drain_args drain = {.fd = out[0]};
    uint64_t start = now_ns();
    pthread_t reader;
    assert(pthread_create(&reader, NULL, drain_thread, &drain) == 0);
    struct winsize ws = {.ws_row = 24, .ws_col = 80};
    int master;
    pid_t pid = forkpty(&master, NULL, NULL, &ws);
    assert(pid >= 0);
    if (pid == 0) {
        char *argv[] = {program("BENCH_CAT", "cat"), (char *)path, NULL};
        execvp(argv[0], argv);
        _exit(127);
    }
    unsigned char buf[32 * 1024];
    struct pollfd fds[2] = {{.fd = master, .events = POLLIN}, {.fd = in[0], .events = POLLIN}};
    for (;;) {
        int ready = poll(fds, 2, -1);
        if (ready < 0 && errno == EINTR) continue;
        assert(ready > 0);
        if (fds[1].revents & POLLIN) {
            ssize_t got = read(in[0], buf, sizeof(buf));
            if (got > 0) write_all(master, buf, (size_t)got);
        }
        if (fds[0].revents & (POLLIN | POLLHUP | POLLERR)) {
            ssize_t got = read(master, buf, sizeof(buf));
            if (got < 0 && errno == EINTR) continue;
            if (got <= 0) break; /* end of file, or EIO once the child's side is gone */
            write_all(out[1], buf, (size_t)got);
        }
    }
    close(out[1]);
    assert(pthread_join(reader, NULL) == 0);
    reap_ok(pid);
    double elapsed = (double)(now_ns() - start);
    close(master); close(in[0]); close(in[1]); close(out[0]);
    size_t newlines = 0;
    for (size_t i = 0; i < len; i++) newlines += input[i] == '\n';
    assert(drain.total - drain.returns == len && drain.returns >= newlines);
    return elapsed;
}

static void proxy(int n, const char *path, const unsigned char *input, size_t len) {
    for (int i = 0; i < warm(n, 1); i++) one_proxy(path, input, len);
    double total = 0;
    for (int i = 0; i < n; i++) total += one_proxy(path, input, len);
    size_rows("c-forkpty-poll", "PROXY", n, total, len);
}

/* `sh -c 'echo ready'` on a new pair with TERM set and a controlling
 * terminal: spawn to its line read and reap. */
static double one_shell(void) {
    uint64_t start = now_ns();
    struct winsize ws = {.ws_row = 24, .ws_col = 80};
    int master;
    pid_t pid = forkpty(&master, NULL, NULL, &ws);
    assert(pid >= 0);
    if (pid == 0) {
        setenv("TERM", "xterm-256color", 1);
        char *argv[] = {program("BENCH_SH", "sh"), "-c", "echo ready", NULL};
        execvp(argv[0], argv);
        _exit(127);
    }
    char said[7];
    size_t got = 0;
    while (got < sizeof(said)) {
        ssize_t n = read(master, said + got, sizeof(said) - got);
        if (n < 0 && errno == EINTR) continue;
        assert(n > 0);
        got += (size_t)n;
    }
    reap_ok(pid);
    double elapsed = (double)(now_ns() - start);
    close(master);
    assert(memcmp(said, "ready\r\n", 7) == 0);
    return elapsed;
}

static void shell_spawn(int n) {
    for (int i = 0; i < warm(n, 5); i++) one_shell();
    double total = 0;
    for (int i = 0; i < n; i++) total += one_shell();
    report("c-forkpty", "SHELL SPAWN", "latency", total / n / 1e3, "us");
}

static void one_pty_open(void) {
    struct winsize ws = {.ws_row = 24, .ws_col = 80};
    int master, slave;
    assert(openpty(&master, &slave, NULL, NULL, &ws) == 0);
    close(slave);
    close(master);
}

static void pty_open(int n) {
    for (int i = 0; i < warm(n, 20); i++) one_pty_open();
    uint64_t start = now_ns();
    for (int i = 0; i < n; i++) one_pty_open();
    report("c-openpty", "PTY OPEN", "latency", (double)(now_ns() - start) / n / 1e3, "us");
}

static void tty_ops(int n) {
    struct winsize ws = {.ws_row = 24, .ws_col = 80};
    int master, slave;
    /* A pair kept open for the name, and a session leader on another. */
    assert(openpty(&master, &slave, NULL, NULL, &ws) == 0);
    int leader;
    pid_t pid = forkpty(&leader, NULL, NULL, &ws);
    assert(pid >= 0);
    if (pid == 0) {
        char *argv[] = {program("BENCH_SLEEP", "sleep"), "30", NULL};
        execvp(argv[0], argv);
        _exit(127);
    }
    struct timespec pause = {.tv_sec = 0, .tv_nsec = 1000000};
    for (int i = 0; tcgetpgrp(leader) != pid; i++) { assert(i < 1000); nanosleep(&pause, NULL); }
    char name[256];
    int rounds = smoke() ? 1 : 2;
    for (int round = 0; round < rounds; round++) {
        int timed = round + 1 == rounds;
        uint64_t start = now_ns();
        for (int i = 0; i < n; i++) {
            struct termios saved, raw;
            assert(tcgetattr(leader, &saved) == 0);
            raw = saved;
            cfmakeraw(&raw);
            assert(tcsetattr(leader, TCSANOW, &raw) == 0);
            assert(tcsetattr(leader, TCSANOW, &saved) == 0);
        }
        if (timed) report("c-termios", "TTY OPS", "raw_restore", (double)(now_ns() - start) / count_d(n), "ns");
        start = now_ns();
        for (int i = 0; i < n; i++) {
            struct winsize got;
            assert(ioctl(leader, TIOCGWINSZ, &got) == 0 && got.ws_row == 24);
        }
        if (timed) report("c-ioctl", "TTY OPS", "win_size", (double)(now_ns() - start) / count_d(n), "ns");
        start = now_ns();
        for (int i = 0; i < n; i++) assert(ioctl(leader, TIOCSWINSZ, &ws) == 0);
        if (timed) report("c-ioctl", "TTY OPS", "set_win_size", (double)(now_ns() - start) / count_d(n), "ns");
        start = now_ns();
        for (int i = 0; i < n; i++) assert(isatty(leader));
        if (timed) report("c-isatty", "TTY OPS", "is_tty", (double)(now_ns() - start) / count_d(n), "ns");
        start = now_ns();
        for (int i = 0; i < n; i++) assert(ttyname_r(slave, name, sizeof(name)) == 0 && !strncmp(name, "/dev/tty", 8));
        if (timed) report("c-ttyname_r", "TTY OPS", "tty_name", (double)(now_ns() - start) / count_d(n), "ns");
        start = now_ns();
        for (int i = 0; i < n; i++) assert(tcgetpgrp(leader) == pid);
        if (timed) report("c-tcgetpgrp", "TTY OPS", "foreground_group", (double)(now_ns() - start) / count_d(n), "ns");
    }
    assert(kill(pid, SIGKILL) == 0);
    int status;
    assert(waitpid(pid, &status, 0) == pid);
    close(leader); close(master); close(slave);
}

static void process_identity(int n) {
    char *argv[] = {program("BENCH_SLEEP", "sleep"), "30", NULL};
    pid_t pid = spawn_posix(argv, null_fd);
    struct proc_bsdinfo first;
    assert(proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &first, sizeof(first)) == (int)sizeof(first));
    int rounds = smoke() ? 1 : 2;
    for (int round = 0; round < rounds; round++) {
        int timed = round + 1 == rounds;
        uint64_t start = now_ns();
        for (int i = 0; i < n; i++) assert(kill(pid, 0) == 0);
        if (timed) report("c-kill0", "PROCESS IDENTITY", "exists", (double)(now_ns() - start) / count_d(n), "ns");
        start = now_ns();
        for (int i = 0; i < n; i++) {
            struct proc_bsdinfo info;
            assert(proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sizeof(info)) == (int)sizeof(info));
            assert(info.pbi_start_tvsec == first.pbi_start_tvsec && info.pbi_start_tvusec == first.pbi_start_tvusec);
        }
        if (timed) report("c-proc_pidinfo", "PROCESS IDENTITY", "start_time", (double)(now_ns() - start) / count_d(n), "ns");
    }
    assert(kill(pid, SIGKILL) == 0);
    int status;
    assert(waitpid(pid, &status, 0) == pid);
}
