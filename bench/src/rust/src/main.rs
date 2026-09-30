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
    let start = Instant::now();
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
    let start = Instant::now();
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
    child.kill().unwrap();
    child.wait().unwrap();
}

fn pty_spawn(n: usize, input: &[u8]) {
    assert_eq!(input.len(), 1024);
    for _ in 0..if std::env::var("SMOKE").as_deref() == Ok("1") { 0 } else { n.min(3) } { one_pty(input); }
    let start = Instant::now();
    for _ in 0..n { one_pty(input); }
    report("rust-portable-pty", "PTY SPAWN", "latency", start.elapsed().as_secs_f64() * 1e6 / n as f64, "us");
}

fn pty_throughput(input: &[u8]) {
    let (master, mut child) = open_cat();
    let mut reader = master.try_clone_reader().unwrap();
    let mut writer = master.take_writer().unwrap();
    let start = Instant::now();
    std::thread::scope(|scope| {
        let tx = scope.spawn(|| writer.write_all(input).unwrap());
        assert_ne!(drain_exact(&mut *reader, expected_pty_bytes(input)), 0);
        tx.join().unwrap();
    });
    let elapsed = start.elapsed().as_secs_f64();
    child.kill().unwrap();
    child.wait().unwrap();
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
    let start = Instant::now();
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
        _ => panic!("unknown workload"),
    }
}
