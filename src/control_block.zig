// Copyright (c) 2026 Egor Lazarchuk
// SPDX-License-Identifier: MIT

const std = @import("std");
const os = @import("os.zig");
const Database = @import("database.zig");

var control_block: ?*SharedControlBlock = null;

pub const MAX_PROCESS_STATS = 256;
pub const CONTROL_BLOCK_MAGIC = 0x19bcde1d;
pub const SharedControlBlock = struct {
    version_cookie: u32,
    futex_lock: u32,

    successful_modules: std.atomic.Value(u32),
    successful_graphics: std.atomic.Value(u32),
    successful_compute: std.atomic.Value(u32),
    successful_raytracing: std.atomic.Value(u32),
    skipped_graphics: std.atomic.Value(u32),
    skipped_compute: std.atomic.Value(u32),
    skipped_raytracing: std.atomic.Value(u32),
    cached_graphics: std.atomic.Value(u32),
    cached_compute: std.atomic.Value(u32),
    cached_raytracing: std.atomic.Value(u32),
    clean_process_deaths: std.atomic.Value(u32),
    dirty_process_deaths: std.atomic.Value(u32),
    parsed_graphics: std.atomic.Value(u32),
    parsed_compute: std.atomic.Value(u32),
    parsed_raytracing: std.atomic.Value(u32),
    parsed_graphics_failures: std.atomic.Value(u32),
    parsed_compute_failures: std.atomic.Value(u32),
    parsed_raytracing_failures: std.atomic.Value(u32),
    parsed_module_failures: std.atomic.Value(u32),
    total_graphics: std.atomic.Value(u32),
    total_compute: std.atomic.Value(u32),
    total_raytracing: std.atomic.Value(u32),
    total_modules: std.atomic.Value(u32),
    banned_modules: std.atomic.Value(u32),
    module_validation_failures: std.atomic.Value(u32),
    progress_started: std.atomic.Value(u32),
    progress_complete: std.atomic.Value(u32),

    // Need to set before `progress_started` is set
    // This is a total number of pipelines
    static_total_count_graphics: std.atomic.Value(u32),
    static_total_count_compute: std.atomic.Value(u32),
    static_total_count_raytracing: std.atomic.Value(u32),

    num_running_processes: std.atomic.Value(u32),
    num_processes_memory_stats: std.atomic.Value(u32),
    metadata_shared_size_mib: std.atomic.Value(u32),
    process_reserved_memory_mib: [MAX_PROCESS_STATS]std.atomic.Value(u32),
    process_shared_memory_mib: [MAX_PROCESS_STATS]std.atomic.Value(u32),
    process_heartbeats: [MAX_PROCESS_STATS]std.atomic.Value(u32),

    dirty_pages_mib: std.atomic.Value(i32),
    io_stall_percentage: std.atomic.Value(i32),

    write_count: u32,
    read_count: u32,
    read_offset: u32,
    write_offset: u32,
    ring_buffer_offset: u32,
    ring_buffer_size: u32,
};

fn mmap(shmem_fd: std.posix.fd_t) !*SharedControlBlock {
    const statx = try os.statx(shmem_fd);
    if (statx.size < @as(i64, @intCast(@sizeOf(SharedControlBlock))))
        return error.SharedMemoryIsSmallerThanControlBlock;

    const mem = try std.posix.mmap(
        null,
        @intCast(statx.size),
        .{ .READ = true, .WRITE = true },
        .{ .TYPE = .SHARED },
        shmem_fd,
        0,
    );
    const cb: *SharedControlBlock = @ptrCast(@alignCast(mem.ptr));
    if (cb.version_cookie != CONTROL_BLOCK_MAGIC)
        return error.InvalidControlBlockMagic;
    return cb;
}

pub fn init(shmem_fd: std.posix.fd_t, db: *const Database, num_threads: u32) !void {
    const cb = try mmap(shmem_fd);
    const graphics_pipelines = db.entries.getPtrConst(.graphics_pipeline).values().len;
    const compute_pipelines = db.entries.getPtrConst(.compute_pipeline).values().len;
    const raytracing_pipelines = db.entries.getPtrConst(.raytracing_pipeline).values().len;

    cb.static_total_count_graphics.store(@intCast(graphics_pipelines), .release);
    cb.static_total_count_compute.store(@intCast(compute_pipelines), .release);
    cb.static_total_count_raytracing.store(@intCast(raytracing_pipelines), .release);
    cb.num_running_processes.store(num_threads, .release);
    cb.num_processes_memory_stats.store(num_threads, .release);
    cb.progress_started.store(1, .release);

    control_block = cb;
}

pub fn record_successful_entry(tag: Database.Entry.Tag) void {
    if (control_block) |cb| {
        switch (tag) {
            .graphics_pipeline => {
                _ = cb.successful_graphics.fetchAdd(1, .release);
            },
            .compute_pipeline => {
                _ = cb.successful_compute.fetchAdd(1, .release);
            },
            .raytracing_pipeline => {
                _ = cb.successful_raytracing.fetchAdd(1, .release);
            },
            else => {},
        }
    }
}

pub fn record_parsed_entry(tag: Database.Entry.Tag) void {
    if (control_block) |cb| {
        switch (tag) {
            .graphics_pipeline => {
                _ = cb.parsed_graphics.fetchAdd(1, .release);
            },
            .compute_pipeline => {
                _ = cb.parsed_compute.fetchAdd(1, .release);
            },
            .raytracing_pipeline => {
                _ = cb.parsed_raytracing.fetchAdd(1, .release);
            },
            else => {},
        }
    }
}

pub fn record_failed_entry(tag: Database.Entry.Tag) void {
    if (control_block) |cb| {
        switch (tag) {
            .graphics_pipeline => {
                _ = cb.parsed_graphics_failures.fetchAdd(1, .release);
            },
            .compute_pipeline => {
                _ = cb.parsed_compute_failures.fetchAdd(1, .release);
            },
            .raytracing_pipeline => {
                _ = cb.parsed_raytracing_failures.fetchAdd(1, .release);
            },
            else => {},
        }
    }
}
