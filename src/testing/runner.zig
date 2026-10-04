//! Test reporting and a native watchdog spanning the body and Io teardown.
const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const upstream = @import("standard_test_runner");
const options = @import("conduit_runner_options");
const timings = @import("preflight_timings");
const io = std.Io.Threaded.global_single_threaded.io();

pub const std_options: std.Options = .{ .logFn = if (builtin.fuzz) upstream.log else log };
var errors: std.atomic.Value(usize) = .init(0);
var fuzz_test: bool = false;

pub fn fuzz(context: anytype, comptime testOne: fn (@TypeOf(context), *testing.Smith) anyerror!void, input: testing.FuzzInputOptions) anyerror!void {
    @disableInstrumentation();
    fuzz_test = true;
    return upstream.fuzz(context, testOne, input);
}

pub fn log(comptime level: std.log.Level, comptime scope: @EnumLiteral(), comptime format: []const u8, args: anytype) void {
    if (level == .err) _ = errors.fetchAdd(1, .monotonic);
    std.log.defaultLog(level, scope, format, args);
}

const Watchdog = struct {
    name: []const u8,
    done: std.atomic.Value(bool) = .init(false),
    phase: std.atomic.Value(enum(u8) { body, io_teardown, reporting }) = .init(.body),
    thread: ?std.Thread = null,

    fn start(watchdog: *Watchdog) !void {
        watchdog.thread = try std.Thread.spawn(.{}, watch, .{watchdog});
    }

    fn stop(watchdog: *Watchdog) void {
        watchdog.done.store(true, .release);
        watchdog.thread.?.join();
    }

    fn watch(watchdog: *Watchdog) void {
        const deadline = std.Io.Clock.awake.now(io).addDuration(.fromMilliseconds(options.watchdog_ms));
        while (!watchdog.done.load(.acquire)) {
            if (std.Io.Clock.awake.now(io).nanoseconds >= deadline.nanoseconds) {
                const directory = if (std.mem.startsWith(u8, watchdog.name, "Child.")) "Child/" else if (std.mem.startsWith(u8, watchdog.name, "testing.")) "testing/" else "";
                const name = watchdog.name[directory.len..];
                const file = name[0 .. std.mem.indexOfScalar(u8, name, '.') orelse name.len];
                std.debug.print("\nconduit: watchdog: src/{s}{s}.zig: {s}; phase={t}\n", .{ directory, file, watchdog.name, watchdog.phase.load(.acquire) });
                std.process.exit(1);
            }
            // Independent of testing.io: even its teardown must stay observable.
            if (builtin.os.tag == .windows) {
                const delay: std.os.windows.LARGE_INTEGER = -10_000;
                _ = std.os.windows.ntdll.NtDelayExecution(.FALSE, &delay);
            } else {
                const delay: std.c.timespec = .{ .sec = 0, .nsec = std.time.ns_per_ms };
                _ = std.c.nanosleep(&delay, null);
            }
        }
    }
};

pub fn main(init: std.process.Init.Minimal) void {
    // Zig's fuzzer owns its own protocol and callbacks. Keep that path intact.
    if (builtin.fuzz) return upstream.main(init);
    serverMain(init) catch |err| std.debug.panic("conduit test runner: {t}", .{err});
}

fn serverMain(init: std.process.Init.Minimal) !void {
    var arg_buffer: [8192]u8 = undefined;
    var arg_allocator: std.heap.FixedBufferAllocator = .init(&arg_buffer);
    const args = try init.args.toSlice(arg_allocator.allocator());
    var listen = false;
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--listen=-")) listen = true;
        if (std.mem.startsWith(u8, arg, "--seed=")) testing.random_seed = try std.fmt.parseUnsigned(u32, arg[7..], 0);
    }
    if (!listen) return upstream.main(init);
    var in_buffer: [4096]u8 = undefined;
    var out_buffer: [4096]u8 = undefined;
    var reader = std.Io.File.stdin().readerStreaming(io, &in_buffer);
    var writer = std.Io.File.stdout().writerStreaming(io, &out_buffer);
    var server = try std.zig.Server.init(.{ .in = &reader.interface, .out = &writer.interface, .zig_version = builtin.zig_version_string });
    const recorder = if (options.record_timings) try timings.Recorder.init(io, init.environ) else {};
    defer if (options.record_timings) recorder.deinit();
    while (true) {
        const header = try server.receiveMessage();
        switch (header.tag) {
            .exit => std.process.exit(0),
            .query_test_metadata => {
                var bytes: std.ArrayList(u8) = .empty;
                defer bytes.deinit(std.heap.page_allocator);
                try bytes.append(std.heap.page_allocator, 0);
                const names = try std.heap.page_allocator.alloc(u32, builtin.test_functions.len);
                defer std.heap.page_allocator.free(names);
                const panics = try std.heap.page_allocator.alloc(u32, builtin.test_functions.len);
                defer std.heap.page_allocator.free(panics);
                @memset(panics, 0);
                for (builtin.test_functions, names) |test_fn, *name| {
                    name.* = @intCast(bytes.items.len);
                    try bytes.appendSlice(std.heap.page_allocator, test_fn.name);
                    try bytes.append(std.heap.page_allocator, 0);
                }
                try server.serveTestMetadata(.{ .names = names, .expected_panic_msgs = panics, .string_bytes = bytes.items });
            },
            .run_test => {
                const index = try server.receiveBody_u32();
                const test_fn = builtin.test_functions[index];
                var watchdog: Watchdog = .{ .name = test_fn.name };
                try watchdog.start();
                defer watchdog.stop();
                std.debug.print("conduit: test: {s}\n", .{test_fn.name});
                try server.serveStringMessage(.test_started, &.{});
                testing.environ = init.environ;
                testing.allocator_instance = .{};
                testing.io_instance = .init(testing.allocator, .{ .argv0 = .init(init.args), .environ = init.environ });
                errors.store(0, .monotonic);
                fuzz_test = false;
                const started = if (options.record_timings) std.Io.Clock.Timestamp.now(io, .awake) else {};
                const status: std.zig.Server.Message.TestResults.Status = if (test_fn.func()) |_| .pass else |err| switch (err) {
                    error.SkipZigTest => .skip,
                    else => fail: {
                        std.debug.print("conduit: {s}: {t}\n", .{ test_fn.name, err });
                        break :fail .fail;
                    },
                };
                watchdog.phase.store(.io_teardown, .release);
                testing.io_instance.deinit();
                const leaks = testing.allocator_instance.detectLeaks();
                testing.allocator_instance.deinitWithoutLeakChecks();
                watchdog.phase.store(.reporting, .release);
                if (options.record_timings) try recorder.record(test_fn.name, @intCast(started.untilNow(io).raw.nanoseconds), @tagName(status));
                try server.serveTestResults(.{ .index = index, .flags = .{
                    .status = status,
                    .fuzz = fuzz_test,
                    .log_err_count = std.math.lossyCast(@FieldType(std.zig.Server.Message.TestResults.Flags, "log_err_count"), errors.load(.monotonic)),
                    .leak_count = std.math.lossyCast(@FieldType(std.zig.Server.Message.TestResults.Flags, "leak_count"), leaks),
                } });
            },
            else => return error.UnexpectedRunnerMessage,
        }
    }
}
