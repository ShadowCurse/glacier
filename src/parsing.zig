// Copyright (c) 2026 Egor Lazarchuk
//
// Based in part on Fossilize project which is:
// Copyright (c) 2026 Hans-Kristian Arntzen
//
// SPDX-License-Identifier: MIT

const std = @import("std");
const log = @import("log.zig");
const simd = @import("simd.zig");
const profiler = @import("profiler.zig");

const vk = @import("vk.zig");
const vu = @import("vk_utils.zig");
const vulkan = @import("vulkan.zig");

const Json = @import("json.zig");
const Database = @import("database.zig");

const Allocator = std.mem.Allocator;

pub const MEASUREMENTS = profiler.Measurements(
    "parsing",
    profiler.all_function_names_in_struct(@This()),
);

pub const Context = struct {
    alloc: Allocator,
    tmp_alloc: Allocator,
    dependencies: std.ArrayListUnmanaged(Dependency) = .empty,
    scanner: *Json,
    db: *const Database,
};

pub const ScannerError = error{ InvalidJson, UnknownPnextChain };
pub const ParseIntError = std.fmt.ParseIntError;
pub const ParseFloatError = std.fmt.ParseFloatError;
pub const DecoderError = std.base64.Error;
pub const AdditionalError = error{
    BasePipelinesNotSupported,
    InvalidShaderPayloadEncoding,
    InvalidShaderPayload,
    NoShaderCodePayload,
    InvalidsTypeForLibraries,
    NoHandle,
};
pub const Error = Allocator.Error || ScannerError || ParseIntError || ParseFloatError ||
    DecoderError || AdditionalError;

pub const ParsedApplicationInfo = struct {
    version: u32,
    application_info: *const vk.VkApplicationInfo,
    device_features2: *const vk.VkPhysicalDeviceFeatures2,
};
pub fn parse_application_info(
    alloc: Allocator,
    tmp_alloc: Allocator,
    database: *const Database,
    json_str: []const u8,
) Error!ParsedApplicationInfo {
    const prof_point = MEASUREMENTS.start(@src());
    defer MEASUREMENTS.end(prof_point);

    var scanner = Json.init(tmp_alloc, json_str);
    const vk_application_info = try alloc.create(vk.VkApplicationInfo);
    const vk_physical_device_features2 = try alloc.create(vk.VkPhysicalDeviceFeatures2);

    var result: ParsedApplicationInfo = .{
        .version = 0,
        .application_info = vk_application_info,
        .device_features2 = vk_physical_device_features2,
    };

    var context: Context = .{
        .alloc = alloc,
        .tmp_alloc = tmp_alloc,
        .scanner = &scanner,
        .db = database,
    };

    while (try scanner_object_next_field(context.scanner)) |s| {
        if (std.mem.eql(u8, s, "version")) {
            const v = try scanner_next_number(context.scanner);
            result.version = try std.fmt.parseInt(u32, v, 10);
        } else if (std.mem.eql(u8, s, "applicationInfo")) {
            try parse_vk_application_info(&context, vk_application_info);
        } else if (std.mem.eql(u8, s, "physicalDeviceFeatures")) {
            try parse_vk_physical_device_features2(&context, vk_physical_device_features2);
        } else {
            const v = try scanner_next_number_or_string(context.scanner);
            log.warn(@src(), "Skipping unknown field {s}: {s}", .{ s, v });
        }
    }
    return result;
}

test "parse_application_info" {
    const json =
        \\{
        \\  "version": 69,
        \\  "applicationInfo": {},
        \\  "physicalDeviceFeatures": {}
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const alloc = arena.allocator();

    const db: Database = .{ .file_fd = undefined, .entries = .initFill(.empty), .arena = arena };

    const result = try parse_application_info(alloc, alloc, &db, json);
    try std.testing.expectEqual(69, result.version);
}

pub const Dependency = struct {
    tag: Database.Entry.Tag,
    hash: u64,
    ptr_to_handle: ?*vulkan.AnyHandle = null,
};

pub const Result = struct {
    version: u32,
    hash: u64,
    create_info: *align(8) const anyopaque,
};
pub const ResultWithDependencies = struct {
    version: u32,
    hash: u64,
    create_info: *align(8) const anyopaque,
    dependencies: []const Dependency = &.{},
};

pub fn parse_sampler(
    alloc: Allocator,
    tmp_alloc: Allocator,
    database: *const Database,
    json_str: []const u8,
) Error!Result {
    const prof_point = MEASUREMENTS.start(@src());
    defer MEASUREMENTS.end(prof_point);

    var scanner = Json.init(tmp_alloc, json_str);
    const create_info = try alloc.create(vk.VkSamplerCreateInfo);
    create_info.* = .{};

    var result: Result = .{
        .version = 0,
        .hash = 0,
        .create_info = @ptrCast(create_info),
    };

    var context: Context = .{
        .alloc = alloc,
        .tmp_alloc = tmp_alloc,
        .scanner = &scanner,
        .db = database,
    };

    while (try scanner_object_next_field(context.scanner)) |s| {
        if (std.mem.eql(u8, s, "version")) {
            const v = try scanner_next_number(context.scanner);
            result.version = try std.fmt.parseInt(u32, v, 10);
        } else if (std.mem.eql(u8, s, "samplers")) {
            try scanner_object_begin(context.scanner);
            const ss = try scanner_next_string(context.scanner);
            result.hash = str_to_hash(ss);
            try parse_simple_type(&context, create_info);
        } else {
            const v = try scanner_next_number_or_string(context.scanner);
            log.warn(@src(), "Skipping unknown field {s}: {s}", .{ s, v });
        }
    }
    return result;
}

test "parse_sampler" {
    const json =
        \\ {
        \\   "version": 69,
        \\   "samplers": {
        \\     "1111111111111111": {}
        \\   }
        \\ }
    ;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const alloc = arena.allocator();

    const db: Database = .{ .file_fd = undefined, .entries = .initFill(.empty), .arena = arena };

    const result = try parse_sampler(alloc, alloc, &db, json);
    try std.testing.expectEqual(69, result.version);
    try std.testing.expectEqual(0x1111111111111111, result.hash);
}

pub fn parse_descriptor_set_layout(
    alloc: Allocator,
    tmp_alloc: Allocator,
    database: *const Database,
    json_str: []const u8,
) Error!ResultWithDependencies {
    const prof_point = MEASUREMENTS.start(@src());
    defer MEASUREMENTS.end(prof_point);

    var scanner = Json.init(tmp_alloc, json_str);
    const create_info =
        try alloc.create(vk.VkDescriptorSetLayoutCreateInfo);

    var result: ResultWithDependencies = .{
        .version = 0,
        .hash = 0,
        .create_info = @ptrCast(create_info),
    };

    var context: Context = .{
        .alloc = alloc,
        .tmp_alloc = tmp_alloc,
        .scanner = &scanner,
        .db = database,
    };

    while (try scanner_object_next_field(context.scanner)) |s| {
        if (std.mem.eql(u8, s, "version")) {
            const v = try scanner_next_number(context.scanner);
            result.version = try std.fmt.parseInt(u32, v, 10);
        } else if (std.mem.eql(u8, s, "setLayouts")) {
            try scanner_object_begin(context.scanner);
            const ss = try scanner_next_string(context.scanner);
            result.hash = str_to_hash(ss);
            try parse_vk_descriptor_set_layout_create_info(
                &context,
                create_info,
            );
        } else {
            const v = try scanner_next_number_or_string(context.scanner);
            log.warn(@src(), "Skipping unknown field {s}: {s}", .{ s, v });
        }
    }
    result.dependencies = context.dependencies.items;
    return result;
}

test "parse_descriptor_set_layout" {
    const json =
        \\{
        \\  "version": 69,
        \\  "setLayouts": {
        \\    "1111111111111111": {}
        \\  }
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const alloc = arena.allocator();

    const db: Database = .{ .file_fd = undefined, .entries = .initFill(.empty), .arena = arena };

    const result = try parse_descriptor_set_layout(alloc, alloc, &db, json);
    try std.testing.expectEqual(69, result.version);
    try std.testing.expectEqual(0x1111111111111111, result.hash);
}

pub fn parse_pipeline_layout(
    alloc: Allocator,
    tmp_alloc: Allocator,
    database: *const Database,
    json_str: []const u8,
) Error!ResultWithDependencies {
    const prof_point = MEASUREMENTS.start(@src());
    defer MEASUREMENTS.end(prof_point);

    var scanner = Json.init(tmp_alloc, json_str);
    const create_info = try alloc.create(vk.VkPipelineLayoutCreateInfo);

    var result: ResultWithDependencies = .{
        .version = 0,
        .hash = 0,
        .create_info = @ptrCast(create_info),
    };

    var context: Context = .{
        .alloc = alloc,
        .tmp_alloc = tmp_alloc,
        .scanner = &scanner,
        .db = database,
    };

    while (try scanner_object_next_field(context.scanner)) |s| {
        if (std.mem.eql(u8, s, "version")) {
            const v = try scanner_next_number(context.scanner);
            result.version = try std.fmt.parseInt(u32, v, 10);
        } else if (std.mem.eql(u8, s, "pipelineLayouts")) {
            try scanner_object_begin(context.scanner);
            const ss = try scanner_next_string(context.scanner);
            result.hash = str_to_hash(ss);
            try parse_vk_pipeline_layout_create_info(
                &context,
                create_info,
            );
        } else {
            const v = try scanner_next_number_or_string(context.scanner);
            log.warn(@src(), "Skipping unknown field {s}: {s}", .{ s, v });
        }
    }
    result.dependencies = context.dependencies.items;
    return result;
}

test "parse_pipeline_layout" {
    const json =
        \\{
        \\  "version": 69,
        \\  "pipelineLayouts": {
        \\    "1111111111111111": {}
        \\  }
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const alloc = arena.allocator();

    const db: Database = .{ .file_fd = undefined, .entries = .initFill(.empty), .arena = arena };

    const result = try parse_pipeline_layout(alloc, alloc, &db, json);
    try std.testing.expectEqual(69, result.version);
    try std.testing.expectEqual(0x1111111111111111, result.hash);
}

pub fn parse_shader_module(
    alloc: Allocator,
    tmp_alloc: Allocator,
    database: *const Database,
    payload: []const u8,
) Error!Result {
    const prof_point = MEASUREMENTS.start(@src());
    defer MEASUREMENTS.end(prof_point);

    // For shader modules the payload is divided in to 2 parts: json and code.
    // json part is 0 teriminated.
    const json_str = std.mem.span(@as([*c]const u8, @ptrCast(payload.ptr)));
    if (json_str.len == payload.len)
        return error.NoShaderCodePayload;
    // The 0 byte is not included into the `json_str.len`, so add it manually.
    const shader_code_payload = payload[json_str.len + 1 ..];

    var scanner = Json.init(tmp_alloc, json_str);
    const create_info = try alloc.create(vk.VkShaderModuleCreateInfo);

    var result: Result = .{
        .version = 0,
        .hash = 0,
        .create_info = @ptrCast(create_info),
    };

    var context: Context = .{
        .alloc = alloc,
        .tmp_alloc = tmp_alloc,
        .scanner = &scanner,
        .db = database,
    };

    while (try scanner_object_next_field(context.scanner)) |s| {
        if (std.mem.eql(u8, s, "version")) {
            const v = try scanner_next_number(context.scanner);
            result.version = try std.fmt.parseInt(u32, v, 10);
        } else if (std.mem.eql(u8, s, "shaderModules")) {
            try scanner_object_begin(context.scanner);
            const ss = try scanner_next_string(context.scanner);
            result.hash = str_to_hash(ss);
            try parse_vk_shader_module_create_info(
                &context,
                create_info,
                shader_code_payload,
            );
        } else {
            const v = try scanner_next_number_or_string(context.scanner);
            log.warn(@src(), "Skipping unknown field {s}: {s}", .{ s, v });
        }
    }
    return result;
}

test "parse_shader_module" {
    const json =
        \\{
        \\  "version": 69,
        \\  "shaderModules": {
        \\    "1111111111111111": {}
        \\  }
        \\}
    ++ "\x00\x81\x82\x83\x00";
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const alloc = arena.allocator();

    const db: Database = .{ .file_fd = undefined, .entries = .initFill(.empty), .arena = arena };

    const result = try parse_shader_module(alloc, alloc, &db, json);
    try std.testing.expectEqual(69, result.version);
    try std.testing.expectEqual(0x1111111111111111, result.hash);
}

pub fn parse_render_pass(
    alloc: Allocator,
    tmp_alloc: Allocator,
    database: *const Database,
    json_str: []const u8,
) Error!Result {
    const prof_point = MEASUREMENTS.start(@src());
    defer MEASUREMENTS.end(prof_point);

    var scanner = Json.init(tmp_alloc, json_str);

    var result: Result = .{
        .version = 0,
        .hash = 0,
        .create_info = undefined,
    };

    var context: Context = .{
        .alloc = alloc,
        .tmp_alloc = tmp_alloc,
        .scanner = &scanner,
        .db = database,
    };

    while (try scanner_object_next_field(context.scanner)) |s| {
        if (std.mem.eql(u8, s, "version")) {
            const v = try scanner_next_number(context.scanner);
            result.version = try std.fmt.parseInt(u32, v, 10);
        } else if (std.mem.eql(u8, s, "renderPasses")) {
            try scanner_object_begin(context.scanner);
            const ss = try scanner_next_string(context.scanner);
            result.hash = str_to_hash(ss);
            const create_info = try alloc.create(vk.VkRenderPassCreateInfo);
            try parse_vk_render_pass_create_info(&context, create_info);
            result.create_info = @ptrCast(create_info);
        } else if (std.mem.eql(u8, s, "renderPasses2")) {
            try scanner_object_begin(context.scanner);
            const ss = try scanner_next_string(context.scanner);
            result.hash = str_to_hash(ss);
            const create_info = try alloc.create(vk.VkRenderPassCreateInfo2);
            try parse_vk_render_pass_create_info2(&context, create_info);
            result.create_info = @ptrCast(create_info);
        } else {
            const v = try scanner_next_number_or_string(context.scanner);
            log.warn(@src(), "Skipping unknown field {s}: {s}", .{ s, v });
        }
    }
    return result;
}

test "parse_render_pass" {
    const json =
        \\{
        \\  "version": 69,
        \\  "renderPasses": {
        \\    "1111111111111111": {}
        \\  }
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const alloc = arena.allocator();

    const db: Database = .{ .file_fd = undefined, .entries = .initFill(.empty), .arena = arena };

    const result = try parse_render_pass(alloc, alloc, &db, json);
    try std.testing.expectEqual(69, result.version);
    try std.testing.expectEqual(0x1111111111111111, result.hash);
}

pub fn parse_compute_pipeline(
    alloc: Allocator,
    tmp_alloc: Allocator,
    database: *const Database,
    json_str: []const u8,
) Error!ResultWithDependencies {
    const prof_point = MEASUREMENTS.start(@src());
    defer MEASUREMENTS.end(prof_point);

    var scanner = Json.init(tmp_alloc, json_str);
    const create_info = try alloc.create(vk.VkComputePipelineCreateInfo);

    var result: ResultWithDependencies = .{
        .version = 0,
        .hash = 0,
        .create_info = @ptrCast(create_info),
    };

    var context: Context = .{
        .alloc = alloc,
        .tmp_alloc = tmp_alloc,
        .scanner = &scanner,
        .db = database,
    };

    while (try scanner_object_next_field(context.scanner)) |s| {
        if (std.mem.eql(u8, s, "version")) {
            const v = try scanner_next_number(context.scanner);
            result.version = try std.fmt.parseInt(u32, v, 10);
        } else if (std.mem.eql(u8, s, "computePipelines")) {
            try scanner_object_begin(context.scanner);
            const ss = try scanner_next_string(context.scanner);
            result.hash = str_to_hash(ss);
            try parse_vk_compute_pipeline_create_info(
                &context,
                create_info,
            );
        }
    }
    result.dependencies = context.dependencies.items;
    return result;
}

test "parse_compute_pipeline" {
    const json =
        \\{
        \\  "version": 69,
        \\  "computePipelines": {
        \\    "1111111111111111": {}
        \\  }
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const alloc = arena.allocator();

    const db: Database = .{
        .file_fd = undefined,
        .entries = .initFill(.empty),
        .arena = arena,
    };

    const result = try parse_compute_pipeline(alloc, alloc, &db, json);
    try std.testing.expectEqual(69, result.version);
    try std.testing.expectEqual(0x1111111111111111, result.hash);
}

pub fn parse_raytracing_pipeline(
    alloc: Allocator,
    tmp_alloc: Allocator,
    database: *const Database,
    json_str: []const u8,
) Error!ResultWithDependencies {
    const prof_point = MEASUREMENTS.start(@src());
    defer MEASUREMENTS.end(prof_point);

    var scanner = Json.init(tmp_alloc, json_str);
    const create_info = try alloc.create(vk.VkRayTracingPipelineCreateInfoKHR);

    var result: ResultWithDependencies = .{
        .version = 0,
        .hash = 0,
        .create_info = @ptrCast(create_info),
    };

    var context: Context = .{
        .alloc = alloc,
        .tmp_alloc = tmp_alloc,
        .scanner = &scanner,
        .db = database,
    };

    while (try scanner_object_next_field(context.scanner)) |s| {
        if (std.mem.eql(u8, s, "version")) {
            const v = try scanner_next_number(context.scanner);
            result.version = try std.fmt.parseInt(u32, v, 10);
        } else if (std.mem.eql(u8, s, "raytracingPipelines")) {
            try scanner_object_begin(context.scanner);
            const ss = try scanner_next_string(context.scanner);
            result.hash = str_to_hash(ss);
            try parse_vk_raytracing_pipeline_create_info(&context, create_info);
        }
    }
    result.dependencies = context.dependencies.items;
    return result;
}

test "parse_raytracing_pipeline" {
    const json =
        \\{
        \\  "version": 69,
        \\  "raytracingPipelines": {
        \\    "1111111111111111": {}
        \\  }
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const alloc = arena.allocator();

    const db: Database = .{
        .file_fd = undefined,
        .entries = .initFill(.empty),
        .arena = arena,
    };

    const result = try parse_raytracing_pipeline(alloc, alloc, &db, json);
    try std.testing.expectEqual(69, result.version);
    try std.testing.expectEqual(0x1111111111111111, result.hash);
}

pub fn parse_graphics_pipeline(
    alloc: Allocator,
    tmp_alloc: Allocator,
    database: *const Database,
    json_str: []const u8,
) Error!ResultWithDependencies {
    const prof_point = MEASUREMENTS.start(@src());
    defer MEASUREMENTS.end(prof_point);

    var scanner = Json.init(tmp_alloc, json_str);
    const create_info = try alloc.create(vk.VkGraphicsPipelineCreateInfo);

    var result: ResultWithDependencies = .{
        .version = 0,
        .hash = 0,
        .create_info = @ptrCast(create_info),
    };

    var context: Context = .{
        .alloc = alloc,
        .tmp_alloc = tmp_alloc,
        .scanner = &scanner,
        .db = database,
    };

    while (try scanner_object_next_field(context.scanner)) |s| {
        if (std.mem.eql(u8, s, "version")) {
            const v = try scanner_next_number(context.scanner);
            result.version = try std.fmt.parseInt(u32, v, 10);
        } else if (std.mem.eql(u8, s, "graphicsPipelines")) {
            try scanner_object_begin(context.scanner);
            const ss = try scanner_next_string(context.scanner);
            result.hash = str_to_hash(ss);
            try parse_vk_graphics_pipeline_create_info(
                &context,
                create_info,
            );
        }
    }
    result.dependencies = context.dependencies.items;
    return result;
}

test "parse_graphics_pipeline" {
    const json =
        \\{
        \\  "version": 69,
        \\  "graphicsPipelines": {
        \\    "1111111111111111": {}
        \\  }
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const alloc = arena.allocator();

    const db: Database = .{
        .file_fd = undefined,
        .entries = .initFill(.empty),
        .arena = arena,
    };

    const result = try parse_graphics_pipeline(alloc, alloc, &db, json);
    try std.testing.expectEqual(69, result.version);
    try std.testing.expectEqual(0x1111111111111111, result.hash);
}

fn str_to_hash(str: []const u8) u64 {
    var input: simd.u8x16 = undefined;
    // also asserts that the len of the string is 16
    @memcpy(@as([]u8, @ptrCast(&input)), str);

    // ASCII for digits and hex
    // 0x30: 0
    // 0x31: 1
    // 0x32: 2
    // 0x33: 3
    // 0x34: 4
    // 0x35: 5
    // 0x36: 6
    // 0x37: 7
    // 0x38: 8
    // 0x39: 9
    //
    // 0x41: A
    // 0x42: B
    // 0x43: C
    // 0x44: D
    // 0x45: E
    // 0x46: F
    //
    // 0x61: a
    // 0x62: b
    // 0x63: c
    // 0x64: d
    // 0x65: e
    // 0x66: f
    //
    // So for 0-9 we need to select 0 if first nible is 0x3
    // For hex we need to select 9 if the first nible is 0x4 or 0x6. 9 is needed because hex values
    // start from 1 like 0x41 and 0x61 and not from 0 like 0x30

    // zig fmt: off
    // 0xF for never used
    const HI_NIBBLE: simd.u8x16 = .{
        0x0, 0x0, 0x0, 0x0,
        0x9, 0x0, 0x9, 0x0,
        0x0, 0x0, 0x0, 0x0,
        0x0, 0x0, 0x0, 0x0,
    };
    // zig fmt: on
    const lo_nibbles = input & @as(simd.u8x16, @splat(0x0f));
    const hi_nibbles = input >> @as(@Vector(16, u3), @splat(4));
    const hi_result = simd.vpshufb_128(HI_NIBBLE, hi_nibbles);

    const r = lo_nibbles + hi_result;

    const hi_mask: @Vector(8, i32) = .{ 0, 2, 4, 6, 8, 10, 12, 14 };
    const lo_mask: @Vector(8, i32) = .{ 1, 3, 5, 7, 9, 11, 13, 15 };
    var hi = @shuffle(u8, r, undefined, hi_mask);
    const lo = @shuffle(u8, r, undefined, lo_mask);
    hi <<= @splat(4);
    const final = hi | lo;

    // need byteSwap since the order of bytes in the string is reverse of order
    // of bytes in the value
    return @byteSwap(@as(u64, @bitCast(final)));
}

test "str_to_hash" {
    const hex_str = "959dfe0bd6073194";
    const r = str_to_hash(hex_str);
    try std.testing.expectEqual(0x959dfe0bd6073194, r);
}

pub fn print_unexpected_token(token: Json.Token) void {
    const prof_point = MEASUREMENTS.start(@src());
    defer MEASUREMENTS.end(prof_point);

    switch (token) {
        .object_begin,
        .object_end,
        .array_begin,
        .array_end,
        .end_of_document,
        => log.err(
            @src(),
            "Got unexpected token type {s}",
            .{@tagName(std.meta.activeTag(token))},
        ),
        .number => |v| log.err(
            @src(),
            "Got unexpected token type {s} with value: {s}",
            .{ @tagName(std.meta.activeTag(token)), v },
        ),
        .string => |v| log.err(
            @src(),
            "Got unexpected token type {s} with value: {s}",
            .{ @tagName(std.meta.activeTag(token)), v },
        ),
    }
}

pub fn scanner_parse_enum(comptime T: type, scanner: *Json) Error!T {
    comptime var integer_type = u32;
    if (@bitSizeOf(T) == 64) integer_type = u64;

    const n = try scanner_next_number(scanner);
    const s = try std.fmt.parseInt(integer_type, n, 10);
    const t: T = @enumFromInt(s);
    return t;
}

pub fn scanner_parse_bitfield(comptime T: type, scanner: *Json) Error!T {
    comptime var integer_type = u32;
    if (@bitSizeOf(T) == 64) integer_type = u64;

    const n = try scanner_next_number(scanner);
    const s = try std.fmt.parseInt(integer_type, n, 10);
    const t: T = @bitCast(s);
    return t;
}

pub fn scanner_parse_number(comptime T: type, scanner: *Json) Error!T {
    const n = try scanner_next_number(scanner);
    if (T == f32) {
        const t = try std.fmt.parseFloat(T, n);
        return t;
    } else {
        const t = try std.fmt.parseInt(T, n, 10);
        return t;
    }
}

pub fn scanner_next_number(scanner: *Json) ScannerError![]const u8 {
    const prof_point = MEASUREMENTS.start(@src());
    defer MEASUREMENTS.end(prof_point);

    switch (scanner.next()) {
        .number => |v| return v,
        else => |t| {
            print_unexpected_token(t);
            return error.InvalidJson;
        },
    }
}

pub fn scanner_next_string(scanner: *Json) ScannerError![]const u8 {
    const prof_point = MEASUREMENTS.start(@src());
    defer MEASUREMENTS.end(prof_point);

    switch (scanner.next()) {
        .string => |s| return s,
        else => |t| {
            print_unexpected_token(t);
            return error.InvalidJson;
        },
    }
}

pub fn scanner_next_number_or_string(scanner: *Json) ScannerError![]const u8 {
    const prof_point = MEASUREMENTS.start(@src());
    defer MEASUREMENTS.end(prof_point);

    switch (scanner.next()) {
        .string => |s| return s,
        .number => |v| return v,
        else => |t| {
            print_unexpected_token(t);
            return error.InvalidJson;
        },
    }
}

pub fn scanner_object_next_field(scanner: *Json) ScannerError!?[]const u8 {
    const prof_point = MEASUREMENTS.start(@src());
    defer MEASUREMENTS.end(prof_point);

    loop: switch (scanner.next()) {
        .string => |s| return s,
        .object_begin => continue :loop scanner.next(),
        .end_of_document, .object_end => return null,
        else => |t| {
            print_unexpected_token(t);
            return error.InvalidJson;
        },
    }
}

pub fn scanner_array_next_object(scanner: *Json) ScannerError!bool {
    const prof_point = MEASUREMENTS.start(@src());
    defer MEASUREMENTS.end(prof_point);

    loop: switch (scanner.next()) {
        .array_begin => continue :loop scanner.next(),
        .array_end => return false,
        .object_begin => return true,
        else => |t| {
            print_unexpected_token(t);
            return error.InvalidJson;
        },
    }
}

pub fn scanner_array_next_array(scanner: *Json) ScannerError!bool {
    const prof_point = MEASUREMENTS.start(@src());
    defer MEASUREMENTS.end(prof_point);

    switch (scanner.next()) {
        .array_begin => return true,
        .array_end => return false,
        else => |t| {
            print_unexpected_token(t);
            return error.InvalidJson;
        },
    }
}

pub fn scanner_array_next_number(scanner: *Json) ScannerError!?[]const u8 {
    const prof_point = MEASUREMENTS.start(@src());
    defer MEASUREMENTS.end(prof_point);

    loop: switch (scanner.next()) {
        .array_begin => continue :loop scanner.next(),
        .array_end => return null,
        .number => |v| return v,
        else => |t| {
            print_unexpected_token(t);
            return error.InvalidJson;
        },
    }
}

pub fn scanner_array_next_string(scanner: *Json) ScannerError!?[]const u8 {
    const prof_point = MEASUREMENTS.start(@src());
    defer MEASUREMENTS.end(prof_point);

    loop: switch (scanner.next()) {
        .array_begin => continue :loop scanner.next(),
        .array_end => return null,
        .string => |s| return s,
        else => |t| {
            print_unexpected_token(t);
            return error.InvalidJson;
        },
    }
}

pub fn scanner_object_begin(scanner: *Json) ScannerError!void {
    const prof_point = MEASUREMENTS.start(@src());
    defer MEASUREMENTS.end(prof_point);

    switch (scanner.next()) {
        .object_begin => return,
        else => |t| {
            print_unexpected_token(t);
            return error.InvalidJson;
        },
    }
}

pub fn scanner_array_begin(scanner: *Json) ScannerError!void {
    const prof_point = MEASUREMENTS.start(@src());
    defer MEASUREMENTS.end(prof_point);

    switch (scanner.next()) {
        .array_begin => return,
        else => |t| {
            print_unexpected_token(t);
            return error.InvalidJson;
        },
    }
}

pub fn parse_simple_type(context: *Context, output: anytype) Error!void {
    const prof_point = MEASUREMENTS.start_named("parse_simple_type");
    defer MEASUREMENTS.end(prof_point);

    const output_type = @typeInfo(@TypeOf(output)).pointer.child;
    const output_fields = @typeInfo(output_type).@"struct".fields;
    log.comptime_assert(
        @src(),
        output_fields.len <= 32,
        "Type contains more than 32 fields",
        .{},
    );
    var parsed_field: u32 = 0;
    while (try scanner_object_next_field(context.scanner)) |s| {
        var consumed: bool = false;
        inline for (output_fields, 0..) |field, i| {
            if ((parsed_field & 1 << i == 0) and std.mem.eql(u8, s, field.name)) {
                parsed_field |= 1 << i;
                switch (field.type) {
                    i16, u16, i32, u32, u64, usize, c_uint => {
                        @field(output, field.name) = try scanner_parse_number(field.type, context.scanner);
                        consumed = true;
                    },
                    f32 => {
                        @field(output, field.name) = try scanner_parse_number(field.type, context.scanner);
                        consumed = true;
                    },
                    ?*anyopaque,
                    ?*const anyopaque,
                    => {
                        if (std.mem.eql(u8, "pNext", field.name)) {
                            @field(output, field.name) = try parse_pnext_chain(context);
                            consumed = true;
                        }
                    },
                    else => {
                        const field_type_info = @typeInfo(field.type);
                        if (field_type_info == .@"enum") {
                            @field(output, field.name) = try scanner_parse_enum(field.type, context.scanner);
                            consumed = true;
                        } else if (field_type_info == .@"struct" and field_type_info.@"struct".layout == .@"packed") {
                            @field(output, field.name) = try scanner_parse_bitfield(field.type, context.scanner);
                            consumed = true;
                        }
                    },
                }
            }
        }
        if (!consumed) {
            const v = try scanner_next_number_or_string(context.scanner);
            log.warn(
                @src(),
                "{s}: Skipping unknown field {s} with value {s}",
                .{ @typeName(output_type), s, v },
            );
        }
    }
}

pub fn parse_number_array(comptime T: type, context: *Context) Error![]T {
    const prof_point = MEASUREMENTS.start_named("parse_number_array");
    defer MEASUREMENTS.end(prof_point);

    try scanner_array_begin(context.scanner);
    var tmp: std.ArrayListUnmanaged(T) = .empty;
    while (try scanner_array_next_number(context.scanner)) |v| {
        const number = try std.fmt.parseInt(T, v, 10);
        try tmp.append(context.tmp_alloc, number);
    }
    return try context.alloc.dupe(T, tmp.items);
}

pub fn parse_single_handle(context: *Context, tag: Database.Entry.Tag, location: *vulkan.AnyHandle) Error!void {
    const prof_point = MEASUREMENTS.start(@src());
    defer MEASUREMENTS.end(prof_point);

    const v = try scanner_next_string(context.scanner);
    const hash = try std.fmt.parseInt(u64, v, 16);
    if (hash == 0)
        location.* = 0
    else {
        if (context.db.entries.getPtrConst(tag).getPtr(hash) == null) return error.NoHandle;
        const dep: Dependency = .{
            .tag = tag,
            .hash = hash,
            .ptr_to_handle = location,
        };
        try context.dependencies.append(context.tmp_alloc, dep);
    }
}

pub fn parse_handle_array(
    comptime T: type,
    tag: Database.Entry.Tag,
    context: *Context,
) Error![]T {
    const prof_point = MEASUREMENTS.start_named("parse_handle_array");
    defer MEASUREMENTS.end(prof_point);

    try scanner_array_begin(context.scanner);
    var tmp: std.ArrayListUnmanaged(T) = .empty;
    var denpendencies_found: u32 = 0;
    while (try scanner_array_next_string(context.scanner)) |hash_str| {
        const hash = try std.fmt.parseInt(u64, hash_str, 16);
        // Must preserve the index in the array for non 0 hashes
        if (hash == 0) {
            try tmp.append(context.tmp_alloc, .none);
        } else {
            if (context.db.entries.getPtrConst(tag).getPtr(hash) == null) return error.NoHandle;
            denpendencies_found += 1;
            var dep: Dependency = .{
                .tag = tag,
                .hash = hash,
            };
            // Initially store the offset into the tmp array for the
            // handle we need. Need to do this type hack to allow any
            // number to be stored in the "8 byte" aligned pointer
            const ptr_as_number: *usize = @ptrCast(&dep.ptr_to_handle);
            ptr_as_number.* = tmp.items.len;
            try tmp.append(context.tmp_alloc, .none);
            try context.dependencies.append(context.tmp_alloc, dep);
        }
    }
    const final_array = try context.alloc.dupe(T, tmp.items);
    // Patch already present dependencies with proper pointers to handles since the
    // handle array now is in the final allocation
    for (0..denpendencies_found) |i| {
        const dep = &context.dependencies.items[context.dependencies.items.len - 1 - i];
        dep.ptr_to_handle = @ptrCast(final_array.ptr + @intFromPtr(dep.ptr_to_handle));
    }
    return final_array;
}

pub fn parse_object_array(
    comptime T: type,
    comptime PARSE_FN: fn (*Context, *T) Error!void,
    context: *Context,
) Error![]T {
    const prof_point = MEASUREMENTS.start_named("parse_object_array");
    defer MEASUREMENTS.end(prof_point);

    const Inner = struct {
        fn migrate_dependencies(
            c: *Context,
            last_dep_number: usize,
            old_slice: []const T,
            new_slice: []const T,
        ) void {
            // Check if any newly added dependencies point into the tmp array and
            // update them by calculating the offset into the tmp array and
            // storing same offset into final array
            const added_dependencies = c.dependencies.items.len - last_dep_number;
            const tmp_ptr_begin: usize = @intFromPtr(old_slice.ptr);
            const tmp_ptr_end: usize = @intFromPtr(old_slice.ptr + old_slice.len);
            for (0..added_dependencies) |i| {
                const dep = &c.dependencies.items[c.dependencies.items.len - 1 - i];
                const ptr_to_handle: usize = @intFromPtr(dep.ptr_to_handle.?);
                if (tmp_ptr_begin <= ptr_to_handle and ptr_to_handle < tmp_ptr_end) {
                    const byte_offset = ptr_to_handle - tmp_ptr_begin;
                    const new_slice_ptr: [*]const u8 = @ptrCast(new_slice.ptr);
                    dep.ptr_to_handle =
                        @ptrCast(@alignCast(@constCast(new_slice_ptr + byte_offset)));
                }
            }
        }

        fn recreate_tmp(
            c: *Context,
            last_dep_number: usize,
            old_tmp: []T,
        ) !std.ArrayListUnmanaged(T) {
            var new_tmp: std.ArrayListUnmanaged(T) =
                try .initCapacity(c.tmp_alloc, old_tmp.len * 2 + 1);
            new_tmp.appendSliceAssumeCapacity(old_tmp);
            migrate_dependencies(c, last_dep_number, old_tmp, new_tmp.items);
            return new_tmp;
        }
    };

    try scanner_array_begin(context.scanner);
    var tmp: std.ArrayListUnmanaged(T) = .empty;
    const last_dep_number = context.dependencies.items.len;
    while (try scanner_array_next_object(context.scanner)) {
        tmp.appendBounded(undefined) catch {
            tmp = try Inner.recreate_tmp(context, last_dep_number, tmp.items);
            tmp.appendAssumeCapacity(undefined);
        };
        const item = &tmp.items[tmp.items.len - 1];
        try PARSE_FN(context, item);
    }
    const final_array = try context.alloc.dupe(T, tmp.items);
    Inner.migrate_dependencies(context, last_dep_number, tmp.items, final_array);
    return final_array;
}

test "parse_object_array" {
    // 2 elements is enough to cause 1 reallocation of the tmp array
    const json = "[{},{}]";

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const alloc = arena.allocator();

    const db: Database = .{ .file_fd = undefined, .entries = .initFill(.empty), .arena = arena };
    var scanner = Json.init(alloc, json);
    var context = Context{
        .alloc = alloc,
        .tmp_alloc = alloc,
        .scanner = &scanner,
        .db = &db,
    };

    const Inner = struct {
        fn dummy(c: *Context, item: *u64) Error!void {
            while (try scanner_object_next_field(c.scanner)) |_| {}
            item.* = 0x69;

            const dep: Dependency = .{
                .tag = .graphics_pipeline,
                .hash = 0x69,
                .ptr_to_handle = @ptrCast(item),
            };
            try c.dependencies.append(c.tmp_alloc, dep);
        }
    };
    const result = try parse_object_array(u64, Inner.dummy, &context);
    try std.testing.expectEqualSlices(u64, &.{ 0x69, 0x69 }, result);
    try std.testing.expectEqual(
        &result[0],
        @as(*u64, @ptrCast(context.dependencies.items[0].ptr_to_handle.?)),
    );
    try std.testing.expectEqual(
        &result[1],
        @as(*u64, @ptrCast(context.dependencies.items[1].ptr_to_handle.?)),
    );
}

pub fn parse_vk_physical_device_mesh_shader_features_ext(
    context: *Context,
    obj: *vk.VkPhysicalDeviceMeshShaderFeaturesEXT,
) Error!void {
    const prof_point = MEASUREMENTS.start(@src());
    defer MEASUREMENTS.end(prof_point);

    obj.* = .{};
    return parse_simple_type(context, obj);
}

pub fn parse_vk_physical_device_fragment_shading_rate_features_khr(
    context: *Context,
    obj: *vk.VkPhysicalDeviceFragmentShadingRateFeaturesKHR,
) Error!void {
    const prof_point = MEASUREMENTS.start(@src());
    defer MEASUREMENTS.end(prof_point);

    obj.* = .{};
    return parse_simple_type(context, obj);
}

pub fn parse_vk_descriptor_set_layout_binding_flags_create_info_ext(
    context: *Context,
    obj: *vk.VkDescriptorSetLayoutBindingFlagsCreateInfoEXT,
) Error!void {
    const prof_point = MEASUREMENTS.start(@src());
    defer MEASUREMENTS.end(prof_point);

    obj.* = .{};
    while (try scanner_object_next_field(context.scanner)) |s| {
        if (std.mem.eql(u8, s, "bindingFlags")) {
            const flags = try parse_number_array(u32, context);
            obj.pBindingFlags = @ptrCast(flags.ptr);
            obj.bindingCount = @intCast(flags.len);
        } else {
            const v = try scanner_next_number_or_string(context.scanner);
            log.warn(@src(), "Skipping unknown field {s}: {s}", .{ s, v });
        }
    }
}

pub fn parse_vk_physical_device_robustness_2_features_khr(
    context: *Context,
    obj: *vk.VkPhysicalDeviceRobustness2FeaturesEXT,
) Error!void {
    const prof_point = MEASUREMENTS.start(@src());
    defer MEASUREMENTS.end(prof_point);

    obj.* = .{};
    try parse_simple_type(context, obj);
}

pub fn parse_vk_physical_device_descriptor_buffer_features_ext(
    context: *Context,
    obj: *vk.VkPhysicalDeviceDescriptorBufferFeaturesEXT,
) Error!void {
    const prof_point = MEASUREMENTS.start(@src());
    defer MEASUREMENTS.end(prof_point);

    obj.* = .{};
    try parse_simple_type(context, obj);
}

pub fn parse_vk_pipeline_rasterization_depth_clip_state_create_info_ext(
    context: *Context,
    obj: *vk.VkPipelineRasterizationDepthClipStateCreateInfoEXT,
) Error!void {
    const prof_point = MEASUREMENTS.start(@src());
    defer MEASUREMENTS.end(prof_point);

    obj.* = .{};
    try parse_simple_type(context, obj);
}

pub fn parse_vk_pipeline_create_flags_2_create_info(
    context: *Context,
    obj: *vk.VkPipelineCreateFlags2CreateInfo,
) Error!void {
    const prof_point = MEASUREMENTS.start(@src());
    defer MEASUREMENTS.end(prof_point);

    obj.* = .{};
    try parse_simple_type(context, obj);
}

pub fn parse_vk_pipeline_discard_rectangle_state_create_info_ext(
    context: *Context,
    item: *vk.VkPipelineDiscardRectangleStateCreateInfoEXT,
) Error!void {
    const prof_point = MEASUREMENTS.start(@src());
    defer MEASUREMENTS.end(prof_point);

    item.* = .{};
    while (try scanner_object_next_field(context.scanner)) |s| {
        if (std.mem.eql(u8, s, "flags")) {
            item.flags = try scanner_parse_bitfield(
                vk.VkPipelineDiscardRectangleStateCreateFlagsEXT,
                context.scanner,
            );
        } else if (std.mem.eql(u8, s, "discardRectangleMode")) {
            item.discardRectangleMode = try scanner_parse_enum(
                vk.VkDiscardRectangleModeEXT,
                context.scanner,
            );
        } else if (std.mem.eql(u8, s, "discardRectangleCount")) {
            item.discardRectangleCount = try scanner_parse_number(u32, context.scanner);
        } else if (std.mem.eql(u8, s, "discardRectangles")) {
            const rectangles = try parse_object_array(
                vk.VkRect2D,
                parse_vk_rect_2d,
                context,
            );
            item.pDiscardRectangles = @ptrCast(rectangles.ptr);
        } else {
            const v = try scanner_next_number_or_string(context.scanner);
            log.warn(@src(), "Skipping unknown field {s}: {s}", .{ s, v });
        }
    }
}

pub fn parse_vk_pipeline_fragment_shading_rate_state_create_info_khr(
    context: *Context,
    item: *vk.VkPipelineFragmentShadingRateStateCreateInfoKHR,
) Error!void {
    const prof_point = MEASUREMENTS.start(@src());
    defer MEASUREMENTS.end(prof_point);

    item.* = .{};
    while (try scanner_object_next_field(context.scanner)) |s| {
        if (std.mem.eql(u8, s, "fragmentSize")) {
            try parse_simple_type(context, &item.fragmentSize);
        } else if (std.mem.eql(u8, s, "combinerOps")) {
            try scanner_array_begin(context.scanner);
            var i: usize = 0;
            while (try scanner_array_next_number(context.scanner)) |v| : (i += 1) {
                if (1 < i) return error.InvalidJson;
                const number = try std.fmt.parseInt(u32, v, 10);
                item.combinerOps[i] = @enumFromInt(number);
            }
        } else {
            const v = try scanner_next_number_or_string(context.scanner);
            log.warn(@src(), "Skipping unknown field {s}: {s}", .{ s, v });
        }
    }
}

pub fn parse_vk_pipeline_rendering_create_info(
    context: *Context,
    item: *vk.VkPipelineRenderingCreateInfo,
) Error!void {
    const prof_point = MEASUREMENTS.start(@src());
    defer MEASUREMENTS.end(prof_point);

    item.* = .{};
    while (try scanner_object_next_field(context.scanner)) |s| {
        if (std.mem.eql(u8, s, "viewMask")) {
            item.viewMask = try scanner_parse_number(u32, context.scanner);
        } else if (std.mem.eql(u8, s, "colorAttachmentFormats")) {
            const formats = try parse_number_array(u32, context);
            item.pColorAttachmentFormats = @ptrCast(formats.ptr);
            item.colorAttachmentCount = @intCast(formats.len);
        } else if (std.mem.eql(u8, s, "depthAttachmentFormat")) {
            item.depthAttachmentFormat = try scanner_parse_enum(vk.VkFormat, context.scanner);
        } else if (std.mem.eql(u8, s, "stencilAttachmentFormat")) {
            item.depthAttachmentFormat = try scanner_parse_enum(vk.VkFormat, context.scanner);
        } else {
            const v = try scanner_next_number_or_string(context.scanner);
            log.warn(@src(), "Skipping unknown field {s}: {s}", .{ s, v });
        }
    }
}

pub fn parse_vk_rendering_attachment_location_info(
    context: *Context,
    item: *vk.VkRenderingAttachmentLocationInfo,
) Error!void {
    const prof_point = MEASUREMENTS.start(@src());
    defer MEASUREMENTS.end(prof_point);

    item.* = .{};
    while (try scanner_object_next_field(context.scanner)) |s| {
        if (std.mem.eql(u8, s, "colorAttachmentLocations")) {
            const attachments = try parse_number_array(u32, context);
            item.pColorAttachmentLocations = @ptrCast(attachments.ptr);
            item.colorAttachmentCount = @intCast(attachments.len);
        } else {
            const v = try scanner_next_number_or_string(context.scanner);
            log.warn(@src(), "Skipping unknown field {s}: {s}", .{ s, v });
        }
    }
}

pub fn parse_vk_rendering_input_attachment_index_info(
    context: *Context,
    item: *vk.VkRenderingInputAttachmentIndexInfo,
) Error!void {
    const prof_point = MEASUREMENTS.start(@src());
    defer MEASUREMENTS.end(prof_point);

    item.* = .{};
    while (try scanner_object_next_field(context.scanner)) |s| {
        if (std.mem.eql(u8, s, "colorAttachmentInputIndices")) {
            const attachments = try parse_number_array(u32, context);
            item.pColorAttachmentInputIndices = @ptrCast(attachments.ptr);
            item.colorAttachmentCount = @intCast(attachments.len);
        } else if (std.mem.eql(u8, s, "depthInputAttachmentIndex")) {
            const index = try context.alloc.create(u32);
            index.* = try scanner_parse_number(u32, context.scanner);
            item.pDepthInputAttachmentIndex = index;
        } else if (std.mem.eql(u8, s, "stencilInputAttachmentIndex")) {
            const index = try context.alloc.create(u32);
            index.* = try scanner_parse_number(u32, context.scanner);
            item.pStencilInputAttachmentIndex = index;
        } else {
            const v = try scanner_next_number_or_string(context.scanner);
            log.warn(@src(), "Skipping unknown field {s}: {s}", .{ s, v });
        }
    }
}

pub fn parse_vk_pipeline_fragment_density_map_layered_create_info_valve(
    context: *Context,
    obj: *vk.VkPipelineFragmentDensityMapLayeredCreateInfoVALVE,
) Error!void {
    const prof_point = MEASUREMENTS.start(@src());
    defer MEASUREMENTS.end(prof_point);

    obj.* = .{};
    try parse_simple_type(context, obj);
}

pub fn parse_vk_structure_type_depth_bias_representation_info_ext(
    context: *Context,
    obj: *vk.VkDepthBiasRepresentationInfoEXT,
) Error!void {
    const prof_point = MEASUREMENTS.start(@src());
    defer MEASUREMENTS.end(prof_point);

    obj.* = .{};
    try parse_simple_type(context, obj);
}

pub fn parse_vk_graphics_pipeline_library_create_info_ext(
    context: *Context,
    obj: *vk.VkGraphicsPipelineLibraryCreateInfoEXT,
) Error!void {
    const prof_point = MEASUREMENTS.start(@src());
    defer MEASUREMENTS.end(prof_point);

    obj.* = .{};
    try parse_simple_type(context, obj);
}

pub fn parse_vk_pipeline_vertex_input_divisor_state_create_info(
    context: *Context,
    obj: *vk.VkPipelineVertexInputDivisorStateCreateInfo,
) Error!void {
    const prof_point = MEASUREMENTS.start(@src());
    defer MEASUREMENTS.end(prof_point);

    obj.* = .{};
    const Inner = struct {
        fn parse_vk_vertex_input_binding_divisor_description(
            c: *Context,
            item: *vk.VkVertexInputBindingDivisorDescription,
        ) Error!void {
            try parse_simple_type(c, item);
        }
    };

    while (try scanner_object_next_field(context.scanner)) |s| {
        if (std.mem.eql(u8, s, "vertexBindingDivisorCount")) {
            obj.vertexBindingDivisorCount = try scanner_parse_number(u32, context.scanner);
        } else if (std.mem.eql(u8, s, "vertexBindingDivisors")) {
            const divisors = try parse_object_array(
                vk.VkVertexInputBindingDivisorDescription,
                Inner.parse_vk_vertex_input_binding_divisor_description,
                context,
            );
            obj.pVertexBindingDivisors = @ptrCast(divisors.ptr);
            obj.vertexBindingDivisorCount = @intCast(divisors.len);
        } else {
            const v = try scanner_next_number_or_string(context.scanner);
            log.warn(@src(), "Skipping unknown field {s}: {s}", .{ s, v });
        }
    }
}

pub fn parse_vk_pipeline_shader_stage_required_subgroup_size_create_info(
    context: *Context,
    obj: *vk.VkPipelineShaderStageRequiredSubgroupSizeCreateInfo,
) Error!void {
    const prof_point = MEASUREMENTS.start(@src());
    defer MEASUREMENTS.end(prof_point);

    obj.* = .{};
    try parse_simple_type(context, obj);
}

pub fn parse_vk_pipeline_rasterization_line_state_create_info(
    context: *Context,
    obj: *vk.VkPipelineRasterizationLineStateCreateInfo,
) Error!void {
    const prof_point = MEASUREMENTS.start(@src());
    defer MEASUREMENTS.end(prof_point);

    obj.* = .{};
    try parse_simple_type(context, obj);
}

pub fn parse_vk_pipeline_robustness_create_info(
    context: *Context,
    obj: *vk.VkPipelineRobustnessCreateInfo,
) Error!void {
    const prof_point = MEASUREMENTS.start(@src());
    defer MEASUREMENTS.end(prof_point);

    obj.* = .{};
    try parse_simple_type(context, obj);
}

pub fn parse_vk_pipeline_rasterization_provoking_vertex_state_create_info_ext(
    context: *Context,
    obj: *vk.VkPipelineRasterizationProvokingVertexStateCreateInfoEXT,
) Error!void {
    const prof_point = MEASUREMENTS.start(@src());
    defer MEASUREMENTS.end(prof_point);

    obj.* = .{};
    try parse_simple_type(context, obj);
}

pub fn parse_vk_pipeline_viewport_depth_clip_control_create_info_ext(
    context: *Context,
    obj: *vk.VkPipelineViewportDepthClipControlCreateInfoEXT,
) Error!void {
    const prof_point = MEASUREMENTS.start(@src());
    defer MEASUREMENTS.end(prof_point);

    obj.* = .{};
    try parse_simple_type(context, obj);
}

pub fn parse_vk_pipeline_tessellation_domain_origin_state_create_info(
    context: *Context,
    obj: *vk.VkPipelineTessellationDomainOriginStateCreateInfo,
) Error!void {
    const prof_point = MEASUREMENTS.start(@src());
    defer MEASUREMENTS.end(prof_point);

    obj.* = .{};
    try parse_simple_type(context, obj);
}

test "test_parse_vk_pipeline_tessellation_domain_origin_state_create_info" {
    const json =
        \\{
        \\  "domainOrigin": 69
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const alloc = arena.allocator();

    const db: Database = .{ .file_fd = undefined, .entries = .initFill(.empty), .arena = arena };
    var scanner = Json.init(alloc, json);
    var context = Context{
        .alloc = alloc,
        .tmp_alloc = alloc,
        .scanner = &scanner,
        .db = &db,
    };

    var item: vk.VkPipelineTessellationDomainOriginStateCreateInfo = undefined;
    try parse_vk_pipeline_tessellation_domain_origin_state_create_info(&context, &item);

    try std.testing.expectEqual(69, @as(i32, @intFromEnum(item.domainOrigin)));
}

pub fn parse_vk_pipeline_rasterization_state_stream_create_info_ext(
    context: *Context,
    obj: *vk.VkPipelineRasterizationStateStreamCreateInfoEXT,
) Error!void {
    const prof_point = MEASUREMENTS.start(@src());
    defer MEASUREMENTS.end(prof_point);

    obj.* = .{};
    try parse_simple_type(context, obj);
}

test "test_parse_vk_pipeline_rasterization_state_stream_create_info_ext" {
    const json =
        \\{
        \\  "flags": 69,
        \\  "rasterizationStream": 69
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const alloc = arena.allocator();

    const db: Database = .{ .file_fd = undefined, .entries = .initFill(.empty), .arena = arena };
    var scanner = Json.init(alloc, json);
    var context = Context{
        .alloc = alloc,
        .tmp_alloc = alloc,
        .scanner = &scanner,
        .db = &db,
    };

    var item: vk.VkPipelineRasterizationStateStreamCreateInfoEXT = undefined;
    try parse_vk_pipeline_rasterization_state_stream_create_info_ext(&context, &item);

    try std.testing.expectEqual(69, @as(u32, @bitCast(item.flags)));
    try std.testing.expectEqual(69, item.rasterizationStream);
}

pub fn parse_vk_pipeline_color_blend_advanced_state_create_info_ext(
    context: *Context,
    obj: *vk.VkPipelineColorBlendAdvancedStateCreateInfoEXT,
) Error!void {
    const prof_point = MEASUREMENTS.start(@src());
    defer MEASUREMENTS.end(prof_point);

    obj.* = .{};
    try parse_simple_type(context, obj);
}

test "test_parse_vk_pipeline_color_blend_advanced_state_create_info_ext" {
    const json =
        \\{
        \\  "srcPremultiplied": 69,
        \\  "dstPremultiplied": 69,
        \\  "blendOverlap": 69
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const alloc = arena.allocator();

    const db: Database = .{ .file_fd = undefined, .entries = .initFill(.empty), .arena = arena };
    var scanner = Json.init(alloc, json);
    var context = Context{
        .alloc = alloc,
        .tmp_alloc = alloc,
        .scanner = &scanner,
        .db = &db,
    };

    var item: vk.VkPipelineColorBlendAdvancedStateCreateInfoEXT = undefined;
    try parse_vk_pipeline_color_blend_advanced_state_create_info_ext(&context, &item);

    try std.testing.expectEqual(69, item.srcPremultiplied);
    try std.testing.expectEqual(69, item.dstPremultiplied);
    try std.testing.expectEqual(69, @as(i32, @intFromEnum(item.blendOverlap)));
}

pub fn parse_vk_pipeline_rasterization_conservative_state_create_info_ext(
    context: *Context,
    obj: *vk.VkPipelineRasterizationConservativeStateCreateInfoEXT,
) Error!void {
    const prof_point = MEASUREMENTS.start(@src());
    defer MEASUREMENTS.end(prof_point);

    obj.* = .{};
    try parse_simple_type(context, obj);
}

test "test_parse_vk_pipeline_rasterization_conservative_state_create_info_ext" {
    const json =
        \\{
        \\  "flags": 69,
        \\  "conservativeRasterizationMode": 69,
        \\  "extraPrimitiveOverestimationSize": 69
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const alloc = arena.allocator();

    const db: Database = .{ .file_fd = undefined, .entries = .initFill(.empty), .arena = arena };
    var scanner = Json.init(alloc, json);
    var context = Context{
        .alloc = alloc,
        .tmp_alloc = alloc,
        .scanner = &scanner,
        .db = &db,
    };

    var item: vk.VkPipelineRasterizationConservativeStateCreateInfoEXT = undefined;
    try parse_vk_pipeline_rasterization_conservative_state_create_info_ext(&context, &item);

    try std.testing.expectEqual(69, @as(i32, @bitCast(item.flags)));
    try std.testing.expectEqual(69, @as(i32, @intFromEnum(item.conservativeRasterizationMode)));
    try std.testing.expectEqual(69, item.extraPrimitiveOverestimationSize);
}

pub fn parse_vk_pipeline_color_write_create_info_ext(
    context: *Context,
    obj: *vk.VkPipelineColorWriteCreateInfoEXT,
) Error!void {
    const prof_point = MEASUREMENTS.start(@src());
    defer MEASUREMENTS.end(prof_point);

    obj.* = .{};
    while (try scanner_object_next_field(context.scanner)) |s| {
        if (std.mem.eql(u8, s, "colorWriteEnables")) {
            const enables = try parse_number_array(u32, context);
            obj.pColorWriteEnables = @ptrCast(enables.ptr);
            obj.attachmentCount = @intCast(enables.len);
        } else {
            const v = try scanner_next_number_or_string(context.scanner);
            log.warn(@src(), "Skipping unknown field {s}: {s}", .{ s, v });
        }
    }
}

test "test_parse_vk_pipeline_color_write_create_info_ext" {
    const json =
        \\{
        \\  "colorWriteEnables": [69, 69, 69, 69]
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const alloc = arena.allocator();

    const db: Database = .{ .file_fd = undefined, .entries = .initFill(.empty), .arena = arena };
    var scanner = Json.init(alloc, json);
    var context = Context{
        .alloc = alloc,
        .tmp_alloc = alloc,
        .scanner = &scanner,
        .db = &db,
    };

    var item: vk.VkPipelineColorWriteCreateInfoEXT = undefined;
    try parse_vk_pipeline_color_write_create_info_ext(&context, &item);

    try std.testing.expectEqual(4, item.attachmentCount);
    try std.testing.expect(item.pColorWriteEnables != null);
    try std.testing.expectEqual(69, item.pColorWriteEnables.?[0]);
    try std.testing.expectEqual(69, item.pColorWriteEnables.?[1]);
    try std.testing.expectEqual(69, item.pColorWriteEnables.?[2]);
    try std.testing.expectEqual(69, item.pColorWriteEnables.?[3]);
}

pub fn parse_vk_sample_locations_info_ext(
    context: *Context,
    obj: *vk.VkSampleLocationsInfoEXT,
) Error!void {
    const prof_point = MEASUREMENTS.start(@src());
    defer MEASUREMENTS.end(prof_point);

    obj.* = .{};
    while (try scanner_object_next_field(context.scanner)) |s| {
        if (std.mem.eql(u8, s, "sampleLocationsPerPixel")) {
            obj.sampleLocationsPerPixel = try scanner_parse_bitfield(vk.VkSampleCountFlags, context.scanner);
        } else if (std.mem.eql(u8, s, "sampleLocationGridSize")) {
            try parse_vk_extent_2d(context, &obj.sampleLocationGridSize);
        } else if (std.mem.eql(u8, s, "sampleLocations")) {
            const locations = try parse_object_array(
                vk.VkSampleLocationEXT,
                parse_vk_sample_location_ext,
                context,
            );
            obj.pSampleLocations = @ptrCast(locations.ptr);
            obj.sampleLocationsCount = @intCast(locations.len);
        } else {
            const v = try scanner_next_number_or_string(context.scanner);
            log.warn(@src(), "Skipping unknown field {s}: {s}", .{ s, v });
        }
    }
}

test "test_parse_vk_sample_locations_info_ext" {
    const json =
        \\{
        \\  "sampleLocationsPerPixel": 69,
        \\  "sampleLocationGridSize": {"width": 69, "height": 69},
        \\  "sampleLocations": [{"x": 69, "y": 69}]
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const alloc = arena.allocator();

    const db: Database = .{ .file_fd = undefined, .entries = .initFill(.empty), .arena = arena };
    var scanner = Json.init(alloc, json);
    var context = Context{
        .alloc = alloc,
        .tmp_alloc = alloc,
        .scanner = &scanner,
        .db = &db,
    };

    var item: vk.VkSampleLocationsInfoEXT = undefined;
    try parse_vk_sample_locations_info_ext(&context, &item);

    try std.testing.expectEqual(69, @as(u32, @bitCast(item.sampleLocationsPerPixel)));
    try std.testing.expectEqual(69, item.sampleLocationGridSize.width);
    try std.testing.expectEqual(69, item.sampleLocationGridSize.height);
    try std.testing.expectEqual(1, item.sampleLocationsCount);
    try std.testing.expectEqual(69, item.pSampleLocations.?[0].x);
    try std.testing.expectEqual(69, item.pSampleLocations.?[0].y);
}

pub fn parse_vk_extent_2d(
    context: *Context,
    item: *vk.VkExtent2D,
) Error!void {
    const prof_point = MEASUREMENTS.start(@src());
    defer MEASUREMENTS.end(prof_point);

    while (try scanner_object_next_field(context.scanner)) |s| {
        if (std.mem.eql(u8, s, "width")) {
            item.width = try scanner_parse_number(u32, context.scanner);
        } else if (std.mem.eql(u8, s, "height")) {
            item.height = try scanner_parse_number(u32, context.scanner);
        } else {
            const v = try scanner_next_number_or_string(context.scanner);
            log.warn(@src(), "Skipping unknown field {s}: {s}", .{ s, v });
        }
    }
}

test "test_parse_vk_extent_2d" {
    const json =
        \\{
        \\  "width": 69,
        \\  "height": 69
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const alloc = arena.allocator();

    const db: Database = .{ .file_fd = undefined, .entries = .initFill(.empty), .arena = arena };
    var scanner = Json.init(alloc, json);
    var context = Context{
        .alloc = alloc,
        .tmp_alloc = alloc,
        .scanner = &scanner,
        .db = &db,
    };

    var item: vk.VkExtent2D = undefined;
    try parse_vk_extent_2d(&context, &item);

    try std.testing.expectEqual(69, item.width);
    try std.testing.expectEqual(69, item.height);
}

pub fn parse_vk_sample_location_ext(
    context: *Context,
    item: *vk.VkSampleLocationEXT,
) Error!void {
    const prof_point = MEASUREMENTS.start(@src());
    defer MEASUREMENTS.end(prof_point);

    while (try scanner_object_next_field(context.scanner)) |s| {
        if (std.mem.eql(u8, s, "x")) {
            item.x = try scanner_parse_number(f32, context.scanner);
        } else if (std.mem.eql(u8, s, "y")) {
            item.y = try scanner_parse_number(f32, context.scanner);
        } else {
            const v = try scanner_next_number_or_string(context.scanner);
            log.warn(@src(), "Skipping unknown field {s}: {s}", .{ s, v });
        }
    }
}

test "test_parse_vk_sample_location_ext" {
    const json =
        \\{
        \\  "x": 69,
        \\  "y": 69
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const alloc = arena.allocator();

    const db: Database = .{ .file_fd = undefined, .entries = .initFill(.empty), .arena = arena };
    var scanner = Json.init(alloc, json);
    var context = Context{
        .alloc = alloc,
        .tmp_alloc = alloc,
        .scanner = &scanner,
        .db = &db,
    };

    var item: vk.VkSampleLocationEXT = undefined;
    try parse_vk_sample_location_ext(&context, &item);

    try std.testing.expectEqual(69, item.x);
    try std.testing.expectEqual(69, item.y);
}

pub fn parse_vk_pipeline_sample_locations_state_create_info_ext(
    context: *Context,
    obj: *vk.VkPipelineSampleLocationsStateCreateInfoEXT,
) Error!void {
    const prof_point = MEASUREMENTS.start(@src());
    defer MEASUREMENTS.end(prof_point);

    obj.* = .{};
    while (try scanner_object_next_field(context.scanner)) |s| {
        if (std.mem.eql(u8, s, "sampleLocationsEnable")) {
            obj.sampleLocationsEnable = try scanner_parse_number(u32, context.scanner);
        } else if (std.mem.eql(u8, s, "sampleLocationsInfo")) {
            try parse_vk_sample_locations_info_ext(context, &obj.sampleLocationsInfo);
        } else {
            const v = try scanner_next_number_or_string(context.scanner);
            log.warn(@src(), "Skipping unknown field {s}: {s}", .{ s, v });
        }
    }
}

test "test_parse_vk_pipeline_sample_locations_state_create_info_ext" {
    const json =
        \\{
        \\  "sampleLocationsEnable": 69,
        \\  "sampleLocationsInfo": {
        \\    "sampleLocationsPerPixel": 69,
        \\    "sampleLocationGridSize": {"width": 69, "height": 69},
        \\    "sampleLocations": [{"x": 69, "y": 69}]
        \\  }
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const alloc = arena.allocator();

    const db: Database = .{ .file_fd = undefined, .entries = .initFill(.empty), .arena = arena };
    var scanner = Json.init(alloc, json);
    var context = Context{
        .alloc = alloc,
        .tmp_alloc = alloc,
        .scanner = &scanner,
        .db = &db,
    };

    var item: vk.VkPipelineSampleLocationsStateCreateInfoEXT = undefined;
    try parse_vk_pipeline_sample_locations_state_create_info_ext(&context, &item);

    try std.testing.expectEqual(69, item.sampleLocationsEnable);
    try std.testing.expectEqual(69, @as(u32, @bitCast(item.sampleLocationsInfo.sampleLocationsPerPixel)));
    try std.testing.expectEqual(
        vk.VkExtent2D{ .width = 69, .height = 69 },
        item.sampleLocationsInfo.sampleLocationGridSize,
    );
    try std.testing.expectEqual(1, item.sampleLocationsInfo.sampleLocationsCount);
    try std.testing.expectEqual(
        vk.VkSampleLocationEXT{ .x = 69, .y = 69 },
        item.sampleLocationsInfo.pSampleLocations.?[0],
    );
}

pub fn parse_vk_render_pass_multiview_create_info(
    context: *Context,
    obj: *vk.VkRenderPassMultiviewCreateInfo,
) Error!void {
    const prof_point = MEASUREMENTS.start(@src());
    defer MEASUREMENTS.end(prof_point);

    obj.* = .{};
    while (try scanner_object_next_field(context.scanner)) |s| {
        if (std.mem.eql(u8, s, "viewMasks")) {
            const masks = try parse_number_array(u32, context);
            obj.pViewMasks = @ptrCast(masks.ptr);
            obj.subpassCount = @intCast(masks.len);
        } else if (std.mem.eql(u8, s, "viewOffsets")) {
            const offsets = try parse_number_array(i32, context);
            obj.pViewOffsets = @ptrCast(offsets.ptr);
            obj.dependencyCount = @intCast(offsets.len);
        } else if (std.mem.eql(u8, s, "correlationMasks")) {
            const masks = try parse_number_array(u32, context);
            obj.pCorrelationMasks = @ptrCast(masks.ptr);
            obj.correlationMaskCount = @intCast(masks.len);
        } else {
            const v = try scanner_next_number_or_string(context.scanner);
            log.warn(@src(), "Skipping unknown field {s}: {s}", .{ s, v });
        }
    }
}

test "test_parse_vk_render_pass_multiview_create_info" {
    const json =
        \\{
        \\  "viewMasks": [69, 69],
        \\  "viewOffsets": [69, 69],
        \\  "correlationMasks": [69]
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const alloc = arena.allocator();

    const db: Database = .{ .file_fd = undefined, .entries = .initFill(.empty), .arena = arena };
    var scanner = Json.init(alloc, json);
    var context = Context{
        .alloc = alloc,
        .tmp_alloc = alloc,
        .scanner = &scanner,
        .db = &db,
    };

    var item: vk.VkRenderPassMultiviewCreateInfo = undefined;
    try parse_vk_render_pass_multiview_create_info(&context, &item);

    try std.testing.expectEqual(2, item.subpassCount);
    try std.testing.expectEqual(69, item.pViewMasks.?[0]);
    try std.testing.expectEqual(69, item.pViewMasks.?[1]);
    try std.testing.expectEqual(2, item.dependencyCount);
    try std.testing.expectEqual(69, item.pViewOffsets.?[0]);
    try std.testing.expectEqual(69, item.pViewOffsets.?[1]);
    try std.testing.expectEqual(1, item.correlationMaskCount);
    try std.testing.expectEqual(69, item.pCorrelationMasks.?[0]);
}

pub fn parse_vk_attachment_description_stencil_layout(
    context: *Context,
    obj: *vk.VkAttachmentDescriptionStencilLayout,
) Error!void {
    const prof_point = MEASUREMENTS.start(@src());
    defer MEASUREMENTS.end(prof_point);

    obj.* = .{};
    try parse_simple_type(context, obj);
}

test "test_parse_vk_attachment_description_stencil_layout" {
    const json =
        \\{
        \\  "stencilInitialLayout": 69,
        \\  "stencilFinalLayout": 69
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const alloc = arena.allocator();

    const db: Database = .{ .file_fd = undefined, .entries = .initFill(.empty), .arena = arena };
    var scanner = Json.init(alloc, json);
    var context = Context{
        .alloc = alloc,
        .tmp_alloc = alloc,
        .scanner = &scanner,
        .db = &db,
    };

    var item: vk.VkAttachmentDescriptionStencilLayout = undefined;
    try parse_vk_attachment_description_stencil_layout(&context, &item);

    try std.testing.expectEqual(69, @as(i32, @intFromEnum(item.stencilInitialLayout)));
    try std.testing.expectEqual(69, @as(i32, @intFromEnum(item.stencilFinalLayout)));
}

pub fn parse_vk_attachment_reference_stencil_layout(
    context: *Context,
    obj: *vk.VkAttachmentReferenceStencilLayout,
) Error!void {
    const prof_point = MEASUREMENTS.start(@src());
    defer MEASUREMENTS.end(prof_point);

    obj.* = .{};
    try parse_simple_type(context, obj);
}

test "test_parse_vk_attachment_reference_stencil_layout" {
    const json =
        \\{
        \\  "stencilLayout": 69
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const alloc = arena.allocator();

    const db: Database = .{ .file_fd = undefined, .entries = .initFill(.empty), .arena = arena };
    var scanner = Json.init(alloc, json);
    var context = Context{
        .alloc = alloc,
        .tmp_alloc = alloc,
        .scanner = &scanner,
        .db = &db,
    };

    var item: vk.VkAttachmentReferenceStencilLayout = undefined;
    try parse_vk_attachment_reference_stencil_layout(&context, &item);

    try std.testing.expectEqual(69, @as(i32, @intFromEnum(item.stencilLayout)));
}

pub fn parse_vk_subpass_description_depth_stencil_resolve(
    context: *Context,
    obj: *vk.VkSubpassDescriptionDepthStencilResolve,
) Error!void {
    const prof_point = MEASUREMENTS.start(@src());
    defer MEASUREMENTS.end(prof_point);

    obj.* = .{};
    while (try scanner_object_next_field(context.scanner)) |s| {
        if (std.mem.eql(u8, s, "depthResolveMode")) {
            obj.depthResolveMode = try scanner_parse_bitfield(vk.VkResolveModeFlags, context.scanner);
        } else if (std.mem.eql(u8, s, "stencilResolveMode")) {
            obj.stencilResolveMode = try scanner_parse_bitfield(vk.VkResolveModeFlags, context.scanner);
        } else if (std.mem.eql(u8, s, "depthStencilResolveAttachment")) {
            const attachment = try context.alloc.create(vk.VkAttachmentReference2);
            try parse_vk_attachment_reference2(context, attachment);
            obj.pDepthStencilResolveAttachment = attachment;
        } else {
            const v = try scanner_next_number_or_string(context.scanner);
            log.warn(@src(), "Skipping unknown field {s}: {s}", .{ s, v });
        }
    }
}

test "test_parse_vk_subpass_description_depth_stencil_resolve" {
    const json =
        \\{
        \\  "depthResolveMode": 69,
        \\  "stencilResolveMode": 69
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const alloc = arena.allocator();

    const db: Database = .{ .file_fd = undefined, .entries = .initFill(.empty), .arena = arena };
    var scanner = Json.init(alloc, json);
    var context = Context{
        .alloc = alloc,
        .tmp_alloc = alloc,
        .scanner = &scanner,
        .db = &db,
    };

    var item: vk.VkSubpassDescriptionDepthStencilResolve = undefined;
    try parse_vk_subpass_description_depth_stencil_resolve(&context, &item);

    try std.testing.expectEqual(69, @as(u32, @bitCast(item.depthResolveMode)));
    try std.testing.expectEqual(69, @as(u32, @bitCast(item.stencilResolveMode)));
}

pub fn parse_vk_fragment_shading_rate_attachment_info_khr(
    context: *Context,
    obj: *vk.VkFragmentShadingRateAttachmentInfoKHR,
) Error!void {
    const prof_point = MEASUREMENTS.start(@src());
    defer MEASUREMENTS.end(prof_point);

    obj.* = .{};
    while (try scanner_object_next_field(context.scanner)) |s| {
        if (std.mem.eql(u8, s, "fragmentShadingRateAttachment")) {
            const attachment = try context.alloc.create(vk.VkAttachmentReference2);
            try parse_vk_attachment_reference2(context, attachment);
            obj.pFragmentShadingRateAttachment = attachment;
        } else if (std.mem.eql(u8, s, "shadingRateAttachmentTexelSize")) {
            try parse_vk_extent_2d(context, &obj.shadingRateAttachmentTexelSize);
        } else {
            const v = try scanner_next_number_or_string(context.scanner);
            log.warn(@src(), "Skipping unknown field {s}: {s}", .{ s, v });
        }
    }
}

test "test_parse_vk_fragment_shading_rate_attachment_info_khr" {
    const json =
        \\{
        \\  "shadingRateAttachmentTexelSize": {"width": 69, "height": 69}
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const alloc = arena.allocator();

    const db: Database = .{ .file_fd = undefined, .entries = .initFill(.empty), .arena = arena };
    var scanner = Json.init(alloc, json);
    var context = Context{
        .alloc = alloc,
        .tmp_alloc = alloc,
        .scanner = &scanner,
        .db = &db,
    };

    var item: vk.VkFragmentShadingRateAttachmentInfoKHR = undefined;
    try parse_vk_fragment_shading_rate_attachment_info_khr(&context, &item);

    try std.testing.expectEqual(69, item.shadingRateAttachmentTexelSize.width);
    try std.testing.expectEqual(69, item.shadingRateAttachmentTexelSize.height);
}

pub fn parse_vk_input_attachment_aspect_reference(
    context: *Context,
    obj: *vk.VkInputAttachmentAspectReference,
) Error!void {
    const prof_point = MEASUREMENTS.start(@src());
    defer MEASUREMENTS.end(prof_point);

    obj.* = .{};
    try parse_simple_type(context, obj);
}

test "test_parse_vk_input_attachment_aspect_reference" {
    const json =
        \\{
        \\  "subpass": 69,
        \\  "inputAttachmentIndex": 69,
        \\  "aspectMask": 69
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const alloc = arena.allocator();

    const db: Database = .{ .file_fd = undefined, .entries = .initFill(.empty), .arena = arena };
    var scanner = Json.init(alloc, json);
    var context = Context{
        .alloc = alloc,
        .tmp_alloc = alloc,
        .scanner = &scanner,
        .db = &db,
    };

    var item: vk.VkInputAttachmentAspectReference = undefined;
    try parse_vk_input_attachment_aspect_reference(&context, &item);

    try std.testing.expectEqual(69, item.subpass);
    try std.testing.expectEqual(69, item.inputAttachmentIndex);
    try std.testing.expectEqual(69, @as(u32, @bitCast(item.aspectMask)));
}

pub fn parse_vk_render_pass_input_attachment_aspect_create_info(
    context: *Context,
    obj: *vk.VkRenderPassInputAttachmentAspectCreateInfo,
) Error!void {
    const prof_point = MEASUREMENTS.start(@src());
    defer MEASUREMENTS.end(prof_point);

    obj.* = .{};
    while (try scanner_object_next_field(context.scanner)) |s| {
        if (std.mem.eql(u8, s, "aspectReferences")) {
            const refs = try parse_object_array(
                vk.VkInputAttachmentAspectReference,
                parse_vk_input_attachment_aspect_reference,
                context,
            );
            obj.pAspectReferences = @ptrCast(refs.ptr);
            obj.aspectReferenceCount = @intCast(refs.len);
        } else {
            const v = try scanner_next_number_or_string(context.scanner);
            log.warn(@src(), "Skipping unknown field {s}: {s}", .{ s, v });
        }
    }
}

test "test_parse_vk_render_pass_input_attachment_aspect_create_info" {
    const json =
        \\{
        \\  "aspectReferences": [{"subpass": 69, "inputAttachmentIndex": 69, "aspectMask": 69}]
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const alloc = arena.allocator();

    const db: Database = .{ .file_fd = undefined, .entries = .initFill(.empty), .arena = arena };
    var scanner = Json.init(alloc, json);
    var context = Context{
        .alloc = alloc,
        .tmp_alloc = alloc,
        .scanner = &scanner,
        .db = &db,
    };

    var item: vk.VkRenderPassInputAttachmentAspectCreateInfo = undefined;
    try parse_vk_render_pass_input_attachment_aspect_create_info(&context, &item);

    try std.testing.expectEqual(1, item.aspectReferenceCount);
    try std.testing.expectEqual(69, item.pAspectReferences.?[0].subpass);
    try std.testing.expectEqual(69, item.pAspectReferences.?[0].inputAttachmentIndex);
    try std.testing.expectEqual(69, @as(u32, @bitCast(item.pAspectReferences.?[0].aspectMask)));
}

pub fn parse_vk_sampler_reduction_mode_create_info(
    context: *Context,
    obj: *vk.VkSamplerReductionModeCreateInfo,
) Error!void {
    const prof_point = MEASUREMENTS.start(@src());
    defer MEASUREMENTS.end(prof_point);

    obj.* = .{};
    try parse_simple_type(context, obj);
}

pub fn parse_vk_component_mapping(
    context: *Context,
    obj: *vk.VkComponentMapping,
) Error!void {
    const prof_point = MEASUREMENTS.start(@src());
    defer MEASUREMENTS.end(prof_point);

    obj.* = .{};
    try parse_simple_type(context, obj);
}

test "test_parse_vk_sampler_reduction_mode_create_info" {
    const json =
        \\{
        \\  "reductionMode": 69
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const alloc = arena.allocator();

    const db: Database = .{ .file_fd = undefined, .entries = .initFill(.empty), .arena = arena };
    var scanner = Json.init(alloc, json);
    var context = Context{
        .alloc = alloc,
        .tmp_alloc = alloc,
        .scanner = &scanner,
        .db = &db,
    };

    var item: vk.VkSamplerReductionModeCreateInfo = undefined;
    try parse_vk_sampler_reduction_mode_create_info(&context, &item);

    try std.testing.expectEqual(69, @as(i32, @intFromEnum(item.reductionMode)));
}

test "test_parse_vk_component_mapping" {
    const json =
        \\{
        \\  "r": 69,
        \\  "g": 69,
        \\  "b": 69,
        \\  "a": 69
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const alloc = arena.allocator();

    const db: Database = .{ .file_fd = undefined, .entries = .initFill(.empty), .arena = arena };
    var scanner = Json.init(alloc, json);
    var context = Context{
        .alloc = alloc,
        .tmp_alloc = alloc,
        .scanner = &scanner,
        .db = &db,
    };

    var item: vk.VkComponentMapping = undefined;
    try parse_vk_component_mapping(&context, &item);

    try std.testing.expectEqual(69, @as(i32, @intFromEnum(item.r)));
    try std.testing.expectEqual(69, @as(i32, @intFromEnum(item.g)));
    try std.testing.expectEqual(69, @as(i32, @intFromEnum(item.b)));
    try std.testing.expectEqual(69, @as(i32, @intFromEnum(item.a)));
}

pub fn parse_vk_sampler_ycbcr_conversion_create_info(
    context: *Context,
    obj: *vk.VkSamplerYcbcrConversionCreateInfo,
) Error!void {
    const prof_point = MEASUREMENTS.start(@src());
    defer MEASUREMENTS.end(prof_point);

    obj.* = .{};
    while (try scanner_object_next_field(context.scanner)) |s| {
        if (std.mem.eql(u8, s, "format")) {
            obj.format = try scanner_parse_enum(vk.VkFormat, context.scanner);
        } else if (std.mem.eql(u8, s, "ycbcrModel")) {
            obj.ycbcrModel = try scanner_parse_enum(vk.VkSamplerYcbcrModelConversion, context.scanner);
        } else if (std.mem.eql(u8, s, "ycbcrRange")) {
            obj.ycbcrRange = try scanner_parse_enum(vk.VkSamplerYcbcrRange, context.scanner);
        } else if (std.mem.eql(u8, s, "components")) {
            try parse_vk_component_mapping(context, &obj.components);
        } else if (std.mem.eql(u8, s, "xChromaOffset")) {
            obj.xChromaOffset = try scanner_parse_enum(vk.VkChromaLocation, context.scanner);
        } else if (std.mem.eql(u8, s, "yChromaOffset")) {
            obj.yChromaOffset = try scanner_parse_enum(vk.VkChromaLocation, context.scanner);
        } else if (std.mem.eql(u8, s, "chromaFilter")) {
            obj.chromaFilter = try scanner_parse_enum(vk.VkFilter, context.scanner);
        } else if (std.mem.eql(u8, s, "forceExplicitReconstruction")) {
            obj.forceExplicitReconstruction = try scanner_parse_number(u32, context.scanner);
        } else {
            const v = try scanner_next_number_or_string(context.scanner);
            log.warn(@src(), "Skipping unknown field {s}: {s}", .{ s, v });
        }
    }
}

test "test_parse_vk_sampler_ycbcr_conversion_create_info" {
    const json =
        \\{
        \\  "format": 69,
        \\  "ycbcrModel": 69,
        \\  "ycbcrRange": 69,
        \\  "components": {"r": 69, "g": 69, "b": 69, "a": 69},
        \\  "xChromaOffset": 69,
        \\  "yChromaOffset": 69,
        \\  "chromaFilter": 69,
        \\  "forceExplicitReconstruction": 69
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const alloc = arena.allocator();

    const db: Database = .{ .file_fd = undefined, .entries = .initFill(.empty), .arena = arena };
    var scanner = Json.init(alloc, json);
    var context = Context{
        .alloc = alloc,
        .tmp_alloc = alloc,
        .scanner = &scanner,
        .db = &db,
    };

    var item: vk.VkSamplerYcbcrConversionCreateInfo = undefined;
    try parse_vk_sampler_ycbcr_conversion_create_info(&context, &item);

    try std.testing.expectEqual(69, @as(i32, @intFromEnum(item.format)));
    try std.testing.expectEqual(69, @as(i32, @intFromEnum(item.ycbcrModel)));
    try std.testing.expectEqual(69, @as(i32, @intFromEnum(item.ycbcrRange)));
    try std.testing.expectEqual(69, @as(i32, @intFromEnum(item.components.r)));
    try std.testing.expectEqual(69, @as(i32, @intFromEnum(item.components.g)));
    try std.testing.expectEqual(69, @as(i32, @intFromEnum(item.components.b)));
    try std.testing.expectEqual(69, @as(i32, @intFromEnum(item.components.a)));
    try std.testing.expectEqual(69, @as(i32, @intFromEnum(item.xChromaOffset)));
    try std.testing.expectEqual(69, @as(i32, @intFromEnum(item.yChromaOffset)));
    try std.testing.expectEqual(69, @as(i32, @intFromEnum(item.chromaFilter)));
    try std.testing.expectEqual(69, item.forceExplicitReconstruction);
}

pub fn parse_vk_clear_color_value(
    context: *Context,
    obj: *vk.VkClearColorValue,
) Error!void {
    const prof_point = MEASUREMENTS.start(@src());
    defer MEASUREMENTS.end(prof_point);

    // Fossilize parses as uint32
    try scanner_array_begin(context.scanner);
    var idx: usize = 0;
    while (try scanner_array_next_number(context.scanner)) |v| {
        if (idx < 4) {
            obj.uint32[idx] = try std.fmt.parseInt(u32, v, 10);
            idx += 1;
        }
    }
}

test "test_parse_vk_clear_color_value" {
    const json = "[69, 69, 69, 69]";
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const alloc = arena.allocator();

    const db: Database = .{ .file_fd = undefined, .entries = .initFill(.empty), .arena = arena };
    var scanner = Json.init(alloc, json);
    var context = Context{
        .alloc = alloc,
        .tmp_alloc = alloc,
        .scanner = &scanner,
        .db = &db,
    };

    var item: vk.VkClearColorValue = undefined;
    try parse_vk_clear_color_value(&context, &item);

    try std.testing.expectEqual(69, item.uint32[0]);
    try std.testing.expectEqual(69, item.uint32[1]);
    try std.testing.expectEqual(69, item.uint32[2]);
    try std.testing.expectEqual(69, item.uint32[3]);
}

pub fn parse_vk_sampler_custom_border_color_create_info_ext(
    context: *Context,
    obj: *vk.VkSamplerCustomBorderColorCreateInfoEXT,
) Error!void {
    const prof_point = MEASUREMENTS.start(@src());
    defer MEASUREMENTS.end(prof_point);

    obj.* = .{ .customBorderColor = undefined };
    while (try scanner_object_next_field(context.scanner)) |s| {
        if (std.mem.eql(u8, s, "customBorderColor")) {
            try parse_vk_clear_color_value(context, &obj.customBorderColor);
        } else if (std.mem.eql(u8, s, "format")) {
            obj.format = try scanner_parse_enum(vk.VkFormat, context.scanner);
        } else {
            const v = try scanner_next_number_or_string(context.scanner);
            log.warn(@src(), "Skipping unknown field {s}: {s}", .{ s, v });
        }
    }
}

test "test_parse_vk_sampler_custom_border_color_create_info_ext" {
    const json =
        \\{
        \\  "customBorderColor": [69, 69, 69, 69],
        \\  "format": 69
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const alloc = arena.allocator();

    const db: Database = .{ .file_fd = undefined, .entries = .initFill(.empty), .arena = arena };
    var scanner = Json.init(alloc, json);
    var context = Context{
        .alloc = alloc,
        .tmp_alloc = alloc,
        .scanner = &scanner,
        .db = &db,
    };

    var item: vk.VkSamplerCustomBorderColorCreateInfoEXT = undefined;
    try parse_vk_sampler_custom_border_color_create_info_ext(&context, &item);

    try std.testing.expectEqual(69, item.customBorderColor.uint32[0]);
    try std.testing.expectEqual(69, item.customBorderColor.uint32[1]);
    try std.testing.expectEqual(69, item.customBorderColor.uint32[2]);
    try std.testing.expectEqual(69, item.customBorderColor.uint32[3]);
    try std.testing.expectEqual(69, @as(i32, @intFromEnum(item.format)));
}

pub fn parse_vk_sampler_border_color_component_mapping_create_info_ext(
    context: *Context,
    obj: *vk.VkSamplerBorderColorComponentMappingCreateInfoEXT,
) Error!void {
    const prof_point = MEASUREMENTS.start(@src());
    defer MEASUREMENTS.end(prof_point);

    obj.* = .{};
    while (try scanner_object_next_field(context.scanner)) |s| {
        if (std.mem.eql(u8, s, "components")) {
            try parse_vk_component_mapping(context, &obj.components);
        } else if (std.mem.eql(u8, s, "srgb")) {
            obj.srgb = try scanner_parse_number(u32, context.scanner);
        } else {
            const v = try scanner_next_number_or_string(context.scanner);
            log.warn(@src(), "Skipping unknown field {s}: {s}", .{ s, v });
        }
    }
}

test "test_parse_vk_sampler_border_color_component_mapping_create_info_ext" {
    const json =
        \\{
        \\  "components": {"r": 69, "g": 69, "b": 69, "a": 69},
        \\  "srgb": 69
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const alloc = arena.allocator();

    const db: Database = .{ .file_fd = undefined, .entries = .initFill(.empty), .arena = arena };
    var scanner = Json.init(alloc, json);
    var context = Context{
        .alloc = alloc,
        .tmp_alloc = alloc,
        .scanner = &scanner,
        .db = &db,
    };

    var item: vk.VkSamplerBorderColorComponentMappingCreateInfoEXT = undefined;
    try parse_vk_sampler_border_color_component_mapping_create_info_ext(&context, &item);

    try std.testing.expectEqual(69, @as(i32, @intFromEnum(item.components.r)));
    try std.testing.expectEqual(69, @as(i32, @intFromEnum(item.components.g)));
    try std.testing.expectEqual(69, @as(i32, @intFromEnum(item.components.b)));
    try std.testing.expectEqual(69, @as(i32, @intFromEnum(item.components.a)));
    try std.testing.expectEqual(69, item.srgb);
}

pub fn parse_vk_mutable_descriptor_type_list_ext(
    context: *Context,
    item: *vk.VkMutableDescriptorTypeListEXT,
) Error!void {
    const prof_point = MEASUREMENTS.start(@src());
    defer MEASUREMENTS.end(prof_point);

    item.* = .{};
    const descriptor_types = try parse_number_array(u32, context);
    item.pDescriptorTypes = @ptrCast(descriptor_types.ptr);
    item.descriptorTypeCount = @intCast(descriptor_types.len);
}

pub fn parse_vk_mutable_descriptor_type_create_info_ext(
    context: *Context,
    obj: *vk.VkMutableDescriptorTypeCreateInfoEXT,
) Error!void {
    const prof_point = MEASUREMENTS.start(@src());
    defer MEASUREMENTS.end(prof_point);

    obj.* = .{};
    while (try scanner_object_next_field(context.scanner)) |s| {
        if (std.mem.eql(u8, s, "sType")) {
            _ = try scanner_next_number(context.scanner);
        } else if (std.mem.eql(u8, s, "mutableDescriptorTypeLists")) {
            try scanner_array_begin(context.scanner);
            var tmp: std.ArrayListUnmanaged(vk.VkMutableDescriptorTypeListEXT) = .empty;
            while (try scanner_array_next_array(context.scanner)) {
                var tmp2: std.ArrayListUnmanaged(u32) = .empty;
                while (try scanner_array_next_number(context.scanner)) |v| {
                    const number = try std.fmt.parseInt(u32, v, 10);
                    try tmp2.append(context.tmp_alloc, number);
                }
                const final = try context.alloc.dupe(u32, tmp2.items);
                const obj2: vk.VkMutableDescriptorTypeListEXT = .{
                    .pDescriptorTypes = @ptrCast(final.ptr),
                    .descriptorTypeCount = @intCast(final.len),
                };
                try tmp.append(context.tmp_alloc, obj2);
            }
            const lists = try context.alloc.dupe(vk.VkMutableDescriptorTypeListEXT, tmp.items);
            obj.pMutableDescriptorTypeLists = @ptrCast(lists.ptr);
            obj.mutableDescriptorTypeListCount = @intCast(lists.len);
        } else {
            const v = try scanner_next_number_or_string(context.scanner);
            log.warn(@src(), "Skipping unknown field {s}: {s}", .{ s, v });
        }
    }
}

test "test_parse_vk_mutable_descriptor_type_create_info_ext" {
    const json =
        \\{
        \\  "sType": 69,
        \\  "mutableDescriptorTypeLists": [
        \\    [
        \\      69,
        \\      70
        \\    ],
        \\    [
        \\      71,
        \\      72,
        \\      73
        \\    ]
        \\  ]
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const alloc = arena.allocator();

    const db: Database = .{ .file_fd = undefined, .entries = .initFill(.empty), .arena = arena };

    var scanner = Json.init(alloc, json);
    var context = Context{
        .alloc = alloc,
        .tmp_alloc = alloc,
        .scanner = &scanner,
        .db = &db,
    };

    var item: vk.VkMutableDescriptorTypeCreateInfoEXT = undefined;
    try parse_vk_mutable_descriptor_type_create_info_ext(&context, &item);

    try std.testing.expectEqual(
        vk.VkStructureType.VK_STRUCTURE_TYPE_MUTABLE_DESCRIPTOR_TYPE_CREATE_INFO_EXT,
        item.sType,
    );
    try std.testing.expectEqual(null, item.pNext);
    try std.testing.expectEqual(2, item.mutableDescriptorTypeListCount);
    try std.testing.expectEqual(2, item.pMutableDescriptorTypeLists.?[0].descriptorTypeCount);
    try std.testing.expectEqual(69, @as(i32, @intFromEnum(item.pMutableDescriptorTypeLists.?[0].pDescriptorTypes.?[0])));
    try std.testing.expectEqual(70, @as(i32, @intFromEnum(item.pMutableDescriptorTypeLists.?[0].pDescriptorTypes.?[1])));
    try std.testing.expectEqual(3, item.pMutableDescriptorTypeLists.?[1].descriptorTypeCount);
    try std.testing.expectEqual(71, @as(i32, @intFromEnum(item.pMutableDescriptorTypeLists.?[1].pDescriptorTypes.?[0])));
    try std.testing.expectEqual(72, @as(i32, @intFromEnum(item.pMutableDescriptorTypeLists.?[1].pDescriptorTypes.?[1])));
    try std.testing.expectEqual(73, @as(i32, @intFromEnum(item.pMutableDescriptorTypeLists.?[1].pDescriptorTypes.?[2])));
}

pub fn parse_pnext_chain(context: *Context) Error!?*anyopaque {
    const prof_point = MEASUREMENTS.start(@src());
    defer MEASUREMENTS.end(prof_point);

    const Inner = struct {
        const Chain = struct {
            c: *Context,
            first_in_chain: *?*anyopaque,
            last_pnext_in_chain: *?**anyopaque,
            fn chain(
                self: *const Chain,
                comptime T: type,
            ) !*T {
                const obj = try self.c.alloc.create(T);
                if (self.first_in_chain.* == null) self.first_in_chain.* = obj;
                if (self.last_pnext_in_chain.*) |lpic| lpic.* = obj;
                self.last_pnext_in_chain.* = @ptrCast(&obj.pNext);
                return obj;
            }
        };
        fn parse_next(
            c: *Context,
            first_in_chain: *?*anyopaque,
            last_pnext_in_chain: *?**anyopaque,
        ) Error!void {
            const stype = try scanner_parse_enum(vk.VkStructureType, c.scanner);
            const chain: Chain = .{
                .c = c,
                .first_in_chain = first_in_chain,
                .last_pnext_in_chain = last_pnext_in_chain,
            };
            switch (stype) {
                .VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_MESH_SHADER_FEATURES_EXT,
                => {
                    const item = try chain.chain(vk.VkPhysicalDeviceMeshShaderFeaturesEXT);
                    try parse_vk_physical_device_mesh_shader_features_ext(c, item);
                },
                .VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FRAGMENT_SHADING_RATE_FEATURES_KHR,
                => {
                    const item =
                        try chain.chain(vk.VkPhysicalDeviceFragmentShadingRateFeaturesKHR);
                    try parse_vk_physical_device_fragment_shading_rate_features_khr(c, item);
                },
                .VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_BINDING_FLAGS_CREATE_INFO,
                => {
                    const item =
                        try chain.chain(vk.VkDescriptorSetLayoutBindingFlagsCreateInfo);
                    try parse_vk_descriptor_set_layout_binding_flags_create_info_ext(c, item);
                },
                .VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_ROBUSTNESS_2_FEATURES_KHR,
                => {
                    const item = try chain.chain(vk.VkPhysicalDeviceRobustness2FeaturesEXT);
                    try parse_vk_physical_device_robustness_2_features_khr(c, item);
                },
                .VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DESCRIPTOR_BUFFER_FEATURES_EXT,
                => {
                    const item = try chain.chain(vk.VkPhysicalDeviceDescriptorBufferFeaturesEXT);
                    try parse_vk_physical_device_descriptor_buffer_features_ext(c, item);
                },
                .VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_DEPTH_CLIP_STATE_CREATE_INFO_EXT,
                => {
                    const item =
                        try chain.chain(vk.VkPipelineRasterizationDepthClipStateCreateInfoEXT);
                    try parse_vk_pipeline_rasterization_depth_clip_state_create_info_ext(c, item);
                },
                .VK_STRUCTURE_TYPE_PIPELINE_CREATE_FLAGS_2_CREATE_INFO,
                => {
                    const item = try chain.chain(vk.VkPipelineCreateFlags2CreateInfo);
                    try parse_vk_pipeline_create_flags_2_create_info(c, item);
                },
                .VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_LIBRARY_CREATE_INFO_EXT,
                => {
                    const item = try chain.chain(vk.VkGraphicsPipelineLibraryCreateInfoEXT);
                    try parse_vk_graphics_pipeline_library_create_info_ext(c, item);
                },
                .VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_DIVISOR_STATE_CREATE_INFO,
                => {
                    const item = try chain.chain(vk.VkPipelineVertexInputDivisorStateCreateInfo);
                    try parse_vk_pipeline_vertex_input_divisor_state_create_info(c, item);
                },
                .VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_REQUIRED_SUBGROUP_SIZE_CREATE_INFO,
                => {
                    const item =
                        try chain.chain(vk.VkPipelineShaderStageRequiredSubgroupSizeCreateInfo);
                    try parse_vk_pipeline_shader_stage_required_subgroup_size_create_info(
                        c,
                        item,
                    );
                },
                .VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_LINE_STATE_CREATE_INFO,
                => {
                    const item = try chain.chain(vk.VkPipelineRasterizationLineStateCreateInfo);
                    try parse_vk_pipeline_rasterization_line_state_create_info(c, item);
                },
                .VK_STRUCTURE_TYPE_PIPELINE_ROBUSTNESS_CREATE_INFO,
                => {
                    const item = try chain.chain(vk.VkPipelineRobustnessCreateInfo);
                    try parse_vk_pipeline_robustness_create_info(c, item);
                },
                .VK_STRUCTURE_TYPE_PIPELINE_TESSELLATION_DOMAIN_ORIGIN_STATE_CREATE_INFO,
                => {
                    const item = try chain.chain(vk.VkPipelineTessellationDomainOriginStateCreateInfo);
                    try parse_vk_pipeline_tessellation_domain_origin_state_create_info(c, item);
                },
                .VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_STREAM_CREATE_INFO_EXT,
                => {
                    const item = try chain.chain(vk.VkPipelineRasterizationStateStreamCreateInfoEXT);
                    try parse_vk_pipeline_rasterization_state_stream_create_info_ext(c, item);
                },
                .VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_ADVANCED_STATE_CREATE_INFO_EXT,
                => {
                    const item = try chain.chain(vk.VkPipelineColorBlendAdvancedStateCreateInfoEXT);
                    try parse_vk_pipeline_color_blend_advanced_state_create_info_ext(c, item);
                },
                .VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_CONSERVATIVE_STATE_CREATE_INFO_EXT,
                => {
                    const item = try chain.chain(vk.VkPipelineRasterizationConservativeStateCreateInfoEXT);
                    try parse_vk_pipeline_rasterization_conservative_state_create_info_ext(c, item);
                },
                .VK_STRUCTURE_TYPE_PIPELINE_COLOR_WRITE_CREATE_INFO_EXT,
                => {
                    const item = try chain.chain(vk.VkPipelineColorWriteCreateInfoEXT);
                    try parse_vk_pipeline_color_write_create_info_ext(c, item);
                },
                .VK_STRUCTURE_TYPE_PIPELINE_SAMPLE_LOCATIONS_STATE_CREATE_INFO_EXT,
                => {
                    const item = try chain.chain(vk.VkPipelineSampleLocationsStateCreateInfoEXT);
                    try parse_vk_pipeline_sample_locations_state_create_info_ext(c, item);
                },
                .VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_PROVOKING_VERTEX_STATE_CREATE_INFO_EXT,
                => {
                    const item = try chain.chain(
                        vk.VkPipelineRasterizationProvokingVertexStateCreateInfoEXT,
                    );
                    try parse_vk_pipeline_rasterization_provoking_vertex_state_create_info_ext(
                        c,
                        item,
                    );
                },
                .VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_DEPTH_CLIP_CONTROL_CREATE_INFO_EXT,
                => {
                    const item =
                        try chain.chain(vk.VkPipelineViewportDepthClipControlCreateInfoEXT);
                    try parse_vk_pipeline_viewport_depth_clip_control_create_info_ext(c, item);
                },
                .VK_STRUCTURE_TYPE_MUTABLE_DESCRIPTOR_TYPE_CREATE_INFO_EXT,
                => {
                    const item = try chain.chain(vk.VkMutableDescriptorTypeCreateInfoEXT);
                    try parse_vk_mutable_descriptor_type_create_info_ext(c, item);
                },
                .VK_STRUCTURE_TYPE_RENDER_PASS_MULTIVIEW_CREATE_INFO,
                => {
                    const item = try chain.chain(vk.VkRenderPassMultiviewCreateInfo);
                    try parse_vk_render_pass_multiview_create_info(c, item);
                },
                .VK_STRUCTURE_TYPE_ATTACHMENT_DESCRIPTION_STENCIL_LAYOUT,
                => {
                    const item = try chain.chain(vk.VkAttachmentDescriptionStencilLayout);
                    try parse_vk_attachment_description_stencil_layout(c, item);
                },
                .VK_STRUCTURE_TYPE_ATTACHMENT_REFERENCE_STENCIL_LAYOUT,
                => {
                    const item = try chain.chain(vk.VkAttachmentReferenceStencilLayout);
                    try parse_vk_attachment_reference_stencil_layout(c, item);
                },
                .VK_STRUCTURE_TYPE_SUBPASS_DESCRIPTION_DEPTH_STENCIL_RESOLVE,
                => {
                    const item = try chain.chain(vk.VkSubpassDescriptionDepthStencilResolve);
                    try parse_vk_subpass_description_depth_stencil_resolve(c, item);
                },
                .VK_STRUCTURE_TYPE_FRAGMENT_SHADING_RATE_ATTACHMENT_INFO_KHR,
                => {
                    const item = try chain.chain(vk.VkFragmentShadingRateAttachmentInfoKHR);
                    try parse_vk_fragment_shading_rate_attachment_info_khr(c, item);
                },
                .VK_STRUCTURE_TYPE_RENDER_PASS_INPUT_ATTACHMENT_ASPECT_CREATE_INFO,
                => {
                    const item = try chain.chain(vk.VkRenderPassInputAttachmentAspectCreateInfo);
                    try parse_vk_render_pass_input_attachment_aspect_create_info(c, item);
                },
                .VK_STRUCTURE_TYPE_SAMPLER_REDUCTION_MODE_CREATE_INFO,
                => {
                    const item = try chain.chain(vk.VkSamplerReductionModeCreateInfo);
                    try parse_vk_sampler_reduction_mode_create_info(c, item);
                },
                .VK_STRUCTURE_TYPE_SAMPLER_YCBCR_CONVERSION_CREATE_INFO,
                => {
                    const item = try chain.chain(vk.VkSamplerYcbcrConversionCreateInfo);
                    try parse_vk_sampler_ycbcr_conversion_create_info(c, item);
                },
                .VK_STRUCTURE_TYPE_SAMPLER_CUSTOM_BORDER_COLOR_CREATE_INFO_EXT,
                => {
                    const item = try chain.chain(vk.VkSamplerCustomBorderColorCreateInfoEXT);
                    try parse_vk_sampler_custom_border_color_create_info_ext(c, item);
                },
                .VK_STRUCTURE_TYPE_SAMPLER_BORDER_COLOR_COMPONENT_MAPPING_CREATE_INFO_EXT,
                => {
                    const item = try chain.chain(vk.VkSamplerBorderColorComponentMappingCreateInfoEXT);
                    try parse_vk_sampler_border_color_component_mapping_create_info_ext(c, item);
                },
                .VK_STRUCTURE_TYPE_PIPELINE_DISCARD_RECTANGLE_STATE_CREATE_INFO_EXT,
                => {
                    const obj = try chain.chain(vk.VkPipelineDiscardRectangleStateCreateInfoEXT);
                    try parse_vk_pipeline_discard_rectangle_state_create_info_ext(c, obj);
                },
                .VK_STRUCTURE_TYPE_PIPELINE_FRAGMENT_SHADING_RATE_STATE_CREATE_INFO_KHR,
                => {
                    const obj =
                        try chain.chain(vk.VkPipelineFragmentShadingRateStateCreateInfoKHR);
                    try parse_vk_pipeline_fragment_shading_rate_state_create_info_khr(c, obj);
                },
                .VK_STRUCTURE_TYPE_PIPELINE_RENDERING_CREATE_INFO,
                => {
                    const obj = try chain.chain(vk.VkPipelineRenderingCreateInfo);
                    try parse_vk_pipeline_rendering_create_info(c, obj);
                },
                .VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_LOCATION_INFO,
                => {
                    const obj = try chain.chain(vk.VkRenderingAttachmentLocationInfo);
                    try parse_vk_rendering_attachment_location_info(c, obj);
                },
                .VK_STRUCTURE_TYPE_RENDERING_INPUT_ATTACHMENT_INDEX_INFO,
                => {
                    const obj = try chain.chain(vk.VkRenderingInputAttachmentIndexInfo);
                    try parse_vk_rendering_input_attachment_index_info(c, obj);
                },
                .VK_STRUCTURE_TYPE_PIPELINE_FRAGMENT_DENSITY_MAP_LAYERED_CREATE_INFO_VALVE,
                => {
                    const obj = try chain.chain(vk.VkPipelineFragmentDensityMapLayeredCreateInfoVALVE);
                    try parse_vk_pipeline_fragment_density_map_layered_create_info_valve(c, obj);
                },
                .VK_STRUCTURE_TYPE_DEPTH_BIAS_REPRESENTATION_INFO_EXT,
                => {
                    const obj = try chain.chain(vk.VkDepthBiasRepresentationInfoEXT);
                    try parse_vk_structure_type_depth_bias_representation_info_ext(c, obj);
                },
                else => {
                    log.err(@src(), "Unknown pnext chain type: {t}", .{stype});
                    return error.UnknownPnextChain;
                },
            }
        }

        fn parse_pipeline_library(
            c: *Context,
            first_in_chain: *?*anyopaque,
            last_pnext_in_chain: *?**anyopaque,
        ) Error!void {
            const obj = try c.alloc.create(vk.VkPipelineLibraryCreateInfoKHR);
            obj.* = .{};
            if (first_in_chain.* == null)
                first_in_chain.* = obj;
            if (last_pnext_in_chain.*) |lpic| {
                lpic.* = obj;
            }
            last_pnext_in_chain.* = @ptrCast(&obj.pNext);
            const libraries = try parse_handle_array(
                vk.VkPipeline,
                .graphics_pipeline,
                c,
            );
            obj.pLibraries = @ptrCast(libraries.ptr);
            obj.libraryCount = @intCast(libraries.len);

            while (try scanner_object_next_field(c.scanner)) |ss| {
                if (std.mem.eql(u8, ss, "sType")) {
                    const stype = try scanner_parse_enum(vk.VkStructureType, c.scanner);
                    if (stype != .VK_STRUCTURE_TYPE_PIPELINE_LIBRARY_CREATE_INFO_KHR) {
                        log.err(
                            @src(),
                            "Expected VkPipelineLibraryCreateInfoKHR({t}) found {t}",
                            .{
                                vk.VkStructureType.VK_STRUCTURE_TYPE_PIPELINE_LIBRARY_CREATE_INFO_KHR,
                                stype,
                            },
                        );
                        return error.InvalidsTypeForLibraries;
                    }
                } else {
                    const v = try scanner_next_number_or_string(c.scanner);
                    log.warn(@src(), "Skipping unknown field {s}: {s}", .{ ss, v });
                }
            }
        }
    };

    var first_in_chain: ?*anyopaque = null;
    var last_pnext_in_chain: ?**anyopaque = null;
    while (try scanner_array_next_object(context.scanner)) {
        const s = try scanner_object_next_field(context.scanner) orelse return error.InvalidJson;
        if (std.mem.eql(u8, s, "sType")) {
            try Inner.parse_next(context, &first_in_chain, &last_pnext_in_chain);
        } else if (std.mem.eql(u8, s, "libraries")) {
            try Inner.parse_pipeline_library(context, &first_in_chain, &last_pnext_in_chain);
        } else {
            const v = try scanner_next_number_or_string(context.scanner);
            log.warn(@src(), "Skipping unknown field {s}: {s}", .{ s, v });
        }
    }
    return first_in_chain;
}

pub fn parse_vk_application_info(
    context: *Context,
    item: *vk.VkApplicationInfo,
) Error!void {
    const prof_point = MEASUREMENTS.start(@src());
    defer MEASUREMENTS.end(prof_point);

    log.info(@src(), "scanner: {any}", .{context.scanner});
    item.* = .{};
    while (try scanner_object_next_field(context.scanner)) |s| {
        log.info(@src(), "token: {s}", .{s});
        if (std.mem.eql(u8, s, "applicationName")) {
            const name_str = try scanner_next_string(context.scanner);
            const name = try context.alloc.dupeZ(u8, name_str);
            item.pApplicationName = @ptrCast(name.ptr);
        } else if (std.mem.eql(u8, s, "engineName")) {
            const name_str = try scanner_next_string(context.scanner);
            const name = try context.alloc.dupeZ(u8, name_str);
            item.pEngineName = @ptrCast(name.ptr);
        } else if (std.mem.eql(u8, s, "applicationVersion")) {
            item.applicationVersion = try scanner_parse_bitfield(vk.ApiVersion, context.scanner);
        } else if (std.mem.eql(u8, s, "engineVersion")) {
            item.engineVersion = try scanner_parse_bitfield(vk.ApiVersion, context.scanner);
        } else if (std.mem.eql(u8, s, "apiVersion")) {
            item.apiVersion = try scanner_parse_bitfield(vk.ApiVersion, context.scanner);
        } else {
            const v = try scanner_next_number_or_string(context.scanner);
            log.warn(@src(), "Skipping unknown field {s}: {s}", .{ s, v });
        }
    }
}

test "test_parse_vk_application_info" {
    const json =
        \\{
        \\  "applicationName": "APP_NAME",
        \\  "engineName": "ENGINE_NAME",
        \\  "applicationVersion": 69,
        \\  "engineVersion": 69,
        \\  "apiVersion": 69
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const alloc = arena.allocator();

    const db: Database = .{ .file_fd = undefined, .entries = .initFill(.empty), .arena = arena };
    var scanner = Json.init(alloc, json);
    var context = Context{
        .alloc = alloc,
        .tmp_alloc = alloc,
        .scanner = &scanner,
        .db = &db,
    };

    var item: vk.VkApplicationInfo = undefined;
    try parse_vk_application_info(&context, &item);

    try std.testing.expectEqual(null, item.pNext);
    try std.testing.expectEqualSlices(u8, "APP_NAME", std.mem.span(item.pApplicationName.?));
    try std.testing.expectEqual(69, @as(u32, @bitCast(item.applicationVersion)));
    try std.testing.expectEqualSlices(u8, "ENGINE_NAME", std.mem.span(item.pEngineName.?));
    try std.testing.expectEqual(69, @as(u32, @bitCast(item.engineVersion)));
    try std.testing.expectEqual(69, @as(u32, @bitCast(item.apiVersion)));
}

pub fn parse_vk_physical_device_features2(
    context: *Context,
    item: *vk.VkPhysicalDeviceFeatures2,
) Error!void {
    const prof_point = MEASUREMENTS.start(@src());
    defer MEASUREMENTS.end(prof_point);

    item.* = .{};
    while (try scanner_object_next_field(context.scanner)) |s| {
        if (std.mem.eql(u8, s, "robustBufferAccess")) {
            item.features.robustBufferAccess = try scanner_parse_number(u32, context.scanner);
        } else if (std.mem.eql(u8, s, "pNext")) {
            item.pNext = try parse_pnext_chain(context);
        } else {
            const v = try scanner_next_number_or_string(context.scanner);
            log.warn(@src(), "Skipping unknown field {s}: {s}", .{ s, v });
        }
    }
}

test "test_parse_vk_physical_device_features2" {
    const json =
        \\{
        \\  "robustBufferAccess": 69
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const alloc = arena.allocator();

    const db: Database = .{ .file_fd = undefined, .entries = .initFill(.empty), .arena = arena };
    var scanner = Json.init(alloc, json);
    var context = Context{
        .alloc = alloc,
        .tmp_alloc = alloc,
        .scanner = &scanner,
        .db = &db,
    };

    var item: vk.VkPhysicalDeviceFeatures2 = undefined;
    try parse_vk_physical_device_features2(&context, &item);

    try std.testing.expectEqual(null, item.pNext);
    try std.testing.expectEqual(item.features, vk.VkPhysicalDeviceFeatures{
        .robustBufferAccess = 69,
    });
}

pub fn parse_vk_sampler_create_info(
    context: *Context,
    item: *vk.VkSamplerCreateInfo,
) Error!void {
    const prof_point = MEASUREMENTS.start(@src());
    defer MEASUREMENTS.end(prof_point);

    item.* = .{};
    try parse_simple_type(context, item);
}

test "test_parse_vk_sampler_create_info" {
    const json =
        \\{
        \\  "flags": 69,
        \\  "minFilter": 69,
        \\  "magFilter": 69,
        \\  "maxAnisotropy": 69,
        \\  "compareOp": 69,
        \\  "anisotropyEnable": 69,
        \\  "mipmapMode": 69,
        \\  "addressModeU": 69,
        \\  "addressModeV": 69,
        \\  "addressModeW": 69,
        \\  "borderColor": 69,
        \\  "unnormalizedCoordinates": 69,
        \\  "compareEnable": 69,
        \\  "mipLodBias": 69,
        \\  "minLod": 69,
        \\  "maxLod": 69
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const alloc = arena.allocator();

    const db: Database = .{ .file_fd = undefined, .entries = .initFill(.empty), .arena = arena };
    var scanner = Json.init(alloc, json);
    var context = Context{
        .alloc = alloc,
        .tmp_alloc = alloc,
        .scanner = &scanner,
        .db = &db,
    };

    var item: vk.VkSamplerCreateInfo = undefined;
    try parse_vk_sampler_create_info(&context, &item);

    try std.testing.expectEqual(null, item.pNext);
    try std.testing.expectEqual(69, @as(u32, @bitCast(item.flags)));
    try std.testing.expectEqual(69, @as(i32, @intFromEnum(item.magFilter)));
    try std.testing.expectEqual(69, @as(i32, @intFromEnum(item.minFilter)));
    try std.testing.expectEqual(69, @as(i32, @intFromEnum(item.mipmapMode)));
    try std.testing.expectEqual(69, @as(i32, @intFromEnum(item.addressModeU)));
    try std.testing.expectEqual(69, @as(i32, @intFromEnum(item.addressModeV)));
    try std.testing.expectEqual(69, @as(i32, @intFromEnum(item.addressModeW)));
    try std.testing.expectEqual(69, item.mipLodBias);
    try std.testing.expectEqual(69, item.anisotropyEnable);
    try std.testing.expectEqual(69, item.maxAnisotropy);
    try std.testing.expectEqual(69, item.compareEnable);
    try std.testing.expectEqual(69, @as(i32, @intFromEnum(item.compareOp)));
    try std.testing.expectEqual(69, item.minLod);
    try std.testing.expectEqual(69, item.maxLod);
    try std.testing.expectEqual(69, @as(i32, @intFromEnum(item.borderColor)));
    try std.testing.expectEqual(69, item.unnormalizedCoordinates);
}

pub fn parse_vk_descriptor_set_layout_create_info(
    context: *Context,
    item: *vk.VkDescriptorSetLayoutCreateInfo,
) Error!void {
    const prof_point = MEASUREMENTS.start(@src());
    defer MEASUREMENTS.end(prof_point);

    item.* = .{};
    while (try scanner_object_next_field(context.scanner)) |s| {
        if (std.mem.eql(u8, s, "flags")) {
            item.flags = try scanner_parse_bitfield(vk.VkDescriptorSetLayoutCreateFlags, context.scanner);
        } else if (std.mem.eql(u8, s, "bindings")) {
            const bindings = try parse_object_array(
                vk.VkDescriptorSetLayoutBinding,
                parse_vk_descriptor_set_layout_binding,
                context,
            );
            item.pBindings = @ptrCast(bindings.ptr);
            item.bindingCount = @intCast(bindings.len);
        } else if (std.mem.eql(u8, s, "pNext")) {
            item.pNext = try parse_pnext_chain(context);
        } else {
            const v = try scanner_next_number_or_string(context.scanner);
            log.warn(@src(), "Skipping unknown field {s}: {s}", .{ s, v });
        }
    }
}

test "test_parse_vk_descriptor_set_layout_create_info" {
    const json =
        \\{
        \\  "flags": 69,
        \\  "bindings": [{}]
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const alloc = arena.allocator();

    const db: Database = .{ .file_fd = undefined, .entries = .initFill(.empty), .arena = arena };
    var scanner = Json.init(alloc, json);
    var context = Context{
        .alloc = alloc,
        .tmp_alloc = alloc,
        .scanner = &scanner,
        .db = &db,
    };

    var item: vk.VkDescriptorSetLayoutCreateInfo = undefined;
    try parse_vk_descriptor_set_layout_create_info(&context, &item);

    try std.testing.expectEqual(null, item.pNext);
    try std.testing.expectEqual(69, @as(u32, @bitCast(item.flags)));
    try std.testing.expectEqual(1, item.bindingCount);
    try std.testing.expect(item.pBindings != null);
}

pub fn parse_vk_descriptor_set_layout_binding(
    context: *Context,
    item: *vk.VkDescriptorSetLayoutBinding,
) Error!void {
    const prof_point = MEASUREMENTS.start(@src());
    defer MEASUREMENTS.end(prof_point);

    item.* = .{};
    while (try scanner_object_next_field(context.scanner)) |s| {
        if (std.mem.eql(u8, s, "descriptorType")) {
            item.descriptorType = try scanner_parse_enum(vk.VkDescriptorType, context.scanner);
        } else if (std.mem.eql(u8, s, "descriptorCount")) {
            item.descriptorCount = try scanner_parse_number(u32, context.scanner);
        } else if (std.mem.eql(u8, s, "stageFlags")) {
            item.stageFlags = try scanner_parse_bitfield(vk.VkShaderStageFlags, context.scanner);
        } else if (std.mem.eql(u8, s, "binding")) {
            item.binding = try scanner_parse_number(u32, context.scanner);
        } else if (std.mem.eql(u8, s, "immutableSamplers")) {
            const samplers = try parse_handle_array(
                vk.VkSampler,
                .sampler,
                context,
            );
            item.pImmutableSamplers = @ptrCast(samplers.ptr);
        } else {
            const v = try scanner_next_number_or_string(context.scanner);
            log.warn(@src(), "Skipping unknown field {s}: {s}", .{ s, v });
        }
    }
}

test "test_parse_vk_descriptor_set_layout_binding" {
    const json =
        \\{
        \\  "descriptorType": 69,
        \\  "descriptorCount": 69,
        \\  "stageFlags": 69,
        \\  "binding": 69,
        \\  "immutableSamplers": [
        \\    "1111111111111111"
        \\  ]
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const alloc = arena.allocator();

    var db: Database = .{ .file_fd = undefined, .entries = .initFill(.empty), .arena = arena };
    try db.entries.getPtr(.sampler).put(alloc, 0x1111111111111111, .{
        .tag = undefined,
        .hash = undefined,
        .payload_flag = undefined,
        .payload_crc = undefined,
        .payload_stored_size = undefined,
        .payload_decompressed_size = undefined,
        .payload_file_offset = undefined,
        .handle = 0x69,
    });

    var scanner = Json.init(alloc, json);
    var context = Context{
        .alloc = alloc,
        .tmp_alloc = alloc,
        .scanner = &scanner,
        .db = &db,
    };

    var item: vk.VkDescriptorSetLayoutBinding = undefined;
    try parse_vk_descriptor_set_layout_binding(&context, &item);

    try std.testing.expectEqual(69, item.binding);
    try std.testing.expectEqual(69, @as(i32, @intFromEnum(item.descriptorType)));
    try std.testing.expectEqual(69, item.descriptorCount);
    try std.testing.expectEqual(69, @as(u32, @bitCast(item.stageFlags)));
    try std.testing.expect(item.pImmutableSamplers != null);

    try std.testing.expectEqual(0, @intFromEnum(item.pImmutableSamplers.?[0]));
    try std.testing.expectEqual(1, context.dependencies.items.len);
    try std.testing.expectEqual(.sampler, context.dependencies.items[0].tag);
    try std.testing.expectEqual(0x1111111111111111, context.dependencies.items[0].hash);
    context.dependencies.items[0].ptr_to_handle.?.* = 0x69;
    try std.testing.expectEqual(0x69, @intFromEnum(item.pImmutableSamplers.?[0]));
}

pub fn parse_vk_pipeline_layout_create_info(
    context: *Context,
    item: *vk.VkPipelineLayoutCreateInfo,
) Error!void {
    const prof_point = MEASUREMENTS.start(@src());
    defer MEASUREMENTS.end(prof_point);

    item.* = .{};
    while (try scanner_object_next_field(context.scanner)) |s| {
        if (std.mem.eql(u8, s, "flags")) {
            item.flags = try scanner_parse_bitfield(vk.VkPipelineLayoutCreateFlags, context.scanner);
        } else if (std.mem.eql(u8, s, "pushConstantRanges")) {
            const constant_ranges = try parse_object_array(
                vk.VkPushConstantRange,
                parse_vk_push_constant_range,
                context,
            );
            item.pPushConstantRanges = @ptrCast(constant_ranges.ptr);
            item.pushConstantRangeCount = @intCast(constant_ranges.len);
        } else if (std.mem.eql(u8, s, "setLayouts")) {
            const set_layouts = try parse_handle_array(
                vk.VkDescriptorSetLayout,
                .descriptor_set_layout,
                context,
            );
            item.pSetLayouts = @ptrCast(set_layouts.ptr);
            item.setLayoutCount = @intCast(set_layouts.len);
        } else {
            const v = try scanner_next_number_or_string(context.scanner);
            log.warn(@src(), "Skipping unknown field {s}: {s}", .{ s, v });
        }
    }
}

test "test_parse_vk_pipeline_layout_create_info" {
    const json =
        \\{
        \\  "flags": 69,
        \\  "setLayouts": [
        \\    "1111111111111111"
        \\  ],
        \\  "pushConstantRanges": [{}]
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const alloc = arena.allocator();

    var db: Database = .{ .file_fd = undefined, .entries = .initFill(.empty), .arena = arena };
    try db.entries.getPtr(.descriptor_set_layout).put(alloc, 0x1111111111111111, .{
        .tag = undefined,
        .hash = undefined,
        .payload_flag = undefined,
        .payload_crc = undefined,
        .payload_stored_size = undefined,
        .payload_decompressed_size = undefined,
        .payload_file_offset = undefined,
        .handle = 0x69,
    });

    var scanner = Json.init(alloc, json);
    var context = Context{
        .alloc = alloc,
        .tmp_alloc = alloc,
        .scanner = &scanner,
        .db = &db,
    };

    var item: vk.VkPipelineLayoutCreateInfo = undefined;
    try parse_vk_pipeline_layout_create_info(&context, &item);

    try std.testing.expectEqual(null, item.pNext);
    try std.testing.expectEqual(69, @as(u32, @bitCast(item.flags)));
    try std.testing.expectEqual(1, item.setLayoutCount);
    try std.testing.expect(item.pSetLayouts != null);
    try std.testing.expectEqual(1, item.pushConstantRangeCount);
    try std.testing.expect(item.pPushConstantRanges != null);

    try std.testing.expectEqual(0, @intFromEnum(item.pSetLayouts.?[0]));
    try std.testing.expectEqual(1, context.dependencies.items.len);
    try std.testing.expectEqual(.descriptor_set_layout, context.dependencies.items[0].tag);
    try std.testing.expectEqual(0x1111111111111111, context.dependencies.items[0].hash);
    context.dependencies.items[0].ptr_to_handle.?.* = 0x69;
    try std.testing.expectEqual(0x69, @intFromEnum(item.pSetLayouts.?[0]));
}

pub fn parse_vk_push_constant_range(context: *Context, item: *vk.VkPushConstantRange) Error!void {
    const prof_point = MEASUREMENTS.start(@src());
    defer MEASUREMENTS.end(prof_point);

    item.* = .{};
    try parse_simple_type(context, item);
}

test "test_parse_vk_push_constant_range" {
    const json =
        \\{
        \\  "stageFlags": 69,
        \\  "size": 69,
        \\  "offset": 69
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const alloc = arena.allocator();

    const db: Database = .{ .file_fd = undefined, .entries = .initFill(.empty), .arena = arena };
    var scanner = Json.init(alloc, json);
    var context = Context{
        .alloc = alloc,
        .tmp_alloc = alloc,
        .scanner = &scanner,
        .db = &db,
    };

    var item: vk.VkPushConstantRange = undefined;
    try parse_vk_push_constant_range(&context, &item);

    try std.testing.expectEqual(69, @as(u32, @bitCast(item.stageFlags)));
    try std.testing.expectEqual(69, item.offset);
    try std.testing.expectEqual(69, item.size);
}

pub fn parse_vk_shader_module_create_info(
    context: *Context,
    item: *vk.VkShaderModuleCreateInfo,
    shader_code_payload: []const u8,
) Error!void {
    const prof_point = MEASUREMENTS.start(@src());
    defer MEASUREMENTS.end(prof_point);

    const Inner = struct {
        fn decode_shader_payload(input: []const u8, output: []u32) bool {
            var offset: u64 = 0;
            for (output) |*out| {
                out.* = 0;
                var shift: u32 = 0;
                while (true) : ({
                    offset += 1;
                    shift += 7;
                }) {
                    if (input.len < offset or 32 < shift)
                        return false;
                    out.* |= @as(u32, @intCast(input[offset] & 0x7f)) << @truncate(shift);
                    if (input[offset] & 0x80 == 0)
                        break;
                }
                offset += 1;
            }
            return offset == input.len;
        }
    };

    item.* = .{};
    // NOTE: there is a possibility that the json object does not have
    // `varintOffset` and `variantSize` fields. In such case the shader code
    // is inlined in the `code` string. Skip this case for now.
    var variant_offset: u64 = 0;
    var variant_size: u64 = 0;
    while (try scanner_object_next_field(context.scanner)) |s| {
        if (std.mem.eql(u8, s, "varintOffset")) {
            variant_offset = try scanner_parse_number(u64, context.scanner);
        } else if (std.mem.eql(u8, s, "varintSize")) {
            variant_size = try scanner_parse_number(u64, context.scanner);
        } else if (std.mem.eql(u8, s, "codeSize")) {
            item.codeSize = try scanner_parse_number(u64, context.scanner);
        } else if (std.mem.eql(u8, s, "flags")) {
            item.flags = try scanner_parse_bitfield(vk.VkShaderModuleCreateFlags, context.scanner);
        } else {
            const v = try scanner_next_number_or_string(context.scanner);
            log.warn(@src(), "Skipping unknown field {s}: {s}", .{ s, v });
        }
    }
    if (shader_code_payload.len < variant_offset + variant_size)
        return error.InvalidShaderPayload;
    if ((item.codeSize & (@sizeOf(u32) - 1)) != 0)
        return error.InvalidShaderPayload;
    const code = try context.alloc.alignedAlloc(u32, .@"64", item.codeSize / @sizeOf(u32));
    if (!Inner.decode_shader_payload(
        shader_code_payload[variant_offset..][0..variant_size],
        code,
    ))
        return error.InvalidShaderPayloadEncoding;
    item.pCode = @ptrCast(code.ptr);
}

test "test_parse_vk_shader_module_create_info" {
    const json =
        \\{
        \\  "varintOffset": 0,
        \\  "varintSize": 1,
        \\  "codeSize": 4,
        \\  "flags": 69
        \\}
    ;
    const code = "\x00\x81\x82\x83\x00";
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const alloc = arena.allocator();

    const db: Database = .{ .file_fd = undefined, .entries = .initFill(.empty), .arena = arena };

    var scanner = Json.init(alloc, json);
    var context = Context{
        .alloc = alloc,
        .tmp_alloc = alloc,
        .scanner = &scanner,
        .db = &db,
    };

    var item: vk.VkShaderModuleCreateInfo = undefined;
    try parse_vk_shader_module_create_info(&context, &item, code);

    try std.testing.expectEqual(null, item.pNext);
    try std.testing.expectEqual(69, @as(u32, @bitCast(item.flags)));
    try std.testing.expectEqual(4, item.codeSize);
    try std.testing.expect(item.pCode != null);
}

pub fn parse_vk_render_pass_create_info(
    context: *Context,
    item: *vk.VkRenderPassCreateInfo,
) Error!void {
    const prof_point = MEASUREMENTS.start(@src());
    defer MEASUREMENTS.end(prof_point);

    item.* = .{};
    while (try scanner_object_next_field(context.scanner)) |s| {
        if (std.mem.eql(u8, s, "flags")) {
            item.flags = try scanner_parse_bitfield(vk.VkRenderPassCreateFlags, context.scanner);
        } else if (std.mem.eql(u8, s, "dependencies")) {
            const dependencies = try parse_object_array(
                vk.VkSubpassDependency,
                parse_vk_subpass_dependency,
                context,
            );
            item.pDependencies = @ptrCast(dependencies.ptr);
            item.dependencyCount = @intCast(dependencies.len);
        } else if (std.mem.eql(u8, s, "attachments")) {
            const attachments = try parse_object_array(
                vk.VkAttachmentDescription,
                parse_vk_attachment_description,
                context,
            );
            item.pAttachments = @ptrCast(attachments.ptr);
            item.attachmentCount = @intCast(attachments.len);
        } else if (std.mem.eql(u8, s, "subpasses")) {
            const subpasses = try parse_object_array(
                vk.VkSubpassDescription,
                parse_vk_subpass_description,
                context,
            );
            item.pSubpasses = @ptrCast(subpasses.ptr);
            item.subpassCount = @intCast(subpasses.len);
        } else {
            const v = try scanner_next_number_or_string(context.scanner);
            log.warn(@src(), "Skipping unknown field {s}: {s}", .{ s, v });
        }
    }
}

test "test_parse_vk_render_pass_create_info" {
    const json =
        \\{
        \\  "flags": 69,
        \\  "dependencies": [{}],
        \\  "attachments": [{}],
        \\  "subpasses": [{}]
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const alloc = arena.allocator();

    const db: Database = .{ .file_fd = undefined, .entries = .initFill(.empty), .arena = arena };
    var scanner = Json.init(alloc, json);
    var context = Context{
        .alloc = alloc,
        .tmp_alloc = alloc,
        .scanner = &scanner,
        .db = &db,
    };

    var item: vk.VkRenderPassCreateInfo = undefined;
    try parse_vk_render_pass_create_info(&context, &item);

    try std.testing.expectEqual(null, item.pNext);
    try std.testing.expectEqual(69, @as(u32, @bitCast(item.flags)));
    try std.testing.expectEqual(1, item.attachmentCount);
    try std.testing.expect(item.pAttachments != null);
    try std.testing.expectEqual(1, item.subpassCount);
    try std.testing.expect(item.pSubpasses != null);
    try std.testing.expectEqual(1, item.dependencyCount);
    try std.testing.expect(item.pDependencies != null);
}

pub fn parse_vk_render_pass_create_info2(
    context: *Context,
    item: *vk.VkRenderPassCreateInfo2,
) Error!void {
    const prof_point = MEASUREMENTS.start(@src());
    defer MEASUREMENTS.end(prof_point);

    item.* = .{};
    while (try scanner_object_next_field(context.scanner)) |s| {
        if (std.mem.eql(u8, s, "flags")) {
            item.flags = try scanner_parse_bitfield(vk.VkRenderPassCreateFlags, context.scanner);
        } else if (std.mem.eql(u8, s, "attachments")) {
            const attachments = try parse_object_array(
                vk.VkAttachmentDescription2,
                parse_vk_attachment_description2,
                context,
            );
            item.pAttachments = @ptrCast(attachments.ptr);
            item.attachmentCount = @intCast(attachments.len);
        } else if (std.mem.eql(u8, s, "subpasses")) {
            const subpasses = try parse_object_array(
                vk.VkSubpassDescription2,
                parse_vk_subpass_description2,
                context,
            );
            item.pSubpasses = @ptrCast(subpasses.ptr);
            item.subpassCount = @intCast(subpasses.len);
        } else if (std.mem.eql(u8, s, "dependencies")) {
            const dependencies = try parse_object_array(
                vk.VkSubpassDependency2,
                parse_vk_subpass_dependency2,
                context,
            );
            item.pDependencies = @ptrCast(dependencies.ptr);
            item.dependencyCount = @intCast(dependencies.len);
        } else if (std.mem.eql(u8, s, "correlatedViewMasks")) {
            const masks = try parse_number_array(u32, context);
            item.pCorrelatedViewMasks = @ptrCast(masks.ptr);
            item.correlatedViewMaskCount = @intCast(masks.len);
        } else {
            const v = try scanner_next_number_or_string(context.scanner);
            log.warn(@src(), "Skipping unknown field {s}: {s}", .{ s, v });
        }
    }
}

test "test_parse_vk_render_pass_create_info2" {
    const json =
        \\{
        \\  "flags": 69,
        \\  "attachments": [{}],
        \\  "subpasses": [{}],
        \\  "dependencies": [{}],
        \\  "correlatedViewMasks": [69, 69]
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const alloc = arena.allocator();

    const db: Database = .{ .file_fd = undefined, .entries = .initFill(.empty), .arena = arena };
    var scanner = Json.init(alloc, json);
    var context = Context{
        .alloc = alloc,
        .tmp_alloc = alloc,
        .scanner = &scanner,
        .db = &db,
    };

    var item: vk.VkRenderPassCreateInfo2 = undefined;
    try parse_vk_render_pass_create_info2(&context, &item);

    try std.testing.expectEqual(null, item.pNext);
    try std.testing.expectEqual(69, @as(u32, @bitCast(item.flags)));
    try std.testing.expectEqual(1, item.attachmentCount);
    try std.testing.expect(item.pAttachments != null);
    try std.testing.expectEqual(1, item.subpassCount);
    try std.testing.expect(item.pSubpasses != null);
    try std.testing.expectEqual(1, item.dependencyCount);
    try std.testing.expect(item.pDependencies != null);
    try std.testing.expectEqual(2, item.correlatedViewMaskCount);
    try std.testing.expectEqual(69, item.pCorrelatedViewMasks.?[0]);
    try std.testing.expectEqual(69, item.pCorrelatedViewMasks.?[1]);
}

pub fn parse_vk_subpass_dependency(
    context: *Context,
    item: *vk.VkSubpassDependency,
) Error!void {
    const prof_point = MEASUREMENTS.start(@src());
    defer MEASUREMENTS.end(prof_point);

    item.* = .{};
    try parse_simple_type(context, item);
}

test "test_parse_vk_subpass_dependency" {
    const json =
        \\{
        \\  "dependencyFlags": 69,
        \\  "dstAccessMask": 69,
        \\  "srcAccessMask": 69,
        \\  "dstStageMask": 69,
        \\  "srcStageMask": 69,
        \\  "dstSubpass": 69,
        \\  "srcSubpass": 69
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const alloc = arena.allocator();

    const db: Database = .{ .file_fd = undefined, .entries = .initFill(.empty), .arena = arena };
    var scanner = Json.init(alloc, json);
    var context = Context{
        .alloc = alloc,
        .tmp_alloc = alloc,
        .scanner = &scanner,
        .db = &db,
    };

    var item: vk.VkSubpassDependency = undefined;
    try parse_vk_subpass_dependency(&context, &item);

    try std.testing.expectEqual(69, item.srcSubpass);
    try std.testing.expectEqual(69, item.dstSubpass);
    try std.testing.expectEqual(69, @as(u32, @bitCast(item.srcStageMask)));
    try std.testing.expectEqual(69, @as(u32, @bitCast(item.dstStageMask)));
    try std.testing.expectEqual(69, @as(u32, @bitCast(item.srcAccessMask)));
    try std.testing.expectEqual(69, @as(u32, @bitCast(item.dstAccessMask)));
    try std.testing.expectEqual(69, @as(u32, @bitCast(item.dependencyFlags)));
}

pub fn parse_vk_subpass_dependency2(
    context: *Context,
    item: *vk.VkSubpassDependency2,
) Error!void {
    const prof_point = MEASUREMENTS.start(@src());
    defer MEASUREMENTS.end(prof_point);

    item.* = .{};
    try parse_simple_type(context, item);
}

test "test_parse_vk_subpass_dependency2" {
    const json =
        \\{
        \\  "srcSubpass": 69,
        \\  "dstSubpass": 69,
        \\  "srcStageMask": 69,
        \\  "dstStageMask": 69,
        \\  "srcAccessMask": 69,
        \\  "dstAccessMask": 69,
        \\  "dependencyFlags": 69,
        \\  "viewOffset": 69
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const alloc = arena.allocator();

    const db: Database = .{ .file_fd = undefined, .entries = .initFill(.empty), .arena = arena };
    var scanner = Json.init(alloc, json);
    var context = Context{
        .alloc = alloc,
        .tmp_alloc = alloc,
        .scanner = &scanner,
        .db = &db,
    };

    var item: vk.VkSubpassDependency2 = undefined;
    try parse_vk_subpass_dependency2(&context, &item);

    try std.testing.expectEqual(null, item.pNext);
    try std.testing.expectEqual(69, item.srcSubpass);
    try std.testing.expectEqual(69, item.dstSubpass);
    try std.testing.expectEqual(69, @as(u32, @bitCast(item.srcStageMask)));
    try std.testing.expectEqual(69, @as(u32, @bitCast(item.dstStageMask)));
    try std.testing.expectEqual(69, @as(u32, @bitCast(item.srcAccessMask)));
    try std.testing.expectEqual(69, @as(u32, @bitCast(item.dstAccessMask)));
    try std.testing.expectEqual(69, @as(u32, @bitCast(item.dependencyFlags)));
    try std.testing.expectEqual(69, item.viewOffset);
}

pub fn parse_vk_attachment_description(
    context: *Context,
    item: *vk.VkAttachmentDescription,
) Error!void {
    const prof_point = MEASUREMENTS.start(@src());
    defer MEASUREMENTS.end(prof_point);

    item.* = .{};
    try parse_simple_type(context, item);
}

test "test_parse_vk_attachment_description" {
    const json =
        \\{
        \\  "flags": 69,
        \\  "format": 69,
        \\  "finalLayout": 69,
        \\  "initialLayout": 69,
        \\  "loadOp": 69,
        \\  "storeOp": 69,
        \\  "samples": 69,
        \\  "stencilLoadOp": 69,
        \\  "stencilStoreOp": 69
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const alloc = arena.allocator();

    const db: Database = .{ .file_fd = undefined, .entries = .initFill(.empty), .arena = arena };
    var scanner = Json.init(alloc, json);
    var context = Context{
        .alloc = alloc,
        .tmp_alloc = alloc,
        .scanner = &scanner,
        .db = &db,
    };

    var item: vk.VkAttachmentDescription = undefined;
    try parse_vk_attachment_description(&context, &item);

    try std.testing.expectEqual(69, @as(u32, @bitCast(item.flags)));
    try std.testing.expectEqual(69, @as(i32, @intFromEnum(item.format)));
    try std.testing.expectEqual(69, @as(u32, @bitCast(item.samples)));
    try std.testing.expectEqual(69, @as(i32, @intFromEnum(item.loadOp)));
    try std.testing.expectEqual(69, @as(i32, @intFromEnum(item.storeOp)));
    try std.testing.expectEqual(69, @as(i32, @intFromEnum(item.stencilLoadOp)));
    try std.testing.expectEqual(69, @as(i32, @intFromEnum(item.stencilStoreOp)));
    try std.testing.expectEqual(69, @as(i32, @intFromEnum(item.initialLayout)));
    try std.testing.expectEqual(69, @as(i32, @intFromEnum(item.finalLayout)));
}

pub fn parse_vk_attachment_description2(
    context: *Context,
    item: *vk.VkAttachmentDescription2,
) Error!void {
    const prof_point = MEASUREMENTS.start(@src());
    defer MEASUREMENTS.end(prof_point);

    item.* = .{};
    try parse_simple_type(context, item);
}

test "test_parse_vk_attachment_description2" {
    const json =
        \\{
        \\  "flags": 69,
        \\  "format": 69,
        \\  "samples": 69,
        \\  "loadOp": 69,
        \\  "storeOp": 69,
        \\  "stencilLoadOp": 69,
        \\  "stencilStoreOp": 69,
        \\  "initialLayout": 69,
        \\  "finalLayout": 69
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const alloc = arena.allocator();

    const db: Database = .{ .file_fd = undefined, .entries = .initFill(.empty), .arena = arena };
    var scanner = Json.init(alloc, json);
    var context = Context{
        .alloc = alloc,
        .tmp_alloc = alloc,
        .scanner = &scanner,
        .db = &db,
    };

    var item: vk.VkAttachmentDescription2 = undefined;
    try parse_vk_attachment_description2(&context, &item);

    try std.testing.expectEqual(null, item.pNext);
    try std.testing.expectEqual(69, @as(u32, @bitCast(item.flags)));
    try std.testing.expectEqual(69, @as(i32, @intFromEnum(item.format)));
    try std.testing.expectEqual(69, @as(u32, @bitCast(item.samples)));
    try std.testing.expectEqual(69, @as(i32, @intFromEnum(item.loadOp)));
    try std.testing.expectEqual(69, @as(i32, @intFromEnum(item.storeOp)));
    try std.testing.expectEqual(69, @as(i32, @intFromEnum(item.stencilLoadOp)));
    try std.testing.expectEqual(69, @as(i32, @intFromEnum(item.stencilStoreOp)));
    try std.testing.expectEqual(69, @as(i32, @intFromEnum(item.initialLayout)));
    try std.testing.expectEqual(69, @as(i32, @intFromEnum(item.finalLayout)));
}

pub fn parse_vk_subpass_description(
    context: *Context,
    item: *vk.VkSubpassDescription,
) Error!void {
    const prof_point = MEASUREMENTS.start(@src());
    defer MEASUREMENTS.end(prof_point);

    item.* = .{};
    while (try scanner_object_next_field(context.scanner)) |s| {
        if (std.mem.eql(u8, s, "flags")) {
            item.flags = try scanner_parse_bitfield(vk.VkSubpassDescriptionFlags, context.scanner);
        } else if (std.mem.eql(u8, s, "pipelineBindPoint")) {
            item.pipelineBindPoint = try scanner_parse_enum(vk.VkPipelineBindPoint, context.scanner);
        } else if (std.mem.eql(u8, s, "inputAttachments")) {
            const attachments = try parse_object_array(
                vk.VkAttachmentReference,
                parse_vk_attachment_reference,
                context,
            );
            item.pInputAttachments = @ptrCast(attachments.ptr);
            item.inputAttachmentCount = @intCast(attachments.len);
        } else if (std.mem.eql(u8, s, "colorAttachments")) {
            const attachments = try parse_object_array(
                vk.VkAttachmentReference,
                parse_vk_attachment_reference,
                context,
            );
            item.pColorAttachments = @ptrCast(attachments.ptr);
            item.colorAttachmentCount = @intCast(attachments.len);
        } else if (std.mem.eql(u8, s, "resolveAttachments")) {
            const attachments = try parse_object_array(
                vk.VkAttachmentReference,
                parse_vk_attachment_reference,
                context,
            );
            item.pResolveAttachments = @ptrCast(attachments.ptr);
        } else if (std.mem.eql(u8, s, "depthStencilAttachment")) {
            const attachment = try context.alloc.create(vk.VkAttachmentReference);
            try parse_vk_attachment_reference(context, attachment);
            item.pDepthStencilAttachment = attachment;
        } else if (std.mem.eql(u8, s, "preserveAttachments")) {
            const attachments = try parse_number_array(u32, context);
            item.pPreserveAttachments = @ptrCast(attachments.ptr);
            item.preserveAttachmentCount = @intCast(attachments.len);
        } else {
            const v = try scanner_next_number_or_string(context.scanner);
            log.warn(@src(), "Skipping unknown field {s}: {s}", .{ s, v });
        }
    }
}

test "test_parse_vk_subpass_description" {
    const json =
        \\{
        \\  "flags": 69,
        \\  "pipelineBindPoint": 69,
        \\  "inputAttachments": [{}],
        \\  "colorAttachments": [{}],
        \\  "resolveAttachments": [{}],
        \\  "depthStencilAttachment": {},
        \\  "preserveAttachments": [69, 69]
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const alloc = arena.allocator();

    const db: Database = .{ .file_fd = undefined, .entries = .initFill(.empty), .arena = arena };
    var scanner = Json.init(alloc, json);
    var context = Context{
        .alloc = alloc,
        .tmp_alloc = alloc,
        .scanner = &scanner,
        .db = &db,
    };

    var item: vk.VkSubpassDescription = undefined;
    try parse_vk_subpass_description(&context, &item);

    try std.testing.expectEqual(69, @as(u32, @bitCast(item.flags)));
    try std.testing.expectEqual(69, @as(i32, @intFromEnum(item.pipelineBindPoint)));
    try std.testing.expectEqual(1, item.inputAttachmentCount);
    try std.testing.expect(item.pInputAttachments != null);
    try std.testing.expectEqual(1, item.colorAttachmentCount);
    try std.testing.expect(item.pColorAttachments != null);
    try std.testing.expect(item.pResolveAttachments != null);
    try std.testing.expect(item.pDepthStencilAttachment != null);
    try std.testing.expectEqual(2, item.preserveAttachmentCount);
    try std.testing.expectEqual(69, item.pPreserveAttachments.?[0]);
    try std.testing.expectEqual(69, item.pPreserveAttachments.?[1]);
}

pub fn parse_vk_subpass_description2(
    context: *Context,
    item: *vk.VkSubpassDescription2,
) Error!void {
    const prof_point = MEASUREMENTS.start(@src());
    defer MEASUREMENTS.end(prof_point);

    item.* = .{};
    while (try scanner_object_next_field(context.scanner)) |s| {
        if (std.mem.eql(u8, s, "flags")) {
            item.flags = try scanner_parse_bitfield(vk.VkSubpassDescriptionFlags, context.scanner);
        } else if (std.mem.eql(u8, s, "pipelineBindPoint")) {
            item.pipelineBindPoint = try scanner_parse_enum(vk.VkPipelineBindPoint, context.scanner);
        } else if (std.mem.eql(u8, s, "viewMask")) {
            item.viewMask = try scanner_parse_number(u32, context.scanner);
        } else if (std.mem.eql(u8, s, "inputAttachments")) {
            const attachments = try parse_object_array(
                vk.VkAttachmentReference2,
                parse_vk_attachment_reference2,
                context,
            );
            item.pInputAttachments = @ptrCast(attachments.ptr);
            item.inputAttachmentCount = @intCast(attachments.len);
        } else if (std.mem.eql(u8, s, "colorAttachments")) {
            const attachments = try parse_object_array(
                vk.VkAttachmentReference2,
                parse_vk_attachment_reference2,
                context,
            );
            item.pColorAttachments = @ptrCast(attachments.ptr);
            item.colorAttachmentCount = @intCast(attachments.len);
        } else if (std.mem.eql(u8, s, "resolveAttachments")) {
            const attachments = try parse_object_array(
                vk.VkAttachmentReference2,
                parse_vk_attachment_reference2,
                context,
            );
            item.pResolveAttachments = @ptrCast(attachments.ptr);
        } else if (std.mem.eql(u8, s, "depthStencilAttachment")) {
            const attachment = try context.alloc.create(vk.VkAttachmentReference2);
            try parse_vk_attachment_reference2(context, attachment);
            item.pDepthStencilAttachment = attachment;
        } else if (std.mem.eql(u8, s, "preserveAttachments")) {
            const attachments = try parse_number_array(u32, context);
            item.pPreserveAttachments = @ptrCast(attachments.ptr);
            item.preserveAttachmentCount = @intCast(attachments.len);
        } else {
            const v = try scanner_next_number_or_string(context.scanner);
            log.warn(@src(), "Skipping unknown field {s}: {s}", .{ s, v });
        }
    }
}

test "test_parse_vk_subpass_description2" {
    const json =
        \\{
        \\  "flags": 69,
        \\  "pipelineBindPoint": 69,
        \\  "viewMask": 69,
        \\  "inputAttachments": [{}],
        \\  "colorAttachments": [{}],
        \\  "resolveAttachments": [{}],
        \\  "depthStencilAttachment": {},
        \\  "preserveAttachments": [69, 69]
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const alloc = arena.allocator();

    const db: Database = .{ .file_fd = undefined, .entries = .initFill(.empty), .arena = arena };
    var scanner = Json.init(alloc, json);
    var context = Context{
        .alloc = alloc,
        .tmp_alloc = alloc,
        .scanner = &scanner,
        .db = &db,
    };

    var item: vk.VkSubpassDescription2 = undefined;
    try parse_vk_subpass_description2(&context, &item);

    try std.testing.expectEqual(null, item.pNext);
    try std.testing.expectEqual(69, @as(u32, @bitCast(item.flags)));
    try std.testing.expectEqual(69, item.viewMask);
    try std.testing.expectEqual(69, @as(i32, @intFromEnum(item.pipelineBindPoint)));
    try std.testing.expectEqual(1, item.inputAttachmentCount);
    try std.testing.expect(item.pInputAttachments != null);
    try std.testing.expectEqual(1, item.colorAttachmentCount);
    try std.testing.expect(item.pColorAttachments != null);
    try std.testing.expect(item.pResolveAttachments != null);
    try std.testing.expect(item.pDepthStencilAttachment != null);
    try std.testing.expectEqual(2, item.preserveAttachmentCount);
    try std.testing.expectEqual(69, item.pPreserveAttachments.?[0]);
    try std.testing.expectEqual(69, item.pPreserveAttachments.?[1]);
}

pub fn parse_vk_attachment_reference(
    context: *Context,
    item: *vk.VkAttachmentReference,
) Error!void {
    const prof_point = MEASUREMENTS.start(@src());
    defer MEASUREMENTS.end(prof_point);

    item.* = .{};
    try parse_simple_type(context, item);
}

test "test_parse_vk_attachment_reference" {
    const json =
        \\{
        \\  "attachment": 69,
        \\  "layout": 69
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const alloc = arena.allocator();

    const db: Database = .{ .file_fd = undefined, .entries = .initFill(.empty), .arena = arena };
    var scanner = Json.init(alloc, json);
    var context = Context{
        .alloc = alloc,
        .tmp_alloc = alloc,
        .scanner = &scanner,
        .db = &db,
    };

    var item: vk.VkAttachmentReference = undefined;
    try parse_vk_attachment_reference(&context, &item);

    try std.testing.expectEqual(69, item.attachment);
    try std.testing.expectEqual(69, @as(i32, @intFromEnum(item.layout)));
}

pub fn parse_vk_attachment_reference2(
    context: *Context,
    item: *vk.VkAttachmentReference2,
) Error!void {
    const prof_point = MEASUREMENTS.start(@src());
    defer MEASUREMENTS.end(prof_point);

    item.* = .{};
    try parse_simple_type(context, item);
}

test "test_parse_vk_attachment_reference2" {
    const json =
        \\{
        \\  "attachment": 69,
        \\  "layout": 69,
        \\  "aspectMask": 69
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const alloc = arena.allocator();

    const db: Database = .{ .file_fd = undefined, .entries = .initFill(.empty), .arena = arena };
    var scanner = Json.init(alloc, json);
    var context = Context{
        .alloc = alloc,
        .tmp_alloc = alloc,
        .scanner = &scanner,
        .db = &db,
    };

    var item: vk.VkAttachmentReference2 = undefined;
    try parse_vk_attachment_reference2(&context, &item);

    try std.testing.expectEqual(69, item.attachment);
    try std.testing.expectEqual(69, @as(i32, @intFromEnum(item.layout)));
    try std.testing.expectEqual(69, @as(u32, @bitCast(item.aspectMask)));
}

pub fn parse_vk_graphics_pipeline_create_info(
    context: *Context,
    item: *vk.VkGraphicsPipelineCreateInfo,
) Error!void {
    const prof_point = MEASUREMENTS.start(@src());
    defer MEASUREMENTS.end(prof_point);

    item.* = .{};
    while (try scanner_object_next_field(context.scanner)) |s| {
        if (std.mem.eql(u8, s, "pNext")) {
            item.pNext = try parse_pnext_chain(context);
        } else if (std.mem.eql(u8, s, "flags")) {
            item.flags = try scanner_parse_bitfield(vk.VkPipelineCreateFlags, context.scanner);
        } else if (std.mem.eql(u8, s, "stages")) {
            const stages = try parse_object_array(
                vk.VkPipelineShaderStageCreateInfo,
                parse_vk_pipeline_shader_stage_create_info,
                context,
            );
            item.pStages = @ptrCast(stages.ptr);
            item.stageCount = @intCast(stages.len);
        } else if (std.mem.eql(u8, s, "vertexInputState")) {
            const vertex_input_state =
                try context.alloc.create(vk.VkPipelineVertexInputStateCreateInfo);
            try parse_vk_pipeline_vertex_input_state_create_info(context, vertex_input_state);
            item.pVertexInputState = vertex_input_state;
        } else if (std.mem.eql(u8, s, "inputAssemblyState")) {
            const input_assembly_state =
                try context.alloc.create(vk.VkPipelineInputAssemblyStateCreateInfo);
            try parse_vk_pipeline_input_assembly_state_create_info(
                context,
                input_assembly_state,
            );
            item.pInputAssemblyState = input_assembly_state;
        } else if (std.mem.eql(u8, s, "tessellationState")) {
            const tesselation_state =
                try context.alloc.create(vk.VkPipelineTessellationStateCreateInfo);
            try parse_vk_pipeline_tessellation_state_create_info(context, tesselation_state);
            item.pTessellationState = tesselation_state;
        } else if (std.mem.eql(u8, s, "viewportState")) {
            const viewport_state =
                try context.alloc.create(vk.VkPipelineViewportStateCreateInfo);
            try parse_vk_pipeline_viewport_state_create_info(context, viewport_state);
            item.pViewportState = viewport_state;
        } else if (std.mem.eql(u8, s, "rasterizationState")) {
            const raseterization_state =
                try context.alloc.create(vk.VkPipelineRasterizationStateCreateInfo);
            try parse_vk_pipeline_rasterization_state_create_info(context, raseterization_state);
            item.pRasterizationState = raseterization_state;
        } else if (std.mem.eql(u8, s, "multisampleState")) {
            const multisample_state =
                try context.alloc.create(vk.VkPipelineMultisampleStateCreateInfo);
            try parse_vk_pipeline_multisample_state_create_info(context, multisample_state);
            item.pMultisampleState = multisample_state;
        } else if (std.mem.eql(u8, s, "depthStencilState")) {
            const depth_stencil_state =
                try context.alloc.create(vk.VkPipelineDepthStencilStateCreateInfo);
            try parse_vk_pipeline_depth_stencil_state_create_info(context, depth_stencil_state);
            item.pDepthStencilState = depth_stencil_state;
        } else if (std.mem.eql(u8, s, "colorBlendState")) {
            const color_blend_state =
                try context.alloc.create(vk.VkPipelineColorBlendStateCreateInfo);
            try parse_vk_pipeline_color_blend_state_create_info(context, color_blend_state);
            item.pColorBlendState = color_blend_state;
        } else if (std.mem.eql(u8, s, "dynamicState")) {
            const dynamic_state = try context.alloc.create(vk.VkPipelineDynamicStateCreateInfo);
            try parse_vk_pipeline_dynamic_state_create_info(context, dynamic_state);
            item.pDynamicState = dynamic_state;
        } else if (std.mem.eql(u8, s, "layout")) {
            try parse_single_handle(context, .pipeline_layout, @ptrCast(&item.layout));
        } else if (std.mem.eql(u8, s, "renderPass")) {
            try parse_single_handle(context, .render_pass, @ptrCast(&item.renderPass));
        } else if (std.mem.eql(u8, s, "subpass")) {
            item.subpass = try scanner_parse_number(u32, context.scanner);
        } else if (std.mem.eql(u8, s, "basePipelineHandle")) {
            const v = try scanner_next_string(context.scanner);
            const base_pipeline_hash = try std.fmt.parseInt(u64, v, 16);
            if (base_pipeline_hash != 0)
                return error.BasePipelinesNotSupported;
        } else if (std.mem.eql(u8, s, "basePipelineIndex")) {
            item.basePipelineIndex = try scanner_parse_number(i32, context.scanner);
        } else {
            const v = try scanner_next_number_or_string(context.scanner);
            log.warn(@src(), "Skipping unknown field {s}: {s}", .{ s, v });
        }
    }
}

test "test_parse_vk_graphics_pipeline_create_info" {
    const json =
        \\{
        \\  "flags": 69,
        \\  "stages": [{}],
        \\  "vertexInputState": {},
        \\  "inputAssemblyState": {},
        \\  "tessellationState": {},
        \\  "viewportState": {},
        \\  "rasterizationState": {},
        \\  "multisampleState": {},
        \\  "depthStencilState": {},
        \\  "colorBlendState": {},
        \\  "dynamicState": {},
        \\  "layout": "1111111111111111",
        \\  "renderPass": "2222222222222222",
        \\  "subpass": 69,
        \\  "basePipelineHandle": "0000000000000000",
        \\  "basePipelineIndex": 69
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const alloc = arena.allocator();

    var db: Database = .{ .file_fd = undefined, .entries = .initFill(.empty), .arena = arena };
    try db.entries.getPtr(.pipeline_layout).put(alloc, 0x1111111111111111, .{
        .tag = undefined,
        .hash = undefined,
        .payload_flag = undefined,
        .payload_crc = undefined,
        .payload_stored_size = undefined,
        .payload_decompressed_size = undefined,
        .payload_file_offset = undefined,
        .handle = 0x69,
    });
    try db.entries.getPtr(.render_pass).put(alloc, 0x2222222222222222, .{
        .tag = undefined,
        .hash = undefined,
        .payload_flag = undefined,
        .payload_crc = undefined,
        .payload_stored_size = undefined,
        .payload_decompressed_size = undefined,
        .payload_file_offset = undefined,
        .handle = 0x69,
    });
    var scanner = Json.init(alloc, json);
    var context = Context{
        .alloc = alloc,
        .tmp_alloc = alloc,
        .scanner = &scanner,
        .db = &db,
    };

    var item: vk.VkGraphicsPipelineCreateInfo = undefined;
    try parse_vk_graphics_pipeline_create_info(&context, &item);

    try std.testing.expectEqual(null, item.pNext);
    try std.testing.expectEqual(69, @as(u32, @bitCast(item.flags)));
    try std.testing.expectEqual(1, item.stageCount);
    try std.testing.expect(item.pStages != null);
    try std.testing.expect(item.pVertexInputState != null);
    try std.testing.expect(item.pInputAssemblyState != null);
    try std.testing.expect(item.pTessellationState != null);
    try std.testing.expect(item.pViewportState != null);
    try std.testing.expect(item.pRasterizationState != null);
    try std.testing.expect(item.pMultisampleState != null);
    try std.testing.expect(item.pDepthStencilState != null);
    try std.testing.expect(item.pColorBlendState != null);
    try std.testing.expect(item.pDynamicState != null);
    try std.testing.expectEqual(69, item.subpass);
    try std.testing.expectEqual(.none, item.basePipelineHandle);
    try std.testing.expectEqual(69, item.basePipelineIndex);

    try std.testing.expectEqual(0, @intFromEnum(item.layout));
    try std.testing.expectEqual(0, @intFromEnum(item.renderPass));
    try std.testing.expectEqual(2, context.dependencies.items.len);
    try std.testing.expectEqual(.pipeline_layout, context.dependencies.items[0].tag);
    try std.testing.expectEqual(0x1111111111111111, context.dependencies.items[0].hash);
    context.dependencies.items[0].ptr_to_handle.?.* = 0x69;
    try std.testing.expectEqual(0x69, @intFromEnum(item.layout));
    try std.testing.expectEqual(.render_pass, context.dependencies.items[1].tag);
    try std.testing.expectEqual(0x2222222222222222, context.dependencies.items[1].hash);
    context.dependencies.items[1].ptr_to_handle.?.* = 0x69;
    try std.testing.expectEqual(0x69, @intFromEnum(item.renderPass));
}

pub fn parse_vk_pipeline_shader_stage_create_info(
    context: *Context,
    item: *vk.VkPipelineShaderStageCreateInfo,
) Error!void {
    const prof_point = MEASUREMENTS.start(@src());
    defer MEASUREMENTS.end(prof_point);

    item.* = .{};
    while (try scanner_object_next_field(context.scanner)) |s| {
        if (std.mem.eql(u8, s, "pNext")) {
            item.pNext = try parse_pnext_chain(context);
        } else if (std.mem.eql(u8, s, "flags")) {
            item.flags = try scanner_parse_bitfield(vk.VkPipelineShaderStageCreateFlags, context.scanner);
        } else if (std.mem.eql(u8, s, "stage")) {
            item.stage = try scanner_parse_bitfield(vk.VkShaderStageFlags, context.scanner);
        } else if (std.mem.eql(u8, s, "module")) {
            try parse_single_handle(context, .shader_module, @ptrCast(&item.module));
        } else if (std.mem.eql(u8, s, "name")) {
            const name_str = try scanner_next_string(context.scanner);
            const name = try context.alloc.dupeZ(u8, name_str);
            item.pName = @ptrCast(name.ptr);
        } else if (std.mem.eql(u8, s, "specializationInfo")) {
            const info = try context.alloc.create(vk.VkSpecializationInfo);
            try parse_vk_specialization_info(context, info);
            item.pSpecializationInfo = info;
        } else {
            const v = try scanner_next_number_or_string(context.scanner);
            log.warn(@src(), "Skipping unknown field {s}: {s}", .{ s, v });
        }
    }
}

test "test_parse_vk_pipeline_shader_stage_create_info" {
    const json =
        \\{
        \\   "flags": 69,
        \\   "stage": 69,
        \\   "module": "1111111111111111",
        \\   "name": "NAME",
        \\   "specializationInfo": {}
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const alloc = arena.allocator();

    var db: Database = .{ .file_fd = undefined, .entries = .initFill(.empty), .arena = arena };
    try db.entries.getPtr(.shader_module).put(alloc, 0x1111111111111111, .{
        .tag = undefined,
        .hash = undefined,
        .payload_flag = undefined,
        .payload_crc = undefined,
        .payload_stored_size = undefined,
        .payload_decompressed_size = undefined,
        .payload_file_offset = undefined,
        .handle = undefined,
    });
    var scanner = Json.init(alloc, json);
    var context = Context{
        .alloc = alloc,
        .tmp_alloc = alloc,
        .scanner = &scanner,
        .db = &db,
    };

    var item: vk.VkPipelineShaderStageCreateInfo = undefined;
    try parse_vk_pipeline_shader_stage_create_info(&context, &item);

    try std.testing.expectEqual(null, item.pNext);
    try std.testing.expectEqual(69, @as(u32, @bitCast(item.flags)));
    try std.testing.expectEqual(69, @as(u32, @bitCast(item.stage)));
    try std.testing.expectEqualSlices(u8, "NAME", std.mem.span(item.pName.?));
    try std.testing.expect(item.pSpecializationInfo != null);

    try std.testing.expectEqual(0, @intFromEnum(item.module));
    try std.testing.expectEqual(1, context.dependencies.items.len);
    try std.testing.expectEqual(.shader_module, context.dependencies.items[0].tag);
    try std.testing.expectEqual(0x1111111111111111, context.dependencies.items[0].hash);
    context.dependencies.items[0].ptr_to_handle.?.* = 0x69;
    try std.testing.expectEqual(0x69, @intFromEnum(item.module));
}

pub fn parse_vk_pipeline_vertex_input_state_create_info(
    context: *Context,
    item: *vk.VkPipelineVertexInputStateCreateInfo,
) Error!void {
    const prof_point = MEASUREMENTS.start(@src());
    defer MEASUREMENTS.end(prof_point);

    item.* = .{};
    while (try scanner_object_next_field(context.scanner)) |s| {
        if (std.mem.eql(u8, s, "pNext")) {
            item.pNext = try parse_pnext_chain(context);
        } else if (std.mem.eql(u8, s, "flags")) {
            item.flags = try scanner_parse_bitfield(vk.VkPipelineVertexInputStateCreateFlags, context.scanner);
        } else if (std.mem.eql(u8, s, "bindings")) {
            const bindings = try parse_object_array(
                vk.VkVertexInputBindingDescription,
                parse_vk_vertex_input_binding_description,
                context,
            );
            item.pVertexBindingDescriptions = @ptrCast(bindings.ptr);
            item.vertexBindingDescriptionCount = @intCast(bindings.len);
        } else if (std.mem.eql(u8, s, "attributes")) {
            const attributes = try parse_object_array(
                vk.VkVertexInputAttributeDescription,
                parse_vk_vertex_input_attribute_description,
                context,
            );
            item.pVertexAttributeDescriptions = @ptrCast(attributes.ptr);
            item.vertexAttributeDescriptionCount = @intCast(attributes.len);
        } else {
            const v = try scanner_next_number_or_string(context.scanner);
            log.warn(@src(), "Skipping unknown field {s}: {s}", .{ s, v });
        }
    }
}

test "test_parse_vk_pipeline_vertex_input_state_create_info" {
    const json =
        \\{
        \\  "flags": 69,
        \\  "attributes": [{}],
        \\  "bindings": [{}]
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const alloc = arena.allocator();

    const db: Database = .{ .file_fd = undefined, .entries = .initFill(.empty), .arena = arena };
    var scanner = Json.init(alloc, json);
    var context = Context{
        .alloc = alloc,
        .tmp_alloc = alloc,
        .scanner = &scanner,
        .db = &db,
    };

    var item: vk.VkPipelineVertexInputStateCreateInfo = undefined;
    try parse_vk_pipeline_vertex_input_state_create_info(&context, &item);

    try std.testing.expectEqual(null, item.pNext);
    try std.testing.expectEqual(69, @as(u32, @bitCast(item.flags)));
    try std.testing.expectEqual(1, item.vertexBindingDescriptionCount);
    try std.testing.expect(item.pVertexBindingDescriptions != null);
    try std.testing.expectEqual(1, item.vertexAttributeDescriptionCount);
    try std.testing.expect(item.pVertexAttributeDescriptions != null);
}

pub fn parse_vk_pipeline_input_assembly_state_create_info(
    context: *Context,
    item: *vk.VkPipelineInputAssemblyStateCreateInfo,
) Error!void {
    const prof_point = MEASUREMENTS.start(@src());
    defer MEASUREMENTS.end(prof_point);

    item.* = .{};
    try parse_simple_type(context, item);
}

test "test_parse_vk_pipeline_input_assembly_state_create_info" {
    const json =
        \\{
        \\  "flags": 69,
        \\  "topology": 69,
        \\  "primitiveRestartEnable": 69
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const alloc = arena.allocator();

    const db: Database = .{ .file_fd = undefined, .entries = .initFill(.empty), .arena = arena };
    var scanner = Json.init(alloc, json);
    var context = Context{
        .alloc = alloc,
        .tmp_alloc = alloc,
        .scanner = &scanner,
        .db = &db,
    };

    var item: vk.VkPipelineInputAssemblyStateCreateInfo = undefined;
    try parse_vk_pipeline_input_assembly_state_create_info(&context, &item);

    try std.testing.expectEqual(null, item.pNext);
    try std.testing.expectEqual(69, @as(u32, @bitCast(item.flags)));
    try std.testing.expectEqual(69, @as(i32, @intFromEnum(item.topology)));
    try std.testing.expectEqual(69, item.primitiveRestartEnable);
}

pub fn parse_vk_pipeline_tessellation_state_create_info(
    context: *Context,
    item: *vk.VkPipelineTessellationStateCreateInfo,
) Error!void {
    const prof_point = MEASUREMENTS.start(@src());
    defer MEASUREMENTS.end(prof_point);

    item.* = .{};
    try parse_simple_type(context, item);
}

test "test_parse_vk_pipeline_tessellation_state_create_info" {
    const json =
        \\{
        \\  "flags": 69,
        \\  "patchControlPoints": 69
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const alloc = arena.allocator();

    const db: Database = .{ .file_fd = undefined, .entries = .initFill(.empty), .arena = arena };
    var scanner = Json.init(alloc, json);
    var context = Context{
        .alloc = alloc,
        .tmp_alloc = alloc,
        .scanner = &scanner,
        .db = &db,
    };

    var item: vk.VkPipelineTessellationStateCreateInfo = undefined;
    try parse_vk_pipeline_tessellation_state_create_info(&context, &item);

    try std.testing.expectEqual(null, item.pNext);
    try std.testing.expectEqual(69, @as(u32, @bitCast(item.flags)));
    try std.testing.expectEqual(69, item.patchControlPoints);
}

pub fn parse_vk_pipeline_viewport_state_create_info(
    context: *Context,
    item: *vk.VkPipelineViewportStateCreateInfo,
) Error!void {
    const prof_point = MEASUREMENTS.start(@src());
    defer MEASUREMENTS.end(prof_point);

    item.* = .{};
    while (try scanner_object_next_field(context.scanner)) |s| {
        if (std.mem.eql(u8, s, "pNext")) {
            item.pNext = try parse_pnext_chain(context);
        } else if (std.mem.eql(u8, s, "flags")) {
            item.flags = try scanner_parse_bitfield(vk.VkPipelineViewportStateCreateFlags, context.scanner);
        } else if (std.mem.eql(u8, s, "viewportCount")) {
            item.viewportCount = try scanner_parse_number(u32, context.scanner);
        } else if (std.mem.eql(u8, s, "viewports")) {
            const viewports = try parse_object_array(
                vk.VkViewport,
                parse_vk_viewport,
                context,
            );
            item.pViewports = @ptrCast(viewports.ptr);
            item.viewportCount = @intCast(viewports.len);
        } else if (std.mem.eql(u8, s, "scissorCount")) {
            item.scissorCount = try scanner_parse_number(u32, context.scanner);
        } else if (std.mem.eql(u8, s, "scissors")) {
            const scissors = try parse_object_array(
                vk.VkRect2D,
                parse_vk_rect_2d,
                context,
            );
            item.pScissors = @ptrCast(scissors.ptr);
            item.scissorCount = @intCast(scissors.len);
        } else {
            const v = try scanner_next_number_or_string(context.scanner);
            log.warn(@src(), "Skipping unknown field {s}: {s}", .{ s, v });
        }
    }
}

test "test_parse_vk_pipeline_viewport_state_create_info" {
    const json =
        \\{
        \\  "flags": 69,
        \\  "viewportCount": 1,
        \\  "scissorCount": 1,
        \\  "viewports": [{}],
        \\  "scissors": [{}]
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const alloc = arena.allocator();

    const db: Database = .{ .file_fd = undefined, .entries = .initFill(.empty), .arena = arena };
    var scanner = Json.init(alloc, json);
    var context = Context{
        .alloc = alloc,
        .tmp_alloc = alloc,
        .scanner = &scanner,
        .db = &db,
    };

    var item: vk.VkPipelineViewportStateCreateInfo = undefined;
    try parse_vk_pipeline_viewport_state_create_info(&context, &item);

    try std.testing.expectEqual(null, item.pNext);
    try std.testing.expectEqual(69, @as(u32, @bitCast(item.flags)));
    try std.testing.expectEqual(1, item.viewportCount);
    try std.testing.expect(item.pViewports != null);
    try std.testing.expectEqual(1, item.scissorCount);
    try std.testing.expect(item.pScissors != null);
}

pub fn parse_vk_pipeline_rasterization_state_create_info(
    context: *Context,
    item: *vk.VkPipelineRasterizationStateCreateInfo,
) Error!void {
    const prof_point = MEASUREMENTS.start(@src());
    defer MEASUREMENTS.end(prof_point);

    item.* = .{};
    try parse_simple_type(context, item);
}

test "test_parse_vk_pipeline_rasterization_state_create_info" {
    const json =
        \\{
        \\  "flags": 69,
        \\  "depthClampEnable": 69,
        \\  "rasterizerDiscardEnable": 69,
        \\  "polygonMode": 69,
        \\  "cullMode": 69,
        \\  "frontFace": 69,
        \\  "depthBiasEnable": 69,
        \\  "depthBiasConstantFactor": 69,
        \\  "depthBiasClamp": 69,
        \\  "depthBiasSlopeFactor": 69,
        \\  "lineWidth": 69
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const alloc = arena.allocator();

    const db: Database = .{ .file_fd = undefined, .entries = .initFill(.empty), .arena = arena };
    var scanner = Json.init(alloc, json);
    var context = Context{
        .alloc = alloc,
        .tmp_alloc = alloc,
        .scanner = &scanner,
        .db = &db,
    };

    var item: vk.VkPipelineRasterizationStateCreateInfo = undefined;
    try parse_vk_pipeline_rasterization_state_create_info(&context, &item);

    try std.testing.expectEqual(null, item.pNext);
    try std.testing.expectEqual(69, @as(u32, @bitCast(item.flags)));
    try std.testing.expectEqual(69, item.depthClampEnable);
    try std.testing.expectEqual(69, item.rasterizerDiscardEnable);
    try std.testing.expectEqual(69, @as(i32, @intFromEnum(item.polygonMode)));
    try std.testing.expectEqual(69, @as(u32, @bitCast(item.cullMode)));
    try std.testing.expectEqual(69, @as(i32, @intFromEnum(item.frontFace)));
    try std.testing.expectEqual(69, item.depthBiasEnable);
    try std.testing.expectEqual(69, item.depthBiasConstantFactor);
    try std.testing.expectEqual(69, item.depthBiasClamp);
    try std.testing.expectEqual(69, item.depthBiasSlopeFactor);
    try std.testing.expectEqual(69, item.lineWidth);
}

pub fn parse_vk_pipeline_multisample_state_create_info(
    context: *Context,
    item: *vk.VkPipelineMultisampleStateCreateInfo,
) Error!void {
    const prof_point = MEASUREMENTS.start(@src());
    defer MEASUREMENTS.end(prof_point);

    item.* = .{};
    while (try scanner_object_next_field(context.scanner)) |s| {
        if (std.mem.eql(u8, s, "pNext")) {
            item.pNext = try parse_pnext_chain(context);
        } else if (std.mem.eql(u8, s, "flags")) {
            item.flags = try scanner_parse_bitfield(vk.VkPipelineMultisampleStateCreateFlags, context.scanner);
        } else if (std.mem.eql(u8, s, "rasterizationSamples")) {
            item.rasterizationSamples = try scanner_parse_bitfield(vk.VkSampleCountFlags, context.scanner);
        } else if (std.mem.eql(u8, s, "sampleShadingEnable")) {
            item.sampleShadingEnable = try scanner_parse_number(u32, context.scanner);
        } else if (std.mem.eql(u8, s, "minSampleShading")) {
            item.minSampleShading = try scanner_parse_number(f32, context.scanner);
        } else if (std.mem.eql(u8, s, "sampleMask")) {
            const mask = try parse_number_array(u32, context);
            item.pSampleMask = @ptrCast(mask.ptr);
        } else if (std.mem.eql(u8, s, "alphaToCoverageEnable")) {
            item.alphaToCoverageEnable = try scanner_parse_number(u32, context.scanner);
        } else if (std.mem.eql(u8, s, "alphaToOneEnable")) {
            item.alphaToOneEnable = try scanner_parse_number(u32, context.scanner);
        } else {
            const v = try scanner_next_number_or_string(context.scanner);
            log.warn(@src(), "Skipping unknown field {s}: {s}", .{ s, v });
        }
    }
}

test "test_parse_vk_pipeline_multisample_state_create_info" {
    const json =
        \\{
        \\  "flags": 69,
        \\  "rasterizationSamples": 69,
        \\  "sampleShadingEnable": 69,
        \\  "minSampleShading": 69,
        \\  "sampleMask": [
        \\    69
        \\  ],
        \\  "alphaToCoverageEnable": 69,
        \\  "alphaToOneEnable": 69
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const alloc = arena.allocator();

    const db: Database = .{ .file_fd = undefined, .entries = .initFill(.empty), .arena = arena };
    var scanner = Json.init(alloc, json);
    var context = Context{
        .alloc = alloc,
        .tmp_alloc = alloc,
        .scanner = &scanner,
        .db = &db,
    };

    var item: vk.VkPipelineMultisampleStateCreateInfo = undefined;
    try parse_vk_pipeline_multisample_state_create_info(&context, &item);

    try std.testing.expectEqual(null, item.pNext);
    try std.testing.expectEqual(69, @as(u32, @bitCast(item.flags)));
    try std.testing.expectEqual(69, @as(u32, @bitCast(item.rasterizationSamples)));
    try std.testing.expectEqual(69, item.sampleShadingEnable);
    try std.testing.expectEqual(69, item.minSampleShading);
    try std.testing.expect(item.pSampleMask != null);
    try std.testing.expectEqual(69, item.alphaToCoverageEnable);
    try std.testing.expectEqual(69, item.alphaToOneEnable);
}

pub fn parse_vk_stencil_op_state(
    context: *Context,
    item: *vk.VkStencilOpState,
) Error!void {
    const prof_point = MEASUREMENTS.start(@src());
    defer MEASUREMENTS.end(prof_point);

    item.* = .{};
    try parse_simple_type(context, item);
}

test "test_parse_vk_stencil_op_state" {
    const json =
        \\{
        \\  "failOp": 69,
        \\  "passOp": 69,
        \\  "depthFailOp": 69,
        \\  "compareOp": 69,
        \\  "compareMask": 69,
        \\  "writeMask": 69,
        \\  "reference": 69
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const alloc = arena.allocator();

    const db: Database = .{ .file_fd = undefined, .entries = .initFill(.empty), .arena = arena };
    var scanner = Json.init(alloc, json);
    var context = Context{
        .alloc = alloc,
        .tmp_alloc = alloc,
        .scanner = &scanner,
        .db = &db,
    };

    var item: vk.VkStencilOpState = undefined;
    try parse_vk_stencil_op_state(&context, &item);

    try std.testing.expectEqual(69, @as(i32, @intFromEnum(item.failOp)));
    try std.testing.expectEqual(69, @as(i32, @intFromEnum(item.passOp)));
    try std.testing.expectEqual(69, @as(i32, @intFromEnum(item.depthFailOp)));
    try std.testing.expectEqual(69, @as(i32, @intFromEnum(item.compareOp)));
    try std.testing.expectEqual(69, item.compareMask);
    try std.testing.expectEqual(69, item.writeMask);
    try std.testing.expectEqual(69, item.reference);
}

pub fn parse_vk_pipeline_depth_stencil_state_create_info(
    context: *Context,
    item: *vk.VkPipelineDepthStencilStateCreateInfo,
) Error!void {
    const prof_point = MEASUREMENTS.start(@src());
    defer MEASUREMENTS.end(prof_point);

    item.* = .{};
    while (try scanner_object_next_field(context.scanner)) |s| {
        if (std.mem.eql(u8, s, "pNext")) {
            item.pNext = try parse_pnext_chain(context);
        } else if (std.mem.eql(u8, s, "flags")) {
            item.flags = try scanner_parse_bitfield(vk.VkPipelineDepthStencilStateCreateFlags, context.scanner);
        } else if (std.mem.eql(u8, s, "depthTestEnable")) {
            item.depthTestEnable = try scanner_parse_number(u32, context.scanner);
        } else if (std.mem.eql(u8, s, "depthWriteEnable")) {
            item.depthWriteEnable = try scanner_parse_number(u32, context.scanner);
        } else if (std.mem.eql(u8, s, "depthCompareOp")) {
            item.depthCompareOp = try scanner_parse_enum(vk.VkCompareOp, context.scanner);
        } else if (std.mem.eql(u8, s, "depthBoundsTestEnable")) {
            item.depthBoundsTestEnable = try scanner_parse_number(u32, context.scanner);
        } else if (std.mem.eql(u8, s, "stencilTestEnable")) {
            item.stencilTestEnable = try scanner_parse_number(u32, context.scanner);
        } else if (std.mem.eql(u8, s, "front")) {
            try parse_vk_stencil_op_state(context, &item.front);
        } else if (std.mem.eql(u8, s, "back")) {
            try parse_vk_stencil_op_state(context, &item.back);
        } else if (std.mem.eql(u8, s, "minDepthBounds")) {
            item.minDepthBounds = try scanner_parse_number(f32, context.scanner);
        } else if (std.mem.eql(u8, s, "maxDepthBounds")) {
            item.maxDepthBounds = try scanner_parse_number(f32, context.scanner);
        } else {
            const v = try scanner_next_number_or_string(context.scanner);
            log.warn(@src(), "Skipping unknown field {s}: {s}", .{ s, v });
        }
    }
}

test "test_parse_vk_pipeline_depth_stencil_state_create_info" {
    const json =
        \\{
        \\  "flags": 69,
        \\  "depthTestEnable": 69,
        \\  "depthWriteEnable": 69,
        \\  "depthCompareOp": 69,
        \\  "depthBoundsTestEnable": 69,
        \\  "stencilTestEnable": 69,
        \\  "front": {},
        \\  "back": {},
        \\  "minDepthBounds": 69,
        \\  "maxDepthBounds": 69
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const alloc = arena.allocator();

    const db: Database = .{ .file_fd = undefined, .entries = .initFill(.empty), .arena = arena };
    var scanner = Json.init(alloc, json);
    var context = Context{
        .alloc = alloc,
        .tmp_alloc = alloc,
        .scanner = &scanner,
        .db = &db,
    };

    var item: vk.VkPipelineDepthStencilStateCreateInfo = undefined;
    try parse_vk_pipeline_depth_stencil_state_create_info(&context, &item);

    try std.testing.expectEqual(null, item.pNext);
    try std.testing.expectEqual(69, @as(u32, @bitCast(item.flags)));
    try std.testing.expectEqual(69, item.depthTestEnable);
    try std.testing.expectEqual(69, item.depthWriteEnable);
    try std.testing.expectEqual(69, @as(i32, @intFromEnum(item.depthCompareOp)));
    try std.testing.expectEqual(69, item.depthBoundsTestEnable);
    try std.testing.expectEqual(69, item.stencilTestEnable);
    try std.testing.expectEqual(vk.VkStencilOpState{}, item.front);
    try std.testing.expectEqual(vk.VkStencilOpState{}, item.back);
    try std.testing.expectEqual(69, item.minDepthBounds);
    try std.testing.expectEqual(69, item.maxDepthBounds);
}

pub fn parse_vk_pipeline_color_blend_state_create_info(
    context: *Context,
    item: *vk.VkPipelineColorBlendStateCreateInfo,
) Error!void {
    const prof_point = MEASUREMENTS.start(@src());
    defer MEASUREMENTS.end(prof_point);

    item.* = .{};
    while (try scanner_object_next_field(context.scanner)) |s| {
        if (std.mem.eql(u8, s, "pNext")) {
            item.pNext = try parse_pnext_chain(context);
        } else if (std.mem.eql(u8, s, "flags")) {
            item.flags = try scanner_parse_bitfield(vk.VkPipelineColorBlendStateCreateFlags, context.scanner);
        } else if (std.mem.eql(u8, s, "logicOpEnable")) {
            item.logicOpEnable = try scanner_parse_number(u32, context.scanner);
        } else if (std.mem.eql(u8, s, "logicOp")) {
            item.logicOp = try scanner_parse_enum(vk.VkLogicOp, context.scanner);
        } else if (std.mem.eql(u8, s, "attachments")) {
            const attachments = try parse_object_array(
                vk.VkPipelineColorBlendAttachmentState,
                parse_vk_pipeline_color_blend_attachment_state,
                context,
            );
            item.pAttachments = @ptrCast(attachments.ptr);
            item.attachmentCount = @intCast(attachments.len);
        } else if (std.mem.eql(u8, s, "blendConstants")) {
            try scanner_array_begin(context.scanner);
            var i: u32 = 0;
            while (try scanner_array_next_number(context.scanner)) |v| {
                item.blendConstants[i] = try std.fmt.parseFloat(f32, v);
                i += 1;
            }
        } else {
            const v = try scanner_next_number_or_string(context.scanner);
            log.warn(@src(), "Skipping unknown field {s}: {s}", .{ s, v });
        }
    }
}

test "test_parse_vk_pipeline_color_blend_state_create_info" {
    const json =
        \\{
        \\  "flags": 69,
        \\  "logicOpEnable": 69,
        \\  "logicOp": 69,
        \\  "attachments": [{}],
        \\  "blendConstants": [
        \\    69.69,
        \\    69.69,
        \\    69.69,
        \\    69.69
        \\  ]
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const alloc = arena.allocator();

    const db: Database = .{ .file_fd = undefined, .entries = .initFill(.empty), .arena = arena };
    var scanner = Json.init(alloc, json);
    var context = Context{
        .alloc = alloc,
        .tmp_alloc = alloc,
        .scanner = &scanner,
        .db = &db,
    };

    var item: vk.VkPipelineColorBlendStateCreateInfo = undefined;
    try parse_vk_pipeline_color_blend_state_create_info(&context, &item);

    try std.testing.expectEqual(null, item.pNext);
    try std.testing.expectEqual(69, @as(u32, @bitCast(item.flags)));
    try std.testing.expectEqual(69, item.logicOpEnable);
    try std.testing.expectEqual(69, @as(i32, @intFromEnum(item.logicOp)));
    try std.testing.expectEqual(1, item.attachmentCount);
    try std.testing.expect(item.pAttachments != null);
    try std.testing.expectEqual([4]f32{ 69.69, 69.69, 69.69, 69.69 }, item.blendConstants);
}

pub fn parse_vk_pipeline_dynamic_state_create_info(
    context: *Context,
    item: *vk.VkPipelineDynamicStateCreateInfo,
) Error!void {
    const prof_point = MEASUREMENTS.start(@src());
    defer MEASUREMENTS.end(prof_point);

    item.* = .{};
    while (try scanner_object_next_field(context.scanner)) |s| {
        if (std.mem.eql(u8, s, "pNext")) {
            item.pNext = try parse_pnext_chain(context);
        } else if (std.mem.eql(u8, s, "flags")) {
            item.flags = try scanner_parse_bitfield(vk.VkPipelineDynamicStateCreateFlags, context.scanner);
        } else if (std.mem.eql(u8, s, "dynamicState")) {
            const states = try parse_number_array(u32, context);
            item.pDynamicStates = @ptrCast(states.ptr);
            item.dynamicStateCount = @intCast(states.len);
        } else {
            const v = try scanner_next_number_or_string(context.scanner);
            log.warn(@src(), "Skipping unknown field {s}: {s}", .{ s, v });
        }
    }
}

test "test_parse_vk_pipeline_dynamic_state_create_info" {
    const json =
        \\{
        \\  "flags": 69,
        \\  "dynamicState": [
        \\    69
        \\  ]
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const alloc = arena.allocator();

    const db: Database = .{ .file_fd = undefined, .entries = .initFill(.empty), .arena = arena };
    var scanner = Json.init(alloc, json);
    var context = Context{
        .alloc = alloc,
        .tmp_alloc = alloc,
        .scanner = &scanner,
        .db = &db,
    };

    var item: vk.VkPipelineDynamicStateCreateInfo = undefined;
    try parse_vk_pipeline_dynamic_state_create_info(&context, &item);

    try std.testing.expectEqual(null, item.pNext);
    try std.testing.expectEqual(69, @as(u32, @bitCast(item.flags)));
    try std.testing.expectEqual(1, item.dynamicStateCount);
    try std.testing.expect(item.pDynamicStates != null);
}

pub fn parse_vk_vertex_input_attribute_description(
    context: *Context,
    item: *vk.VkVertexInputAttributeDescription,
) Error!void {
    const prof_point = MEASUREMENTS.start(@src());
    defer MEASUREMENTS.end(prof_point);

    item.* = .{};
    try parse_simple_type(context, item);
}

test "test_parse_vk_vertex_input_attribute_description" {
    const json =
        \\{
        \\  "location": 69,
        \\  "binding": 69,
        \\  "format": 69,
        \\  "offset": 69
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const alloc = arena.allocator();

    const db: Database = .{ .file_fd = undefined, .entries = .initFill(.empty), .arena = arena };
    var scanner = Json.init(alloc, json);
    var context = Context{
        .alloc = alloc,
        .tmp_alloc = alloc,
        .scanner = &scanner,
        .db = &db,
    };

    var item: vk.VkVertexInputAttributeDescription = undefined;
    try parse_vk_vertex_input_attribute_description(&context, &item);

    try std.testing.expectEqual(69, item.location);
    try std.testing.expectEqual(69, item.binding);
    try std.testing.expectEqual(69, @as(i32, @intFromEnum(item.format)));
    try std.testing.expectEqual(69, item.offset);
}

pub fn parse_vk_vertex_input_binding_description(
    context: *Context,
    item: *vk.VkVertexInputBindingDescription,
) Error!void {
    const prof_point = MEASUREMENTS.start(@src());
    defer MEASUREMENTS.end(prof_point);

    item.* = .{};
    try parse_simple_type(context, item);
}

test "test_parse_vk_vertex_input_binding_description" {
    const json =
        \\{
        \\  "binding": 69,
        \\  "stride": 69,
        \\  "inputRate": 69
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const alloc = arena.allocator();

    const db: Database = .{ .file_fd = undefined, .entries = .initFill(.empty), .arena = arena };
    var scanner = Json.init(alloc, json);
    var context = Context{
        .alloc = alloc,
        .tmp_alloc = alloc,
        .scanner = &scanner,
        .db = &db,
    };

    var item: vk.VkVertexInputBindingDescription = undefined;
    try parse_vk_vertex_input_binding_description(&context, &item);

    try std.testing.expectEqual(69, item.binding);
    try std.testing.expectEqual(69, item.stride);
    try std.testing.expectEqual(69, @as(i32, @intFromEnum(item.inputRate)));
}

pub fn parse_vk_pipeline_color_blend_attachment_state(
    context: *Context,
    item: *vk.VkPipelineColorBlendAttachmentState,
) Error!void {
    const prof_point = MEASUREMENTS.start(@src());
    defer MEASUREMENTS.end(prof_point);

    item.* = .{};
    try parse_simple_type(context, item);
}

test "test_parse_vk_pipeline_color_blend_attachment_state" {
    const json =
        \\{
        \\  "blendEnable": 69,
        \\  "srcColorBlendFactor": 69,
        \\  "dstColorBlendFactor": 69,
        \\  "colorBlendOp": 69,
        \\  "srcAlphaBlendFactor": 69,
        \\  "dstAlphaBlendFactor": 69,
        \\  "alphaBlendOp": 69,
        \\  "colorWriteMask": 69
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const alloc = arena.allocator();

    const db: Database = .{ .file_fd = undefined, .entries = .initFill(.empty), .arena = arena };
    var scanner = Json.init(alloc, json);
    var context = Context{
        .alloc = alloc,
        .tmp_alloc = alloc,
        .scanner = &scanner,
        .db = &db,
    };

    var item: vk.VkPipelineColorBlendAttachmentState = undefined;
    try parse_vk_pipeline_color_blend_attachment_state(&context, &item);

    try std.testing.expectEqual(69, item.blendEnable);
    try std.testing.expectEqual(69, @as(i32, @intFromEnum(item.srcColorBlendFactor)));
    try std.testing.expectEqual(69, @as(i32, @intFromEnum(item.dstColorBlendFactor)));
    try std.testing.expectEqual(69, @as(i32, @intFromEnum(item.colorBlendOp)));
    try std.testing.expectEqual(69, @as(i32, @intFromEnum(item.srcAlphaBlendFactor)));
    try std.testing.expectEqual(69, @as(i32, @intFromEnum(item.dstAlphaBlendFactor)));
    try std.testing.expectEqual(69, @as(i32, @intFromEnum(item.alphaBlendOp)));
    try std.testing.expectEqual(69, @as(u32, @bitCast(item.colorWriteMask)));
}

pub fn parse_vk_viewport(
    context: *Context,
    item: *vk.VkViewport,
) Error!void {
    const prof_point = MEASUREMENTS.start(@src());
    defer MEASUREMENTS.end(prof_point);

    item.* = .{};
    try parse_simple_type(context, item);
}

test "test_parse_vk_viewport" {
    const json =
        \\{
        \\  "x": 69.69,
        \\  "y": 69.69,
        \\  "width": 69.69,
        \\  "height": 69.69,
        \\  "minDepth": 69.69,
        \\  "maxDepth": 69.69
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const alloc = arena.allocator();

    const db: Database = .{ .file_fd = undefined, .entries = .initFill(.empty), .arena = arena };
    var scanner = Json.init(alloc, json);
    var context = Context{
        .alloc = alloc,
        .tmp_alloc = alloc,
        .scanner = &scanner,
        .db = &db,
    };

    var item: vk.VkViewport = undefined;
    try parse_vk_viewport(&context, &item);

    try std.testing.expectEqual(69.69, item.x);
    try std.testing.expectEqual(69.69, item.y);
    try std.testing.expectEqual(69.69, item.width);
    try std.testing.expectEqual(69.69, item.height);
    try std.testing.expectEqual(69.69, item.minDepth);
    try std.testing.expectEqual(69.69, item.maxDepth);
}

pub fn parse_vk_rect_2d(
    context: *Context,
    item: *vk.VkRect2D,
) Error!void {
    const prof_point = MEASUREMENTS.start(@src());
    defer MEASUREMENTS.end(prof_point);

    while (try scanner_object_next_field(context.scanner)) |s| {
        if (std.mem.eql(u8, s, "x")) {
            item.offset.x = try scanner_parse_number(i32, context.scanner);
        } else if (std.mem.eql(u8, s, "y")) {
            item.offset.y = try scanner_parse_number(i32, context.scanner);
        } else if (std.mem.eql(u8, s, "width")) {
            item.extent.width = try scanner_parse_number(u32, context.scanner);
        } else if (std.mem.eql(u8, s, "height")) {
            item.extent.height = try scanner_parse_number(u32, context.scanner);
        } else {
            const v = try scanner_next_number_or_string(context.scanner);
            log.warn(@src(), "Skipping unknown field {s}: {s}", .{ s, v });
        }
    }
}

test "test_parse_vk_rect_2d" {
    const json =
        \\{
        \\  "x": 69,
        \\  "y": 69,
        \\  "width": 69,
        \\  "height": 69
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const alloc = arena.allocator();

    const db: Database = .{ .file_fd = undefined, .entries = .initFill(.empty), .arena = arena };
    var scanner = Json.init(alloc, json);
    var context = Context{
        .alloc = alloc,
        .tmp_alloc = alloc,
        .scanner = &scanner,
        .db = &db,
    };

    var item: vk.VkRect2D = undefined;
    try parse_vk_rect_2d(&context, &item);

    try std.testing.expectEqual(69, item.offset.x);
    try std.testing.expectEqual(69, item.offset.y);
    try std.testing.expectEqual(69, item.extent.width);
    try std.testing.expectEqual(69, item.extent.height);
}

pub fn parse_vk_specialization_map_entry(
    context: *Context,
    item: *vk.VkSpecializationMapEntry,
) Error!void {
    const prof_point = MEASUREMENTS.start(@src());
    defer MEASUREMENTS.end(prof_point);

    item.* = .{};
    try parse_simple_type(context, item);
}

test "test_parse_vk_specialization_map_entry" {
    const json =
        \\{
        \\  "constantID": 69,
        \\  "offset": 69,
        \\  "size": 69
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const alloc = arena.allocator();

    const db: Database = .{ .file_fd = undefined, .entries = .initFill(.empty), .arena = arena };
    var scanner = Json.init(alloc, json);
    var context = Context{
        .alloc = alloc,
        .tmp_alloc = alloc,
        .scanner = &scanner,
        .db = &db,
    };

    var item: vk.VkSpecializationMapEntry = undefined;
    try parse_vk_specialization_map_entry(&context, &item);

    try std.testing.expectEqual(69, item.constantID);
    try std.testing.expectEqual(69, item.offset);
    try std.testing.expectEqual(69, item.size);
}

pub fn parse_vk_specialization_info(
    context: *Context,
    item: *vk.VkSpecializationInfo,
) Error!void {
    const prof_point = MEASUREMENTS.start(@src());
    defer MEASUREMENTS.end(prof_point);

    while (try scanner_object_next_field(context.scanner)) |s| {
        if (std.mem.eql(u8, s, "dataSize")) {
            item.dataSize = try scanner_parse_number(u64, context.scanner);
        } else if (std.mem.eql(u8, s, "data")) {
            const data_str = try scanner_next_string(context.scanner);
            var decoder = std.base64.standard.Decoder;
            const data_size = try decoder.calcSizeForSlice(data_str);
            const data = try context.alloc.alloc(u8, data_size);
            try decoder.decode(data, data_str);
            item.pData = @ptrCast(data.ptr);
        } else if (std.mem.eql(u8, s, "mapEntries")) {
            const entries = try parse_object_array(
                vk.VkSpecializationMapEntry,
                parse_vk_specialization_map_entry,
                context,
            );
            item.pMapEntries = @ptrCast(entries.ptr);
            item.mapEntryCount = @intCast(entries.len);
        } else {
            const v = try scanner_next_number_or_string(context.scanner);
            log.warn(@src(), "Skipping unknown field {s}: {s}", .{ s, v });
        }
    }
}

test "test_parse_vk_specialization_info" {
    const json =
        \\{
        \\  "mapEntries": [{}],
        \\  "dataSize": 69,
        \\  "data": ""
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const alloc = arena.allocator();

    const db: Database = .{ .file_fd = undefined, .entries = .initFill(.empty), .arena = arena };
    var scanner = Json.init(alloc, json);
    var context = Context{
        .alloc = alloc,
        .tmp_alloc = alloc,
        .scanner = &scanner,
        .db = &db,
    };

    var item: vk.VkSpecializationInfo = undefined;
    try parse_vk_specialization_info(&context, &item);

    try std.testing.expectEqual(1, item.mapEntryCount);
    try std.testing.expect(item.pMapEntries != null);
    try std.testing.expectEqual(69, item.dataSize);
    try std.testing.expect(item.pData != null);
}

pub fn parse_vk_compute_pipeline_create_info(
    context: *Context,
    item: *vk.VkComputePipelineCreateInfo,
) Error!void {
    const prof_point = MEASUREMENTS.start(@src());
    defer MEASUREMENTS.end(prof_point);

    item.* = .{};
    while (try scanner_object_next_field(context.scanner)) |s| {
        if (std.mem.eql(u8, s, "pNext")) {
            item.pNext = try parse_pnext_chain(context);
        } else if (std.mem.eql(u8, s, "flags")) {
            item.flags = try scanner_parse_bitfield(vk.VkPipelineCreateFlags, context.scanner);
        } else if (std.mem.eql(u8, s, "stage")) {
            try parse_vk_pipeline_shader_stage_create_info(
                context,
                &item.stage,
            );
        } else if (std.mem.eql(u8, s, "layout")) {
            try parse_single_handle(context, .pipeline_layout, @ptrCast(&item.layout));
        } else if (std.mem.eql(u8, s, "basePipelineHandle")) {
            const v = try scanner_next_string(context.scanner);
            const base_pipeline_hash = try std.fmt.parseInt(u64, v, 16);
            if (base_pipeline_hash != 0)
                return error.BasePipelinesNotSupported;
        } else if (std.mem.eql(u8, s, "basePipelineIndex")) {
            item.basePipelineIndex = try scanner_parse_number(i32, context.scanner);
        } else {
            const v = try scanner_next_number_or_string(context.scanner);
            log.warn(@src(), "Skipping unknown field {s}: {s}", .{ s, v });
        }
    }
}

test "test_parse_vk_compute_pipeline_create_info" {
    const json =
        \\{
        \\  "flags": 69,
        \\  "stage": {},
        \\  "layout": "1111111111111111",
        \\  "basePipelineHandle": "0000000000000000",
        \\  "basePipelineIndex": 69
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const alloc = arena.allocator();

    var db: Database = .{ .file_fd = undefined, .entries = .initFill(.empty), .arena = arena };
    try db.entries.getPtr(.pipeline_layout).put(alloc, 0x1111111111111111, .{
        .tag = undefined,
        .hash = undefined,
        .payload_flag = undefined,
        .payload_crc = undefined,
        .payload_stored_size = undefined,
        .payload_decompressed_size = undefined,
        .payload_file_offset = undefined,
        .handle = undefined,
    });

    var scanner = Json.init(alloc, json);
    var context = Context{
        .alloc = alloc,
        .tmp_alloc = alloc,
        .scanner = &scanner,
        .db = &db,
    };

    var item: vk.VkComputePipelineCreateInfo = undefined;
    try parse_vk_compute_pipeline_create_info(&context, &item);

    try std.testing.expectEqual(null, item.pNext);
    try std.testing.expectEqual(69, @as(u32, @bitCast(item.flags)));
    try std.testing.expectEqual(vk.VkPipelineShaderStageCreateInfo{
        .sType = vk.VkStructureType.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
    }, item.stage);
    try std.testing.expectEqual(.none, item.basePipelineHandle);
    try std.testing.expectEqual(69, item.basePipelineIndex);

    try std.testing.expectEqual(0, @intFromEnum(item.layout));
    try std.testing.expectEqual(1, context.dependencies.items.len);
    try std.testing.expectEqual(.pipeline_layout, context.dependencies.items[0].tag);
    try std.testing.expectEqual(0x1111111111111111, context.dependencies.items[0].hash);
    context.dependencies.items[0].ptr_to_handle.?.* = 0x69;
    try std.testing.expectEqual(0x69, @intFromEnum(item.layout));
}

pub fn parse_vk_raytracing_pipeline_create_info(
    context: *Context,
    item: *vk.VkRayTracingPipelineCreateInfoKHR,
) Error!void {
    const prof_point = MEASUREMENTS.start(@src());
    defer MEASUREMENTS.end(prof_point);

    item.* = .{};
    while (try scanner_object_next_field(context.scanner)) |s| {
        if (std.mem.eql(u8, s, "pNext")) {
            item.pNext = try parse_pnext_chain(context);
        } else if (std.mem.eql(u8, s, "flags")) {
            item.flags = try scanner_parse_bitfield(vk.VkPipelineCreateFlags, context.scanner);
        } else if (std.mem.eql(u8, s, "stages")) {
            const stages = try parse_object_array(
                vk.VkPipelineShaderStageCreateInfo,
                parse_vk_pipeline_shader_stage_create_info,
                context,
            );
            item.pStages = @ptrCast(stages.ptr);
            item.stageCount = @intCast(stages.len);
        } else if (std.mem.eql(u8, s, "groups")) {
            const groups = try parse_object_array(
                vk.VkRayTracingShaderGroupCreateInfoKHR,
                parse_vk_ray_tracing_shader_group_create_info,
                context,
            );
            item.pGroups = @ptrCast(groups.ptr);
            item.groupCount = @intCast(groups.len);
        } else if (std.mem.eql(u8, s, "libraryInfo")) {
            const library =
                try context.alloc.create(vk.VkPipelineLibraryCreateInfoKHR);
            try parse_vk_pipeline_library_create_info(context, library);
            item.pLibraryInfo = library;
        } else if (std.mem.eql(u8, s, "libraryInterface")) {
            const interface =
                try context.alloc.create(vk.VkRayTracingPipelineInterfaceCreateInfoKHR);
            try parse_vk_ray_tracing_pipeline_interface_create_info(context, interface);
            item.pLibraryInterface = interface;
        } else if (std.mem.eql(u8, s, "maxPipelineRayRecursionDepth")) {
            item.maxPipelineRayRecursionDepth = try scanner_parse_number(u32, context.scanner);
        } else if (std.mem.eql(u8, s, "dynamicState")) {
            const dynamic_state = try context.alloc.create(vk.VkPipelineDynamicStateCreateInfo);
            try parse_vk_pipeline_dynamic_state_create_info(context, dynamic_state);
            item.pDynamicState = dynamic_state;
        } else if (std.mem.eql(u8, s, "layout")) {
            try parse_single_handle(context, .pipeline_layout, @ptrCast(&item.layout));
        } else if (std.mem.eql(u8, s, "basePipelineHandle")) {
            const v = try scanner_next_string(context.scanner);
            const base_pipeline_hash = try std.fmt.parseInt(u64, v, 16);
            if (base_pipeline_hash != 0)
                return error.BasePipelinesNotSupported;
        } else if (std.mem.eql(u8, s, "basePipelineIndex")) {
            item.basePipelineIndex = try scanner_parse_number(i32, context.scanner);
        } else {
            const v = try scanner_next_number_or_string(context.scanner);
            log.warn(@src(), "Skipping unknown field {s}: {s}", .{ s, v });
        }
    }
}

test "test_parse_vk_raytracing_pipeline_create_info" {
    const json =
        \\{
        \\  "flags": 69,
        \\  "stages": [{}],
        \\  "groups": [{}],
        \\  "maxPipelineRayRecursionDepth": 69,
        \\  "libraryInfo": {},
        \\  "libraryInterface": {},
        \\  "dynamicState": {},
        \\  "layout": "1111111111111111",
        \\  "basePipelineHandle": "0000000000000000",
        \\  "basePipelineIndex": 69
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const alloc = arena.allocator();

    var db: Database = .{ .file_fd = undefined, .entries = .initFill(.empty), .arena = arena };
    try db.entries.getPtr(.pipeline_layout).put(alloc, 0x1111111111111111, .{
        .tag = undefined,
        .hash = undefined,
        .payload_flag = undefined,
        .payload_crc = undefined,
        .payload_stored_size = undefined,
        .payload_decompressed_size = undefined,
        .payload_file_offset = undefined,
        .handle = 0x69,
    });
    var scanner = Json.init(alloc, json);
    var context = Context{
        .alloc = alloc,
        .tmp_alloc = alloc,
        .scanner = &scanner,
        .db = &db,
    };

    var item: vk.VkRayTracingPipelineCreateInfoKHR = undefined;
    try parse_vk_raytracing_pipeline_create_info(&context, &item);

    try std.testing.expectEqual(null, item.pNext);
    try std.testing.expectEqual(69, @as(u32, @bitCast(item.flags)));
    try std.testing.expectEqual(1, item.stageCount);
    try std.testing.expect(item.pStages != null);
    try std.testing.expectEqual(1, item.groupCount);
    try std.testing.expect(item.pGroups != null);
    try std.testing.expectEqual(69, item.maxPipelineRayRecursionDepth);
    try std.testing.expect(item.pLibraryInfo != null);
    try std.testing.expect(item.pLibraryInterface != null);
    try std.testing.expect(item.pDynamicState != null);
    try std.testing.expectEqual(.none, item.basePipelineHandle);
    try std.testing.expectEqual(69, item.basePipelineIndex);

    try std.testing.expectEqual(0, @intFromEnum(item.layout));
    try std.testing.expectEqual(1, context.dependencies.items.len);
    try std.testing.expectEqual(.pipeline_layout, context.dependencies.items[0].tag);
    try std.testing.expectEqual(0x1111111111111111, context.dependencies.items[0].hash);
    context.dependencies.items[0].ptr_to_handle.?.* = 0x69;
    try std.testing.expectEqual(0x69, @intFromEnum(item.layout));
}

pub fn parse_vk_ray_tracing_shader_group_create_info(
    context: *Context,
    item: *vk.VkRayTracingShaderGroupCreateInfoKHR,
) Error!void {
    const prof_point = MEASUREMENTS.start(@src());
    defer MEASUREMENTS.end(prof_point);

    item.* = .{};
    try parse_simple_type(context, item);
}

test "test_parse_vk_ray_tracing_shader_group_create_info" {
    const json =
        \\{
        \\  "type": 69,
        \\  "generalShader": 69,
        \\  "closestHitShader": 69,
        \\  "anyHitShader": 69,
        \\  "intersectionShader": 69
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const alloc = arena.allocator();

    const db: Database = .{ .file_fd = undefined, .entries = .initFill(.empty), .arena = arena };
    var scanner = Json.init(alloc, json);
    var context = Context{
        .alloc = alloc,
        .tmp_alloc = alloc,
        .scanner = &scanner,
        .db = &db,
    };

    var item: vk.VkRayTracingShaderGroupCreateInfoKHR = undefined;
    try parse_vk_ray_tracing_shader_group_create_info(&context, &item);

    try std.testing.expectEqual(null, item.pNext);
    try std.testing.expectEqual(69, @as(i32, @intFromEnum(item.type)));
    try std.testing.expectEqual(69, item.generalShader);
    try std.testing.expectEqual(69, item.closestHitShader);
    try std.testing.expectEqual(69, item.anyHitShader);
    try std.testing.expectEqual(69, item.intersectionShader);
    try std.testing.expectEqual(null, item.pShaderGroupCaptureReplayHandle);
}

pub fn parse_vk_pipeline_library_create_info(
    context: *Context,
    item: *vk.VkPipelineLibraryCreateInfoKHR,
) Error!void {
    const prof_point = MEASUREMENTS.start(@src());
    defer MEASUREMENTS.end(prof_point);

    item.* = .{};
    while (try scanner_object_next_field(context.scanner)) |s| {
        if (std.mem.eql(u8, s, "pNext")) {
            item.pNext = try parse_pnext_chain(context);
        } else if (std.mem.eql(u8, s, "libraries")) {
            const libraries = try parse_handle_array(
                vk.VkPipeline,
                .raytracing_pipeline,
                context,
            );
            item.pLibraries = @ptrCast(libraries.ptr);
            item.libraryCount = @intCast(libraries.len);
        } else {
            const v = try scanner_next_number_or_string(context.scanner);
            log.warn(@src(), "Skipping unknown field {s}: {s}", .{ s, v });
        }
    }
}

test "test_parse_vk_pipeline_library_create_info" {
    const json =
        \\{
        \\  "libraries": ["1111111111111111"]
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const alloc = arena.allocator();

    var db: Database = .{ .file_fd = undefined, .entries = .initFill(.empty), .arena = arena };
    try db.entries.getPtr(.raytracing_pipeline).put(alloc, 0x1111111111111111, .{
        .tag = undefined,
        .hash = undefined,
        .payload_flag = undefined,
        .payload_crc = undefined,
        .payload_stored_size = undefined,
        .payload_decompressed_size = undefined,
        .payload_file_offset = undefined,
        .handle = 0x69,
    });
    var scanner = Json.init(alloc, json);
    var context = Context{
        .alloc = alloc,
        .tmp_alloc = alloc,
        .scanner = &scanner,
        .db = &db,
    };

    var item: vk.VkPipelineLibraryCreateInfoKHR = undefined;
    try parse_vk_pipeline_library_create_info(&context, &item);

    try std.testing.expectEqual(null, item.pNext);
    try std.testing.expectEqual(1, item.libraryCount);
    try std.testing.expect(item.pLibraries != null);

    try std.testing.expectEqual(0, @intFromEnum(item.pLibraries.?[0]));
    try std.testing.expectEqual(1, context.dependencies.items.len);
    try std.testing.expectEqual(.raytracing_pipeline, context.dependencies.items[0].tag);
    try std.testing.expectEqual(0x1111111111111111, context.dependencies.items[0].hash);
    context.dependencies.items[0].ptr_to_handle.?.* = 0x69;
    try std.testing.expectEqual(0x69, @intFromEnum(item.pLibraries.?[0]));
}

pub fn parse_vk_ray_tracing_pipeline_interface_create_info(
    context: *Context,
    item: *vk.VkRayTracingPipelineInterfaceCreateInfoKHR,
) Error!void {
    const prof_point = MEASUREMENTS.start(@src());
    defer MEASUREMENTS.end(prof_point);

    item.* = .{};
    try parse_simple_type(context, item);
}

test "test_parse_vk_ray_tracing_pipeline_interface_create_info" {
    const json =
        \\{
        \\  "maxPipelineRayPayloadSize": 69,
        \\  "maxPipelineRayHitAttributeSize": 69
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const alloc = arena.allocator();

    const db: Database = .{ .file_fd = undefined, .entries = .initFill(.empty), .arena = arena };
    var scanner = Json.init(alloc, json);
    var context = Context{
        .alloc = alloc,
        .tmp_alloc = alloc,
        .scanner = &scanner,
        .db = &db,
    };

    var item: vk.VkRayTracingPipelineInterfaceCreateInfoKHR = undefined;
    try parse_vk_ray_tracing_pipeline_interface_create_info(&context, &item);

    try std.testing.expectEqual(null, item.pNext);
    try std.testing.expectEqual(69, item.maxPipelineRayPayloadSize);
    try std.testing.expectEqual(69, item.maxPipelineRayHitAttributeSize);
}
