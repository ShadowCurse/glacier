// Copyright (c) 2026 Egor Lazarchuk
// SPDX-License-Identifier: MIT

const std = @import("std");
const build_options = @import("build_options");
const log = @import("log.zig");
const parsing = @import("parsing.zig");
const control_block = @import("control_block.zig");

const vk = @import("vk.zig");
const vv = @import("vk_validation.zig");
const vulkan = @import("vulkan.zig");

const Allocator = std.mem.Allocator;
const Validation = vv.Validation;
const Database = @import("database.zig");
const Barrier = @import("barrier.zig");

const DryCreate = struct {
    const Self = @This();

    pub const create_vk_sampler = Self.create;
    pub const create_descriptor_set_layout = Self.create;
    pub const create_pipeline_layout = Self.create;
    pub const parse_shader_module = Self.create;
    pub const create_shader_module = Self.create;
    pub const create_render_pass = Self.create;
    pub const create_raytracing_pipeline = Self.create;
    pub const create_compute_pipeline = Self.create;
    pub const create_graphics_pipeline = Self.create;

    fn create(vk_device: vk.VkDevice, create_info: *align(8) const anyopaque) !vulkan.AnyHandle {
        var result: vulkan.AnyHandle = 0x69;
        asm volatile (""
            :
            : [vk_device] "r" (vk_device),
            : .{ .memory = true });
        asm volatile (""
            :
            : [create_info] "r" (create_info),
            : .{ .memory = true });
        asm volatile (""
            : [result] "=r" (result),
        );
        return result;
    }
};

const DryDestroy = struct {
    const Self = @This();

    pub const destroy_vk_sampler = Self.destroy;
    pub const destroy_descriptor_set_layout = Self.destroy;
    pub const destroy_pipeline_layout = Self.destroy;
    pub const parse_shader_module = Self.destroy;
    pub const destroy_shader_module = Self.destroy;
    pub const destroy_render_pass = Self.destroy;
    pub const destroy_pipeline = Self.destroy;

    fn destroy(vk_device: vk.VkDevice, handle: vulkan.AnyHandle) void {
        asm volatile (""
            :
            : [vk_device] "r" (vk_device),
        );
        asm volatile (""
            :
            : [handle] "r" (handle),
        );
    }
};

const NoValidation = struct {
    const Self = @This();

    pub const validate_VkSamplerCreateInfo = validate;
    pub const validate_VkDescriptorSetLayoutCreateInfo = validate;
    pub const validate_VkPipelineLayoutCreateInfo = validate;
    pub const validate_VkRenderPassCreateInfo = validate;
    pub const validate_VkGraphicsPipelineCreateInfo = validate;
    pub const validate_VkComputePipelineCreateInfo = validate;
    pub const validate_VkRayTracingPipelineCreateInfoKHR = validate;
    fn validate(_: *const vv.Extensions, _: *const anyopaque, _: bool) bool {
        return true;
    }

    pub fn validate_shader_code(_: *const vv.Validation, _: *const anyopaque) bool {
        return true;
    }
};

const PARSE = parsing;
const CREATE = if (build_options.no_driver) DryCreate else vulkan;
const DESTROY = if (build_options.no_driver) DryDestroy else vulkan;
const VALIDATE = if (build_options.no_validation) NoValidation else vv;

const RootEntry = struct {
    entry: *Database.Entry,
    arena: std.heap.ArenaAllocator,
};
pub fn init_root_entries(alloc: Allocator, db: *Database) ![]RootEntry {
    const graphics_pipelines = db.entries.getPtrConst(.graphics_pipeline).values().len;
    const compute_pipelines = db.entries.getPtrConst(.compute_pipeline).values().len;
    const raytracing_pipelines = db.entries.getPtrConst(.raytracing_pipeline).values().len;

    const total_pipelines = graphics_pipelines + compute_pipelines + raytracing_pipelines;
    const root_entries: []RootEntry = try alloc.alloc(RootEntry, total_pipelines);
    var re = root_entries;
    for (db.entries.getPtr(.graphics_pipeline).values(), re[0..graphics_pipelines]) |*e, *r|
        r.* = .{ .entry = e, .arena = .init(std.heap.page_allocator) };
    re = re[graphics_pipelines..];
    for (db.entries.getPtr(.compute_pipeline).values(), re[0..compute_pipelines]) |*e, *r|
        r.* = .{ .entry = e, .arena = .init(std.heap.page_allocator) };
    re = re[compute_pipelines..];
    for (db.entries.getPtr(.raytracing_pipeline).values(), re[0..raytracing_pipelines]) |*e, *r|
        r.* = .{ .entry = e, .arena = .init(std.heap.page_allocator) };
    return root_entries;
}

pub fn actual_thread_count(num_threads: ?u32) u32 {
    var thread_count: u32 = @truncate(std.Thread.getCpuCount() catch 1);
    if (num_threads) |nt| {
        if (nt != 0) thread_count = nt;
    }
    return thread_count;
}

pub const WorkQueue = struct {
    entries: []RootEntry,
    next_parse: std.atomic.Value(u32) = .init(0),
    next_create: std.atomic.Value(u32) = .init(0),

    const Self = @This();
    pub fn take_next_parse(self: *Self) ?*RootEntry {
        var result: ?*RootEntry = null;
        const next = self.next_parse.fetchAdd(1, .acq_rel);
        if (next < self.entries.len) result = &self.entries[next];
        return result;
    }
    pub fn take_next_create(self: *Self) ?*RootEntry {
        var result: ?*RootEntry = null;
        const next = self.next_create.fetchAdd(1, .acq_rel);
        if (next < self.entries.len) result = &self.entries[next];
        return result;
    }
};

pub const Task = struct {
    root_entry: *RootEntry = undefined,
    queue: std.ArrayListUnmanaged(struct { *Database.Entry, u32 }) = .empty,
    arena: std.heap.ArenaAllocator = undefined,
};
pub const Tasks = struct {
    tasks: [MAX_TASKS]Task = .{Task{}} ** MAX_TASKS,
    current: u8 = 0,

    const MAX_TASKS = 8;
    const Self = @This();

    pub fn next(self: *Self) *Task {
        const task = &self.tasks[self.current];
        self.current += 1;
        self.current %= MAX_TASKS;
        return task;
    }
};

pub const Context = struct {
    arena: std.heap.ArenaAllocator,
    shared_alloc: Allocator,
    barrier: *Barrier,
    db: *Database,
    work_queue: *WorkQueue,
    thread_count: u32,
    validation: *const Validation,
    vk_device: vk.VkDevice,
};

pub fn init_contexts(
    alloc: Allocator,
    shared_alloc: Allocator,
    barrier: *Barrier,
    db: *Database,
    work_queue: *WorkQueue,
    thread_count: u32,
    validation: *const Validation,
    vk_device: vk.VkDevice,
) ![]align(64) Context {
    const contexts = try alloc.alignedAlloc(Context, .@"64", thread_count);
    for (contexts) |*c| {
        c.* = .{
            .arena = .init(std.heap.page_allocator),
            .shared_alloc = shared_alloc,
            .barrier = barrier,
            .db = db,
            .work_queue = work_queue,
            .thread_count = thread_count,
            .validation = validation,
            .vk_device = vk_device,
        };
    }
    return contexts;
}

pub fn spawn_threads(
    alloc: Allocator,
    comptime function: fn (*Context) void,
    contexts: []Context,
) ![]std.Thread {
    const threads = try alloc.alloc(std.Thread, contexts.len);
    for (threads, contexts) |*t, *c| t.* = try std.Thread.spawn(.{}, function, .{c});
    return threads;
}

pub fn parse(context: *Context) !void {
    return parse_inner(PARSE, VALIDATE, context);
}

pub fn parse_inner(comptime P: type, comptime V: type, context: *Context) !void {
    const work_queue = context.work_queue;
    const shared_alloc = context.shared_alloc;
    const thread_alloc = context.arena.allocator();
    defer _ = context.arena.reset(.retain_capacity);

    var tasks: Tasks = .{};
    for (&tasks.tasks) |*t| t.arena = .init(thread_alloc);
    while (true) {
        const task = tasks.next();
        if (task.queue.items.len == 0) {
            if (work_queue.take_next_parse()) |root_entry| {
                log.debug(
                    @src(),
                    "Adding new parse task: {t} 0x{x:0>16}",
                    .{ root_entry.entry.tag, root_entry.entry.hash },
                );
                task.root_entry = root_entry;
                task.queue = .empty;
                _ = task.arena.reset(.retain_capacity);
                try task.queue.append(task.arena.allocator(), .{ root_entry.entry, 0 });
            }
        }
        for (&tasks.tasks) |*t| {
            if (t.queue.items.len != 0) break;
        } else {
            break;
        }
        if (task.queue.items.len == 0) continue;

        const tmp_alloc = task.arena.allocator();
        while (task.queue.pop()) |tuple| {
            const curr_entry, const next_dep = tuple;

            switch (curr_entry.parse(
                P,
                V,
                shared_alloc,
                task.root_entry.arena.allocator(),
                tmp_alloc,
                context.db,
                context.validation,
            )) {
                .parsed => {
                    if (next_dep != curr_entry.dependencies.len) {
                        try task.queue.append(tmp_alloc, .{ curr_entry, next_dep + 1 });
                        const dep = curr_entry.dependencies[next_dep];
                        try task.queue.append(tmp_alloc, .{ dep.entry, 0 });
                    }
                },
                .parsing => {
                    try task.queue.append(tmp_alloc, .{ curr_entry, next_dep });
                    break;
                },
                .invalid => {
                    log.debug(
                        @src(),
                        "Encountered invalid entry during parsing {t} 0x{x:0>16}",
                        .{ curr_entry.tag, curr_entry.hash },
                    );
                    curr_entry.decrement_dependencies();
                    while (task.queue.pop()) |t| {
                        const e, _ = t;
                        log.debug(
                            @src(),
                            "Invalidating parent: {t} 0x{x:0>16}",
                            .{ e.tag, e.hash },
                        );
                        e.status.store(.invalid, .release);
                        e.decrement_dependencies();
                    }
                    control_block.record_failed_entry(task.root_entry.entry.tag);
                    break;
                },
            }
        } else {
            control_block.record_parsed_entry(task.root_entry.entry.tag);
        }
    }
}

pub fn create(context: *Context) !void {
    return create_inner(PARSE, CREATE, VALIDATE, DESTROY, context);
}

pub fn create_inner(
    comptime P: type,
    comptime C: type,
    comptime V: type,
    comptime D: type,
    context: *Context,
) !void {
    const work_queue = context.work_queue;
    const thread_alloc = context.arena.allocator();

    var tasks: Tasks = .{};
    for (&tasks.tasks) |*t| t.arena = .init(thread_alloc);
    while (true) {
        const task = tasks.next();
        if (task.queue.items.len == 0) {
            if (work_queue.take_next_create()) |root_entry| {
                log.debug(
                    @src(),
                    "Adding new create task: {t} 0x{x:0>16}",
                    .{ root_entry.entry.tag, root_entry.entry.hash },
                );
                task.root_entry = root_entry;
                task.queue = .empty;
                _ = task.arena.reset(.retain_capacity);
                try task.queue.append(task.arena.allocator(), .{ root_entry.entry, 0 });
            }
        }
        for (&tasks.tasks) |*t| {
            if (t.queue.items.len != 0) break;
        } else {
            break;
        }
        if (task.queue.items.len == 0) continue;

        const tmp_alloc = task.arena.allocator();
        while (task.queue.pop()) |tuple| {
            const curr_entry, const next_dep = tuple;

            switch (curr_entry.create(
                P,
                C,
                V,
                tmp_alloc,
                context.db,
                context.validation,
                context.vk_device,
            )) {
                .dependencies => {
                    if (next_dep != curr_entry.dependencies.len) {
                        try task.queue.append(tmp_alloc, .{ curr_entry, next_dep + 1 });
                        const dep = curr_entry.dependencies[next_dep];
                        try task.queue.append(tmp_alloc, .{ dep.entry, 0 });
                    } else {
                        try task.queue.append(tmp_alloc, .{ curr_entry, next_dep });
                        break;
                    }
                },
                .creating => {
                    try task.queue.append(tmp_alloc, .{ curr_entry, next_dep });
                    break;
                },
                .created => {
                    curr_entry.destroy(D, context.vk_device);
                },
                .invalid => {
                    log.debug(
                        @src(),
                        "Encountered invalid entry during creating {t} 0x{x:0>16}",
                        .{ curr_entry.tag, curr_entry.hash },
                    );
                    curr_entry.destroy_dependencies(D, context.vk_device);
                    while (task.queue.pop()) |t| {
                        const e, _ = t;
                        log.debug(
                            @src(),
                            "Invalidating parent: {t} 0x{x:0>16}",
                            .{ e.tag, e.hash },
                        );
                        e.status.store(.invalid, .release);
                        e.destroy_dependencies(D, context.vk_device);
                    }
                    _ = task.arena.reset(.retain_capacity);
                    break;
                },
            }
        } else {
            _ = task.arena.reset(.retain_capacity);
            control_block.record_successful_entry(task.root_entry.entry.tag);
        }
    }
}

test "parse/create" {
    const Dummy = struct {
        fn parse(
            _: Allocator,
            _: Allocator,
            _: *const Database,
            _: []const u8,
        ) parsing.Error!parsing.Result {
            unreachable;
        }
        fn parse_with_dependencies(
            _: Allocator,
            _: Allocator,
            _: *const Database,
            _: []const u8,
        ) parsing.Error!parsing.ResultWithDependencies {
            unreachable;
        }

        fn put_pipelines(
            alloc: Allocator,
            db: *Database,
            data: []const struct {
                hash: u32,
                dependent_by: u32 = 0,
                create_info: ?*align(8) const anyopaque = null,
            },
        ) !void {
            db.entries.getPtr(.graphics_pipeline).deinit(alloc);
            db.entries = .initFill(.empty);
            for (data) |d| {
                try db.entries.getPtr(.graphics_pipeline).put(alloc, d.hash, .{
                    .tag = .graphics_pipeline,
                    .hash = d.hash,
                    .payload_flag = .not_compressed,
                    .payload_crc = 0,
                    .payload_stored_size = 1,
                    .payload_decompressed_size = 0,
                    .payload_file_offset = 0,
                    .status = if (d.create_info != null) .init(.parsed) else .init(.not_parsed),
                    .create_info = d.create_info,
                    .dependent_by = .init(d.dependent_by),
                });
            }
        }

        fn create(_: vk.VkDevice, _: *align(8) const anyopaque) !vulkan.AnyHandle {
            unreachable;
        }
        fn destroy(_: vk.VkDevice, _: vulkan.AnyHandle) void {
            unreachable;
        }
    };

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const alloc = arena.allocator();

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const tmp_file = try tmp_dir.dir.createFile(std.testing.io, "parse_test", .{ .read = true });
    try tmp_file.setLength(std.testing.io, 1);

    // Simple root node with 2 deps
    {
        const TestParse = struct {
            const Global = struct {
                var n: u32 = 0;
                var gp: vk.VkGraphicsPipelineCreateInfo = .{};
            };

            pub const parse_sampler = Dummy.parse;
            pub const parse_descriptor_set_layout = Dummy.parse_with_dependencies;
            pub const parse_pipeline_layout = Dummy.parse_with_dependencies;
            pub const parse_render_pass = Dummy.parse;
            pub const parse_compute_pipeline = Dummy.parse_with_dependencies;
            pub const parse_raytracing_pipeline = Dummy.parse_with_dependencies;
            pub fn parse_graphics_pipeline(
                _: Allocator,
                _: Allocator,
                _: *const Database,
                _: []const u8,
            ) parsing.Error!parsing.ResultWithDependencies {
                defer Global.n += 1;

                var dependencies: []const parsing.Dependency = &.{
                    .{ .tag = .graphics_pipeline, .hash = 1 },
                    .{ .tag = .graphics_pipeline, .hash = 2 },
                };
                if (Global.n != 0) dependencies = &.{};
                return .{
                    .version = 6,
                    .hash = Global.n,
                    .create_info = @ptrCast(&Global.gp),
                    .dependencies = dependencies,
                };
            }
        };

        var db: Database = .{ .file_fd = tmp_file.handle, .entries = .initFill(.empty), .arena = arena };
        try Dummy.put_pipelines(alloc, &db, &.{
            .{ .hash = 1 },
            .{ .hash = 2 },
        });
        var test_entry: Database.Entry = .{
            .tag = .graphics_pipeline,
            .hash = 0,
            .payload_flag = .not_compressed,
            .payload_crc = 0,
            .payload_stored_size = 1,
            .payload_decompressed_size = 0,
            .payload_file_offset = 0,
        };
        var root_entries: [1]RootEntry = .{.{ .entry = &test_entry, .arena = .init(alloc) }};
        var work_queue: WorkQueue = .{ .entries = &root_entries };
        var validation: vv.Validation = undefined;
        var thread_context: Context = .{
            .arena = .init(alloc),
            .shared_alloc = alloc,
            .barrier = undefined,
            .db = &db,
            .work_queue = &work_queue,
            .thread_count = 1,
            .validation = &validation,
            .vk_device = undefined,
        };
        try parse_inner(TestParse, NoValidation, &thread_context);
        try std.testing.expectEqual(.parsed, test_entry.status.raw);
        const pipelines = db.entries.getPtr(.graphics_pipeline);
        for (pipelines.values()) |*entry| {
            try std.testing.expectEqual(.parsed, entry.status.raw);
            try std.testing.expectEqual(1, entry.dependent_by.raw);
        }
    }

    // Simple root node with 2 deps, one of deps is invalid
    {
        const TestParse = struct {
            const Global = struct {
                var n: u32 = 0;
                var gp: vk.VkGraphicsPipelineCreateInfo = .{};
            };

            pub const parse_sampler = Dummy.parse;
            pub const parse_descriptor_set_layout = Dummy.parse_with_dependencies;
            pub const parse_pipeline_layout = Dummy.parse_with_dependencies;
            pub const parse_render_pass = Dummy.parse;
            pub const parse_compute_pipeline = Dummy.parse_with_dependencies;
            pub const parse_raytracing_pipeline = Dummy.parse_with_dependencies;
            pub fn parse_graphics_pipeline(
                _: Allocator,
                _: Allocator,
                _: *const Database,
                _: []const u8,
            ) parsing.Error!parsing.ResultWithDependencies {
                defer Global.n += 1;

                var dependencies: []const parsing.Dependency = undefined;
                var hash: u32 = undefined;
                switch (Global.n) {
                    0 => {
                        hash = 0;
                        dependencies = &.{
                            .{ .tag = .graphics_pipeline, .hash = 1 },
                            .{ .tag = .graphics_pipeline, .hash = 2 },
                        };
                    },
                    1 => {
                        hash = 1;
                        dependencies = &.{};
                    },
                    2 => {
                        return error.InvalidJson;
                    },
                    else => unreachable,
                }
                return .{
                    .version = 6,
                    .hash = hash,
                    .create_info = @ptrCast(&Global.gp),
                    .dependencies = dependencies,
                };
            }
        };

        var db: Database = .{ .file_fd = tmp_file.handle, .entries = .initFill(.empty), .arena = arena };
        try Dummy.put_pipelines(alloc, &db, &.{
            .{ .hash = 1 },
            .{ .hash = 2 },
        });

        var test_entry: Database.Entry = .{
            .tag = .graphics_pipeline,
            .hash = 0,
            .payload_flag = .not_compressed,
            .payload_crc = 0,
            .payload_stored_size = 1,
            .payload_decompressed_size = 0,
            .payload_file_offset = 0,
        };
        var root_entries: [1]RootEntry = .{.{ .entry = &test_entry, .arena = .init(alloc) }};
        var work_queue: WorkQueue = .{ .entries = &root_entries };
        var validation: vv.Validation = undefined;
        var thread_context: Context = .{
            .arena = .init(alloc),
            .shared_alloc = alloc,
            .barrier = undefined,
            .db = &db,
            .work_queue = &work_queue,
            .thread_count = 1,
            .validation = &validation,
            .vk_device = undefined,
        };
        try parse_inner(TestParse, NoValidation, &thread_context);
        try std.testing.expectEqual(.invalid, test_entry.status.raw);
        const pipelines = db.entries.getPtr(.graphics_pipeline);
        for (pipelines.values()) |*entry| {
            if (entry.hash == 1) {
                try std.testing.expectEqual(.parsed, entry.status.raw);
                try std.testing.expectEqual(0, entry.dependent_by.raw);
            }
            if (entry.hash == 2) {
                try std.testing.expectEqual(.invalid, entry.status.raw);
                try std.testing.expectEqual(0, entry.dependent_by.raw);
            }
        }
    }

    // Create simple root node with 2 deps
    // Make sure the creation and destruction order is correct
    {
        const Global = struct {
            var create_counter: u32 = 0;
            var destroy_counter: u32 = 0;
            var gp0: u64 = 0xA;
            var gp0_1: u64 = 0;
            var gp0_2: u64 = 0;
            var gp1: u64 = 0xB;
            var gp2: u64 = 0xC;
        };
        const Parse = struct {
            pub const parse_sampler = Dummy.parse;
            pub const parse_shader_module = Dummy.parse;
            pub const parse_descriptor_set_layout = Dummy.parse_with_dependencies;
            pub const parse_pipeline_layout = Dummy.parse_with_dependencies;
            pub const parse_render_pass = Dummy.parse;
            pub const parse_compute_pipeline = Dummy.parse_with_dependencies;
            pub const parse_raytracing_pipeline = Dummy.parse_with_dependencies;
            pub const parse_graphics_pipeline = Dummy.parse_with_dependencies;
        };
        const Create = struct {
            pub const create_vk_sampler = Dummy.create;
            pub const create_descriptor_set_layout = Dummy.create;
            pub const create_pipeline_layout = Dummy.create;
            pub const parse_shader_module = Dummy.create;
            pub const create_shader_module = Dummy.create;
            pub const create_render_pass = Dummy.create;
            pub const create_raytracing_pipeline = Dummy.create;
            pub const create_compute_pipeline = Dummy.create;
            pub fn create_graphics_pipeline(
                _: vk.VkDevice,
                create_info: *align(8) const anyopaque,
            ) !vulkan.AnyHandle {
                defer Global.create_counter += 1;
                const c: *const u64 = @ptrCast(create_info);
                switch (Global.create_counter) {
                    0 => try std.testing.expectEqual(0xB, c.*),
                    1 => try std.testing.expectEqual(0xC, c.*),
                    2 => try std.testing.expectEqual(0xA, c.*),
                    else => unreachable,
                }
                return c.*;
            }
        };
        const Destroy = struct {
            pub const destroy_vk_sampler = Dummy.destroy;
            pub const destroy_descriptor_set_layout = Dummy.destroy;
            pub const destroy_pipeline_layout = Dummy.destroy;
            pub const parse_shader_module = Dummy.destroy;
            pub const destroy_shader_module = Dummy.destroy;
            pub const destroy_render_pass = Dummy.destroy;
            pub fn destroy_pipeline(_: vk.VkDevice, handle: vulkan.AnyHandle) void {
                defer Global.destroy_counter += 1;
                switch (Global.destroy_counter) {
                    0 => std.testing.expectEqual(0xA, handle) catch unreachable,
                    1 => std.testing.expectEqual(0xB, handle) catch unreachable,
                    2 => std.testing.expectEqual(0xC, handle) catch unreachable,
                    else => unreachable,
                }
            }
        };

        var db: Database = .{ .file_fd = tmp_file.handle, .entries = .initFill(.empty), .arena = arena };
        try Dummy.put_pipelines(
            alloc,
            &db,
            &.{
                .{ .hash = 0xB, .dependent_by = 1, .create_info = &Global.gp1 },
                .{ .hash = 0xC, .dependent_by = 1, .create_info = &Global.gp2 },
            },
        );
        var test_entry: Database.Entry = .{
            .tag = .graphics_pipeline,
            .hash = 0xA,
            .payload_flag = .not_compressed,
            .payload_crc = 0,
            .payload_stored_size = 1,
            .payload_decompressed_size = 0,
            .payload_file_offset = 0,
            .status = .init(.parsed),
            .create_info = &Global.gp0,
            .dependencies = &.{
                .{
                    .entry = db.entries.getPtr(.graphics_pipeline).getPtr(0xB).?,
                    .ptr_to_handle = @ptrCast(&Global.gp0_1),
                },
                .{
                    .entry = db.entries.getPtr(.graphics_pipeline).getPtr(0xC).?,
                    .ptr_to_handle = @ptrCast(&Global.gp0_2),
                },
            },
        };
        var root_entries: [1]RootEntry = .{.{ .entry = &test_entry, .arena = .init(alloc) }};
        var work_queue: WorkQueue = .{ .entries = &root_entries };
        var thread_context: Context = .{
            .arena = .init(alloc),
            .shared_alloc = alloc,
            .barrier = undefined,
            .db = &db,
            .work_queue = &work_queue,
            .thread_count = 1,
            .validation = undefined,
            .vk_device = undefined,
        };
        try create_inner(Parse, Create, NoValidation, Destroy, &thread_context);

        try std.testing.expectEqual(0xB, Global.gp0_1);
        try std.testing.expectEqual(0xC, Global.gp0_2);
        try std.testing.expectEqual(.created, test_entry.status.raw);
        try std.testing.expectEqual(true, test_entry.dependencies_destroyed.raw);
        const pipelines = db.entries.getPtr(.graphics_pipeline);
        for (pipelines.values()) |*entry| {
            try std.testing.expectEqual(.created, entry.status.raw);
            try std.testing.expectEqual(0, entry.dependent_by.raw);
            try std.testing.expectEqual(true, entry.dependencies_destroyed.raw);
        }
    }

    // Create simple root node with 2 deps, but one is uncreatable
    // Make sure the creation and destruction order is correct
    {
        const Global = struct {
            var create_counter: u32 = 0;
            var destroy_counter: u32 = 0;
            var gp0: u64 = 0xA;
            var gp0_1: u64 = 0;
            var gp0_2: u64 = 0;
            var gp1: u64 = 0xB;
            var gp2: u64 = 0xC;
        };
        const Parse = struct {
            pub const parse_sampler = Dummy.parse;
            pub const parse_shader_module = Dummy.parse;
            pub const parse_descriptor_set_layout = Dummy.parse_with_dependencies;
            pub const parse_pipeline_layout = Dummy.parse_with_dependencies;
            pub const parse_render_pass = Dummy.parse;
            pub const parse_compute_pipeline = Dummy.parse_with_dependencies;
            pub const parse_raytracing_pipeline = Dummy.parse_with_dependencies;
            pub const parse_graphics_pipeline = Dummy.parse_with_dependencies;
        };
        const Create = struct {
            pub const create_vk_sampler = Dummy.create;
            pub const create_descriptor_set_layout = Dummy.create;
            pub const create_pipeline_layout = Dummy.create;
            pub const parse_shader_module = Dummy.create;
            pub const create_shader_module = Dummy.create;
            pub const create_render_pass = Dummy.create;
            pub const create_raytracing_pipeline = Dummy.create;
            pub const create_compute_pipeline = Dummy.create;
            pub fn create_graphics_pipeline(
                _: vk.VkDevice,
                create_info: *align(8) const anyopaque,
            ) !vulkan.AnyHandle {
                defer Global.create_counter += 1;
                const c: *const u64 = @ptrCast(create_info);
                switch (Global.create_counter) {
                    0 => try std.testing.expectEqual(0xB, c.*),
                    1 => {
                        try std.testing.expectEqual(0xC, c.*);
                        return error.SomeError;
                    },
                    2 => try std.testing.expectEqual(0xA, c.*),
                    else => unreachable,
                }
                return c.*;
            }
        };
        const Destroy = struct {
            pub const destroy_vk_sampler = Dummy.destroy;
            pub const destroy_descriptor_set_layout = Dummy.destroy;
            pub const destroy_pipeline_layout = Dummy.destroy;
            pub const parse_shader_module = Dummy.destroy;
            pub const destroy_shader_module = Dummy.destroy;
            pub const destroy_render_pass = Dummy.destroy;
            pub fn destroy_pipeline(_: vk.VkDevice, handle: vulkan.AnyHandle) void {
                defer Global.destroy_counter += 1;
                switch (Global.destroy_counter) {
                    0 => std.testing.expectEqual(0xB, handle) catch unreachable,
                    else => unreachable,
                }
            }
        };

        var db: Database = .{ .file_fd = tmp_file.handle, .entries = .initFill(.empty), .arena = arena };
        try Dummy.put_pipelines(
            alloc,
            &db,
            &.{
                .{ .hash = 0xB, .dependent_by = 1, .create_info = &Global.gp1 },
                .{ .hash = 0xC, .dependent_by = 1, .create_info = &Global.gp2 },
            },
        );
        var test_entry: Database.Entry = .{
            .tag = .graphics_pipeline,
            .hash = 0xA,
            .payload_flag = .not_compressed,
            .payload_crc = 0,
            .payload_stored_size = 1,
            .payload_decompressed_size = 0,
            .payload_file_offset = 0,
            .status = .init(.parsed),
            .create_info = &Global.gp0,
            .dependencies = &.{
                .{
                    .entry = db.entries.getPtr(.graphics_pipeline).getPtr(0xB).?,
                    .ptr_to_handle = @ptrCast(&Global.gp0_1),
                },
                .{
                    .entry = db.entries.getPtr(.graphics_pipeline).getPtr(0xC).?,
                    .ptr_to_handle = @ptrCast(&Global.gp0_2),
                },
            },
        };
        var root_entries: [1]RootEntry = .{.{ .entry = &test_entry, .arena = .init(alloc) }};
        var work_queue: WorkQueue = .{ .entries = &root_entries };
        var thread_context: Context = .{
            .arena = .init(alloc),
            .shared_alloc = alloc,
            .barrier = undefined,
            .db = &db,
            .work_queue = &work_queue,
            .thread_count = 1,
            .validation = undefined,
            .vk_device = undefined,
        };
        try create_inner(Parse, Create, NoValidation, Destroy, &thread_context);

        try std.testing.expectEqual(0, Global.gp0_1);
        try std.testing.expectEqual(0, Global.gp0_2);
        try std.testing.expectEqual(.invalid, test_entry.status.raw);
        try std.testing.expectEqual(true, test_entry.dependencies_destroyed.raw);
        const pipelines = db.entries.getPtr(.graphics_pipeline);
        for (pipelines.values()) |*entry| {
            switch (entry.hash) {
                0xB => {
                    try std.testing.expectEqual(.created, entry.status.raw);
                    try std.testing.expectEqual(0, entry.dependent_by.raw);
                    try std.testing.expectEqual(true, entry.dependencies_destroyed.raw);
                },
                0xC => {
                    try std.testing.expectEqual(.invalid, entry.status.raw);
                    try std.testing.expectEqual(0, entry.dependent_by.raw);
                    try std.testing.expectEqual(true, entry.dependencies_destroyed.raw);
                },
                else => unreachable,
            }
        }
    }
}
