// Copyright (c) 2026 Egor Lazarchuk
// SPDX-License-Identifier: MIT

const std = @import("std");
const log = @import("log.zig");
const builtin = @import("builtin");

pub var global_freq: u64 = 0;
pub var global_last_thread_id: std.atomic.Value(u32) = .init(0);
pub var times: [options.num_threads]Time = .{Time{}} ** options.num_threads;
pub threadlocal var current: ?*Measurement = null;
pub threadlocal var thread_id: ?u32 = null;

pub const Options = struct {
    enabled: bool = false,
    num_threads: u32 = 128,
};

const root = @import("root");
pub const options: Options = if (@hasDecl(root, "profiler_options"))
    root.profiler_options
else
    .{};

pub const get_perf_counter = if (builtin.cpu.arch == .x86_64)
    rdtc
else if (builtin.cpu.arch == .aarch64)
    cntvct_el0
else
    @compileError("Only x86_64 is supported");

fn rdtc() u64 {
    var high: u64 = 0;
    var low: u64 = 0;
    asm volatile (
        \\rdtsc
        : [low] "={eax}" (low),
          [high] "={edx}" (high),
    );
    return (high << 32) | low;
}

fn cntvct_el0() u64 {
    return asm volatile ("mrs %[ret], cntvct_el0"
        : [ret] "=r" (-> u64),
    );
}

pub const get_perf_counter_frequency = if (builtin.cpu.arch == .x86_64)
    tsc_freq
else if (builtin.cpu.arch == .aarch64)
    cntfrq_el0
else
    @compileError("Only x86_64 is supported");

fn tsc_freq() u64 {
    const s = get_perf_counter();

    // std.Thread.sleep(1000_000);
    var timespec: std.os.linux.timespec = .{ .sec = 0, .nsec = 1000_000 };
    _ = std.os.linux.clock_nanosleep(.MONOTONIC, .{ .ABSTIME = false }, &timespec, null);

    const e = get_perf_counter();
    return (e - s) * 1000;
}

fn cntfrq_el0() u64 {
    return asm volatile ("mrs %[ret], cntfrq_el0"
        : [ret] "=r" (-> u64),
    );
}

pub fn all_function_names_in_struct(comptime T: type) []const [:0]const u8 {
    const type_info = @typeInfo(T);
    var result: []const [:0]const u8 = &.{};
    for (type_info.@"struct".decls) |decl|
        result = result ++ &[1][:0]const u8{decl.name};
    return result;
}

pub const Time = struct {
    start: u64 = 0,
    end: u64 = 0,

    fn delta(self: Time) u64 {
        return self.end - self.start;
    }
};

pub const Measurement = struct {
    without_children: u64 = 0,
    with_children: u64 = 0,
    hit_count: u64 = 0,
    // align size to 32 bytes so the cache line is divided into
    // whole number of Measurements
    _: u64 = 0,
};

pub fn start_measurement() void {
    take_thread_id();
    if (thread_id == 0)
        global_freq = get_perf_counter_frequency();
    times[thread_id.?].start = get_perf_counter();
}

pub fn end_measurement() void {
    times[thread_id.?].end = get_perf_counter();
}

pub fn take_thread_id() void {
    log.assert(
        @src(),
        thread_id == null,
        "{d} attempted taking multiple thread ids",
        .{std.Thread.getCurrentId()},
    );
    thread_id = global_last_thread_id.fetchAdd(1, .seq_cst);
}

pub fn Measurements(comptime FILE: []const u8, comptime NAMES: []const []const u8) type {
    const thread_measurements_size = NAMES.len * @sizeOf(Measurement);
    const aligned_thread_measurements_size = std.mem.alignForward(u64, thread_measurements_size, 64);
    const num_of_measurements = aligned_thread_measurements_size / @sizeOf(Measurement);
    log.comptime_assert(@src(), num_of_measurements % 2 == 0, "", .{});

    return if (!options.enabled)
        struct {
            pub fn start(comptime _: std.builtin.SourceLocation) void {}
            pub fn start_named(comptime _: []const u8) void {}
            pub fn end(_: void) void {}
            pub fn print() void {}
        }
    else
        struct {
            pub var measurements: [options.num_threads][num_of_measurements]Measurement =
                .{.{Measurement{}} ** num_of_measurements} ** options.num_threads;

            pub const Point = struct {
                start_time: u64,
                parent: ?*Measurement,
                current: *Measurement,
                current_with_children: u64,
            };

            pub fn start(comptime src: std.builtin.SourceLocation) Point {
                return start_named(src.fn_name);
            }

            pub fn start_named(comptime name: []const u8) Point {
                const index = comptime blk: {
                    var found: bool = false;
                    for (NAMES, 0..) |n, i| {
                        if (std.mem.eql(u8, n, name)) {
                            found = true;
                            break :blk i;
                        }
                    }
                    if (!found) log.comptime_err(
                        @src(),
                        "Cannot find profile point: {s} in the file: {s}",
                        .{ name, FILE },
                    );
                };
                const parent = current;
                current = &measurements[thread_id.?][index];
                return .{
                    .start_time = get_perf_counter(),
                    .parent = parent,
                    .current = current.?,
                    .current_with_children = current.?.with_children,
                };
            }

            pub fn end(point: Point) void {
                const end_time = get_perf_counter();
                const elapsed = end_time - point.start_time;
                point.current.hit_count += 1;
                point.current.without_children +%= elapsed;
                point.current.with_children = point.current_with_children + elapsed;
                if (point.parent) |parent| parent.without_children -%= elapsed;
                current = point.parent;
            }

            pub fn max_name_aligment() u64 {
                var longest: u64 = 0;
                for (NAMES) |n| longest = @max(longest, n.len);
                return longest + FILE.len;
            }

            pub fn print(comptime NAME_ALIGN: u64, tid: u32) void {
                const freq: f64 = @floatFromInt(global_freq);
                const elapsed: f64 = @floatFromInt(times[tid].delta());
                inline for (NAMES, measurements[tid][0..NAMES.len]) |name, m| {
                    if (m.hit_count != 0) {
                        const without_children_ms: f64 =
                            @as(f64, @floatFromInt(m.without_children)) / freq * 1000.0;
                        const without_children: f64 =
                            @as(f64, @floatFromInt(m.without_children)) / elapsed * 100.0;
                        const with_children_ms: f64 =
                            @as(f64, @floatFromInt(m.with_children)) / freq * 1000.0;
                        const with_children: f64 =
                            @as(f64, @floatFromInt(m.with_children)) / elapsed * 100.0;
                        const full_name = std.fmt.comptimePrint("{s}:{s}", .{ FILE, name });
                        log.info(
                            @src(),
                            "t: {d:>3} | {s:<" ++
                                std.fmt.comptimePrint("{d}", .{NAME_ALIGN + 1}) ++
                                "} | hit: {d:>9} | exclusive: {d:>12} cycles | {d:>12.3} ms | {d:>7.3}% | inclusive: {d:>12} cycles | {d:>12.3} ms | {d:>7.3}%",
                            .{
                                tid,
                                full_name,
                                m.hit_count,
                                m.without_children,
                                without_children_ms,
                                without_children,
                                m.with_children,
                                with_children_ms,
                                with_children,
                            },
                        );
                    }
                }
            }
        };
}

pub fn print(comptime types: []const type) void {
    @setEvalBranchQuota(100_000);

    if (options.enabled) {
        const longest_name_aligment = comptime blk: {
            var longest: u64 = 0;
            for (types) |t| longest = @max(longest, t.max_name_aligment());
            break :blk longest;
        };
        for (0..global_last_thread_id.raw) |tid| {
            inline for (types) |t| t.print(longest_name_aligment, @intCast(tid));

            const freq: f64 = @floatFromInt(global_freq);
            const elapsed: f64 = @floatFromInt(times[tid].delta());
            const time_ms = elapsed / freq * 1000.0;
            log.info(@src(), "t: {d:>3} | total time: {d:>12.3} ms", .{ tid, time_ms });
        }
    }
}
