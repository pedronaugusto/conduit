const posix = @import("std").posix;
/// A copied process identity. Retain both fields; the pid alone is not
/// authority to signal. Save this boot's identity alongside persistent
/// records, then use captureStarted or endRecorded within that boot.
pub const Record = struct {
    pid: posix.pid_t,
    /// Linux clock ticks after boot, as returned by conduit.startTime.
    start: u64,
    /// Group and session observed in the same adoption snapshot as start.
    /// These are saved facts, not authority to signal a group later.
    group: posix.pid_t,
    session: posix.pid_t,
};
