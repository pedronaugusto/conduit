//! Starting a child process on Windows: the command line `CreateProcessW`
//! takes, the standard handles it inherits, and the attribute list that
//! attaches it to a pseudoconsole.
//!
//! The public contract lives on `Child.spawn`; this file is the half of it
//! that only exists here.

const std = @import("std");
const windows = std.os.windows;
const Allocator = std.mem.Allocator;

const Child = @import("contract.zig");
const State = @import("state.zig");
const command_line = @import("command_line.zig");
const stdio_plan = @import("stdio_plan.zig");
const trace = @import("../trace.zig");
const win32 = @import("../win32.zig");
const windows_search = @import("windows/search.zig");

const SpawnError = Child.SpawnError;
const SpawnOptions = Child.SpawnOptions;
const file = @import("../handles.zig").file;

/// See `Child.spawn`.
pub fn spawn(allocator: Allocator, io: std.Io, options: SpawnOptions, state: *State) SpawnError!*State {
    var arena_state: std.heap.ArenaAllocator = .init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try refuseWhatWindowsCannotDo(options);

    // `CreateProcessW` writes to the command line it is given, so it must be a
    // mutable buffer. A custom child environment needs its program resolved
    // before this call: Windows otherwise searches the parent's PATH even
    // though it installs the supplied block in the child.
    const line = try command_line.serialise(arena, options.argv);
    const application = try applicationName(arena, io, options);

    const environment: ?[*:0]const u16 = if (options.environ) |map| env: {
        const block = try map.createWindowsBlock(arena, .{});
        break :env block.slice.ptr;
    } else null;

    const cwd = try workingDirectory(arena, options.cwd);

    var plan: Plan = try .init(io, options, null);
    errdefer plan.closeAll(io);
    var child_handles = try ChildHandles.init(childHandles(&plan));
    defer child_handles.deinit();
    const given = child_handles.given;
    // `extra_fds` as private inheritable copies, but for a console handle,
    // which the child reaches through the console it shares and which no
    // handle list may name.
    const extras = try arena.alloc(windows.HANDLE, options.extra_fds.len);
    var extras_made: usize = 0;
    var extra_duplicates: usize = 0;
    defer for (options.extra_fds[0..extras_made], extras[0..extras_made]) |extra, handle| {
        if (handle != extra.handle) windows.CloseHandle(handle);
    };
    for (options.extra_fds, extras) |extra, *slot| {
        if (isConsole(extra.handle)) {
            slot.* = extra.handle;
        } else {
            slot.* = try inheritableCopy(extra.handle);
            extra_duplicates += 1;
        }
        extras_made += 1;
    }

    var startup: win32.StartupInfoExW = std.mem.zeroes(win32.StartupInfoExW);
    var flags: windows.CreateProcessFlags = .{
        .create_new_process_group = options.detach,
        .create_unicode_environment = environment != null,
    };

    // What the child is attached to or handed, in the shape `CreateProcessW`
    // takes it: a pseudoconsole through an attribute list, or three standard
    // handles and a list of what may be inherited.
    var attributes: ?AttributeList = null;
    defer if (attributes) |*list| list.deinit();
    try describeChild(arena, options, given, extras, &startup, &flags, &attributes);

    // A console handle is already meaningful to a child sharing this
    // process's console and is not inherited through the handle table. Every
    // other handle is named in the restrictive attribute list below. With no
    // such handle there is nothing to inherit, so passing FALSE is what keeps
    // unrelated inheritable handles out of the child.
    const inherit_handles: windows.BOOL = switch (options.stdio) {
        .pty => .FALSE,
        else => inherit: {
            for (given) |slot| {
                const handle = slot orelse continue;
                if (!isConsole(handle)) break :inherit .TRUE;
            }
            if (extra_duplicates != 0) break :inherit .TRUE;
            break :inherit .FALSE;
        },
    };

    traceSpawn(options, &startup, flags, inherit_handles);

    // The child is started suspended and put in its job before it runs, so
    // there is no moment in which it exists outside one -- a child that got as
    // far as starting something of its own first would have left that
    // something outside the job, which is the whole thing the job is for.
    flags.create_suspended = true;

    const job = try createJob(options.job_limits);
    errdefer job.close();

    var information: windows.PROCESS.INFORMATION = undefined;
    if (windows.kernel32.CreateProcessW(
        application,
        line.ptr,
        null,
        null,
        inherit_handles,
        flags,
        environment,
        cwd,
        &startup.StartupInfo,
        &information,
    ) == .FALSE) return createError();

    // From here the child exists, so a failure has to end it rather than
    // return and leave it suspended forever.
    errdefer {
        _ = win32.TerminateProcess(information.hProcess, 1);
        windows.CloseHandle(information.hThread);
        windows.CloseHandle(information.hProcess);
    }

    if (win32.AssignProcessToJobObject(job.handle, information.hProcess) == .FALSE) {
        return error.JobAssignmentFailed;
    }
    if (win32.ResumeThread(information.hThread) == std.math.maxInt(windows.DWORD)) {
        return createError();
    }

    plan.closeChildSide(io);

    state.* = .{
        .allocator = state.allocator,
        .descendants = options.descendants,
        .process_id = information.dwProcessId,
        .id = information.hProcess,
        .thread = information.hThread,
        .job = job.handle,
        .job_port = job.port,
        .tree_ended = false,
        .handles_open = true,
        // `CREATE_NEW_PROCESS_GROUP` makes a group whose id is the process id,
        // which is what `GenerateConsoleCtrlEvent` is addressed to.
        .pgid = if (options.detach) information.dwProcessId else null,
        .forks = {},
        .cgroup = {},
        .term = null,
        .stdin = plan.parent[0],
        .stdout = plan.parent[1],
        .stderr = plan.parent[2],
        .pty = switch (options.stdio) {
            .pty => |pty| pty.master(),
            else => null,
        },
    };
    return state;
}

/// Says what the child is attached to or handed, in the two records
/// `CreateProcessW` takes them in.
///
/// A pseudoconsole is attached through an attribute list rather than through
/// the standard handles. Naming a standard handle alongside a pseudoconsole
/// is unsupported; `STARTF_USESTDHANDLES` with three null handles keeps the
/// parent's streams out. Nothing needs to be inheritable in that case either,
/// which is why `inheritHandles` differs.
fn describeChild(
    arena: Allocator,
    options: SpawnOptions,
    given: [3]?windows.HANDLE,
    extras: []const windows.HANDLE,
    startup: *win32.StartupInfoExW,
    flags: *windows.CreateProcessFlags,
    attributes: *?AttributeList,
) SpawnError!void {
    switch (options.stdio) {
        .pty => |pty| {
            const console = pty.slaveHandle().?;
            var list = try AttributeList.init(arena, 1);
            try list.setPseudoConsole(console);
            if (trace.enabled()) {
                trace.print("spawn: pseudoconsole attribute set, hpcon=0x{x}", .{@intFromPtr(console)}); // safe: printed, never dereferenced
            }
            attributes.* = list;
            startup.StartupInfo.cb = @sizeOf(win32.StartupInfoExW);
            startup.lpAttributeList = list.raw;
            flags.extended_startupinfo_present = true;

            // And no standard handles, said out loud. `CreateProcessW` gives a
            // child the parent's standard handles even with `bInheritHandles`
            // false, when those handles are not console handles: they are
            // duplicated into the child as a special case. So a program whose
            // own streams are pipes -- which is every program a build system, a
            // service or a test harness starts -- would hand a child on a
            // pseudoconsole the parent's pipes, and everything the child wrote
            // would go there rather than to the console it is attached to. From
            // a terminal it looks right, because console handles are not
            // duplicated and the child falls back to its console; everywhere
            // else it is wrong.
            //
            // `STARTF_USESTDHANDLES` with all three left null is how a child is
            // given none, and a child with none uses the console it has, which
            // is the pseudoconsole. This is not the combination Windows
            // documents as unsupported alongside a pseudoconsole -- that is
            // *naming* a handle, which is why `stderr_to` with `.pty` is
            // refused rather than merged in here.
            startup.StartupInfo.dwFlags = win32.startf_usestdhandles;
        },
        else => {
            startup.StartupInfo.cb = @sizeOf(windows.STARTUPINFOW);
            startup.StartupInfo.dwFlags = win32.startf_usestdhandles;
            startup.StartupInfo.hStdInput = given[0];
            startup.StartupInfo.hStdOutput = given[1];
            startup.StartupInfo.hStdError = given[2];

            // And nothing else. `bInheritHandles` on its own hands the child
            // every inheritable handle this process holds -- which on a machine
            // where this program's own standard streams are inheritable pipes
            // means the child, and anything the child starts, keeps those pipes
            // open for as long as it lives. A handle list says exactly which
            // three the child is being given.
            if (try inheritList(arena, given, extras)) |inheritable| {
                var list = try AttributeList.init(arena, 1);
                try list.setHandleList(inheritable);
                attributes.* = list;
                startup.StartupInfo.cb = @sizeOf(win32.StartupInfoExW);
                startup.lpAttributeList = list.raw;
                flags.extended_startupinfo_present = true;
            }

            // What the child holds above its standard three is said where its C
            // runtime looks for inherited descriptors.
            if (extras.len != 0) {
                const table = try runtimeTable(arena, extras);
                startup.StartupInfo.cbReserved2 = @intCast(table.len);
                startup.StartupInfo.lpReserved2 = &table[0];
            }
        },
    }
}

/// The child's working directory, as `CreateProcessW` wants it, and `null` for
/// a child that inherits this process's.
///
/// The directory is looked at here rather than left to `CreateProcessW`, which
/// reports one that is not there with an error code it also uses for other
/// things -- a program at a path that does not exist is one of them -- so the
/// two would be indistinguishable afterwards. `spawn` promises
/// `BadWorkingDirectory` for one and `FileNotFound` for the other on both
/// systems, and on POSIX the fork child reports which step failed; this is what
/// keeps that promise here. A directory that goes away between this and the
/// spawn comes back as whatever `CreateProcessW` makes of it, which is the
/// ordinary cost of asking first.
fn workingDirectory(arena: Allocator, wanted: ?[]const u8) SpawnError!?[*:0]const u16 {
    const dir = wanted orelse return null;
    const wide = (try std.unicode.wtf8ToWtf16LeAllocZ(arena, dir)).ptr;
    const attributes = win32.GetFileAttributesW(wide);
    if (attributes == win32.invalid_file_attributes) return error.BadWorkingDirectory;
    if (attributes & win32.file_attribute_directory == 0) return error.BadWorkingDirectory;
    return wide;
}

/// The executable passed as `lpApplicationName`, when this package has to
/// resolve it itself to honour the selected child environment.
///
/// With no custom environment, null preserves `CreateProcessW`'s native
/// search exactly. A program that already names a path needs no search either,
/// but is passed explicitly so command-line parsing cannot choose a different
/// executable. For a bare name and custom environment the ordinary Windows
/// directories are searched first, then that environment's PATH.
fn applicationName(
    arena: Allocator,
    io: std.Io,
    options: SpawnOptions,
) SpawnError!?[*:0]const u16 {
    const program = options.argv[0];
    if (!isBareProgram(program)) {
        return (try std.unicode.wtf8ToWtf16LeAllocZ(arena, program)).ptr;
    }
    const environment = options.environ orelse return null;
    // A name with no UTF-16 spelling is refused as such, not as a file that
    // could not be found.
    _ = try std.unicode.wtf8ToWtf16LeAllocZ(arena, program);
    const found = try findBare(arena, io, program, environment) orelse return error.FileNotFound;
    return (try std.unicode.wtf8ToWtf16LeAllocZ(arena, found)).ptr;
}

/// Where a bare program name resolves for a child given `environment`: the
/// directory of this executable, the current directory, the system
/// directories, then that environment's `PATH`, with `.exe` supplied when the
/// name has no extension. `findProgram` asks the same question.
pub fn findBare(
    arena: Allocator,
    io: std.Io,
    program: []const u8,
    environment: *const std.process.Environ.Map,
) Allocator.Error!?[]const u8 {
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const executable_dir: ?[]const u8 = if (std.process.executableDirPath(io, &path_buffer)) |len|
        try arena.dupe(u8, path_buffer[0..len])
    else |_|
        null;
    const current_dir: ?[]const u8 = if (std.process.currentPath(io, &path_buffer)) |len|
        try arena.dupe(u8, path_buffer[0..len])
    else |_|
        null;
    const system = std.unicode.wtf16LeToWtf8Alloc(arena, windows.getSystemDirectoryWtf16Le()) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
    };

    // The order and the spelling are `windows_search`'s, and tested on every
    // system; which of them holds a file is asked here.
    const list = try windows_search.candidates(arena, .{
        .executable_dir = executable_dir,
        .current_dir = current_dir,
        .system_dir = system,
        .path = environment.get("PATH"),
    }, program);
    for (list) |candidate| {
        const wide = std.unicode.wtf8ToWtf16LeAllocZ(arena, candidate) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            // A name with no UTF-16 spelling names no file here.
            else => continue,
        };
        const attributes = win32.GetFileAttributesW(wide.ptr);
        if (attributes == win32.invalid_file_attributes) continue;
        if (attributes & win32.file_attribute_directory != 0) continue;
        return candidate;
    }
    return null;
}

/// Whether `program` names a program to search for: see `windows_search`.
pub const isBareProgram = windows_search.isBareProgram;

/// The options this system has no way to honour, refused rather than accepted
/// and quietly dropped.
fn refuseWhatWindowsCannotDo(options: SpawnOptions) SpawnError!void {
    // Windows has no argument that selects a PATH for CreateProcessW. This
    // implementation resolves `.child_environ` before the call; the other two
    // choices remain unsupported rather than being silently treated as it.
    if (options.path_search != .child_environ) return error.Unsupported;

    if (windows_search.isBatchFile(options.argv[0])) return error.UnsupportedBatchFile;

    // A pseudoconsole is attached through the attribute list, and Windows
    // documents `STARTF_USESTDHANDLES` as unsupported alongside it -- so there
    // is nowhere to put the caller's file. Refusing beats accepting the option
    // and quietly dropping it.
    if (options.stdio == .pty and options.stderr_to != null) return error.Unsupported;
    // The same for the C runtime's table, which names handles in the startup
    // record a pseudoconsole child is given none in.
    if (options.stdio == .pty and options.extra_fds.len != 0) return error.Unsupported;
    if (options.extra_fds.len > runtime_table_limit - 3) return error.Unsupported;

    // A Windows process runs as the token it was created with. Changing the
    // user, the group or the file-creation mask are not steps between a fork
    // and an exec there -- there is no fork -- and there is nothing here that
    // could honour the option, so it is refused rather than accepted and
    // quietly not done.
    if (options.credentials.any()) return error.Unsupported;

    // Windows has no `setrlimit`, and `ResourceLimit` is a pair of POSIX types
    // with no counterpart here. The job object below is what bounds a child on
    // this system, and it bounds the whole tree rather than the one process;
    // `SpawnOptions.job_limits` is the option that reaches it. Accepting the
    // POSIX list and setting nothing would be the worst of both.
    if (options.resource_limits.len != 0) return error.Unsupported;
}

/// What this package asked the operating system for, when `CONDUIT_TRACE` says
/// to print it.
fn traceSpawn(
    options: SpawnOptions,
    startup: *const win32.StartupInfoExW,
    flags: windows.CreateProcessFlags,
    inherit_handles: windows.BOOL,
) void {
    if (trace.enabled()) {
        trace.print(
            "spawn: child_windows.spawn, stdio={s}, cb={d}, flags=0x{x:0>8}, si_flags=0x{x:0>8}, inherit={s}, attributes={s}",
            .{
                @tagName(options.stdio),
                startup.StartupInfo.cb,
                @as(u32, @bitCast(flags)),
                startup.StartupInfo.dwFlags,
                // Not `@tagName`. A Windows `BOOL` names only `FALSE`; every
                // other value, `TRUE` included, is an unnamed one of a
                // non-exhaustive enum, and asking for the name of one of those
                // ends the process.
                if (inherit_handles.toBool()) "TRUE" else "FALSE",
                if (startup.lpAttributeList == null) "none" else "present",
            },
        );
        // Whether this process has a console of its own is the question behind
        // "where did the child's output go": a console child with no console
        // flags and no pseudoconsole inherits its parent's, and one whose
        // parent has none gets a new one nobody can see.
        const inherited = inheritedHandles();
        for (inherited, 0..) |slot, index| {
            const name = ([3][]const u8{ "stdin", "stdout", "stderr" })[index];
            if (slot) |handle| {
                trace.print("spawn: parent {s}=0x{x}, console: {s}", .{
                    name,
                    @intFromPtr(handle), // safe: printed, never dereferenced
                    if (isConsole(handle)) "yes" else "no",
                });
            } else {
                trace.print("spawn: parent {s} is not there", .{name});
            }
        }
    }
}

//======================================================================
// The job object.
//======================================================================

/// A job object and the port it reports on.
const Job = struct {
    handle: windows.HANDLE,
    port: windows.HANDLE,

    fn close(job: Job) void {
        windows.CloseHandle(job.handle);
        windows.CloseHandle(job.port);
    }
};

/// The container the child and everything it starts will live in.
///
/// Every child on this system gets one, because it is what makes `kill` reach
/// the tree and what `deinit` closes to end whatever the child left behind.
/// `limits` is what the caller wants bounded inside it, and a caller who wants
/// nothing bounded pays for one extra call and no more.
///
/// The port is associated before anything is in the job, which is what makes
/// `Child.waitTree` possible: the message that says the job is empty is posted
/// on the transition to empty, so a port attached after the child had already
/// started and stopped would hear nothing and wait forever.
fn createJob(limits: Child.JobLimits) SpawnError!Job {
    if (limits.cpu_rate) |rate| {
        if (rate < 1 or rate > 10_000) return error.InvalidJobLimit;
    }

    const handle = win32.CreateJobObjectW(null, null) orelse return createError();
    errdefer windows.CloseHandle(handle);

    const port = win32.CreateIoCompletionPort(
        windows.INVALID_HANDLE_VALUE,
        null,
        0,
        1,
    ) orelse return createError();
    errdefer windows.CloseHandle(port);

    // The job handle as the key, so a message that arrives on this port can be
    // told to be this job's. One port per job makes that a formality; a key
    // that means nothing would not.
    var association: win32.JobObjectAssociateCompletionPort = .{
        .CompletionKey = handle,
        .CompletionPort = port,
    };
    if (win32.SetInformationJobObject(
        handle,
        win32.job_object_associate_completion_port_information,
        &association,
        @sizeOf(win32.JobObjectAssociateCompletionPort),
    ) == .FALSE) return createError();

    const job: Job = .{ .handle = handle, .port = port };

    var extended: win32.JobObjectExtendedLimitInformation = std.mem.zeroes(
        win32.JobObjectExtendedLimitInformation,
    );
    var flags = win32.job_object_limit_kill_on_job_close;
    if (limits.active_processes) |most| {
        flags |= win32.job_object_limit_active_process;
        extended.BasicLimitInformation.ActiveProcessLimit = most;
    }
    if (limits.process_memory_bytes) |bytes| {
        flags |= win32.job_object_limit_process_memory;
        extended.ProcessMemoryLimit = bytes;
    }
    if (limits.job_memory_bytes) |bytes| {
        flags |= win32.job_object_limit_job_memory;
        extended.JobMemoryLimit = bytes;
    }
    extended.BasicLimitInformation.LimitFlags = flags;
    if (win32.SetInformationJobObject(
        job.handle,
        win32.job_object_extended_limit_information,
        &extended,
        @sizeOf(win32.JobObjectExtendedLimitInformation),
    ) == .FALSE) return createError();

    // A second call, because the processor share is a different information
    // class from the rest -- it is scheduling rather than a limit on a
    // resource the job holds.
    if (limits.cpu_rate) |rate| {
        var control: win32.JobObjectCpuRateControlInformation = .{
            .ControlFlags = win32.job_object_cpu_rate_control_enable |
                win32.job_object_cpu_rate_control_hard_cap,
            .Value = rate,
        };
        if (win32.SetInformationJobObject(
            job.handle,
            win32.job_object_cpu_rate_control_information,
            &control,
            @sizeOf(win32.JobObjectCpuRateControlInformation),
        ) == .FALSE) return createError();
    }

    return job;
}

//======================================================================
// Standard handles.
//======================================================================

/// The handles a spawn involves. `stdio_plan` holds the policy; what is here
/// is the two calls that open a handle on this system.
const Plan = stdio_plan.Plan(struct {
    pub const Error = SpawnError;
    pub const openNull = openNul;

    pub fn openPipe(child_reads: bool) SpawnError!stdio_plan.Pipe {
        return makePipe(if (child_reads) .to_child else .from_child);
    }
});

/// The handles the child is being given, in the order `STARTF_USESTDHANDLES`
/// names them.
///
/// `Target.inherit` has to be said with the parent's own handle here: naming
/// the child's standard handles is all or nothing, so a null slot would hand
/// the child nothing at all -- which is what `.close` means and not what
/// `.inherit` does. A stream this process does not have is `null` either way,
/// and a child cannot inherit what does not exist.
fn childHandles(plan: *const Plan) [3]?windows.HANDLE {
    const inherited = inheritedHandles();
    var given: [3]?windows.HANDLE = @splat(null);
    for (plan.child, 0..) |target, slot| given[slot] = switch (target) {
        .inherit => inherited[slot],
        .place => |handle| handle,
        .close => null,
    };
    return given;
}

/// Private inheritable copies of the ordinary handles one spawn gives its
/// child. No flag on a caller-owned handle is ever changed, so concurrent
/// spawns cannot observe or restore one another's temporary state.
const ChildHandles = struct {
    given: [3]?windows.HANDLE,
    duplicates: [3]windows.HANDLE = undefined,
    count: usize = 0,

    fn init(originals: [3]?windows.HANDLE) SpawnError!ChildHandles {
        var result: ChildHandles = .{ .given = originals };
        errdefer result.deinit();
        for (originals, 0..) |slot, index| {
            const original = slot orelse continue;
            if (isConsole(original)) continue;

            var duplicate: ?windows.HANDLE = null;
            for (originals[0..index], 0..) |earlier, earlier_index| {
                if (earlier == original) {
                    duplicate = result.given[earlier_index];
                    break;
                }
            }
            if (duplicate == null) {
                const made = try inheritableCopy(original);
                result.duplicates[result.count] = made;
                result.count += 1;
                duplicate = made;
            }
            result.given[index] = duplicate;
        }
        return result;
    }

    fn deinit(handles: *ChildHandles) void {
        for (handles.duplicates[0..handles.count]) |handle| windows.CloseHandle(handle);
        handles.* = undefined;
    }
};

/// The handles the child is being given, deduplicated, for the attribute list
/// that stops it from inheriting anything else — or `null` when there is no
/// handle-table handle to inherit.
///
/// A `null` slot is `Stream.close`: there is nothing to inherit, and it is
/// simply left out. A console handle is different. A child sharing this
/// process's console reaches it through the console rather than through the
/// handle table, and naming one in a handle list is how `CreateProcessW` comes
/// back with `ERROR_INVALID_PARAMETER`, so it too is left out. Any ordinary
/// handles beside it are still listed, and an all-console or all-closed plan
/// uses `bInheritHandles=FALSE`.
///
/// Every handle in the list is a private inheritable duplicate made for this
/// spawn and closed once `CreateProcessW` returns.
fn inheritList(arena: Allocator, given: [3]?windows.HANDLE, extras: []const windows.HANDLE) Allocator.Error!?[]windows.HANDLE {
    var list: std.ArrayList(windows.HANDLE) = .empty;
    for (given) |slot| {
        const handle = slot orelse continue;
        if (isConsole(handle)) continue;
        if (std.mem.findScalar(windows.HANDLE, list.items, handle) != null) continue;
        try list.append(arena, handle);
    }
    for (extras) |handle| {
        if (isConsole(handle)) continue;
        if (std.mem.findScalar(windows.HANDLE, list.items, handle) != null) continue;
        try list.append(arena, handle);
    }
    if (list.items.len == 0) return null;
    return list.items;
}

/// The most descriptors the C runtime's table can describe: its size is the
/// startup record's 16-bit `cbReserved2`, and each descriptor takes a flag
/// byte and a handle after the count.
pub const runtime_table_limit = (std.math.maxInt(u16) - @sizeOf(i32)) / (1 + @sizeOf(usize));

/// The table of inherited descriptors the Microsoft C runtime reads from the
/// startup record at its start, the layout libuv writes for Node's extra
/// stdio: the count as an `int`, a flag byte for each descriptor, then each
/// descriptor's handle, packed with no alignment.
///
/// The standard three are left unopened, with no flag and no handle, so the
/// runtime takes them from the standard handles as it does with no table:
/// those are already what `STARTF_USESTDHANDLES` says. Each extra handle is
/// `FOPEN`, with `FPIPE` or `FDEV` for a pipe or a character device, since
/// the runtime reads and seeks differently on those.
fn runtimeTable(arena: Allocator, extras: []const windows.HANDLE) Allocator.Error![]u8 {
    const count = 3 + extras.len;
    const table = try arena.alloc(u8, @sizeOf(i32) + count + count * @sizeOf(usize));
    std.mem.writeInt(i32, table[0..4], @intCast(count), .little);
    const flags = table[4..][0..count];
    const values = table[4 + count ..];
    const invalid = std.math.maxInt(usize);
    for (0..count) |fd| {
        const value: usize = if (fd < 3) invalid else @intFromPtr(extras[fd - 3]); // safe: the handle's value, written into the record the child reads, never dereferenced
        std.mem.writeInt(usize, values[fd * @sizeOf(usize) ..][0..@sizeOf(usize)], value, .little);
        flags[fd] = if (fd < 3) 0 else switch (win32.GetFileType(extras[fd - 3])) {
            win32.file_type_pipe => runtime_open | runtime_pipe,
            win32.file_type_char => runtime_open | runtime_device,
            else => runtime_open,
        };
    }
    return table;
}

/// The C runtime's descriptor flags: `FOPEN`, `FPIPE` and `FDEV`.
const runtime_open: u8 = 0x01;
const runtime_pipe: u8 = 0x08;
const runtime_device: u8 = 0x40;

/// An inheritable duplicate of one of the caller's handles, which is left as
/// it was.
fn inheritableCopy(original: windows.HANDLE) SpawnError!windows.HANDLE {
    const process = windows.GetCurrentProcess();
    var made: windows.HANDLE = undefined;
    if (win32.DuplicateHandle(process, original, process, &made, 0, .TRUE, win32.duplicate_same_access) == .FALSE)
        return createError();
    return made;
}

/// Whether a handle is one of this process's console handles.
///
/// The console is the one thing a child gets without the handle table: a
/// process that shares this one's console has its console handles already, and
/// naming one in a handle list makes `CreateProcessW` fail.
fn isConsole(handle: windows.HANDLE) bool {
    var mode: windows.DWORD = undefined;
    return win32.GetConsoleMode(handle, &mode) != .FALSE;
}

/// This process's three standard handles, as a child inheriting them gets
/// them.
///
/// The process parameters rather than `GetStdHandle`, so a program whose own
/// standard streams were redirected by *its* parent passes on what it actually
/// has. A stream this process does not have is `null` here, and a child cannot
/// inherit what does not exist: that slot behaves as `Stream.close` does.
fn inheritedHandles() [3]?windows.HANDLE {
    const parameters = windows.peb().ProcessParameters;
    return .{
        parameters.hStdInput,
        parameters.hStdOutput,
        parameters.hStdError,
    };
}

const PipeDirection = enum { to_child, from_child };

/// A pipe whose child end is inheritable and whose parent end is not.
///
/// Windows has no per-handle `O_CLOEXEC`: inheritance is a flag on the handle
/// and `CreateProcessW` takes every inheritable handle at once. So both ends
/// are created inheritable — there is no other way to ask — and the end this
/// process keeps has the flag cleared again immediately, which is what stops a
/// later, unrelated spawn from handing it to someone else.
fn makePipe(direction: PipeDirection) SpawnError!stdio_plan.Pipe {
    var security: windows.SECURITY_ATTRIBUTES = .{
        .nLength = @sizeOf(windows.SECURITY_ATTRIBUTES),
        .lpSecurityDescriptor = null,
        .bInheritHandle = .TRUE,
    };
    var read_end: windows.HANDLE = undefined;
    var write_end: windows.HANDLE = undefined;
    if (win32.CreatePipe(&read_end, &write_end, &security, 0) == .FALSE) return createError();

    const ends: stdio_plan.Pipe = switch (direction) {
        .to_child => .{ .child = read_end, .parent = write_end },
        .from_child => .{ .child = write_end, .parent = read_end },
    };
    _ = win32.SetHandleInformation(ends.parent, win32.handle_flag_inherit, 0);
    return ends;
}

/// The null device, opened for both directions and inheritable, so one handle
/// can serve all three of the child's streams.
fn openNul() SpawnError!windows.HANDLE {
    var security: windows.SECURITY_ATTRIBUTES = .{
        .nLength = @sizeOf(windows.SECURITY_ATTRIBUTES),
        .lpSecurityDescriptor = null,
        .bInheritHandle = .TRUE,
    };
    const handle = win32.CreateFileW(
        std.unicode.wtf8ToWtf16LeStringLiteral("NUL"),
        win32.generic_read | win32.generic_write,
        win32.file_share_read | win32.file_share_write,
        &security,
        win32.open_existing,
        0,
        null,
    );
    if (handle == windows.INVALID_HANDLE_VALUE) return error.NoDevice;
    return handle;
}

//======================================================================
// The attribute list.
//======================================================================

/// A `PROC_THREAD_ATTRIBUTE_LIST`, whose size only the operating system knows.
///
/// The buffer is allocated from the caller's arena, but the list itself has to
/// be deleted with `DeleteProcThreadAttributeList` before that memory goes
/// away, which is what `deinit` is for.
const AttributeList = struct {
    raw: *win32.ProcThreadAttributeList,

    fn init(arena: Allocator, count: u32) SpawnError!AttributeList {
        var size: windows.SIZE_T = 0;
        // Documented to fail with `ERROR_INSUFFICIENT_BUFFER` and report the
        // size it wants; a success here would mean a list of no bytes.
        _ = win32.InitializeProcThreadAttributeList(null, count, 0, &size);
        if (size == 0) return error.Unexpected;

        // Over-aligned rather than guessed at: the list holds pointers.
        const buffer = try arena.alignedAlloc(u8, .of(usize), size);
        const raw: *win32.ProcThreadAttributeList = @ptrCast(buffer.ptr); // safe: an opaque list in a buffer of the size Windows asked for, pointer-aligned
        if (win32.InitializeProcThreadAttributeList(raw, count, 0, &size) == .FALSE) {
            return createError();
        }
        return .{ .raw = raw };
    }

    /// Attaches a pseudoconsole to every process started with this list.
    ///
    /// `UpdateProcThreadAttribute` keeps a pointer to the value rather than
    /// copying it for some attributes, so the `HPCON` must stay put until
    /// `CreateProcessW` has returned. It does: the `Pty` outlives the spawn.
    fn setPseudoConsole(list: *AttributeList, console: win32.Hpcon) SpawnError!void {
        if (win32.UpdateProcThreadAttribute(
            list.raw,
            0,
            win32.proc_thread_attribute_pseudoconsole,
            console,
            @sizeOf(win32.Hpcon),
            null,
            null,
        ) == .FALSE) return createError();
    }

    /// Limits what the child inherits to exactly these handles.
    ///
    /// `UpdateProcThreadAttribute` keeps a pointer to the array rather than
    /// copying it, so `handles` must outlive the `CreateProcessW` call. The
    /// arena it comes from does.
    fn setHandleList(list: *AttributeList, handles: []windows.HANDLE) SpawnError!void {
        if (win32.UpdateProcThreadAttribute(
            list.raw,
            0,
            win32.proc_thread_attribute_handle_list,
            @ptrCast(handles.ptr), // safe: the handle array Windows reads, its size in bytes beside it
            handles.len * @sizeOf(windows.HANDLE),
            null,
            null,
        ) == .FALSE) return createError();
    }

    fn deinit(list: *AttributeList) void {
        win32.DeleteProcThreadAttributeList(list.raw);
        list.* = undefined;
    }
};

//======================================================================
// Errors.
//======================================================================

/// `GetLastError` as one of `SpawnError`. Every call in this file that can
/// fail for a reason a caller might act on reports it this way.
fn createError() SpawnError {
    return switch (windows.GetLastError()) {
        .FILE_NOT_FOUND, .PATH_NOT_FOUND, .MOD_NOT_FOUND => error.FileNotFound,
        .ACCESS_DENIED => error.AccessDenied,
        .INVALID_NAME, .BAD_PATHNAME => error.FileNotFound,
        .FILENAME_EXCED_RANGE => error.NameTooLong,
        .DIRECTORY => error.BadWorkingDirectory,
        .BAD_EXE_FORMAT, .EXE_MACHINE_TYPE_MISMATCH, .INVALID_EXE_SIGNATURE => error.InvalidExe,
        .SHARING_VIOLATION => error.FileBusy,
        .NOT_ENOUGH_MEMORY, .OUTOFMEMORY => error.SystemResources,
        .TOO_MANY_OPEN_FILES => error.ProcessFdQuotaExceeded,
        .MAX_THRDS_REACHED => error.ResourceLimitReached,
        else => |err| win32.unexpected(err),
    };
}
