fn program(name: &str, fallback: &str) -> String {
    std::env::var(format!("BENCH_{name}")).unwrap_or_else(|_| fallback.into())
}
use portable_pty::{native_pty_system, CommandBuilder, PtySize};
use std::env;
use std::fs;
use std::io::{Read, Write};
use std::os::unix::process::CommandExt;
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

unsafe extern "C" {
    fn kill(pid: i32, sig: i32) -> i32;
    fn proc_listchildpids(ppid: i32, buffer: *mut std::ffi::c_void, buffersize: i32) -> i32;
}

fn report(side: &str, workload: &str, metric: &str, value: f64, unit: &str) {
    println!("{side}\t{workload}\t{metric}\t{value:.6}\t{unit}");
}

fn null_command(program: &str) -> Command {
    let mut cmd = Command::new(program);
    cmd.stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null());
    cmd
}

fn one_spawn_wait() {
    assert!(null_command(&program("TRUE", "true")).status().unwrap().success());
}

fn spawn_wait(n: usize) {
    for _ in 0..if std::env::var("SMOKE").as_deref() == Ok("1") { 0 } else { n.min(10) } { one_spawn_wait(); }
    let start = BenchmarkInstant::now();
    for _ in 0..n { one_spawn_wait(); }
    report("rust-std", "SPAWN+WAIT", "latency", start.elapsed().as_secs_f64() * 1e6 / n as f64, "us");
}

fn one_collect(arg: &str) {
    let out = Command::new(&program("ECHO", "echo"))
        .arg(arg)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .output().unwrap();
    assert!(out.status.success() && out.stdout.len() == 1025 && out.stdout[1024] == b'\n');
}

fn spawn_collect(n: usize, input: &[u8]) {
    assert_eq!(input.len(), 1024);
    let arg = std::str::from_utf8(input).unwrap();
    for _ in 0..if std::env::var("SMOKE").as_deref() == Ok("1") { 0 } else { n.min(5) } { one_collect(arg); }
    let start = BenchmarkInstant::now();
    for _ in 0..n { one_collect(arg); }
    report("rust-std", "SPAWN+COLLECT", "latency", start.elapsed().as_secs_f64() * 1e6 / n as f64, "us");
}

fn expected_pty_bytes(input: &[u8]) -> usize {
    input.len()
}

fn drain_exact(reader: &mut dyn Read, wanted: usize) -> u64 {
    let mut buf = [0u8; 64 * 1024];
    let mut total = 0usize;
    let mut sum = 0u64;
    while total < wanted {
        let take = buf.len().min(wanted - total);
        let got = reader.read(&mut buf[..take]).unwrap();
        assert!(got != 0, "early PTY EOF");
        for &b in &buf[..got] { sum = sum.wrapping_add(b as u64); }
        total += got;
    }
    sum
}

fn open_cat() -> (Box<dyn portable_pty::MasterPty + Send>, Box<dyn portable_pty::Child + Send>) {
    let pair = native_pty_system().openpty(PtySize {
        rows: 24, cols: 80, pixel_width: 0, pixel_height: 0,
    }).unwrap();
    let fd = pair.master.as_raw_fd().unwrap();
    unsafe {
        let mut term: libc::termios = std::mem::zeroed();
        assert_eq!(libc::tcgetattr(fd, &mut term), 0);
        libc::cfmakeraw(&mut term);
        assert_eq!(libc::tcsetattr(fd, libc::TCSANOW, &term), 0);
    }
    let child = pair.slave.spawn_command(CommandBuilder::new(&program("CAT", "cat"))).unwrap();
    drop(pair.slave);
    (pair.master, child)
}

fn one_pty(input: &[u8]) {
    let (master, mut child) = open_cat();
    let mut reader = master.try_clone_reader().unwrap();
    let mut writer = master.take_writer().unwrap();
    writer.write_all(input).unwrap();
    assert_ne!(drain_exact(&mut *reader, expected_pty_bytes(input)), 0);
    kill_and_wait(&mut *child);
}

/// SIGKILL to the child and a reap, as the C and Go sides end it.
/// portable-pty's own `kill` sends SIGHUP and, as the child is never gone at
/// its first look, sleeps 50 ms before looking again: a wait no other side
/// pays, so the round trip does not use it.
fn kill_and_wait(child: &mut (dyn portable_pty::Child + Send)) {
    let pid = child.process_id().expect("child pid") as i32;
    assert_eq!(unsafe { kill(pid, 9) }, 0);
    child.wait().unwrap();
}

fn pty_spawn(n: usize, input: &[u8]) {
    assert_eq!(input.len(), 1024);
    for _ in 0..if std::env::var("SMOKE").as_deref() == Ok("1") { 0 } else { n.min(3) } { one_pty(input); }
    let start = BenchmarkInstant::now();
    for _ in 0..n { one_pty(input); }
    report("rust-portable-pty", "PTY SPAWN", "latency", start.elapsed().as_secs_f64() * 1e6 / n as f64, "us");
}

fn pty_throughput(input: &[u8]) {
    let (master, mut child) = open_cat();
    let mut reader = master.try_clone_reader().unwrap();
    let mut writer = master.take_writer().unwrap();
    let start = BenchmarkInstant::now();
    std::thread::scope(|scope| {
        let tx = scope.spawn(|| writer.write_all(input).unwrap());
        assert_ne!(drain_exact(&mut *reader, expected_pty_bytes(input)), 0);
        tx.join().unwrap();
    });
    let elapsed = start.elapsed().as_secs_f64();
    kill_and_wait(&mut *child);
    report("rust-portable-pty", "PTY THROUGHPUT", "throughput", input.len() as f64 / elapsed / 1e6, "MB/s");
}

fn child_pids(parent: u32) -> Vec<i32> {
    for _ in 0..1000 {
        let mut pids = [0i32; 8];
        let count = unsafe {
            proc_listchildpids(parent as i32, pids.as_mut_ptr().cast(), std::mem::size_of_val(&pids) as i32)
        };
        if count >= 2 { return pids[..count as usize].to_vec(); }
        std::thread::sleep(Duration::from_millis(1));
    }
    panic!("tree did not start");
}

fn confirm_gone(pids: &[i32]) {
    for _ in 0..1000 {
        if pids.iter().all(|&pid| unsafe { kill(pid, 0) } != 0) { return; }
        std::thread::sleep(Duration::from_millis(1));
    }
    panic!("descendant survived");
}

fn one_tree_kill() -> f64 {
    let mut cmd = null_command(&program("SH", "sh"));
    cmd.args(["-c", "sleep 30 & sleep 30 & wait"]);
    cmd.process_group(0);
    let mut child = cmd.spawn().unwrap();
    let pids = child_pids(child.id());
    let start = BenchmarkInstant::now();
    assert_eq!(unsafe { kill(-(child.id() as i32), 9) }, 0);
    child.wait().unwrap();
    let elapsed = start.elapsed().as_secs_f64();
    confirm_gone(&pids);
    elapsed
}

fn tree_kill(n: usize) {
    for _ in 0..if std::env::var("SMOKE").as_deref() == Ok("1") { 0 } else { n.min(2) } { one_tree_kill(); }
    let mut total = 0.0;
    for _ in 0..n { total += one_tree_kill(); }
    report("rust-std+killpg", "TREE KILL", "latency", total * 1e3 / n as f64, "ms");
}

fn main() {
    let args: Vec<String> = env::args().collect();
    assert_eq!(args.len(), 4, "usage: rust-bench WORKLOAD ITERATIONS INPUT");
    let n: usize = args[2].parse().unwrap();
    let input = fs::read(&args[3]).unwrap();
    match args[1].as_str() {
        "spawn_wait" => spawn_wait(n),
        "spawn_collect" => spawn_collect(n, &input),
        "pty_spawn" => pty_spawn(n, &input),
        "pty_throughput" => pty_throughput(&input),
        "wait_timeout" => println!("rust-std\tWAIT-TIMEOUT\tovershoot\tn/a\tus"),
        "tree_kill" => tree_kill(n),
        "exchange" => exchange(n, &input),
        "collect" => collect(n, &args[3], &input),
        "input_writer" => input_writer(n, &input),
        "try_wait" => try_wait(n),
        "reaper_wait" => reaper_wait(n),
        "proxy" => proxy(n, &args[3], &input),
        "shell_spawn" => shell_spawn(n),
        "pty_open" => pty_open(n),
        "tty_ops" => tty_ops(n),
        "environ" => environ(n),
        "signal" => signal_round_trip(n),
        "extra_fds" => extra_fds(n),
        _ => panic!("unknown workload"),
    }
}

// Runtime smoke mode never starts a performance clock.
struct BenchmarkInstant(Option<Instant>);
impl BenchmarkInstant {
    fn now() -> Self {
        Self(if std::env::var("SMOKE").as_deref() == Ok("1") { None } else { Some(Instant::now()) })
    }
    fn elapsed(&self) -> std::time::Duration {
        self.0.map_or(std::time::Duration::from_nanos(1), |start| start.elapsed())
    }
}

// ------------------------------------------------------------------------
// The rest of conduit's operations, where Rust's standard library or
// portable-pty has the same one.

fn smoke() -> bool {
    std::env::var("SMOKE").as_deref() == Ok("1")
}

fn warm(n: usize, limit: usize) -> usize {
    if smoke() { 0 } else { n.min(limit) }
}

fn agree(side: &str, workload: &str, metric: &str, value: usize, unit: &str) {
    println!("{side}\t{workload}\t{metric}\t{value}\t{unit}");
}

/// Per-operation latency and the bytes it moved per second.
fn size_rows(side: &str, workload: &str, n: usize, total: f64, bytes: usize) {
    report(side, workload, "latency", total * 1e6 / n as f64, "us");
    report(side, workload, "throughput", (bytes * n) as f64 / total / 1e6, "MB/s");
    agree(side, workload, "bytes_out", bytes, "bytes");
}

fn piped_cat() -> std::process::Child {
    Command::new(program("CAT", "cat"))
        .stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::null())
        .spawn().unwrap()
}

/// `cat` given the input on a thread, as the std documentation of
/// `wait_with_output` writes it, and its output collected: spawn to reap.
fn one_exchange(input: &[u8]) -> f64 {
    let start = BenchmarkInstant::now();
    let mut child = piped_cat();
    let mut stdin = child.stdin.take().unwrap();
    let out = std::thread::scope(|scope| {
        scope.spawn(move || { let _ = stdin.write_all(input); });
        child.wait_with_output().unwrap()
    });
    let elapsed = start.elapsed().as_secs_f64();
    assert!(out.status.success() && out.stdout == input);
    elapsed
}

fn exchange(n: usize, input: &[u8]) {
    for _ in 0..warm(n, 3) { one_exchange(input); }
    let total: f64 = (0..n).map(|_| one_exchange(input)).sum();
    size_rows("rust-std", "EXCHANGE", n, total, input.len());
}

fn one_collect_file(path: &str, input: &[u8]) -> f64 {
    let start = BenchmarkInstant::now();
    let out = Command::new(program("CAT", "cat")).arg(path)
        .stdin(Stdio::null()).stdout(Stdio::piped()).stderr(Stdio::null())
        .output().unwrap();
    let elapsed = start.elapsed().as_secs_f64();
    assert!(out.status.success() && out.stdout == input);
    elapsed
}

fn collect(n: usize, path: &str, input: &[u8]) {
    for _ in 0..warm(n, 3) { one_collect_file(path, input); }
    let total: f64 = (0..n).map(|_| one_collect_file(path, input)).sum();
    size_rows("rust-std", "COLLECT", n, total, input.len());
}

/// The input queued 64 bytes at a time on a channel a writer thread empties
/// into the pipe, then closed, while `cat`'s output is collected.
fn one_input_writer(input: &[u8]) -> f64 {
    let start = BenchmarkInstant::now();
    let mut child = piped_cat();
    let mut stdin = child.stdin.take().unwrap();
    let (tx, rx) = std::sync::mpsc::channel::<Vec<u8>>();
    let writer = std::thread::spawn(move || {
        for chunk in rx { stdin.write_all(&chunk).unwrap(); }
    });
    for chunk in input.chunks(64) { tx.send(chunk.to_vec()).unwrap(); }
    drop(tx);
    let out = child.wait_with_output().unwrap();
    writer.join().unwrap();
    let elapsed = start.elapsed().as_secs_f64();
    assert!(out.status.success() && out.stdout == input);
    elapsed
}

fn input_writer(n: usize, input: &[u8]) {
    for _ in 0..warm(n, 2) { one_input_writer(input); }
    let total: f64 = (0..n).map(|_| one_input_writer(input)).sum();
    size_rows("rust-std", "INPUT WRITER", n, total, input.len());
}

fn try_wait(n: usize) {
    let mut child = null_command(&program("SLEEP", "sleep")).arg("30").spawn().unwrap();
    for _ in 0..warm(n, 1000) { assert!(child.try_wait().unwrap().is_none()); }
    let start = BenchmarkInstant::now();
    for _ in 0..n { assert!(child.try_wait().unwrap().is_none()); }
    let elapsed = start.elapsed().as_secs_f64();
    child.kill().unwrap();
    child.wait().unwrap();
    report("rust-std", "TRY WAIT", "call", elapsed * 1e9 / n as f64, "ns");
}

/// `true` spawned and its wait put on a thread of its own, joined.
fn one_reaper_wait() -> f64 {
    let start = BenchmarkInstant::now();
    let mut child = null_command(&program("TRUE", "true")).spawn().unwrap();
    let status = std::thread::spawn(move || child.wait().unwrap()).join().unwrap();
    let elapsed = start.elapsed().as_secs_f64();
    assert!(status.success());
    elapsed
}

fn reaper_wait(n: usize) {
    for _ in 0..warm(n, 10) { one_reaper_wait(); }
    let total: f64 = (0..n).map(|_| one_reaper_wait()).sum();
    report("rust-std", "REAPER WAIT", "latency", total * 1e6 / n as f64, "us");
}

fn pty_size() -> PtySize {
    PtySize { rows: 24, cols: 80, pixel_width: 0, pixel_height: 0 }
}

/// Copy to the end, which a pair whose child has gone reports as EIO.
fn copy_to_end(from: &mut dyn Read, to: &mut dyn Write) {
    match std::io::copy(from, to) {
        Ok(_) => {}
        Err(e) if e.raw_os_error() == Some(libc::EIO) => {}
        Err(e) => panic!("copy: {e}"),
    }
}

/// `cat FILE` on a pair in its default mode, both directions moved with
/// `std::io::copy` (the master to a pipe another thread drains, and an input
/// pipe that never speaks to the master): spawn to every byte out and reap.
fn one_proxy(path: &str, input: &[u8]) -> f64 {
    let (mut in_r, in_w) = std::io::pipe().unwrap();
    let (mut out_r, mut out_w) = std::io::pipe().unwrap();
    let pair = native_pty_system().openpty(pty_size()).unwrap();
    let start = BenchmarkInstant::now();
    let drain = std::thread::spawn(move || {
        let mut buf = vec![0u8; 64 * 1024];
        let (mut total, mut returns) = (0usize, 0usize);
        loop {
            let got = out_r.read(&mut buf).unwrap();
            if got == 0 { return (total, returns); }
            total += got;
            returns += buf[..got].iter().filter(|&&b| b == b'\r').count();
        }
    });
    let mut cmd = CommandBuilder::new(program("CAT", "cat"));
    cmd.arg(path);
    let mut child = pair.slave.spawn_command(cmd).unwrap();
    drop(pair.slave);
    let mut reader = pair.master.try_clone_reader().unwrap();
    let mut writer = pair.master.take_writer().unwrap();
    let forward = std::thread::spawn(move || copy_to_end(&mut in_r, &mut writer));
    copy_to_end(&mut reader, &mut out_w);
    drop(out_w);
    let (total, returns) = drain.join().unwrap();
    let status = child.wait().unwrap();
    let elapsed = start.elapsed().as_secs_f64();
    drop(in_w);
    forward.join().unwrap();
    let newlines = input.iter().filter(|&&b| b == b'\n').count();
    assert!(status.success() && total - returns == input.len() && returns >= newlines);
    elapsed
}

fn proxy(n: usize, path: &str, input: &[u8]) {
    for _ in 0..warm(n, 1) { one_proxy(path, input); }
    let total: f64 = (0..n).map(|_| one_proxy(path, input)).sum();
    size_rows("rust-portable-pty", "PROXY", n, total, input.len());
}

/// `sh -c 'echo ready'` on a new pair with TERM set and a controlling
/// terminal: spawn to its line read and reap.
fn one_shell() -> f64 {
    let start = BenchmarkInstant::now();
    let pair = native_pty_system().openpty(pty_size()).unwrap();
    let mut cmd = CommandBuilder::new(program("SH", "sh"));
    cmd.args(["-c", "echo ready"]);
    cmd.env("TERM", "xterm-256color");
    let mut child = pair.slave.spawn_command(cmd).unwrap();
    drop(pair.slave);
    let mut reader = pair.master.try_clone_reader().unwrap();
    let mut said = [0u8; 7];
    reader.read_exact(&mut said).unwrap();
    let status = child.wait().unwrap();
    let elapsed = start.elapsed().as_secs_f64();
    assert!(status.success() && &said == b"ready\r\n");
    elapsed
}

fn shell_spawn(n: usize) {
    for _ in 0..warm(n, 5) { one_shell(); }
    let total: f64 = (0..n).map(|_| one_shell()).sum();
    report("rust-portable-pty", "SHELL SPAWN", "latency", total * 1e6 / n as f64, "us");
}

fn pty_open(n: usize) {
    let system = native_pty_system();
    for _ in 0..warm(n, 20) { drop(system.openpty(pty_size()).unwrap()); }
    let start = BenchmarkInstant::now();
    for _ in 0..n { drop(system.openpty(pty_size()).unwrap()); }
    report("rust-portable-pty", "PTY OPEN", "latency", start.elapsed().as_secs_f64() * 1e6 / n as f64, "us");
}

fn tty_ops(n: usize) {
    use std::io::IsTerminal;
    use std::os::fd::FromRawFd;
    let pair = native_pty_system().openpty(pty_size()).unwrap();
    let mut cmd = CommandBuilder::new(program("SLEEP", "sleep"));
    cmd.arg("30");
    let mut child = pair.slave.spawn_command(cmd).unwrap();
    let master = pair.master;
    let fd = master.as_raw_fd().unwrap();
    let file = std::mem::ManuallyDrop::new(unsafe { std::fs::File::from_raw_fd(fd) });
    let rounds = if smoke() { 1 } else { 2 };
    for round in 0..rounds {
        let timed = round + 1 == rounds;
        let start = BenchmarkInstant::now();
        for _ in 0..n { assert_eq!(master.get_size().unwrap().rows, 24); }
        if timed { report("rust-portable-pty", "TTY OPS", "pty_size", start.elapsed().as_secs_f64() * 1e9 / n as f64, "ns"); }
        let start = BenchmarkInstant::now();
        for _ in 0..n { master.resize(pty_size()).unwrap(); }
        if timed { report("rust-portable-pty", "TTY OPS", "pty_resize", start.elapsed().as_secs_f64() * 1e9 / n as f64, "ns"); }
        let start = BenchmarkInstant::now();
        for _ in 0..n { assert!(file.is_terminal()); }
        if timed { report("rust-std", "TTY OPS", "is_tty", start.elapsed().as_secs_f64() * 1e9 / n as f64, "ns"); }
    }
    kill_and_wait(&mut *child);
    drop(pair.slave);
}

fn environ(n: usize) {
    use std::collections::HashMap;
    use std::ffi::OsString;
    let inherit = || {
        let mut map: HashMap<OsString, OsString> = std::env::vars_os().collect();
        map.insert("TERM".into(), "xterm-256color".into());
        map.remove(std::ffi::OsStr::new("CONDUIT_BENCH_UNSET"));
        map
    };
    let only = || -> HashMap<OsString, OsString> {
        HashMap::from([
            ("PATH".into(), "/usr/bin:/bin".into()),
            ("HOME".into(), "/nonexistent".into()),
            ("TERM".into(), "xterm-256color".into()),
        ])
    };
    let inherited = inherit().len();
    let rounds = if smoke() { 1 } else { 2 };
    for round in 0..rounds {
        let timed = round + 1 == rounds;
        let start = BenchmarkInstant::now();
        for _ in 0..n { assert_eq!(inherit().len(), inherited); }
        if timed { report("rust-std", "ENVIRON", "inherit", start.elapsed().as_secs_f64() * 1e6 / n as f64, "us"); }
        let start = BenchmarkInstant::now();
        for _ in 0..n { assert_eq!(only().len(), 3); }
        if timed { report("rust-std", "ENVIRON", "only", start.elapsed().as_secs_f64() * 1e6 / n as f64, "us"); }
    }
    agree("rust-std", "ENVIRON", "inherited_vars", inherited, "count");
}

// ------------------------------------------------------------------------
// Signals and descriptors beyond the standard three.

/// The child every side signals: `c-bench signal_child`; see coverage.c.
fn signal_child() -> String {
    std::env::var("BENCH_SIGNAL_CHILD").expect("BENCH_SIGNAL_CHILD unset")
}

fn read_exact(from: &mut dyn Read, expected: &[u8]) {
    let mut buffer = vec![0u8; expected.len()];
    from.read_exact(&mut buffer).unwrap();
    assert_eq!(buffer, expected);
}

/// std has only `Child::kill` (SIGKILL), so any other signal is `kill(2)`
/// through libc, to the one pid, in a group of its own so the teardown
/// reaches the descendant.
fn signal_round_trip(n: usize) {
    let mut child = Command::new(signal_child())
        .arg("signal_child")
        .stdin(Stdio::null()).stdout(Stdio::piped()).stderr(Stdio::null())
        .process_group(0)
        .spawn().unwrap();
    let pid = child.id() as i32;
    let mut out = child.stdout.take().unwrap();
    read_exact(&mut out, b"r\n");
    let mut one = || {
        assert_eq!(unsafe { libc::kill(pid, libc::SIGUSR1) }, 0);
        read_exact(&mut out, b"x\n");
    };
    for _ in 0..warm(n, 20) {
        one();
    }
    let start = BenchmarkInstant::now();
    for _ in 0..n {
        one();
    }
    report("rust-libc-kill", "SIGNAL", "round_trip", start.elapsed().as_secs_f64() * 1e6 / n as f64, "us");
    agree("rust-libc-kill", "SIGNAL", "acks", n, "count");
    unsafe { libc::kill(-pid, libc::SIGKILL) };
    child.wait().unwrap();
}

/// std has no descriptor mapping; `pre_exec` with `dup2` is what the
/// command-fds crate does, and it sends std to its fork path.
fn one_extra_fds() -> f64 {
    let start = BenchmarkInstant::now();
    let mut ends = [0i32; 2];
    assert_eq!(unsafe { libc::pipe(ends.as_mut_ptr()) }, 0);
    for fd in ends {
        unsafe { libc::fcntl(fd, libc::F_SETFD, libc::FD_CLOEXEC) };
    }
    let write_end = ends[1];
    let mut cmd = null_command(&program("SH", "sh"));
    cmd.args(["-c", "echo x >&3"]);
    unsafe {
        cmd.pre_exec(move || {
            if write_end == 3 {
                if libc::fcntl(3, libc::F_SETFD, 0) != 0 {
                    return Err(std::io::Error::last_os_error());
                }
            } else if libc::dup2(write_end, 3) != 3 {
                return Err(std::io::Error::last_os_error());
            }
            Ok(())
        });
    }
    let mut child = cmd.spawn().unwrap();
    unsafe { libc::close(write_end) };
    let mut reader = unsafe { <fs::File as std::os::fd::FromRawFd>::from_raw_fd(ends[0]) };
    let mut got = Vec::new();
    reader.read_to_end(&mut got).unwrap();
    assert!(child.wait().unwrap().success());
    let elapsed = start.elapsed().as_secs_f64();
    assert_eq!(got, b"x\n");
    elapsed
}

fn extra_fds(n: usize) {
    for _ in 0..warm(n, 5) {
        one_extra_fds();
    }
    let total: f64 = (0..n).map(|_| one_extra_fds()).sum();
    report("rust-std-pre-exec", "EXTRA FDS", "latency", total * 1e6 / n as f64, "us");
    agree("rust-std-pre-exec", "EXTRA FDS", "bytes_out", 2, "bytes");
}
