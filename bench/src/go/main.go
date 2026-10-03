package main

/*
#include <libproc.h>
*/
import "C"

import (
	"context"
	"fmt"
	"io"
	"os"
	"os/exec"
	"strconv"
	"syscall"
	"time"
	"unsafe"

	"github.com/creack/pty"
	"golang.org/x/term"
)

func warm(n, limit int) int {
	if os.Getenv("SMOKE") == "1" {
		return 0
	}
	return min(n, limit)
}
func program(name, fallback string) string {
	if value := os.Getenv("BENCH_" + name); value != "" {
		return value
	}
	return fallback
}
func report(side, workload, metric string, value float64, unit string) {
	fmt.Printf("%s\t%s\t%s\t%.6f\t%s\n", side, workload, metric, value, unit)
}

func oneSpawnWait() {
	cmd := exec.Command(program("TRUE", "true"))
	cmd.Stdin, cmd.Stdout, cmd.Stderr = nil, nil, nil
	if err := cmd.Run(); err != nil {
		panic(err)
	}
}

func spawnWait(n int) {
	for i := 0; i < warm(n, 10); i++ {
		oneSpawnWait()
	}
	start := benchmarkNow()
	for i := 0; i < n; i++ {
		oneSpawnWait()
	}
	report("go-os-exec", "SPAWN+WAIT", "latency", float64(benchmarkSince(start).Nanoseconds())/float64(n)/1e3, "us")
}

func oneCollect(arg string) {
	cmd := exec.Command(program("ECHO", "echo"), arg)
	cmd.Stdin, cmd.Stderr = nil, nil
	out, err := cmd.Output()
	if err != nil || len(out) != 1025 || out[1024] != '\n' {
		panic("bad echo output")
	}
}

func spawnCollect(n int, input []byte) {
	if len(input) != 1024 {
		panic("bad input")
	}
	arg := string(input)
	for i := 0; i < warm(n, 5); i++ {
		oneCollect(arg)
	}
	start := benchmarkNow()
	for i := 0; i < n; i++ {
		oneCollect(arg)
	}
	report("go-os-exec", "SPAWN+COLLECT", "latency", float64(benchmarkSince(start).Nanoseconds())/float64(n)/1e3, "us")
}

func expectedPtyBytes(input []byte) int {
	return len(input)
}

func drainExact(r io.Reader, wanted int) uint64 {
	buf := make([]byte, 64*1024)
	total := 0
	var sum uint64
	for total < wanted {
		take := min(len(buf), wanted-total)
		n, err := r.Read(buf[:take])
		if err != nil || n == 0 {
			panic(fmt.Sprintf("pty read: %v", err))
		}
		for _, b := range buf[:n] {
			sum += uint64(b)
		}
		total += n
	}
	return sum
}

func openCat() (*exec.Cmd, *os.File) {
	cmd := exec.Command(program("CAT", "cat"))
	f, err := pty.Start(cmd)
	if err != nil {
		panic(err)
	}
	if _, err := term.MakeRaw(int(f.Fd())); err != nil {
		panic(err)
	}
	return cmd, f
}

func onePty(input []byte) {
	cmd, f := openCat()
	if _, err := f.Write(input); err != nil {
		panic(err)
	}
	if drainExact(f, expectedPtyBytes(input)) == 0 {
		panic("zero checksum")
	}
	if err := cmd.Process.Kill(); err != nil {
		panic(err)
	}
	_ = cmd.Wait()
	_ = f.Close()
}

func ptySpawn(n int, input []byte) {
	if len(input) != 1024 {
		panic("bad input")
	}
	for i := 0; i < warm(n, 3); i++ {
		onePty(input)
	}
	start := benchmarkNow()
	for i := 0; i < n; i++ {
		onePty(input)
	}
	report("go-creack-pty", "PTY SPAWN", "latency", float64(benchmarkSince(start).Nanoseconds())/float64(n)/1e3, "us")
}

func ptyThroughput(input []byte) {
	cmd, f := openCat()
	done := make(chan error, 1)
	start := benchmarkNow()
	go func() { _, err := f.Write(input); done <- err }()
	if drainExact(f, expectedPtyBytes(input)) == 0 {
		panic("zero checksum")
	}
	if err := <-done; err != nil {
		panic(err)
	}
	elapsed := benchmarkSince(start).Seconds()
	if err := cmd.Process.Kill(); err != nil {
		panic(err)
	}
	_ = cmd.Wait()
	_ = f.Close()
	report("go-creack-pty", "PTY THROUGHPUT", "throughput", float64(len(input))/elapsed/1e6, "MB/s")
}

func oneWaitTimeout() float64 {
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, program("SLEEP", "sleep"), "0.01")
	if err := cmd.Start(); err != nil {
		panic(err)
	}
	start := benchmarkNow()
	if err := cmd.Wait(); err != nil {
		panic(err)
	}
	return float64(benchmarkSince(start).Nanoseconds())
}

func waitTimeout(n int) {
	for i := 0; i < warm(n, 3); i++ {
		oneWaitTimeout()
	}
	var total float64
	for i := 0; i < n; i++ {
		total += oneWaitTimeout()
	}
	over := total/float64(n)/1e3 - 10000
	if over < 0 {
		over = 0
	}
	report("go-command-context", "WAIT-TIMEOUT", "overshoot", over, "us")
}

func childPids(parent int) []int {
	for i := 0; i < 1000; i++ {
		storage := make([]C.pid_t, 8)
		count := int(C.proc_listchildpids(C.pid_t(parent), unsafe.Pointer(&storage[0]), C.int(len(storage)*int(unsafe.Sizeof(storage[0])))))
		if count >= 2 {
			pids := make([]int, count)
			for j := range pids {
				pids[j] = int(storage[j])
			}
			return pids
		}
		time.Sleep(time.Millisecond)
	}
	panic("tree did not start")
}

func confirmGone(pids []int) {
	for i := 0; i < 1000; i++ {
		any := false
		for _, pid := range pids {
			if syscall.Kill(pid, 0) == nil {
				any = true
			}
		}
		if !any {
			return
		}
		time.Sleep(time.Millisecond)
	}
	panic("descendant survived")
}

func oneTreeKill() float64 {
	cmd := exec.Command(program("SH", "sh"), "-c", "sleep 30 & sleep 30 & wait")
	cmd.Stdin, cmd.Stdout, cmd.Stderr = nil, nil, nil
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	if err := cmd.Start(); err != nil {
		panic(err)
	}
	pids := childPids(cmd.Process.Pid)
	start := benchmarkNow()
	if err := syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL); err != nil {
		panic(err)
	}
	_ = cmd.Wait()
	elapsed := benchmarkSince(start).Seconds()
	confirmGone(pids)
	return elapsed
}

func treeKill(n int) {
	for i := 0; i < warm(n, 2); i++ {
		oneTreeKill()
	}
	var total float64
	for i := 0; i < n; i++ {
		total += oneTreeKill()
	}
	report("go-os-exec+killpg", "TREE KILL", "latency", total*1e3/float64(n), "ms")
}

func main() {
	if len(os.Args) != 4 {
		panic("usage: go-bench WORKLOAD ITERATIONS INPUT")
	}
	n, err := strconv.Atoi(os.Args[2])
	if err != nil {
		panic(err)
	}
	input, err := os.ReadFile(os.Args[3])
	if err != nil {
		panic(err)
	}
	switch os.Args[1] {
	case "spawn_wait":
		spawnWait(n)
	case "spawn_collect":
		spawnCollect(n, input)
	case "pty_spawn":
		ptySpawn(n, input)
	case "pty_throughput":
		ptyThroughput(input)
	case "wait_timeout":
		waitTimeout(n)
	case "tree_kill":
		treeKill(n)
	case "exchange":
		exchange(n, input)
	case "collect":
		collect(n, os.Args[3], input)
	case "input_writer":
		inputWriter(n, input)
	case "read_available":
		readAvailable(n, input)
	case "reaper_wait":
		reaperWait(n)
	case "proxy":
		proxy(n, os.Args[3], input)
	case "shell_spawn":
		shellSpawn(n)
	case "pty_open":
		ptyOpen(n)
	case "tty_ops":
		ttyOps(n)
	case "find_program":
		findProgram(n)
	case "environ":
		environ(n)
	case "process_identity":
		processIdentity(n)
	default:
		panic("unknown workload")
	}
}

func benchmarkNow() time.Time {
    if os.Getenv("SMOKE") == "1" { return time.Time{} }
    return time.Now()
}
func benchmarkSince(start time.Time) time.Duration {
    if os.Getenv("SMOKE") == "1" { return time.Nanosecond }
    return time.Since(start)
}
