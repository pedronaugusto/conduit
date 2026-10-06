const std = @import("std");
const conduit = @import("conduit.zig");
const builtin = @import("builtin");
const tty = @import("conduit.tty");
const environ_impl = @import("environ.zig");
const shell = @import("shell.zig");
const is_windows = builtin.os.tag == .windows;
const Pty = conduit.Pty;
const Child = conduit.Child;
const InputWriter = conduit.InputWriter;
const Reaper = conduit.Reaper;
const Orphans = conduit.Orphans;
const Cgroup = conduit.Cgroup;
const console = conduit.console;
const Proxy = conduit.Proxy;
const Expect = conduit.Expect;
const Term = conduit.Term;
const succeeded = conduit.succeeded;
const exitCode = conduit.exitCode;
const signalName = conduit.signalName;
const signalNumber = conduit.signalNumber;
const shellStatus = conduit.shellStatus;
const Size = conduit.Size;
const Saved = conduit.Saved;
const Handle = conduit.Handle;
const spawnShell = conduit.spawnShell;
const Shell = conduit.Shell;
const ShellOptions = conduit.ShellOptions;
const SpawnShellError = conduit.SpawnShellError;
const findProgram = conduit.findProgram;
const environ = conduit.environ;
const rawMode = conduit.rawMode;
const RawModeError = conduit.RawModeError;
const restore = conduit.restore;
const RestoreError = conduit.RestoreError;
const winSize = conduit.winSize;
const WinSizeError = conduit.WinSizeError;
const setWinSize = conduit.setWinSize;
const SetWinSizeError = conduit.SetWinSizeError;
const isTty = conduit.isTty;
const foregroundGroup = conduit.foregroundGroup;
const ForegroundGroupError = conduit.ForegroundGroupError;
const ttyName = conduit.ttyName;
const TtyNameError = conduit.TtyNameError;
const processExists = conduit.processExists;
const bootIdentity = conduit.bootIdentity;
const parseBootIdentity = conduit.parseBootIdentity;
const startTime = conduit.startTime;
const CapturedPid = conduit.CapturedPid;
const captureStarted = conduit.captureStarted;
const killRecorded = conduit.killRecorded;
test {
    _ = @import("testing/support.zig");
    _ = @import("input_writer_test.zig");
    _ = @import("child/exchange_test.zig");
    _ = @import("child/output.zig");
    _ = Pty;
    _ = Child;
    _ = Reaper;
    _ = Orphans;
    _ = @import("deadline_test.zig");
    _ = @import("close_on_exec_test.zig");
    _ = @import("pin.zig");
    _ = @import("spin.zig");
    _ = console;
    _ = Proxy;
    _ = @import("proxy_test.zig");
    _ = Expect;
    // A module of its own, so its declarations are named here to be
    // compiled for every target the check builds.
    inline for (.{ tty.Size, tty.Saved, tty.rawMode, tty.restore, tty.winSize, tty.isTty, tty.openControlling, tty.Controlling, tty.Deadline, tty.ForkGap }) |decl| _ = decl;
    _ = environ_impl;
    _ = shell;
    _ = @import("find.zig");
    _ = @import("child/windows/search.zig");
    _ = @import("child/spawn_test.zig");
    _ = @import("child/descendants_test.zig");
    _ = @import("child/windows/completion.zig");
    if (builtin.os.tag == .linux) _ = @import("supervisor_test.zig");
    _ = @import("lineage.zig");
}

test {
    _ = @import("child/reaper_test.zig");
    if (comptime !is_windows) _ = @import("tree_test.zig");
    if (comptime !is_windows) _ = @import("wait_test.zig");
    _ = @import("handles_test.zig");
    _ = @import("lineage_test.zig");
    _ = @import("expect_test.zig");
}

test "the process's own terminal opens as a terminal, or says there is none" {
    const io = std.testing.io;
    const own = tty.openControlling(io) catch |err| switch (err) {
        // A test run with no terminal of its own: a CI runner, a service.
        error.NotATerminal, error.NoDevice, error.FileNotFound, error.AccessDenied => return error.SkipZigTest,
        else => return err,
    };
    defer own.close(io);
    try std.testing.expect(tty.isTty(own.input.handle));
    try std.testing.expect(tty.isTty(own.output.handle));
    if (!is_windows) try std.testing.expectEqual(own.input.handle, own.output.handle);
}

test {
    _ = @import("input_writer.zig");
    _ = @import("orphans.zig");
    _ = @import("proxy.zig");
    _ = tty.console;
}
