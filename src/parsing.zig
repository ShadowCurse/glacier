const std = @import("std");
const vk = @import("volk.zig");
const log = @import("log.zig");

const Allocator = std.mem.Allocator;

pub fn parse_physical_device_mesh_shader_features_ext(
    scanner: *std.json.Scanner,
    obj: *vk.VkPhysicalDeviceMeshShaderFeaturesEXT,
) !void {
    while (true) {
        switch (try scanner.next()) {
            .string => |s| {
                if (std.mem.eql(u8, s, "taskShader")) {
                    switch (try scanner.next()) {
                        .number => |v| {
                            obj.taskShader = try std.fmt.parseInt(u8, v, 10);
                        },
                        else => return error.InvalidJson,
                    }
                } else if (std.mem.eql(u8, s, "meshShader")) {
                    switch (try scanner.next()) {
                        .number => |v| {
                            obj.meshShader = try std.fmt.parseInt(u8, v, 10);
                        },
                        else => return error.InvalidJson,
                    }
                } else if (std.mem.eql(u8, s, "multiviewMeshShader")) {
                    switch (try scanner.next()) {
                        .number => |v| {
                            obj.multiviewMeshShader = try std.fmt.parseInt(u8, v, 10);
                        },
                        else => return error.InvalidJson,
                    }
                } else if (std.mem.eql(u8, s, "primitiveFragmentShadingRateMeshShader")) {
                    switch (try scanner.next()) {
                        .number => |v| {
                            obj.primitiveFragmentShadingRateMeshShader = try std.fmt.parseInt(u8, v, 10);
                        },
                        else => return error.InvalidJson,
                    }
                } else if (std.mem.eql(u8, s, "meshShaderQueries")) {
                    switch (try scanner.next()) {
                        .number => |v| {
                            obj.meshShaderQueries = try std.fmt.parseInt(u8, v, 10);
                        },
                        else => return error.InvalidJson,
                    }
                } else return error.InvalidJson;
            },
            .object_end => return,
            else => return error.InvalidJson,
        }
    }
}

pub fn parse_physical_device_fragment_shading_rate_features_khr(
    scanner: *std.json.Scanner,
    obj: *vk.VkPhysicalDeviceFragmentShadingRateFeaturesKHR,
) !void {
    while (true) {
        switch (try scanner.next()) {
            .string => |s| {
                if (std.mem.eql(u8, s, "pipelineFragmentShadingRate")) {
                    switch (try scanner.next()) {
                        .number => |v| {
                            obj.pipelineFragmentShadingRate = try std.fmt.parseInt(u8, v, 10);
                        },
                        else => return error.InvalidJson,
                    }
                } else if (std.mem.eql(u8, s, "primitiveFragmentShadingRate")) {
                    switch (try scanner.next()) {
                        .number => |v| {
                            obj.primitiveFragmentShadingRate = try std.fmt.parseInt(u8, v, 10);
                        },
                        else => return error.InvalidJson,
                    }
                } else if (std.mem.eql(u8, s, "attachmentFragmentShadingRate")) {
                    switch (try scanner.next()) {
                        .number => |v| {
                            obj.attachmentFragmentShadingRate = try std.fmt.parseInt(u8, v, 10);
                        },
                        else => return error.InvalidJson,
                    }
                } else return error.InvalidJson;
            },
            .object_end => return,
            else => return error.InvalidJson,
        }
    }
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

// Example json
// {
//   "version": 6,
//   "applicationInfo": {
//     "applicationName": "citadel",
//     "engineName": "Source2",
//     "applicationVersion": 1,
//     "engineVersion": 1,
//     "apiVersion": 4202496
//   },
//   "physicalDeviceFeatures": {
//     "robustBufferAccess": 0,
//     "pNext": [
//       {
//         "sType": 1000328000,
//         "taskShader": 1,
//         "meshShader": 1,
//         "multiviewMeshShader": 1,
//         "primitiveFragmentShadingRateMeshShader": 0,
//         "meshShaderQueries": 1
//       },
//       {
//         "sType": 1000226003,
//         "pipelineFragmentShadingRate": 1,
//         "primitiveFragmentShadingRate": 1,
//         "attachmentFragmentShadingRate": 1
//       }
//     ]
//   }
// }
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
            while (true) {
                switch (try scanner.next()) {
                    .string => |s| {
                        if (std.mem.eql(u8, s, "applicationName")) {
                            switch (try scanner.next()) {
                                .string => |name| {
                                    const n = try aa.dupeZ(u8, name);
                                    vk_application_info.pApplicationName = @ptrCast(n.ptr);
                                },
                                else => return error.InvalidJson,
                            }
                        } else if (std.mem.eql(u8, s, "engineName")) {
                            switch (try scanner.next()) {
                                .string => |name| {
                                    const n = try aa.dupeZ(u8, name);
                                    vk_application_info.pEngineName = @ptrCast(n.ptr);
                                },
                                else => return error.InvalidJson,
                            }
                        } else if (std.mem.eql(u8, s, "applicationVersion")) {
                            switch (try scanner.next()) {
                                .number => |v| {
                                    vk_application_info.applicationVersion =
                                        try std.fmt.parseInt(u32, v, 10);
                                },
                                else => return error.InvalidJson,
                            }
                        } else if (std.mem.eql(u8, s, "engineVersion")) {
                            switch (try scanner.next()) {
                                .number => |v| {
                                    vk_application_info.engineVersion =
                                        try std.fmt.parseInt(u32, v, 10);
                                },
                                else => return error.InvalidJson,
                            }
                        } else if (std.mem.eql(u8, s, "apiVersion")) {
                            switch (try scanner.next()) {
                                .number => |v| {
                                    vk_application_info.apiVersion =
                                        try std.fmt.parseInt(u32, v, 10);
                                },
                                else => return error.InvalidJson,
                            }
                        }
                    },
                    .object_begin => {},
                    .object_end => break,
                    else => return error.InvalidJson,
                }
            }
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

    log.info(@src(), "app name {s}", .{vk_app_info.pApplicationName});
    log.info(@src(), "engine name {s}", .{vk_app_info.pEngineName});
    log.info(@src(), "pNext {*}", .{vk_app_info.pNext});
    var pnext = vk_app_info.pNext;
    while (pnext) |next| {
        const n: *const vk.VkStructureType = @alignCast(@ptrCast(next));
        switch (n.*) {
            vk.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2 => {
                log.info(@src(), "next chain: VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2", .{});
                const nn: *const vk.VkPhysicalDeviceFeatures2 = @alignCast(@ptrCast(next));
                pnext = nn.pNext;
            },
            vk.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_MESH_SHADER_FEATURES_EXT => {
                log.info(@src(), "next chain: VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_MESH_SHADER_FEATURES_EXT", .{});
                const nn: *const vk.VkPhysicalDeviceMeshShaderFeaturesEXT = @alignCast(@ptrCast(next));
                pnext = nn.pNext;
            },
            vk.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FRAGMENT_SHADING_RATE_FEATURES_KHR => {
                log.info(@src(), "next chain: VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FRAGMENT_SHADING_RATE_FEATURES_KHR", .{});
                const nn: *const vk.VkPhysicalDeviceFragmentShadingRateFeaturesKHR = @alignCast(@ptrCast(next));
                pnext = nn.pNext;
            },
            else => {
                log.info(@src(), "unknown struct type: {d}", .{n.*});
                break;
            },
        }
    }
}
