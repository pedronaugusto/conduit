//! The child lifecycle, shared only by the process implementation and Reaper.
const State = @This();
const builtin = @import("builtin");
const std = @import("std");
const Child = @import("contract.zig");
const posix = std.posix;
const windows = std.os.windows;
const is_windows = builtin.target.os.tag == .windows;
const tree = @import("../tree.zig");
const cgroups = @import("../cgroup.zig");
const reactor = @import("reactor");
const Id = std.process.Child.Id;
const Pty = @import("../pty.zig").Pty;
const Supervisor = @import("../supervisor.zig").Supervisor;
const Tracker = @import("../lineage.zig").Tracker;
const ProcessGroupId = Child.ProcessGroupId;
const Term = Child.Term;

stdin: ?std.Io.File = null,
stdout: ?std.Io.File = null,
stderr: ?std.Io.File = null,
pty: ?Pty.Master = null,
gpa: std.mem.Allocator,
/// The spawn's one descendant lifecycle policy.
descendants: Child.Descendants = .survive,
/// Completion of the platform scope, independent of recovering root status.
/// Only lifecycle teardown reads this after all borrowing tasks have joined.
scope_complete: bool = false,
/// A termination request owns tree cleanup even if the child catches it and
/// exits normally. Protected by identity alongside signal delivery and reap.
end_descendants: bool = false,
process_id: Child.Id,
/// The operating system's name for the child.
///
/// On POSIX this stays meaningful after the child is reaped only as a label:
/// the operating system may have handed the number to an unrelated process by
/// then. On Windows it is a handle, and it is closed once the child is reaped
/// — see `handles_open`.
id: Id,
/// Windows only: the handle to the child's initial thread, which
/// `CreateProcessW` hands back and nothing else here uses. It is closed
/// alongside `id`.
thread: if (is_windows) windows.HANDLE else void,
/// Windows only: whether `id` and `thread` are still open handles.
///
/// Reaping a child closes them, and a closed handle must not be closed again.
/// POSIX has no such thing: a process id is a number.
handles_open: if (is_windows) bool else void,
/// Windows only: the job object holding the child and everything it starts.
///
/// This is what makes `kill` and `killWait` reach the whole tree there, the
/// way a signal to a process group does on POSIX. `null` once `deinit` has
/// closed it; the lifecycle policy determines whether closing it ends members.
job: if (is_windows) ?windows.HANDLE else void,
/// Windows only: what the job reports, which is how `waitTree` learns that the
/// job has emptied. Attached before anything is in the job and detached before
/// `job` is closed.
job_events: if (is_windows) ?reactor.Job else void,
/// Windows only: whether the job has been heard to empty. `waitTree` sets it,
/// and answers from it thereafter: the message is posted once and taking it
/// off the job's reports consumes it.
tree_ended: if (is_windows) bool else void,
/// The child's process group, when `detach` asked for one. `null` means the
/// child is in the process group it inherited, and a signal is addressed to
/// the child alone.
pgid: ?ProcessGroupId,
/// POSIX: whether the child has forked, watched from before it ran, so that
/// `kill` can leave out the descendant walk for a child that never has.
/// `tree.Forks` says where there is a watch; elsewhere it answers that the
/// walk is needed. Closed by `deinit`.
forks: if (is_windows) void else tree.Forks,
/// POSIX: the watch on the child's end, opened as it was spawned and closed by
/// `deinit` (`exit.open`). `null` where none could be had.
exit_watch: if (is_windows) void else ?reactor.Process,
/// Linux: the cgroup the child was put in before it ran, where this process
/// may make one, and which everything the child starts is born into. `kill`
/// ends the whole of it. Elsewhere, and where none could be made, it is
/// none, and `kill` walks. `deinit` removes it.
cgroup: if (is_windows) void else cgroups.Cgroup,
/// Linux: private adoption owner, with its root status returned on the channel.
supervisor: if (builtin.target.os.tag == .linux) ?Supervisor else void = if (builtin.target.os.tag == .linux) null else {},
/// Darwin: lineage observer, started before the root is released to exec.
lineage: if (is_windows) void else ?*Tracker = if (is_windows) {} else null,
/// How the child ended, once it has been reaped. While this is `null` the
/// child is still a process the operating system knows about.
///
/// Written once, by whichever call reaps the child, and published through
/// `reaped`. **Read it with `tryWait`**, which does that load: a `Reaper` may
/// be the one that writes it, and a plain read of the field from another task
/// is then a race on a value that is not a single word.
term: ?Term,
/// Whether `term` has been written and may be read.
///
/// Stored with release ordering after `term`, and loaded with acquire
/// ordering before every read of it, so that a task which sees a term sees
/// the whole of it. The separate `identity` claim keeps signalling safe
/// until this publication says the identity has been retired.
reaped: std.atomic.Value(bool) = .init(false),
/// Whether some task is inside the operating system's wait for this child.
///
/// Exactly one may be: two waits on one child are one status and one `ECHILD`,
/// and the second is a child nobody can account for. Whoever does not take
/// this reads the answer the one who did publishes — `tryWait` by saying the
/// child is still running, `wait` by waiting for the answer to appear.
reaping: std.atomic.Value(bool) = .init(false),
/// The right to use or retire the OS identity. Signalling holds it for the
/// whole tree walk and delivery; reaping holds it only for the final,
/// nonblocking wait, handle closure and publication. Waiting for an exit
/// never holds it, so a child being waited for can still be killed.
///
/// Not an `aegis.Guarded`, and deliberately a raw lock (an OS boundary: it
/// guards the use of an operating-system name, not one value). It is held
/// across a descendant walk and signal delivery, which a spin guard's bounded
/// sections do not allow; `tryWaitClaimed` must take it without waiting, which
/// `Guarded` cannot; and its waiters yield rather than burn the walk's time.
identity: std.atomic.Mutex = .unlocked,
/// A force request still owns group cleanup at the final, nonblocking reap.
/// Protected by identity, so fork completion cannot be followed by retirement
/// before the group is addressed again.
force_tree: bool = false,
/// An identity retired without a term, because something else reaped it.
/// Guarded by `identity`; once set, no signal uses the child's name again.
identity_retired: bool = false,
