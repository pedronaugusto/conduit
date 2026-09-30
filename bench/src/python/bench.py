#!/usr/bin/env python3
import os
import ctypes
import signal
import subprocess
import sys
import threading
import time
import tty

from ptyprocess import PtyProcess

LIBPROC = ctypes.CDLL(os.environ.get("BENCH_LIBPROC", "/usr/lib/libSystem.B.dylib"), use_errno=True)
LIBPROC.proc_listchildpids.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_int]
LIBPROC.proc_listchildpids.restype = ctypes.c_int


def report(side, workload, metric, value, unit):
    print(f"{side}\t{workload}\t{metric}\t{value:.6f}\t{unit}")


def one_spawn_wait():
    result = subprocess.run(
        [os.environ.get("BENCH_TRUE", "true")], stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )
    assert result.returncode == 0


def spawn_wait(n):
    for _ in range(0 if os.environ.get("SMOKE") == "1" else min(n, 10)):
        one_spawn_wait()
    start = time.perf_counter_ns()
    for _ in range(n):
        one_spawn_wait()
    report("python-subprocess", "SPAWN+WAIT", "latency", (time.perf_counter_ns() - start) / n / 1e3, "us")


def one_collect(arg):
    result = subprocess.run(
        [os.environ.get("BENCH_ECHO", "echo"), arg], stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
    )
    assert result.returncode == 0 and len(result.stdout) == 1025 and result.stdout[-1] == 10


def spawn_collect(n, data):
    assert len(data) == 1024
    arg = data.decode("ascii")
    for _ in range(0 if os.environ.get("SMOKE") == "1" else min(n, 5)):
        one_collect(arg)
    start = time.perf_counter_ns()
    for _ in range(n):
        one_collect(arg)
    report("python-subprocess", "SPAWN+COLLECT", "latency", (time.perf_counter_ns() - start) / n / 1e3, "us")


def expected_pty_bytes(data):
    return len(data)


def write_all(child, data):
    view = memoryview(data)
    while view:
        sent = child.write(view)
        assert sent > 0
        view = view[sent:]


def drain_exact(child, wanted):
    total = 0
    checksum = 0
    while total < wanted:
        chunk = child.read(min(65536, wanted - total))
        assert chunk
        checksum = (checksum + sum(chunk)) & ((1 << 64) - 1)
        total += len(chunk)
    return checksum


def open_cat():
    child = PtyProcess.spawn([os.fsencode(os.environ.get("BENCH_CAT", "cat"))], dimensions=(24, 80))
    tty.setraw(child.fd)
    return child


def one_pty(data):
    child = open_cat()
    try:
        write_all(child, data)
        assert drain_exact(child, expected_pty_bytes(data)) != 0
        child.kill(signal.SIGKILL)
        child.wait()
    finally:
        child.close(force=True)


def pty_spawn(n, data):
    assert len(data) == 1024
    for _ in range(0 if os.environ.get("SMOKE") == "1" else min(n, 3)):
        one_pty(data)
    start = time.perf_counter_ns()
    for _ in range(n):
        one_pty(data)
    report("python-ptyprocess", "PTY SPAWN", "latency", (time.perf_counter_ns() - start) / n / 1e3, "us")


def pty_throughput(data):
    child = open_cat()
    error = []
    def writer():
        try:
            write_all(child, data)
        except BaseException as exc:
            error.append(exc)
    thread = threading.Thread(target=writer)
    start = time.perf_counter_ns()
    thread.start()
    assert drain_exact(child, expected_pty_bytes(data)) != 0
    thread.join()
    elapsed = (time.perf_counter_ns() - start) / 1e9
    if error:
        raise error[0]
    child.kill(signal.SIGKILL)
    child.wait()
    child.close(force=True)
    report("python-ptyprocess", "PTY THROUGHPUT", "throughput", len(data) / elapsed / 1e6, "MB/s")


def one_wait_timeout():
    child = subprocess.Popen(
        [os.environ.get("BENCH_SLEEP", "sleep"), "0.01"], stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )
    start = time.perf_counter_ns()
    assert child.wait(timeout=1.0) == 0
    return time.perf_counter_ns() - start


def wait_timeout(n):
    for _ in range(0 if os.environ.get("SMOKE") == "1" else min(n, 3)):
        one_wait_timeout()
    total = sum(one_wait_timeout() for _ in range(n))
    report("python-subprocess", "WAIT-TIMEOUT", "overshoot", max(0.0, total / n / 1e3 - 10000.0), "us")


def child_pids(parent):
    for _ in range(1000):
        storage = (ctypes.c_int * 8)()
        count = LIBPROC.proc_listchildpids(parent, storage, ctypes.sizeof(storage))
        if count >= 2:
            return list(storage[:count])
        time.sleep(0.001)
    raise RuntimeError("tree did not start")


def confirm_gone(pids):
    for _ in range(1000):
        alive = []
        for pid in pids:
            try:
                os.kill(pid, 0)
                alive.append(pid)
            except ProcessLookupError:
                pass
        if not alive:
            return
        time.sleep(0.001)
    raise RuntimeError(f"descendants survived: {alive}")


def one_tree_kill():
    child = subprocess.Popen(
        [os.environ.get("BENCH_SH", "sh"), "-c", "sleep 30 & sleep 30 & wait"],
        stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL, start_new_session=True,
    )
    pids = child_pids(child.pid)
    start = time.perf_counter_ns()
    os.killpg(child.pid, signal.SIGKILL)
    child.wait()
    elapsed = time.perf_counter_ns() - start
    confirm_gone(pids)
    return elapsed


def tree_kill(n):
    for _ in range(0 if os.environ.get("SMOKE") == "1" else min(n, 2)):
        one_tree_kill()
    total = sum(one_tree_kill() for _ in range(n))
    report("python-subprocess+killpg", "TREE KILL", "latency", total / n / 1e6, "ms")


def main():
    if len(sys.argv) != 4:
        raise SystemExit("usage: bench.py WORKLOAD ITERATIONS INPUT")
    workload, n_text, path = sys.argv[1:]
    n = int(n_text)
    with open(path, "rb") as f:
        data = f.read()
    {
        "spawn_wait": lambda: spawn_wait(n),
        "spawn_collect": lambda: spawn_collect(n, data),
        "pty_spawn": lambda: pty_spawn(n, data),
        "pty_throughput": lambda: pty_throughput(data),
        "wait_timeout": lambda: wait_timeout(n),
        "tree_kill": lambda: tree_kill(n),
    }[workload]()


if __name__ == "__main__":
    main()
