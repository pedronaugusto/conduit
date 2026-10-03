package main

// The rest of conduit's operations, where os/exec, creack/pty or x/term has
// the same one.

import (
	"bytes"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"strings"
	"syscall"

	"github.com/creack/pty"
	"golang.org/x/term"
)

func smoke() bool { return os.Getenv("SMOKE") == "1" }

func agree(side, workload, metric string, value int, unit string) {
	fmt.Printf("%s\t%s\t%s\t%d\t%s\n", side, workload, metric, value, unit)
}

// Per-operation latency and the bytes it moved per second.
func sizeRows(side, workload string, n int, totalNs float64, size int) {
	report(side, workload, "latency", totalNs/float64(n)/1e3, "us")
	report(side, workload, "throughput", float64(size*n)/totalNs*1e3, "MB/s")
	agree(side, workload, "bytes_out", size, "bytes")
}

// `cat` given the input by os/exec's own copier and its output collected.
func oneExchange(input []byte) float64 {
	start := benchmarkNow()
	cmd := exec.Command(program("CAT", "cat"))
	cmd.Stdin = bytes.NewReader(input)
	cmd.Stderr = nil
	out, err := cmd.Output()
	elapsed := float64(benchmarkSince(start).Nanoseconds())
	if err != nil || !bytes.Equal(out, input) {
		panic("bad exchange")
	}
	return elapsed
}

func exchange(n int, input []byte) {
	for i := 0; i < warm(n, 3); i++ {
		oneExchange(input)
	}
	var total float64
	for i := 0; i < n; i++ {
		total += oneExchange(input)
	}
	sizeRows("go-os-exec", "EXCHANGE", n, total, len(input))
}

func oneCollectFile(path string, input []byte) float64 {
	start := benchmarkNow()
	cmd := exec.Command(program("CAT", "cat"), path)
	cmd.Stdin, cmd.Stderr = nil, nil
	out, err := cmd.Output()
	elapsed := float64(benchmarkSince(start).Nanoseconds())
	if err != nil || !bytes.Equal(out, input) {
		panic("bad collect")
	}
	return elapsed
}

func collect(n int, path string, input []byte) {
	for i := 0; i < warm(n, 3); i++ {
		oneCollectFile(path, input)
	}
	var total float64
	for i := 0; i < n; i++ {
		total += oneCollectFile(path, input)
	}
	sizeRows("go-os-exec", "COLLECT", n, total, len(input))
}

// The input queued 64 bytes at a time on a channel a goroutine empties into
// StdinPipe, then closed, while `cat`'s output is collected.
func oneInputWriter(input []byte) float64 {
	start := benchmarkNow()
	cmd := exec.Command(program("CAT", "cat"))
	cmd.Stderr = nil
	stdin, err := cmd.StdinPipe()
	if err != nil {
		panic(err)
	}
	var out bytes.Buffer
	cmd.Stdout = &out
	if err := cmd.Start(); err != nil {
		panic(err)
	}
	queue := make(chan []byte, len(input)/64+1)
	done := make(chan error, 1)
	go func() {
		var failed error
		for chunk := range queue {
			if _, err := stdin.Write(chunk); err != nil && failed == nil {
				failed = err
			}
		}
		done <- errors.Join(failed, stdin.Close())
	}()
	for at := 0; at < len(input); at += 64 {
		queue <- append([]byte(nil), input[at:min(len(input), at+64)]...)
	}
	close(queue)
	if err := <-done; err != nil {
		panic(err)
	}
	if err := cmd.Wait(); err != nil {
		panic(err)
	}
	elapsed := float64(benchmarkSince(start).Nanoseconds())
	if !bytes.Equal(out.Bytes(), input) {
		panic("bad input writer output")
	}
	return elapsed
}

func inputWriter(n int, input []byte) {
	for i := 0; i < warm(n, 2); i++ {
		oneInputWriter(input)
	}
	var total float64
	for i := 0; i < n; i++ {
		total += oneInputWriter(input)
	}
	sizeRows("go-os-exec", "INPUT WRITER", n, total, len(input))
}

// What an ended `echo` left in a pipe, read without waiting until nothing is
// left: a non-blocking descriptor read to EAGAIN or end of file.
func oneReadAvailable(arg string) float64 {
	r, w, err := os.Pipe()
	if err != nil {
		panic(err)
	}
	cmd := exec.Command(program("ECHO", "echo"), arg)
	cmd.Stdin, cmd.Stdout, cmd.Stderr = nil, w, nil
	if err := cmd.Start(); err != nil {
		panic(err)
	}
	w.Close()
	if err := cmd.Wait(); err != nil {
		panic(err)
	}
	conn, err := r.SyscallConn()
	if err != nil {
		panic(err)
	}
	buf := make([]byte, 4096)
	total := 0
	start := benchmarkNow()
	conn.Control(func(fd uintptr) {
		if err := syscall.SetNonblock(int(fd), true); err != nil {
			panic(err)
		}
		for {
			got, err := syscall.Read(int(fd), buf)
			if err == syscall.EAGAIN || got == 0 {
				return
			}
			if err != nil {
				panic(err)
			}
			total += got
		}
	})
	elapsed := float64(benchmarkSince(start).Nanoseconds())
	r.Close()
	if total != len(arg)+1 {
		panic("bad read available")
	}
	return elapsed
}

func readAvailable(n int, input []byte) {
	arg := string(input)
	for i := 0; i < warm(n, 5); i++ {
		oneReadAvailable(arg)
	}
	var total float64
	for i := 0; i < n; i++ {
		total += oneReadAvailable(arg)
	}
	report("go-syscall-nonblock", "READ AVAILABLE", "latency", total/float64(n)/1e3, "us")
	agree("go-syscall-nonblock", "READ AVAILABLE", "bytes_out", len(arg)+1, "bytes")
}

// `true` started and its wait put on a goroutine of its own, joined.
func oneReaperWait() float64 {
	start := benchmarkNow()
	cmd := exec.Command(program("TRUE", "true"))
	cmd.Stdin, cmd.Stdout, cmd.Stderr = nil, nil, nil
	if err := cmd.Start(); err != nil {
		panic(err)
	}
	done := make(chan error, 1)
	go func() { done <- cmd.Wait() }()
	err := <-done
	elapsed := float64(benchmarkSince(start).Nanoseconds())
	if err != nil {
		panic(err)
	}
	return elapsed
}

func reaperWait(n int) {
	for i := 0; i < warm(n, 10); i++ {
		oneReaperWait()
	}
	var total float64
	for i := 0; i < n; i++ {
		total += oneReaperWait()
	}
	report("go-os-exec", "REAPER WAIT", "latency", total/float64(n)/1e3, "us")
}

func copyToEnd(to io.Writer, from io.Reader) {
	if _, err := io.Copy(to, from); err != nil && !errors.Is(err, syscall.EIO) {
		panic(err)
	}
}

// `cat FILE` on a pair in its default mode, moved as creack/pty's README
// does it: io.Copy each way (the master to a pipe another goroutine drains,
// and an input pipe that never speaks to the master). Spawn to every byte
// out and reap.
func oneProxy(path string, input []byte) float64 {
	inR, inW, err := os.Pipe()
	if err != nil {
		panic(err)
	}
	outR, outW, err := os.Pipe()
	if err != nil {
		panic(err)
	}
	start := benchmarkNow()
	type counts struct{ total, returns int }
	drained := make(chan counts, 1)
	go func() {
		buf := make([]byte, 64*1024)
		var c counts
		for {
			got, err := outR.Read(buf)
			c.total += got
			c.returns += bytes.Count(buf[:got], []byte{'\r'})
			if err == io.EOF {
				drained <- c
				return
			}
			if err != nil {
				panic(err)
			}
		}
	}()
	cmd := exec.Command(program("CAT", "cat"), path)
	ptmx, err := pty.StartWithSize(cmd, &pty.Winsize{Rows: 24, Cols: 80})
	if err != nil {
		panic(err)
	}
	forwarded := make(chan struct{})
	go func() { copyToEnd(ptmx, inR); close(forwarded) }()
	copyToEnd(outW, ptmx)
	outW.Close()
	got := <-drained
	if err := cmd.Wait(); err != nil {
		panic(err)
	}
	elapsed := float64(benchmarkSince(start).Nanoseconds())
	inW.Close()
	<-forwarded
	ptmx.Close()
	inR.Close()
	outR.Close()
	if got.total-got.returns != len(input) || got.returns < bytes.Count(input, []byte{'\n'}) {
		panic("bad proxy output")
	}
	return elapsed
}

func proxy(n int, path string, input []byte) {
	for i := 0; i < warm(n, 1); i++ {
		oneProxy(path, input)
	}
	var total float64
	for i := 0; i < n; i++ {
		total += oneProxy(path, input)
	}
	sizeRows("go-creack-pty", "PROXY", n, total, len(input))
}

// `sh -c 'echo ready'` on a new pair with TERM set and a controlling
// terminal: spawn to its line read and reap.
func oneShell() float64 {
	start := benchmarkNow()
	cmd := exec.Command(program("SH", "sh"), "-c", "echo ready")
	cmd.Env = append(os.Environ(), "TERM=xterm-256color")
	ptmx, err := pty.StartWithSize(cmd, &pty.Winsize{Rows: 24, Cols: 80})
	if err != nil {
		panic(err)
	}
	said := make([]byte, 7)
	if _, err := io.ReadFull(ptmx, said); err != nil {
		panic(err)
	}
	if err := cmd.Wait(); err != nil {
		panic(err)
	}
	elapsed := float64(benchmarkSince(start).Nanoseconds())
	ptmx.Close()
	if string(said) != "ready\r\n" {
		panic("bad shell output")
	}
	return elapsed
}

func shellSpawn(n int) {
	for i := 0; i < warm(n, 5); i++ {
		oneShell()
	}
	var total float64
	for i := 0; i < n; i++ {
		total += oneShell()
	}
	report("go-creack-pty", "SHELL SPAWN", "latency", total/float64(n)/1e3, "us")
}

// pty.Open with the window size conduit and openpty set at opening.
func onePtyOpen() {
	ptmx, tty, err := pty.Open()
	if err != nil {
		panic(err)
	}
	if err := pty.Setsize(ptmx, &pty.Winsize{Rows: 24, Cols: 80}); err != nil {
		panic(err)
	}
	tty.Close()
	ptmx.Close()
}

func ptyOpen(n int) {
	for i := 0; i < warm(n, 20); i++ {
		onePtyOpen()
	}
	start := benchmarkNow()
	for i := 0; i < n; i++ {
		onePtyOpen()
	}
	report("go-creack-pty", "PTY OPEN", "latency", float64(benchmarkSince(start).Nanoseconds())/float64(n)/1e3, "us")
}

func ttyOps(n int) {
	cmd := exec.Command(program("SLEEP", "sleep"), "30")
	ptmx, err := pty.StartWithSize(cmd, &pty.Winsize{Rows: 24, Cols: 80})
	if err != nil {
		panic(err)
	}
	fd := int(ptmx.Fd())
	size := &pty.Winsize{Rows: 24, Cols: 80}
	rounds := 2
	if smoke() {
		rounds = 1
	}
	row := func(side, metric string, timed bool, op func()) {
		start := benchmarkNow()
		for i := 0; i < n; i++ {
			op()
		}
		if timed {
			report(side, "TTY OPS", metric, float64(benchmarkSince(start).Nanoseconds())/float64(n), "ns")
		}
	}
	for round := 0; round < rounds; round++ {
		timed := round+1 == rounds
		row("go-x-term", "raw_restore", timed, func() {
			saved, err := term.MakeRaw(fd)
			if err != nil {
				panic(err)
			}
			if err := term.Restore(fd, saved); err != nil {
				panic(err)
			}
		})
		row("go-x-term", "win_size", timed, func() {
			if _, rows, err := term.GetSize(fd); err != nil || rows != 24 {
				panic("bad size")
			}
		})
		row("go-creack-pty", "pty_size", timed, func() {
			if got, err := pty.GetsizeFull(ptmx); err != nil || got.Cols != 80 {
				panic("bad size")
			}
		})
		row("go-creack-pty", "pty_resize", timed, func() {
			if err := pty.Setsize(ptmx, size); err != nil {
				panic(err)
			}
		})
		row("go-x-term", "is_tty", timed, func() {
			if !term.IsTerminal(fd) {
				panic("not a terminal")
			}
		})
	}
	cmd.Process.Kill()
	cmd.Wait()
	ptmx.Close()
}

const missingProgram = "conduit-bench-no-such-program"

func findProgram(n int) {
	found, err := exec.LookPath(program("CAT", "cat"))
	if err != nil {
		panic(err)
	}
	rounds := 2
	if smoke() {
		rounds = 1
	}
	for round := 0; round < rounds; round++ {
		timed := round+1 == rounds
		start := benchmarkNow()
		for i := 0; i < n; i++ {
			if path, err := exec.LookPath(program("CAT", "cat")); err != nil || path != found {
				panic("unstable lookup")
			}
		}
		if timed {
			report("go-os-exec", "FIND PROGRAM", "hit", float64(benchmarkSince(start).Nanoseconds())/float64(n)/1e3, "us")
		}
		start = benchmarkNow()
		for i := 0; i < n; i++ {
			if _, err := exec.LookPath(missingProgram); err == nil {
				panic("found a missing program")
			}
		}
		if timed {
			report("go-os-exec", "FIND PROGRAM", "miss", float64(benchmarkSince(start).Nanoseconds())/float64(n)/1e3, "us")
		}
	}
	fmt.Printf("go-os-exec\tFIND PROGRAM\tfound:%s\t%d\tbytes\n", found, len(found))
}

func environ(n int) {
	inherit := func() map[string]string {
		m := make(map[string]string)
		for _, kv := range os.Environ() {
			if k, v, ok := strings.Cut(kv, "="); ok {
				m[k] = v
			}
		}
		m["TERM"] = "xterm-256color"
		delete(m, "CONDUIT_BENCH_UNSET")
		return m
	}
	only := func() map[string]string {
		return map[string]string{"PATH": "/usr/bin:/bin", "HOME": "/nonexistent", "TERM": "xterm-256color"}
	}
	inherited := len(inherit())
	rounds := 2
	if smoke() {
		rounds = 1
	}
	for round := 0; round < rounds; round++ {
		timed := round+1 == rounds
		start := benchmarkNow()
		for i := 0; i < n; i++ {
			if len(inherit()) != inherited {
				panic("unstable environment")
			}
		}
		if timed {
			report("go-os", "ENVIRON", "inherit", float64(benchmarkSince(start).Nanoseconds())/float64(n)/1e3, "us")
		}
		start = benchmarkNow()
		for i := 0; i < n; i++ {
			if len(only()) != 3 {
				panic("bad environment")
			}
		}
		if timed {
			report("go-os", "ENVIRON", "only", float64(benchmarkSince(start).Nanoseconds())/float64(n)/1e3, "us")
		}
	}
	agree("go-os", "ENVIRON", "inherited_vars", inherited, "count")
}

func processIdentity(n int) {
	cmd := exec.Command(program("SLEEP", "sleep"), "30")
	cmd.Stdin, cmd.Stdout, cmd.Stderr = nil, nil, nil
	if err := cmd.Start(); err != nil {
		panic(err)
	}
	rounds := 2
	if smoke() {
		rounds = 1
	}
	for round := 0; round < rounds; round++ {
		start := benchmarkNow()
		for i := 0; i < n; i++ {
			process, err := os.FindProcess(cmd.Process.Pid)
			if err != nil || process.Signal(syscall.Signal(0)) != nil {
				panic("process gone")
			}
		}
		if round+1 == rounds {
			report("go-os", "PROCESS IDENTITY", "exists", float64(benchmarkSince(start).Nanoseconds())/float64(n), "ns")
		}
	}
	cmd.Process.Kill()
	cmd.Wait()
}

// The child every side signals: `c-bench signal_child`; see coverage.c.
func signalChild() string {
	if path := os.Getenv("BENCH_SIGNAL_CHILD"); path != "" {
		return path
	}
	panic("BENCH_SIGNAL_CHILD unset")
}

func readExact(from io.Reader, expected string) {
	buffer := make([]byte, len(expected))
	if _, err := io.ReadFull(from, buffer); err != nil || string(buffer) != expected {
		panic(fmt.Sprintf("read %q, %v", buffer, err))
	}
}

// Process.Signal to the one pid, in a group of its own so the teardown
// reaches the descendant.
func signalRoundTrip(n int) {
	cmd := exec.Command(signalChild(), "signal_child")
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	out, err := cmd.StdoutPipe()
	if err != nil {
		panic(err)
	}
	if err := cmd.Start(); err != nil {
		panic(err)
	}
	readExact(out, "r\n")
	one := func() {
		if err := cmd.Process.Signal(syscall.SIGUSR1); err != nil {
			panic(err)
		}
		readExact(out, "x\n")
	}
	for i := 0; i < warm(n, 20); i++ {
		one()
	}
	start := benchmarkNow()
	for i := 0; i < n; i++ {
		one()
	}
	report("go-os", "SIGNAL", "round_trip", float64(benchmarkSince(start).Nanoseconds())/float64(n)/1e3, "us")
	agree("go-os", "SIGNAL", "acks", n, "count")
	syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL)
	cmd.Wait()
}

// ExtraFiles: the pipe's write end becomes the child's descriptor 3.
func oneExtraFds() float64 {
	start := benchmarkNow()
	r, w, err := os.Pipe()
	if err != nil {
		panic(err)
	}
	cmd := exec.Command(program("SH", "sh"), "-c", "echo x >&3")
	cmd.Stdin, cmd.Stdout, cmd.Stderr = nil, nil, nil
	cmd.ExtraFiles = []*os.File{w}
	if err := cmd.Start(); err != nil {
		panic(err)
	}
	w.Close()
	got, err := io.ReadAll(r)
	if err != nil {
		panic(err)
	}
	if err := cmd.Wait(); err != nil {
		panic(err)
	}
	ns := float64(benchmarkSince(start).Nanoseconds())
	r.Close()
	if string(got) != "x\n" {
		panic("bad output")
	}
	return ns
}

func extraFds(n int) {
	for i := 0; i < warm(n, 5); i++ {
		oneExtraFds()
	}
	total := 0.0
	for i := 0; i < n; i++ {
		total += oneExtraFds()
	}
	report("go-os-exec", "EXTRA FDS", "latency", total/float64(n)/1e3, "us")
	agree("go-os-exec", "EXTRA FDS", "bytes_out", 2, "bytes")
}
