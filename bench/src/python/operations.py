"""The rest of conduit's operations, where the standard library, ptyprocess
or pexpect has the same one."""
import os
import queue
import shutil
import signal
import subprocess
import termios
import threading
import time
import tty
import pty as stdlib_pty

import pexpect
from ptyprocess import PtyProcess

from bench import benchmark_clock_ns, no_close_delay, report, write_all

SMOKE = os.environ.get("SMOKE") == "1"
CAT = os.environ.get("BENCH_CAT", "cat")
ECHO = os.environ.get("BENCH_ECHO", "echo")
SLEEP = os.environ.get("BENCH_SLEEP", "sleep")
SH = os.environ.get("BENCH_SH", "sh")
TRUE = os.environ.get("BENCH_TRUE", "true")
EXPECT_MESSAGE = b"expect round trip 0123456789\n"
MISSING_PROGRAM = "conduit-bench-no-such-program"


def warm(n, limit):
    return 0 if SMOKE else min(n, limit)


def agree(side, workload, metric, value, unit):
    print(f"{side}\t{workload}\t{metric}\t{value}\t{unit}")


def size_rows(side, workload, n, total_ns, size):
    report(side, workload, "latency", total_ns / n / 1e3, "us")
    report(side, workload, "throughput", size * n / total_ns * 1e3, "MB/s")
    agree(side, workload, "bytes_out", size, "bytes")


def repeat(n, limit, one):
    for _ in range(warm(n, limit)):
        one()
    return sum(one() for _ in range(n))


def rows(n, timed_rows):
    """Each (side, workload, metric, unit, scale, op) run n times, twice outside
    smoke, the first round untimed."""
    for round in range(1 if SMOKE else 2):
        for side, workload, metric, unit, scale, op in timed_rows:
            start = benchmark_clock_ns()
            for _ in range(n):
                op()
            elapsed = benchmark_clock_ns() - start
            if round == (0 if SMOKE else 1):
                report(side, workload, metric, elapsed / n / scale, unit)


def one_exchange(data):
    start = benchmark_clock_ns()
    result = subprocess.run([CAT], input=data, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    elapsed = benchmark_clock_ns() - start
    assert result.returncode == 0 and result.stdout == data
    return elapsed


def exchange(n, data):
    size_rows("python-subprocess", "EXCHANGE", n, repeat(n, 3, lambda: one_exchange(data)), len(data))


def one_collect(path, data):
    start = benchmark_clock_ns()
    result = subprocess.run([CAT, path], stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                            stderr=subprocess.DEVNULL)
    elapsed = benchmark_clock_ns() - start
    assert result.returncode == 0 and result.stdout == data
    return elapsed


def collect(n, path, data):
    size_rows("python-subprocess", "COLLECT", n, repeat(n, 3, lambda: one_collect(path, data)), len(data))


def one_input_writer(data):
    """The input queued 64 bytes at a time for a writer thread, then ended,
    while cat's output is read here."""
    start = benchmark_clock_ns()
    child = subprocess.Popen([CAT], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                             stderr=subprocess.DEVNULL, bufsize=0)
    chunks = queue.SimpleQueue()

    def writer():
        while (chunk := chunks.get()) is not None:
            view = memoryview(chunk)
            while view:
                view = view[child.stdin.write(view):]
        child.stdin.close()

    thread = threading.Thread(target=writer)
    thread.start()
    for at in range(0, len(data), 64):
        chunks.put(data[at:at + 64])
    chunks.put(None)
    out = child.stdout.read()
    child.stdout.close()
    assert child.wait() == 0
    thread.join()
    elapsed = benchmark_clock_ns() - start
    assert out == data
    return elapsed


def input_writer(n, data):
    size_rows("python-subprocess", "INPUT WRITER", n, repeat(n, 2, lambda: one_input_writer(data)), len(data))


def one_read_available(arg):
    child = subprocess.Popen([ECHO, arg], stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                             stderr=subprocess.DEVNULL)
    assert child.wait() == 0
    fd = child.stdout.fileno()
    total = 0
    start = benchmark_clock_ns()
    os.set_blocking(fd, False)
    while True:
        try:
            chunk = os.read(fd, 4096)
        except BlockingIOError:
            break
        if not chunk:
            break
        total += len(chunk)
    elapsed = benchmark_clock_ns() - start
    child.stdout.close()
    assert total == len(arg) + 1
    return elapsed


def read_available(n, data):
    arg = data.decode("ascii")
    report("python-os-nonblock", "READ AVAILABLE", "latency",
           repeat(n, 5, lambda: one_read_available(arg)) / n / 1e3, "us")
    agree("python-os-nonblock", "READ AVAILABLE", "bytes_out", len(arg) + 1, "bytes")


def try_wait(n):
    child = subprocess.Popen([SLEEP, "30"], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                             stderr=subprocess.DEVNULL)
    for _ in range(warm(n, 1000)):
        assert child.poll() is None
    start = benchmark_clock_ns()
    for _ in range(n):
        assert child.poll() is None
    elapsed = benchmark_clock_ns() - start
    child.kill()
    child.wait()
    report("python-subprocess", "TRY WAIT", "call", elapsed / n, "ns")


def one_reaper_wait():
    start = benchmark_clock_ns()
    child = subprocess.Popen([TRUE], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                             stderr=subprocess.DEVNULL)
    thread = threading.Thread(target=child.wait)
    thread.start()
    thread.join()
    elapsed = benchmark_clock_ns() - start
    assert child.returncode == 0
    return elapsed


def reaper_wait(n):
    report("python-subprocess", "REAPER WAIT", "latency", repeat(n, 10, one_reaper_wait) / n / 1e3, "us")


def expect(n):
    child = pexpect.spawn(CAT, dimensions=(24, 80))
    # pexpect sleeps 50 ms before each send and briefly after each read by
    # default; both are documented knobs, and no other side sleeps.
    child.delaybeforesend = None
    child.delayafterread = None
    no_close_delay(child.ptyproc)
    tty.setraw(child.child_fd, termios.TCSANOW)
    message = EXPECT_MESSAGE
    patterns = [b"never-a\n", b"never-b\n", b"never-c\n", message]
    for _ in range(warm(n, 20)):
        child.send(message)
        child.expect_exact(message, timeout=5)

    def until():
        child.send(message)
        assert child.expect_exact(message, timeout=5) == 0 and child.before == b""

    def until_any():
        child.send(message)
        assert child.expect_exact(patterns, timeout=5) == 3 and child.before == b""

    def exact_bytes():
        child.send(message)
        assert child.read(len(message)) == message

    for metric, op in (("until", until), ("until_any", until_any), ("bytes", exact_bytes)):
        start = benchmark_clock_ns()
        for _ in range(n):
            op()
        report("python-pexpect", "EXPECT", metric, (benchmark_clock_ns() - start) / n / 1e3, "us")
    os.kill(child.pid, signal.SIGKILL)
    child.wait()
    child.close()


def one_proxy(path, data):
    """cat FILE on a pair in its default mode through the standard library's
    own proxy, pty.spawn, with its standard input a pipe that never speaks
    and its standard output a pipe another thread drains."""
    in_r, in_w = os.pipe()
    out_r, out_w = os.pipe()
    counts = [0, 0]

    def drain():
        while chunk := os.read(out_r, 65536):
            counts[0] += len(chunk)
            counts[1] += chunk.count(b"\r")

    saved = (os.dup(0), os.dup(1))
    start = benchmark_clock_ns()
    thread = threading.Thread(target=drain)
    thread.start()
    os.dup2(in_r, 0)
    os.dup2(out_w, 1)
    try:
        status = stdlib_pty.spawn([CAT, path])
    finally:
        os.dup2(saved[0], 0)
        os.dup2(saved[1], 1)
    os.close(out_w)
    thread.join()
    elapsed = benchmark_clock_ns() - start
    for fd in (*saved, in_r, in_w, out_r):
        os.close(fd)
    assert os.waitstatus_to_exitcode(status) == 0
    assert counts[0] - counts[1] == len(data) and counts[1] >= data.count(b"\n")
    return elapsed


def proxy(n, path, data):
    size_rows("python-pty-spawn", "PROXY", n, repeat(n, 1, lambda: one_proxy(path, data)), len(data))


def one_shell():
    start = benchmark_clock_ns()
    child = PtyProcess.spawn([SH, "-c", "echo ready"], env=dict(os.environ, TERM="xterm-256color"),
                             dimensions=(24, 80))
    no_close_delay(child)
    said = b""
    while len(said) < 7:
        said += child.read(7 - len(said))
    assert child.wait() == 0
    elapsed = benchmark_clock_ns() - start
    child.close()
    assert said == b"ready\r\n"
    return elapsed


def shell_spawn(n):
    report("python-ptyprocess", "SHELL SPAWN", "latency", repeat(n, 5, one_shell) / n / 1e3, "us")


def one_pty_open():
    master, slave = os.openpty()
    termios.tcsetwinsize(master, (24, 80))
    os.close(slave)
    os.close(master)


def pty_open(n):
    for _ in range(warm(n, 20)):
        one_pty_open()
    start = benchmark_clock_ns()
    for _ in range(n):
        one_pty_open()
    report("python-os", "PTY OPEN", "latency", (benchmark_clock_ns() - start) / n / 1e3, "us")


def tty_ops(n):
    child = PtyProcess.spawn([SLEEP, "30"], dimensions=(24, 80))
    no_close_delay(child)
    fd = child.fd
    master, slave = os.openpty()
    for _ in range(1000):
        if os.tcgetpgrp(fd) == child.pid:
            break
        time.sleep(0.001)

    def raw_restore():
        saved = tty.setraw(fd, termios.TCSANOW)
        termios.tcsetattr(fd, termios.TCSANOW, saved)

    def win_size():
        assert termios.tcgetwinsize(fd)[0] == 24

    def pty_size():
        assert child.getwinsize()[1] == 80

    def is_tty():
        assert os.isatty(fd)

    def tty_name():
        assert os.ttyname(slave).startswith("/dev/tty")

    def foreground_group():
        assert os.tcgetpgrp(fd) == child.pid

    rows(n, [
        ("python-tty", "TTY OPS", "raw_restore", "ns", 1, raw_restore),
        ("python-termios", "TTY OPS", "win_size", "ns", 1, win_size),
        ("python-termios", "TTY OPS", "set_win_size", "ns", 1, lambda: termios.tcsetwinsize(fd, (24, 80))),
        ("python-ptyprocess", "TTY OPS", "pty_size", "ns", 1, pty_size),
        ("python-ptyprocess", "TTY OPS", "pty_resize", "ns", 1, lambda: child.setwinsize(24, 80)),
        ("python-os", "TTY OPS", "is_tty", "ns", 1, is_tty),
        ("python-os", "TTY OPS", "tty_name", "ns", 1, tty_name),
        ("python-os", "TTY OPS", "foreground_group", "ns", 1, foreground_group),
    ])
    child.kill(signal.SIGKILL)
    child.wait()
    child.close()
    os.close(master)
    os.close(slave)


def find_program(n):
    found = shutil.which(CAT)

    def hit():
        assert shutil.which(CAT) == found

    def miss():
        assert shutil.which(MISSING_PROGRAM) is None

    rows(n, [
        ("python-shutil", "FIND PROGRAM", "hit", "us", 1e3, hit),
        ("python-shutil", "FIND PROGRAM", "miss", "us", 1e3, miss),
    ])
    agree("python-shutil", "FIND PROGRAM", f"found:{found}", len(found), "bytes")


def environ(n):
    def inherit():
        env = os.environ.copy()
        env["TERM"] = "xterm-256color"
        env.pop("CONDUIT_BENCH_UNSET", None)
        return env

    inherited = len(inherit())

    def inherit_checked():
        assert len(inherit()) == inherited

    def only():
        assert len({"PATH": "/usr/bin:/bin", "HOME": "/nonexistent", "TERM": "xterm-256color"}) == 3

    rows(n, [
        ("python-os", "ENVIRON", "inherit", "us", 1e3, inherit_checked),
        ("python-os", "ENVIRON", "only", "us", 1e3, only),
    ])
    agree("python-os", "ENVIRON", "inherited_vars", inherited, "count")


def process_identity(n):
    child = subprocess.Popen([SLEEP, "30"], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                             stderr=subprocess.DEVNULL)
    rows(n, [("python-os", "PROCESS IDENTITY", "exists", "ns", 1, lambda: os.kill(child.pid, 0))])
    child.kill()
    child.wait()


# The child every side signals: `c-bench signal_child`; see coverage.c.
SIGNAL_CHILD = os.environ.get("BENCH_SIGNAL_CHILD")


def read_exact(fd, expected):
    got = b""
    while len(got) < len(expected):
        chunk = os.read(fd, len(expected) - len(got))
        assert chunk
        got += chunk
    assert got == expected, got


def signal_round_trip(n):
    """`Popen.send_signal` to the one pid, in a group of its own so the
    teardown reaches the descendant."""
    child = subprocess.Popen([SIGNAL_CHILD, "signal_child"], stdin=subprocess.DEVNULL,
                             stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, process_group=0)
    out = child.stdout.fileno()
    read_exact(out, b"r\n")

    def one():
        child.send_signal(signal.SIGUSR1)
        read_exact(out, b"x\n")

    for _ in range(warm(n, 20)):
        one()
    start = benchmark_clock_ns()
    for _ in range(n):
        one()
    report("python-subprocess", "SIGNAL", "round_trip", (benchmark_clock_ns() - start) / n / 1e3, "us")
    agree("python-subprocess", "SIGNAL", "acks", n, "count")
    os.killpg(child.pid, signal.SIGKILL)
    child.wait()
    child.stdout.close()


def one_extra_fds():
    """`os.posix_spawn` with the pipe's write end dup'd to 3: `subprocess`
    keeps a passed descriptor at its own number, so the standard library's
    way to put one at 3 is a spawn file action."""
    start = benchmark_clock_ns()
    r, w = os.pipe()
    devnull = os.open(os.devnull, os.O_RDWR)
    pid = os.posix_spawnp(SH, [SH, "-c", "echo x >&3"], os.environ, file_actions=[
        (os.POSIX_SPAWN_DUP2, devnull, 0), (os.POSIX_SPAWN_DUP2, devnull, 1),
        (os.POSIX_SPAWN_DUP2, devnull, 2), (os.POSIX_SPAWN_DUP2, w, 3)])
    os.close(w)
    os.close(devnull)
    got = b""
    while True:
        chunk = os.read(r, 8)
        if not chunk:
            break
        got += chunk
    _, status = os.waitpid(pid, 0)
    elapsed = benchmark_clock_ns() - start
    os.close(r)
    assert os.waitstatus_to_exitcode(status) == 0 and got == b"x\n", got
    return elapsed


def extra_fds(n):
    report("python-os-posix_spawn", "EXTRA FDS", "latency", repeat(n, 5, one_extra_fds) / n / 1e3, "us")
    agree("python-os-posix_spawn", "EXTRA FDS", "bytes_out", 2, "bytes")


WORKLOADS = {
    "exchange": lambda n, path, data: exchange(n, data),
    "collect": lambda n, path, data: collect(n, path, data),
    "input_writer": lambda n, path, data: input_writer(n, data),
    "read_available": lambda n, path, data: read_available(n, data),
    "try_wait": lambda n, path, data: try_wait(n),
    "reaper_wait": lambda n, path, data: reaper_wait(n),
    "expect": lambda n, path, data: expect(n),
    "proxy": lambda n, path, data: proxy(n, path, data),
    "shell_spawn": lambda n, path, data: shell_spawn(n),
    "pty_open": lambda n, path, data: pty_open(n),
    "tty_ops": lambda n, path, data: tty_ops(n),
    "find_program": lambda n, path, data: find_program(n),
    "environ": lambda n, path, data: environ(n),
    "process_identity": lambda n, path, data: process_identity(n),
    "signal": lambda n, path, data: signal_round_trip(n),
    "extra_fds": lambda n, path, data: extra_fds(n),
}
