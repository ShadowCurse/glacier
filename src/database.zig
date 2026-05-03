// Copyright (c) 2026 Egor Lazarchuk
//
// Based in part on Fossilize project which is:
// Copyright (c) 2026 Hans-Kristian Arntzen
//
// SPDX-License-Identifier: MIT

const std = @import("std");
const miniz = @import("miniz");
const log = @import("log.zig");
const parsing = @import("parsing.zig");
const profiler = @import("profiler.zig");
const crc32 = @import("crc32.zig");
const os = @import("os.zig");

const vk = @import("vk.zig");
const vv = @import("vk_validation.zig");
const vulkan = @import("vulkan.zig");

const Validation = vv.Validation;
const Allocator = std.mem.Allocator;

pub const MEASUREMENTS = profiler.Measurements(
    "database",
    profiler.all_function_names_in_struct(@This()) ++
        profiler.all_function_names_in_struct(Entry) ++
        .{"mz_uncompress"},
);

file_fd: std.os.linux.fd_t,
entries: EntriesType,
arena: std.heap.ArenaAllocator,

pub const FileReadError = error{NotEnoughBytesInFile};
pub const CrcError = error{CrcMissmatch};
pub const MinizError = error{ CannotUncompressPayload, DecompressedSizeMissmatch };
pub const ReadAndCheckCrcError =
    std.posix.UnexpectedError ||
    std.mem.Allocator.Error ||
    FileReadError ||
    CrcError;
pub const GetPayloadError = ReadAndCheckCrcError ||
    MinizError;

const Database = @This();

pub const MAGIC = "\x81FOSSILIZEDB";
pub const Header = extern struct {
    magic: [12]u8,
    unused_1: u8,
    unused_2: u8,
    unused_3: u8,
    version: u8,
};

pub const EntriesType = std.EnumArray(
    Entry.Tag,
    std.AutoArrayHashMapUnmanaged(u64, Entry),
);
pub const Entry = struct {
    tag: Tag,
    hash: u64,

    payload_flag: PayloadFlags,
    payload_crc: u32,
    payload_stored_size: u32,
    payload_decompressed_size: u32,
    // TODO: maybe expand this to allow big files
    payload_file_offset: u32,

    create_info: ?*align(8) const anyopaque = null,
    dependencies: []const Dependency = &.{},
    handle: vulkan.AnyHandle = 0,

    // atomicly updated
    dependent_by: std.atomic.Value(u32) = .init(0),
    status: std.atomic.Value(Status) = .init(.not_parsed),
    dependencies_destroyed: std.atomic.Value(bool) = .init(false),

    comptime {
        const C = struct {
            fn check_size() void {
                log.comptime_assert(
                    @src(),
                    @sizeOf(Entry) == 64,
                    "Database.Entry must be 64 bytes, but it is {d}",
                    .{@as(u32, @sizeOf(Entry))},
                );
            }
        };
        C.check_size();
    }

    pub const Tag = enum(u8) {
        application_info = 0,
        sampler = 1,
        descriptor_set_layout = 2,
        pipeline_layout = 3,
        shader_module = 4,
        render_pass = 5,
        graphics_pipeline = 6,
        compute_pipeline = 7,
        application_blob_link = 8,
        raytracing_pipeline = 9,
    };

    pub const Status = enum(u8) {
        not_parsed = 0,
        parsing = 1,
        parsed = 2,
        creating = 3,
        created = 4,
        invalid = 5,
    };

    pub const PayloadFlags = enum {
        not_compressed,
        compressed,
    };

    pub const Dependency = struct {
        entry: *Entry,
        ptr_to_handle: ?*vulkan.AnyHandle,
    };

    pub fn print_graph(self: *const Entry, db: *const Database) !void {
        const G = struct {
            var padding: u32 = 0;
        };
        for (0..G.padding) |_|
            log.output("    ", .{});
        log.output(
            "{t} hash: 0x{x:0>16} status: {t} depended_by: {d}\n",
            .{ self.tag, self.hash, self.status.raw, self.dependent_by.raw },
        );
        for (self.dependencies) |dep| {
            G.padding += 1;
            try dep.entry.print_graph(db);
            G.padding -= 1;
        }
    }

    pub fn get_payload(
        self: *const Entry,
        alloc: Allocator,
        tmp_alloc: Allocator,
        db: *const Database,
    ) GetPayloadError![]const u8 {
        const prof_point = MEASUREMENTS.start(@src());
        defer MEASUREMENTS.end(prof_point);

        switch (self.payload_flag) {
            .not_compressed => {
                const payload = try self.read_and_check_crc(alloc, db);
                return payload;
            },
            .compressed => {
                const payload = try self.read_and_check_crc(tmp_alloc, db);
                const decompressed_payload = try alloc.alloc(u8, self.payload_decompressed_size);
                var decompressed_len: u64 = self.payload_decompressed_size;

                {
                    const pp = MEASUREMENTS.start_named("mz_uncompress");
                    defer MEASUREMENTS.end(pp);

                    const MzAlloc = struct {
                        fn mz_alloc(alloc_ptr: ?*anyopaque, items: usize, size: usize) callconv(.c) ?*anyopaque {
                            const a: *Allocator = @ptrCast(@alignCast(alloc_ptr.?));
                            const total_bytes = items * size;
                            const total_bytes_aligned_8 = (total_bytes + 8) & ~@as(usize, 7);
                            const result = a.alloc(u64, total_bytes_aligned_8 / 8) catch return null;
                            return @ptrCast(result.ptr);
                        }
                        fn mz_free(_: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {}
                    };

                    if (miniz.mz_uncompress(
                        decompressed_payload.ptr,
                        &decompressed_len,
                        payload.ptr,
                        payload.len,
                        &MzAlloc.mz_alloc,
                        &MzAlloc.mz_free,
                        @ptrCast(@constCast(&tmp_alloc)),
                    ) != miniz.MZ_OK)
                        return error.CannotUncompressPayload;
                }
                if (decompressed_len != self.payload_decompressed_size)
                    return error.DecompressedSizeMissmatch;
                return decompressed_payload;
            },
        }
    }

    pub fn read_and_check_crc(
        self: *const Entry,
        alloc: Allocator,
        db: *const Database,
    ) ReadAndCheckCrcError![]const u8 {
        // Alloc with cache line alignment for SIMD crc32 implementation.
        // All entries should have crc32.
        const payload = try alloc.alignedAlloc(u8, .@"64", self.payload_stored_size);

        const read_bytes = try os.pread(db.file_fd, payload, self.payload_file_offset);
        if (read_bytes != payload.len) return error.NotEnoughBytesInFile;

        if (self.payload_crc != 0) {
            const calculated_crc = crc32.crc32_simd(0, payload);
            if (calculated_crc != self.payload_crc)
                return error.CrcMissmatch;
        }

        return payload;
    }

    pub fn check_version_and_hash(self: *const Entry, v: anytype) !void {
        if (v.version != 6) {
            log.err(
                @src(),
                "Vertion of entry: {t} 0x{x:0>16} is invalid: {d} != {d}",
                .{ self.tag, self.hash, v.version, @as(u32, 6) },
            );
            return error.InvalidVerson;
        }
        if (v.hash != self.hash) {
            log.err(
                @src(),
                "Hash for entry: {t} 0x{x:0>16} is not equal to json value: 0x{x:0>16} != 0x{x:0>16}",
                .{ self.tag, self.hash, v.hash, self.hash },
            );
            return error.InvalidHash;
        }
    }

    pub const ParseResult = enum(u8) {
        parsing = 1,
        parsed = 2,
        invalid = 5,
    };
    pub fn parse(
        self: *Entry,
        comptime PARSE: type,
        comptime VALIDATE: type,
        dependency_alloc: Allocator,
        entry_alloc: Allocator,
        tmp_alloc: Allocator,
        db: *Database,
        validation: *const Validation,
    ) ParseResult {
        const prof_point = MEASUREMENTS.start_named("parse");
        defer MEASUREMENTS.end(prof_point);

        if (self.status.cmpxchgStrong(.not_parsed, .parsing, .acq_rel, .acquire)) |old| {
            log.assert(
                @src(),
                old == .parsing or old == .parsed or old == .invalid,
                "Entry: {t} 0x{x:0>16} has invalid parse state: {t}",
                .{ self.tag, self.hash, old },
            );
            return switch (old) {
                .parsed => .parsed,
                .parsing => .parsing,
                .invalid => .invalid,
                else => unreachable,
            };
        }

        // Shader modules consume a lot of memory. Instead of storing them
        // in database memory, do the parsing and creation on one go since
        // we know they cannot have dependencies.
        if (self.tag != .shader_module) {
            const payload = self.get_payload(tmp_alloc, tmp_alloc, db) catch |err| {
                log.debug(
                    @src(),
                    "Entry: {t} 0x{x:0>16} failed to read the payload: {t}",
                    .{ self.tag, self.hash, err },
                );
                self.status.store(.invalid, .release);
                return .invalid;
            };
            self.parse_inner(
                PARSE,
                VALIDATE,
                dependency_alloc,
                entry_alloc,
                tmp_alloc,
                db,
                validation,
                payload,
            ) catch |err| {
                log.debug(
                    @src(),
                    "Entry: {t} 0x{x:0>16} failed parse: {t}",
                    .{ self.tag, self.hash, err },
                );
                if (err == parsing.ScannerError.InvalidJson)
                    log.debug(@src(), "payload: {s}", .{payload});

                self.status.store(.invalid, .release);
                return .invalid;
            };
        }

        log.debug(@src(), "Entry: {t} 0x{x:0>16} parsed", .{ self.tag, self.hash });
        self.status.store(.parsed, .release);
        return .parsed;
    }

    pub fn process_result_with_dependencies(
        self: *Entry,
        alloc: Allocator,
        db: *Database,
        result: *const parsing.ResultWithDependencies,
    ) !void {
        const prof_point = MEASUREMENTS.start(@src());
        defer MEASUREMENTS.end(prof_point);

        try self.check_version_and_hash(result);
        self.create_info = result.create_info;
        const dependencies = try alloc.alloc(Dependency, result.dependencies.len);
        for (result.dependencies, 0..) |dep, i| {
            const dep_entry = db.entries.getPtr(dep.tag).getPtr(dep.hash);
            log.assert(
                @src(),
                dep_entry != null,
                "Entry: {t} 0x{x:0>16} parsed correctly, but dependency {t} 0x{x:0>16} cannot be found",
                .{ self.tag, self.hash, dep.tag, dep.hash },
            );
            dependencies[i] = .{
                .entry = dep_entry.?,
                .ptr_to_handle = @ptrCast(dep.ptr_to_handle),
            };
            _ = dep_entry.?.dependent_by.fetchAdd(1, .release);
        }
        self.dependencies = dependencies;
    }

    pub fn parse_inner(
        self: *Entry,
        comptime PARSE: type,
        comptime VALIDATE: type,
        dependency_alloc: Allocator,
        entry_alloc: Allocator,
        tmp_alloc: Allocator,
        db: *Database,
        validation: *const Validation,
        payload: []const u8,
    ) !void {
        const prof_point = MEASUREMENTS.start_named("parse_inner");
        defer MEASUREMENTS.end(prof_point);

        switch (self.tag) {
            .sampler => {
                const result = try PARSE.parse_sampler(entry_alloc, tmp_alloc, db, payload);
                try self.check_version_and_hash(result);
                self.create_info = result.create_info;
                if (!VALIDATE.validate_VkSamplerCreateInfo(
                    &validation.extensions,
                    @ptrCast(result.create_info),
                    true,
                ))
                    return error.CheckFailedVkSamplerCreateInfo;
            },
            .descriptor_set_layout => {
                const result = try PARSE.parse_descriptor_set_layout(
                    entry_alloc,
                    tmp_alloc,
                    db,
                    payload,
                );
                try self.process_result_with_dependencies(dependency_alloc, db, &result);
                if (!VALIDATE.validate_VkDescriptorSetLayoutCreateInfo(
                    &validation.extensions,
                    @ptrCast(result.create_info),
                    true,
                ))
                    return error.CheckFailedVkDescriptorSetLayoutCreateInfo;
            },
            .pipeline_layout => {
                const result =
                    try PARSE.parse_pipeline_layout(entry_alloc, tmp_alloc, db, payload);
                try self.process_result_with_dependencies(dependency_alloc, db, &result);
                if (!VALIDATE.validate_VkPipelineLayoutCreateInfo(
                    &validation.extensions,
                    @ptrCast(result.create_info),
                    true,
                ))
                    return error.CheckFailedVkPipelineLayoutCreateInfo;
            },
            .render_pass => {
                const result = try PARSE.parse_render_pass(
                    entry_alloc,
                    tmp_alloc,
                    db,
                    payload,
                );
                try self.check_version_and_hash(result);
                self.create_info = result.create_info;
                if (!VALIDATE.validate_VkRenderPassCreateInfo(
                    &validation.extensions,
                    @ptrCast(result.create_info),
                    true,
                ))
                    return error.CheckFailedVkRenderPassCreateInfo;
            },
            .graphics_pipeline => {
                const result = try PARSE.parse_graphics_pipeline(
                    entry_alloc,
                    tmp_alloc,
                    db,
                    payload,
                );
                try self.process_result_with_dependencies(dependency_alloc, db, &result);
                if (!VALIDATE.validate_VkGraphicsPipelineCreateInfo(
                    &validation.extensions,
                    @ptrCast(result.create_info),
                    true,
                ))
                    return error.CheckFailedVkGraphicsPipelineCreateInfo;
            },
            .compute_pipeline => {
                const result = try PARSE.parse_compute_pipeline(
                    entry_alloc,
                    tmp_alloc,
                    db,
                    payload,
                );
                try self.process_result_with_dependencies(dependency_alloc, db, &result);
                if (!VALIDATE.validate_VkComputePipelineCreateInfo(
                    &validation.extensions,
                    @ptrCast(result.create_info),
                    true,
                ))
                    return error.CheckFailedVkComputePipelineCreateInfo;
            },
            .raytracing_pipeline => {
                const result = try PARSE.parse_raytracing_pipeline(
                    entry_alloc,
                    tmp_alloc,
                    db,
                    payload,
                );
                try self.process_result_with_dependencies(dependency_alloc, db, &result);
                if (!VALIDATE.validate_VkRayTracingPipelineCreateInfoKHR(
                    &validation.extensions,
                    @ptrCast(result.create_info),
                    true,
                ))
                    return error.CheckFailedVkRayTracingPipelineCreateInfoKHR;
            },
            else => {},
        }
    }

    pub const CreateResult = enum(u8) {
        creating = 3,
        created = 4,
        invalid = 5,
        dependencies = 6,
    };
    pub fn create(
        self: *Entry,
        comptime PARSE: type,
        comptime CREATE: type,
        comptime VALIDATE: type,
        tmp_alloc: Allocator,
        db: *Database,
        validation: *const Validation,
        vk_device: vk.VkDevice,
    ) CreateResult {
        const prof_point = MEASUREMENTS.start_named("create");
        defer MEASUREMENTS.end(prof_point);

        if (self.status.load(.acquire) == .invalid) return .invalid;
        for (self.dependencies) |dep| {
            const d_status = dep.entry.status.load(.acquire);
            if (d_status == .invalid) {
                self.status.store(.invalid, .release);
                return .invalid;
            }
            if (d_status != .created) return .dependencies;
        }

        if (self.status.cmpxchgStrong(.parsed, .creating, .acq_rel, .acquire)) |old| {
            log.assert(
                @src(),
                old == .creating or old == .created or old == .invalid,
                "Entry: {t} 0x{x:0>16} has invalid create state: {t}",
                .{ self.tag, self.hash, old },
            );
            return switch (old) {
                .created => .created,
                .creating => .creating,
                .invalid => .invalid,
                else => unreachable,
            };
        }

        self.create_inner(PARSE, CREATE, VALIDATE, tmp_alloc, db, validation, vk_device) catch |err| {
            log.debug(
                @src(),
                "Entry: {t} 0x{x:0>16} cannot be created: {t}",
                .{ self.tag, self.hash, err },
            );
            self.status.store(.invalid, .release);
            return .invalid;
        };

        log.debug(@src(), "Entry: {t} 0x{x:0>16} created", .{ self.tag, self.hash });
        self.status.store(.created, .release);
        return .created;
    }

    pub fn create_inner(
        self: *Entry,
        comptime PARSE: type,
        comptime CREATE: type,
        comptime VALIDATE: type,
        tmp_alloc: Allocator,
        db: *Database,
        validation: *const Validation,
        vk_device: vk.VkDevice,
    ) !void {
        const prof_point = MEASUREMENTS.start_named("create_inner");
        defer MEASUREMENTS.end(prof_point);

        for (self.dependencies) |dep| {
            log.assert(
                @src(),
                dep.entry.handle != 0,
                "Entry: {t} 0x{x:0>16} has null handle for dependency {t} 0x{x:0>16}",
                .{ self.tag, self.hash, dep.entry.tag, dep.entry.hash },
            );
            log.assert(
                @src(),
                dep.ptr_to_handle != null,
                "Entry: {t} 0x{x:0>16} Dependency {t} 0x{x:0>16} contains null ptr_to_handle",
                .{ self.tag, self.hash, dep.entry.tag, dep.entry.hash },
            );
            dep.ptr_to_handle.?.* = dep.entry.handle;
        }
        switch (self.tag) {
            .sampler => self.handle = try CREATE.create_vk_sampler(vk_device, @ptrCast(self.create_info)),
            .descriptor_set_layout => self.handle =
                @bitCast(try CREATE.create_descriptor_set_layout(vk_device, @ptrCast(self.create_info))),
            .pipeline_layout => self.handle =
                @bitCast(try CREATE.create_pipeline_layout(vk_device, @ptrCast(self.create_info))),
            .shader_module => {
                const payload = try self.get_payload(tmp_alloc, tmp_alloc, db);
                const result = try PARSE.parse_shader_module(
                    tmp_alloc,
                    tmp_alloc,
                    db,
                    payload,
                );
                try self.check_version_and_hash(result);
                if (!VALIDATE.validate_shader_code(validation, @ptrCast(result.create_info)))
                    return error.InvalidShaderCode;

                self.handle =
                    @bitCast(try CREATE.create_shader_module(vk_device, @ptrCast(result.create_info)));
            },
            .render_pass => self.handle =
                @bitCast(try CREATE.create_render_pass(vk_device, @ptrCast(self.create_info))),
            .graphics_pipeline => self.handle =
                @bitCast(try CREATE.create_graphics_pipeline(vk_device, @ptrCast(self.create_info))),
            .compute_pipeline => self.handle =
                @bitCast(try CREATE.create_compute_pipeline(vk_device, @ptrCast(self.create_info))),
            .raytracing_pipeline => self.handle =
                @bitCast(try CREATE.create_raytracing_pipeline(vk_device, @ptrCast(self.create_info))),
            else => {},
        }
    }

    pub fn decrement_dependencies(self: *Entry) void {
        const prof_point = MEASUREMENTS.start(@src());
        defer MEASUREMENTS.end(prof_point);

        if (self.dependencies_destroyed.cmpxchgStrong(false, true, .acq_rel, .acquire) == null) {
            for (self.dependencies) |dep| _ = dep.entry.dependent_by.fetchSub(1, .acq_rel);
        }
    }

    pub fn destroy_dependencies(
        self: *Entry,
        comptime DESTROY: type,
        vk_device: vk.VkDevice,
    ) void {
        const prof_point = MEASUREMENTS.start_named("destroy_dependencies");
        defer MEASUREMENTS.end(prof_point);

        if (self.dependencies_destroyed.cmpxchgStrong(false, true, .acq_rel, .acquire) == null) {
            for (self.dependencies) |dep| {
                _ = dep.entry.dependent_by.fetchSub(1, .acq_rel);
                dep.entry.destroy(DESTROY, vk_device);
            }
        }
    }

    pub fn destroy(self: *Entry, comptime DESTROY: type, vk_device: vk.VkDevice) void {
        const prof_point = MEASUREMENTS.start_named("destroy");
        defer MEASUREMENTS.end(prof_point);

        const status = self.status.load(.acquire);
        if (status != .created) return;

        const dependent_by = self.dependent_by.load(.acquire);
        if (dependent_by != 0) return;

        if (self.dependencies_destroyed.cmpxchgStrong(false, true, .acq_rel, .acquire) == null) {
            switch (self.tag) {
                .application_info => {},
                .sampler => DESTROY.destroy_vk_sampler(vk_device, self.handle),
                .descriptor_set_layout => DESTROY.destroy_descriptor_set_layout(vk_device, self.handle),
                .pipeline_layout => DESTROY.destroy_pipeline_layout(vk_device, self.handle),
                .shader_module,
                => DESTROY.destroy_shader_module(vk_device, self.handle),
                .render_pass,
                => DESTROY.destroy_render_pass(vk_device, self.handle),
                .graphics_pipeline,
                .compute_pipeline,
                .raytracing_pipeline,
                => DESTROY.destroy_pipeline(vk_device, self.handle),
                .application_blob_link => {},
            }
            for (self.dependencies) |dep| {
                _ = dep.entry.dependent_by.fetchSub(1, .acq_rel);
                dep.entry.destroy(DESTROY, vk_device);
            }
        }
    }
};
pub const FileEntry = extern struct {
    // 8 bytes: ???
    // 16 bytes: tag
    // 16 bytes: value
    tag_hash: [40]u8,
    stored_size: u32,
    flags: Flags,
    crc: u32,
    decompressed_size: u32,
    // payload of `stored_size` size

    pub const Flags = enum(u32) {
        NOT_COMPRESSED = 1,
        COMPRESSED = 2,
    };

    pub fn from_ptr(ptr: [*]const u8) FileEntry {
        var entry: FileEntry = undefined;
        const entry_bytes = std.mem.asBytes(&entry);
        var ptr_bytes: []const u8 = undefined;
        ptr_bytes.ptr = ptr;
        ptr_bytes.len = @sizeOf(FileEntry);
        @memcpy(entry_bytes, ptr_bytes);
        return entry;
    }

    pub fn get_tag(entry: *const FileEntry) !Entry.Tag {
        const tag_str = entry.tag_hash[8..24];
        const tag_value = try std.fmt.parseInt(u8, tag_str, 16);
        return @enumFromInt(tag_value);
    }

    pub fn get_hash(entry: *const FileEntry) !u64 {
        const value_str = entry.tag_hash[24..];
        return std.fmt.parseInt(u64, value_str, 16);
    }

    pub fn format(self: *const FileEntry, w: *std.Io.Writer) !void {
        try w.print(
            "tag: {s:<21} value: 0x{x:<16} stored_size: {d:<6} flags: {s:<14} crc: {d:<10} decompressed_size: {d}",
            .{
                @tagName(try self.get_tag()),
                try self.get_hash(),
                self.stored_size,
                @tagName(self.flags),
                self.crc,
                self.decompressed_size,
            },
        );
    }
};

pub fn init(path: [:0]const u8) !Database {
    const prof_point = MEASUREMENTS.start(@src());
    defer MEASUREMENTS.end(prof_point);

    log.info(@src(), "Openning database as path: {s}", .{path});
    // const file = try std.fs.openFileAbsolute(path, .{});
    // const file = try std.fs.cwd().openFile(path, .{});
    const file_fd = try os.open(path, .{}, 0);
    const statx = try os.statx(file_fd);
    // const file_stat = try file.stat();
    const file_size = statx.size;
    var file_offset: u64 = 0;

    // Initial parsing here and goes through the file sequentialy
    try os.fadvise(file_fd, 0, @intCast(file_size), std.os.linux.POSIX_FADV.SEQUENTIAL);

    var header: Header = undefined;
    log.assert(@src(), try os.pread(file_fd, @ptrCast(&header), file_offset) == @sizeOf(Header), "", .{});
    file_offset += @sizeOf(Header);

    if (!std.mem.eql(u8, &header.magic, MAGIC)) return error.InvalidMagicValue;

    log.info(@src(), "Stored header version: {d}", .{header.version});

    // All database related allocations will be in this arena.
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const alloc = arena.allocator();

    var entries: EntriesType = .initFill(.empty);

    while (file_offset < statx.size) {
        // If entry is incomplete, stop
        if (file_size - file_offset < @sizeOf(FileEntry)) break;

        var entry: FileEntry = undefined;
        log.assert(
            @src(),
            try os.pread(file_fd, @ptrCast(&entry), file_offset) == @sizeOf(FileEntry),
            "",
            .{},
        );
        file_offset += @sizeOf(FileEntry);

        // If payload for the entry is incomplete, stop
        if (file_size - file_offset < entry.stored_size) break;

        const payload_file_offset: u64 = file_offset;
        file_offset += entry.stored_size;
        const entry_tag = entry.get_tag() catch {
            log.debug(@src(), "Skipping corrupted FileEntry: cannot parse tag: {any}", .{entry.tag_hash});
            continue;
        };
        // There is no used for these blobs, so skip them.
        if (entry_tag == .application_blob_link) continue;

        const entry_hash = entry.get_hash() catch {
            log.debug(@src(), "Skipping corrupted FileEntry: cannot parse hash: {any}", .{entry.tag_hash});
            continue;
        };
        const result = try entries.getPtr(entry_tag).getOrPut(alloc, entry_hash);
        if (result.found_existing) log.warn(
            @src(),
            "Entry: {t} 0x{x:0>16} found duplicate at file offset: 0x{x}",
            .{ entry_tag, entry_hash, file_offset - entry.stored_size - @sizeOf(FileEntry) },
        ) else {
            result.value_ptr.* = .{
                .tag = entry_tag,
                .hash = entry_hash,
                .payload_flag = if (entry.flags == .COMPRESSED) .compressed else .not_compressed,
                .payload_crc = entry.crc,
                .payload_stored_size = entry.stored_size,
                .payload_decompressed_size = entry.decompressed_size,
                .payload_file_offset = @intCast(payload_file_offset),
            };
        }
    }

    var iter = entries.iterator();
    while (iter.next()) |e| {
        const map = entries.getPtrConst(e.key);
        log.info(@src(), "Found {s:<21} {d:>8}", .{ @tagName(e.key), map.count() });
    }

    // Later file is accessed by multiple threads at random offsets
    try os.fadvise(file_fd, 0, @intCast(statx.size), std.os.linux.POSIX_FADV.RANDOM);

    return .{
        .file_fd = file_fd,
        .entries = entries,
        .arena = arena,
    };
}
