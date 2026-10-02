// Compile-time adapters preserve the workload across the ownership API change.
const std = @import("std");
const conduit = @import("conduit");
pub fn openPty(a: std.mem.Allocator) !conduit.Pty {
    return if (@typeInfo(@TypeOf(conduit.Pty.open)).@"fn".params.len == 2)
        conduit.Pty.open(a, .{ .rows = 24, .cols = 80 })
    else
        conduit.Pty.open(.{ .rows = 24, .cols = 80 });
}
pub fn pid(child: *conduit.Child) std.posix.pid_t {
    return if (@hasDecl(conduit.Child, "processId")) child.processId().? else child.id;
}
pub fn stdout(child: conduit.Child) std.Io.File {
    return if (@hasDecl(conduit.Child, "stdoutFile")) child.stdoutFile().? else child.stdout.?;
}
pub fn terminal(child: conduit.Child) conduit.Pty.Master {
    return if (@hasDecl(conduit.Child, "terminalMaster")) child.terminalMaster().? else child.pty.?;
}
pub fn readHandle(pty: conduit.Pty) conduit.Pty.Handle {
    return if (@hasDecl(conduit.Pty, "readHandle")) pty.readHandle().? else pty.read.?;
}
pub fn outputTerm(out: *const conduit.Child.Output) conduit.Term {
    return if (@hasDecl(conduit.Child.Output, "term")) out.term() else out.term;
}
pub fn outputBytes(out: *const conduit.Child.Output) []const u8 {
    return if (@hasDecl(conduit.Child.Output, "stdout")) out.stdout() else out.stdout;
}

// Both pins run the same cleanup; the current API reports failed completion.
pub fn deinitReaper(reaper: *conduit.Reaper, io: std.Io) void {
    const Result = @typeInfo(@TypeOf(conduit.Reaper.deinit)).@"fn".return_type.?;
    if (@typeInfo(Result) == .error_union) {
        reaper.deinit(io) catch @panic("reaper cleanup failed");
    } else reaper.deinit(io);
}
