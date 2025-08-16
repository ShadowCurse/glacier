const std = @import("std");
const vk = @import("volk.zig");
const log = @import("log.zig");

const Allocator = std.mem.Allocator;

pub fn print_vk_struct(@"struct": anytype) void {
    const t = @typeInfo(@TypeOf(@"struct")).pointer.child;
    const fields = @typeInfo(t).@"struct".fields;
    log.info(@src(), "Type: {s}", .{@typeName(t)});
    inline for (fields) |field| {
        switch (field.type) {
            u32, u64, vk.VkStructureType => {
                log.info(@src(), "\t{s}: {d}", .{ field.name, @field(@"struct", field.name) });
            },
            [*c]const u8 => {
                log.info(@src(), "\t{s}: {s}", .{ field.name, @field(@"struct", field.name) });
            },
            ?*anyopaque, ?*const anyopaque => {
                log.info(@src(), "\t{s}: {?}", .{ field.name, @field(@"struct", field.name) });
            },
            else => log.info(
                @src(),
                "\tCannot format field {s} of type {s}",
                .{ field.name, @typeName(field.type) },
            ),
        }
    }
}

pub fn print_vk_chain(chain: anytype) void {
    var current: ?*const anyopaque = chain;
    while (current) |c| {
        const struct_type: *const vk.VkStructureType = @alignCast(@ptrCast(c));
        switch (struct_type.*) {
            vk.VK_STRUCTURE_TYPE_APPLICATION_INFO => {
                const nn: *const vk.VkApplicationInfo = @alignCast(@ptrCast(c));
                print_vk_struct(nn);
                current = nn.pNext;
            },
            vk.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2 => {
                const nn: *const vk.VkPhysicalDeviceFeatures2 = @alignCast(@ptrCast(c));
                print_vk_struct(nn);
                current = nn.pNext;
            },
            vk.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_MESH_SHADER_FEATURES_EXT => {
                const nn: *const vk.VkPhysicalDeviceMeshShaderFeaturesEXT = @alignCast(@ptrCast(c));
                print_vk_struct(nn);
                current = nn.pNext;
            },
            vk.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FRAGMENT_SHADING_RATE_FEATURES_KHR => {
                const nn: *const vk.VkPhysicalDeviceFragmentShadingRateFeaturesKHR = @alignCast(@ptrCast(c));
                print_vk_struct(nn);
                current = nn.pNext;
            },
            else => {
                log.info(@src(), "unknown struct type: {d}", .{struct_type.*});
                break;
            },
        }
    }
}

pub const NameMap = struct { json_name: []const u8, field_name: []const u8, type: type };
pub fn parse_type(
    comptime name_map: []const NameMap,
    arena_alloc: ?Allocator,
    scanner: *std.json.Scanner,
    output: anytype,
) !void {
    var field_is_parsed: [name_map.len]bool = .{false} ** name_map.len;
    while (true) {
        switch (try scanner.next()) {
            .string => |s| {
                inline for (name_map, 0..) |nm, i| {
                    if (!field_is_parsed[i] and std.mem.eql(u8, s, nm.json_name)) {
                        field_is_parsed[i] = true;
                        switch (nm.type) {
                            u8, u32 => {
                                switch (try scanner.next()) {
                                    .number => |v| {
                                        @field(output, nm.field_name) =
                                            try std.fmt.parseInt(nm.type, v, 10);
                                    },
                                    else => return error.InvalidJson,
                                }
                            },
                            []const u8 => {
                                switch (try scanner.next()) {
                                    .string => |name| {
                                        if (arena_alloc) |aa| {
                                            const n = try aa.dupeZ(u8, name);
                                            @field(output, nm.field_name) = @ptrCast(n.ptr);
                                        }
                                    },
                                    else => return error.InvalidJson,
                                }
                            },
                            else => log.comptime_err(
                                @src(),
                                "Cannot parse field with type: {any}",
                                .{nm[2]},
                            ),
                        }
                    }
                }
            },
            .object_begin => {},
            .object_end => break,
            else => return error.InvalidJson,
        }
    }
}

pub fn parse_physical_device_mesh_shader_features_ext(
    scanner: *std.json.Scanner,
    obj: *vk.VkPhysicalDeviceMeshShaderFeaturesEXT,
) !void {
    return parse_type(
        &.{
            .{
                .json_name = "taskShader",
                .field_name = "taskShader",
                .type = u8,
            },
            .{
                .json_name = "meshShader",
                .field_name = "meshShader",
                .type = u8,
            },
            .{
                .json_name = "multiviewMeshShader",
                .field_name = "multiviewMeshShader",
                .type = u8,
            },
            .{
                .json_name = "primitiveFragmentShadingRateMeshShader",
                .field_name = "primitiveFragmentShadingRateMeshShader",
                .type = u8,
            },
            .{
                .json_name = "meshShaderQueries",
                .field_name = "meshShaderQueries",
                .type = u8,
            },
        },
        null,
        scanner,
        obj,
    );
}

pub fn parse_physical_device_fragment_shading_rate_features_khr(
    scanner: *std.json.Scanner,
    obj: *vk.VkPhysicalDeviceFragmentShadingRateFeaturesKHR,
) !void {
    return parse_type(
        &.{
            .{
                .json_name = "pipelineFragmentShadingRate",
                .field_name = "pipelineFragmentShadingRate",
                .type = u8,
            },
            .{
                .json_name = "primitiveFragmentShadingRate",
                .field_name = "primitiveFragmentShadingRate",
                .type = u8,
            },
            .{
                .json_name = "attachmentFragmentShadingRate",
                .field_name = "attachmentFragmentShadingRate",
                .type = u8,
            },
        },
        null,
        scanner,
        obj,
    );
}

pub fn parse_pnext_chain(arena_alloc: Allocator, scanner: *std.json.Scanner) !?*anyopaque {
    if (try scanner.next() != .array_begin) return error.InvalidJson;
    if (try scanner.next() != .object_begin) return error.InvalidJson;
    var first_in_chain: ?*anyopaque = null;
    var last_pnext_in_chain: ?**anyopaque = null;
    while (true) {
        switch (try scanner.next()) {
            .string => |s| {
                if (std.mem.eql(u8, s, "sType")) {
                    switch (try scanner.next()) {
                        .number => |v| {
                            const stype = try std.fmt.parseInt(u32, v, 10);
                            switch (stype) {
                                vk.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_MESH_SHADER_FEATURES_EXT => {
                                    const obj =
                                        try arena_alloc.create(vk.VkPhysicalDeviceMeshShaderFeaturesEXT);
                                    obj.* = .{ .sType = stype };
                                    if (first_in_chain == null)
                                        first_in_chain = obj;
                                    if (last_pnext_in_chain) |lpic| {
                                        lpic.* = obj;
                                    }
                                    last_pnext_in_chain = @ptrCast(&obj.pNext);
                                    try parse_physical_device_mesh_shader_features_ext(scanner, obj);
                                },
                                vk.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FRAGMENT_SHADING_RATE_FEATURES_KHR => {
                                    const obj =
                                        try arena_alloc.create(vk.VkPhysicalDeviceFragmentShadingRateFeaturesKHR);
                                    obj.* = .{ .sType = stype };
                                    if (first_in_chain == null)
                                        first_in_chain = obj;
                                    if (last_pnext_in_chain) |lpic| {
                                        lpic.* = obj;
                                    }
                                    last_pnext_in_chain = @ptrCast(&obj.pNext);
                                    try parse_physical_device_fragment_shading_rate_features_khr(scanner, obj);
                                },
                                else => return error.InvalidJson,
                            }
                        },
                        else => return error.InvalidJson,
                    }
                } else return error.InvalidJson;
            },
            .object_begin => {},
            .array_end => return first_in_chain,
            else => return error.InvalidJson,
        }
    }
    unreachable;
}

pub fn parse_application_info(
    arena_alloc: Allocator,
    json_str: []const u8,
) !*const vk.VkApplicationInfo {
    const Inner = struct {
        fn parse_app_info(
            aa: Allocator,
            scanner: *std.json.Scanner,
            vk_application_info: *vk.VkApplicationInfo,
        ) !void {
            return parse_type(
                &.{
                    .{
                        .json_name = "applicationName",
                        .field_name = "pApplicationName",
                        .type = []const u8,
                    },
                    .{
                        .json_name = "engineName",
                        .field_name = "pEngineName",
                        .type = []const u8,
                    },
                    .{
                        .json_name = "applicationVersion",
                        .field_name = "applicationVersion",
                        .type = u32,
                    },
                    .{
                        .json_name = "engineVersion",
                        .field_name = "engineVersion",
                        .type = u32,
                    },
                    .{
                        .json_name = "apiVersion",
                        .field_name = "apiVersion",
                        .type = u32,
                    },
                },
                aa,
                scanner,
                vk_application_info,
            );
        }
        fn parse_device_features(
            aa: Allocator,
            scanner: *std.json.Scanner,
            vk_physical_device_features2: *vk.VkPhysicalDeviceFeatures2,
        ) !void {
            while (true) {
                switch (try scanner.next()) {
                    .string => |s| {
                        if (std.mem.eql(u8, s, "robustBufferAccess")) {
                            switch (try scanner.next()) {
                                .number => |v| {
                                    vk_physical_device_features2.features.robustBufferAccess =
                                        try std.fmt.parseInt(u32, v, 10);
                                },
                                else => return error.InvalidJson,
                            }
                        } else if (std.mem.eql(u8, s, "pNext")) {
                            vk_physical_device_features2.pNext = try parse_pnext_chain(aa, scanner);
                        } else {
                            return error.InvalidJson;
                        }
                    },
                    .object_begin => {},
                    .object_end => break,
                    else => return error.InvalidJson,
                }
            }
        }
    };

    var scanner = std.json.Scanner.initCompleteInput(arena_alloc, json_str);
    const vk_application_info = try arena_alloc.create(vk.VkApplicationInfo);
    vk_application_info.* = .{ .sType = vk.VK_STRUCTURE_TYPE_APPLICATION_INFO };
    const vk_physical_device_features2 = try arena_alloc.create(vk.VkPhysicalDeviceFeatures2);
    vk_physical_device_features2.* = .{ .sType = vk.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2 };

    while (true) {
        switch (try scanner.next()) {
            .string => |s| {
                if (std.mem.eql(u8, s, "version")) {
                    switch (try scanner.next()) {
                        .number => |n| {
                            const version = try std.fmt.parseInt(u32, n, 10);
                            log.info(@src(), "version: {d}", .{version});
                        },
                        else => return error.InvalidJson,
                    }
                } else if (std.mem.eql(u8, s, "applicationInfo")) {
                    try Inner.parse_app_info(arena_alloc, &scanner, vk_application_info);
                } else if (std.mem.eql(u8, s, "physicalDeviceFeatures")) {
                    try Inner.parse_device_features(
                        arena_alloc,
                        &scanner,
                        vk_physical_device_features2,
                    );
                    vk_application_info.pNext = @ptrCast(vk_physical_device_features2);
                }
            },
            .end_of_document => break,
            else => {},
        }
    }
    return vk_application_info;
}

test "parse_application_info" {
    const json =
        \\{
        \\  "version": 6,
        \\  "applicationInfo": {
        \\    "applicationName": "citadel",
        \\    "engineName": "Source2",
        \\    "applicationVersion": 1,
        \\    "engineVersion": 1,
        \\    "apiVersion": 4202496
        \\  },
        \\  "physicalDeviceFeatures": {
        \\    "robustBufferAccess": 0,
        \\    "pNext": [
        \\      {
        \\        "sType": 1000328000,
        \\        "taskShader": 1,
        \\        "meshShader": 1,
        \\        "multiviewMeshShader": 1,
        \\        "primitiveFragmentShadingRateMeshShader": 0,
        \\        "meshShaderQueries": 1
        \\      },
        \\      {
        \\        "sType": 1000226003,
        \\        "pipelineFragmentShadingRate": 1,
        \\        "primitiveFragmentShadingRate": 1,
        \\        "attachmentFragmentShadingRate": 1
        \\      }
        \\    ]
        \\  }
        \\}
    ;
    var gpa = std.heap.DebugAllocator(.{}).init;
    const gpa_alloc = gpa.allocator();
    var arena = std.heap.ArenaAllocator.init(gpa_alloc);
    const arena_alloc = arena.allocator();

    const vk_app_info = try parse_application_info(arena_alloc, json);
    print_vk_chain(vk_app_info);
}
