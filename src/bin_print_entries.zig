// Copyright (c) 2026 Egor Lazarchuk
// SPDX-License-Identifier: MIT

const std = @import("std");
const root = @import("root.zig");
const vk = @import("vk.zig");
const log = @import("log.zig");
const args_parser = @import("args_parser.zig");
const parsing = @import("parsing.zig");
const vv = @import("vk_validation.zig");
const vu = @import("vk_utils.zig");
const vulkan = @import("vulkan.zig");

const Database = @import("database.zig");
const Allocator = std.mem.Allocator;

pub const log_options = log.Options{
    .level = .err,
};

const Args = struct {
    database_path: [:0]const u8 = &.{},
    graph: bool = false,
    create_info: bool = false,
    hash: ?u64 = null,
    tag: ?Database.Entry.Tag = null,
};

pub fn main(init: std.process.Init.Minimal) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const arena_alloc = arena.allocator();
    var tmp_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const tmp_alloc = tmp_arena.allocator();

    const args = try args_parser.parse(init.args, Args, arena_alloc);
    if (args.database_path.len == 0) {
        args_parser.print_help(Args);
        return;
    }

    const thread_count = root.actual_thread_count(null);
    log.info(@src(), "Using {d} threads", .{thread_count});

    var db: Database = try .init(args.database_path);

    var validation: vv.Validation = undefined;
    const vk_instance, const vk_device = try vulkan.init(
        arena_alloc,
        tmp_alloc,
        &db,
        false,
        &validation,
    );
    defer vulkan.deinit(vk_instance, vk_device);
    _ = tmp_arena.reset(.retain_capacity);

    const root_entries = try root.init_root_entries(arena_alloc, &db);
    var work_queue: root.WorkQueue = .{ .entries = root_entries };

    const shared_alloc = db.arena.allocator();
    const contexts = try root.init_contexts(
        arena_alloc,
        shared_alloc,
        undefined,
        &db,
        &work_queue,
        thread_count,
        &validation,
        vk_device,
    );
    // Reuse already existing arena
    contexts[0].arena = tmp_arena;

    const secondary_threads = try root.spawn_threads(
        arena_alloc,
        secondary_thread_process,
        contexts[1..],
    );
    process(&contexts[0]);
    for (secondary_threads) |st| st.join();

    if (args.tag) |tag|
        try print_entries_of_tag(&args, &db, tag)
    else for (std.enums.values(Database.Entry.Tag)) |tag| {
        try print_entries_of_tag(&args, &db, tag);
    }

    var total_used_bytes = arena.queryCapacity() + db.arena.queryCapacity();
    for (contexts) |*c| total_used_bytes += c.arena.queryCapacity();
    log.info(@src(), "Total allocators memory: {d}MB", .{total_used_bytes / 1024 / 1024});
    const rusage = std.posix.getrusage(0);
    log.info(@src(), "Resource usage: max rss: {d}MB minor faults: {d} major faults: {d}", .{
        @as(usize, @intCast(rusage.maxrss)) / 1024,
        rusage.minflt,
        rusage.majflt,
    });
}

pub fn print_entries_of_tag(args: *const Args, db: *const Database, tag: Database.Entry.Tag) !void {
    const entries = db.entries.getPtrConst(tag).values();

    if (args.hash) |h| {
        var entry: ?*const Database.Entry = null;
        for (entries) |*e| if (e.hash == h) {
            entry = e;
        };
        if (entry) |e| try print_entry(args, db, e);
    } else {
        log.output("#### {t} ####\n", .{tag});
        for (entries) |*e| try print_entry(args, db, e);
    }
}

pub fn print_entry(args: *const Args, db: *const Database, entry: *const Database.Entry) !void {
    if (args.graph)
        try entry.print_graph(db);
    if (args.create_info) {
        var buff: [256]u8 = undefined;
        const name = try std.fmt.bufPrint(&buff, "0x{x:0>16}", .{entry.hash});
        if (entry.create_info) |ci| {
            vu.print_struct(name, ci, true);
        } else {
            log.output("{s}: no create_info\n", .{name});
        }
    }
}

pub fn secondary_thread_process(context: *root.Context) void {
    process(context);
}

pub fn process(context: *root.Context) void {
    root.parse(context) catch unreachable;
}
