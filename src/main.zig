const std = @import("std");
const vk = @import("volk.zig");
const log = @import("log.zig");

const args_parser = @import("args_parser.zig");

const Allocator = std.mem.Allocator;

pub const log_options = log.Options{
    .level = .Debug,
};

const Args = struct {
    help: bool = false,
    device_index: ?u32 = null,
    enable_validation: bool = false,
    spirv_val: bool = false,
    on_disk_pipeline_cache: ?[]const u8 = null,
    on_disk_validation_cache: ?[]const u8 = null,
    on_disk_validation_blacklist: ?[]const u8 = null,
    on_disk_validation_whitelist: ?[]const u8 = null,
    on_disk_replay_whitelist: ?[]const u8 = null,
    on_disk_replay_whitelist_mask: ?[]const u8 = null,
    num_threads: ?u32 = null,
    loop: ?u32 = null,
    pipeline_hash: ?u32 = null,
    graphics_pipeline_range: ?u32 = null,
    compute_pipeline_range: ?u32 = null,
    raytracing_pipeline_range: ?u32 = null,
    enable_pipeline_stats: ?[]const u8 = null,
    on_disk_module_identifier: ?[]const u8 = null,
    quiet_slave: bool = false,
    master_process: bool = false,
    slave_process: bool = false,
    progress: bool = false,
    shmem_fd: ?u32 = null,
    control_fd: ?u32 = null,
    shader_cache_size: ?u32 = null,
    // Deprecated
    ignore_derived_pipelines: void = {},
    log_memory: bool = false,
    null_device: bool = false,
    timeout_seconds: ?u32 = null,
    implicit_whitelist: ?u32 = null,
    replayer_cache: ?[]const u8 = null,
    disable_signal_handler: bool = false,
    disable_rate_limiter: bool = false,
    database_paths: args_parser.LastArgs = .{},
};

pub fn main() !void {
    const args = try args_parser.parse(Args);
    if (args.help) {
        try args_parser.print_help(Args);
        return;
    }

    var gpa = std.heap.DebugAllocator(.{}).init;
    const gpa_alloc = gpa.allocator();
    var arena = std.heap.ArenaAllocator.init(gpa_alloc);
    const arena_alloc = arena.allocator();

    const db_path = std.mem.span(args.database_paths.values[0]);
    const db = try open_database(gpa_alloc, arena_alloc, db_path);
    _ = db;

    // try vk.check_result(vk.volkInitialize());
    // const api_version = vk.volkGetInstanceVersion();
    // log.info(
    //     @src(),
    //     "Vulkan version: {d}.{d}.{d}",
    //     .{
    //         vk.VK_API_VERSION_MAJOR(api_version),
    //         vk.VK_API_VERSION_MINOR(api_version),
    //         vk.VK_API_VERSION_PATCH(api_version),
    //     },
    // );
    //
    // const vk_instance = try create_vk_instance(arena_alloc, api_version);
    // vk.volkLoadInstance(vk_instance);
    //
    // const physical_device = try select_physical_device(arena_alloc, vk_instance);
    // const vk_device = try create_vk_device(arena_alloc, &physical_device);
    // _ = vk_device;
}

pub fn mmap_file(path: []const u8) ![]const u8 {
    const fd = try std.posix.open(path, .{ .ACCMODE = .RDONLY }, 0);
    defer std.posix.close(fd);

    const stat = try std.posix.fstat(fd);
    const mem = try std.posix.mmap(
        null,
        @intCast(stat.size),
        std.posix.PROT.READ,
        .{ .TYPE = .PRIVATE },
        fd,
        0,
    );
    return mem;
}

pub const Database = struct {
    file_mem: []const u8,
    entries: []EntryPtr,

    pub const MAGIC = "\x81FOSSILIZEDB";
    pub const Header = extern struct {
        magic: [12]u8,
        unused_1: u8,
        unused_2: u8,
        unused_3: u8,
        version: u8,
    };

    pub const EntryPtr = [*]const u8;
    pub const Entry = extern struct {
        // 8 bytes: ???
        // 16 bytes: tag
        // 16 bytes: value
        tag_hash: [40]u8,
        stored_size: u32,
        flags: u32,
        crc: u32,
        decompressed_size: u32,
        // payload of `stored_size` size

        pub const Tag = enum(u8) {
            APPLICATION_INFO = 0,
            SAMPLER = 1,
            DESCRIPTOR_SET_LAYOUT = 2,
            PIPELINE_LAYOUT = 3,
            SHADER_MODULE = 4,
            RENDER_PASS = 5,
            GRAPHICS_PIPELINE = 6,
            COMPUTE_PIPELINE = 7,
            APPLICATION_BLOB_LINK = 8,
            RAYTRACING_PIPELINE = 9,
        };

        pub fn get_tag(entry: *const Entry) !Tag {
            const tag_str = entry.tag_hash[8..24];
            const tag_value = try std.fmt.parseInt(u8, tag_str, 16);
            return @enumFromInt(tag_value);
        }

        pub fn get_value(entry: *const Entry) !u64 {
            const value_str = entry.tag_hash[24..];
            return std.fmt.parseInt(u64, value_str, 16);
        }

        pub fn from_ptr(ptr: EntryPtr) Entry {
            var entry: Entry = undefined;
            const entry_bytes = std.mem.asBytes(&entry);
            var ptr_bytes: []const u8 = undefined;
            ptr_bytes.ptr = ptr;
            ptr_bytes.len = @sizeOf(Entry);
            @memcpy(entry_bytes, ptr_bytes);
            return entry;
        }

        pub fn format(
            value: *const Entry,
            comptime fmt: []const u8,
            options: std.fmt.FormatOptions,
            writer: anytype,
        ) !void {
            _ = fmt;
            _ = options;
            try writer.print("tag: {s:<21} value: 0x{x:<16} stored_size: {d:<6} flags: {d} crc: {d:<10} decompressed_size: {d}", .{
                @tagName(try value.get_tag()),
                try value.get_value(),
                value.stored_size,
                value.flags,
                value.crc,
                value.decompressed_size,
            });
        }
    };
};

pub fn open_database(gpa_alloc: Allocator, arena_alloc: Allocator, path: []const u8) !Database {
    log.info(@src(), "Openning database as path: {s}", .{path});
    const file_mem = try mmap_file(path);

    const header: *const Database.Header = @ptrCast(file_mem.ptr);
    if (!std.mem.eql(u8, &header.magic, Database.MAGIC))
        return error.InvalidMagicValue;

    log.info(@src(), "Stored header version: {d}", .{header.version});

    var entries: std.ArrayListUnmanaged(Database.EntryPtr) = .empty;
    var remaining_file_mem = file_mem[@sizeOf(Database.Header)..];

    while (0 < remaining_file_mem.len) {
        const entry_ptr: Database.EntryPtr = @alignCast(@ptrCast(remaining_file_mem.ptr));
        const entry: Database.Entry = .from_ptr(entry_ptr);
        log.info(@src(), "Found entry: {}", .{entry});

        try entries.append(arena_alloc, entry_ptr);
        remaining_file_mem = remaining_file_mem[@sizeOf(Database.Entry) + entry.stored_size ..];
    }

    return .{
        .file_mem = file_mem,
        .entries = try gpa_alloc.dupe(Database.EntryPtr, entries.items),
    };
}

const VK_VALIDATION_LAYERS_NAMES = [_][*c]const u8{"VK_LAYER_KHRONOS_validation"};
const VK_ADDITIONAL_EXTENSIONS_NAMES = [_][*c]const u8{"VK_EXT_debug_utils"};

pub fn contains_all_extensions(
    log_prefix: []const u8,
    extensions: []const vk.VkExtensionProperties,
    to_find: []const [*c]const u8,
) bool {
    var found_extensions: u32 = 0;
    for (extensions) |e| {
        var required = "--------";
        for (to_find) |tf| {
            const extension_name_span = std.mem.span(@as(
                [*c]const u8,
                @ptrCast(&e.extensionName),
            ));
            const tf_extension_name_span = std.mem.span(@as(
                [*c]const u8,
                tf,
            ));
            if (std.mem.eql(u8, extension_name_span, tf_extension_name_span)) {
                found_extensions += 1;
                required = "required";
            }
        }
        log.debug(@src(), "({s})({s}) Extension version: {d}.{d}.{d} Name: {s}", .{
            required,
            log_prefix,
            vk.VK_API_VERSION_MAJOR(e.specVersion),
            vk.VK_API_VERSION_MINOR(e.specVersion),
            vk.VK_API_VERSION_PATCH(e.specVersion),
            e.extensionName,
        });
    }
    return found_extensions == to_find.len;
}

pub fn contains_all_layers(
    log_prefix: []const u8,
    layers: []const vk.VkLayerProperties,
    to_find: []const [*c]const u8,
) bool {
    var found_layers: u32 = 0;
    for (layers) |l| {
        var required = "--------";
        for (to_find) |tf| {
            const layer_name_span = std.mem.span(@as([*c]const u8, @ptrCast(&l.layerName)));
            const tf_layer_name_span = std.mem.span(@as([*c]const u8, tf));
            if (std.mem.eql(u8, layer_name_span, tf_layer_name_span)) {
                found_layers += 1;
                required = "required";
            }
        }
        log.debug(@src(), "({s})({s}) Layer name: {s} Spec version: {d}.{d}.{d} Description: {s}", .{
            required,
            log_prefix,
            l.layerName,
            vk.VK_API_VERSION_MAJOR(l.specVersion),
            vk.VK_API_VERSION_MINOR(l.specVersion),
            vk.VK_API_VERSION_PATCH(l.specVersion),
            l.description,
        });
    }
    return found_layers == to_find.len;
}

pub fn get_instance_extensions(arena_alloc: Allocator) ![]const vk.VkExtensionProperties {
    var extensions_count: u32 = 0;
    try vk.check_result(vk.vkEnumerateInstanceExtensionProperties.?(
        null,
        &extensions_count,
        null,
    ));
    const extensions = try arena_alloc.alloc(vk.VkExtensionProperties, extensions_count);
    try vk.check_result(vk.vkEnumerateInstanceExtensionProperties.?(
        null,
        &extensions_count,
        extensions.ptr,
    ));
    return extensions;
}

pub fn get_instance_layer_properties(arena_alloc: Allocator) ![]const vk.VkLayerProperties {
    var layer_property_count: u32 = 0;
    try vk.check_result(vk.vkEnumerateInstanceLayerProperties.?(&layer_property_count, null));
    const layers = try arena_alloc.alloc(vk.VkLayerProperties, layer_property_count);
    try vk.check_result(vk.vkEnumerateInstanceLayerProperties.?(
        &layer_property_count,
        layers.ptr,
    ));
    return layers;
}

pub fn create_vk_instance(arena_alloc: Allocator, api_version: u32) !vk.VkInstance {
    const extensions = try get_instance_extensions(arena_alloc);
    if (!contains_all_extensions("Instance", extensions, &VK_ADDITIONAL_EXTENSIONS_NAMES))
        return error.AdditionalExtensionsNotFound;

    const all_extension_names = try arena_alloc.alloc([*c]const u8, extensions.len);
    for (extensions, 0..) |e, i|
        all_extension_names[i] = &e.extensionName;

    const layers = try get_instance_layer_properties(arena_alloc);
    if (!contains_all_layers("Instance", layers, &VK_VALIDATION_LAYERS_NAMES))
        return error.InstanceValidationLayersNotFound;

    const app_info = vk.VkApplicationInfo{
        .sType = vk.VK_STRUCTURE_TYPE_APPLICATION_INFO,
        .pApplicationName = "glacier",
        .applicationVersion = vk.VK_MAKE_VERSION(0, 0, 1),
        .pEngineName = "glacier",
        .engineVersion = vk.VK_MAKE_VERSION(0, 0, 1),
        .apiVersion = api_version,
        .pNext = null,
    };
    const instance_create_info = vk.VkInstanceCreateInfo{
        .sType = vk.VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
        .pApplicationInfo = &app_info,
        .ppEnabledExtensionNames = all_extension_names.ptr,
        .enabledExtensionCount = @as(u32, @intCast(all_extension_names.len)),
        .ppEnabledLayerNames = @ptrCast(&VK_VALIDATION_LAYERS_NAMES),
        .enabledLayerCount = @as(u32, @intCast(VK_VALIDATION_LAYERS_NAMES.len)),
    };

    var vk_instance: vk.VkInstance = undefined;
    try vk.check_result(vk.vkCreateInstance.?(&instance_create_info, null, &vk_instance));
    return vk_instance;
}

pub fn init_debug_callback(instance: vk.VkInstance) void {
    const create_info = vk.VkDebugReportCallbackCreateInfoEXT{
        .sType = vk.VK_STRUCTURE_TYPE_DEBUG_REPORT_CALLBACK_CREATE_INFO_EXT,
        .pfnCallback = debug_callback,
        .flags = vk.VK_DEBUG_REPORT_ERROR_BIT_EXT,
        .pUserData = null,
    };

    try vk.check_result(
        vk.vkCreateDebugReportCallbackEXT.?(instance, &create_info, null, &debug_callback),
    );
}

pub fn debug_callback(
    flags: vk.VkDebugReportFlagsEXT,
    _: vk.VkDebugReportObjectTypeEXT,
    _: u64,
    _: usize,
    _: i32,
    layer: [*c]const u8,
    message: [*c]const u8,
    _: *anyopaque,
) callconv(.c) vk.VkResult {
    if (flags & vk.VK_DEBUG_REPORT_ERROR_BIT_EXT != 0)
        log.err(@src(), "Layer: {s} Message: {s}", .{ layer, message });

    return vk.VK_FALSE;
}

pub fn get_physical_devices(
    arena_alloc: Allocator,
    vk_instance: vk.VkInstance,
) ![]const vk.VkPhysicalDevice {
    var physical_device_count: u32 = 0;
    try vk.check_result(vk.vkEnumeratePhysicalDevices.?(
        vk_instance,
        &physical_device_count,
        null,
    ));
    const physical_devices = try arena_alloc.alloc(
        vk.VkPhysicalDevice,
        physical_device_count,
    );
    try vk.check_result(vk.vkEnumeratePhysicalDevices.?(
        vk_instance,
        &physical_device_count,
        physical_devices.ptr,
    ));
    return physical_devices;
}

pub fn get_physical_divece_exensions(
    arena_alloc: Allocator,
    physical_device: vk.VkPhysicalDevice,
    extension_name: [*c]const u8,
) ![]const vk.VkExtensionProperties {
    var extensions_count: u32 = 0;
    try vk.check_result(vk.vkEnumerateDeviceExtensionProperties.?(
        physical_device,
        extension_name,
        &extensions_count,
        null,
    ));
    const extensions = try arena_alloc.alloc(vk.VkExtensionProperties, extensions_count);
    try vk.check_result(vk.vkEnumerateDeviceExtensionProperties.?(
        physical_device,
        extension_name,
        &extensions_count,
        extensions.ptr,
    ));
    return extensions;
}

pub fn get_physical_device_layers(
    arena_alloc: Allocator,
    physical_device: vk.VkPhysicalDevice,
) ![]const vk.VkLayerProperties {
    var layer_property_count: u32 = 0;
    try vk.check_result(vk.vkEnumerateDeviceLayerProperties.?(
        physical_device,
        &layer_property_count,
        null,
    ));
    const layers = try arena_alloc.alloc(vk.VkLayerProperties, layer_property_count);
    try vk.check_result(vk.vkEnumerateDeviceLayerProperties.?(
        physical_device,
        &layer_property_count,
        layers.ptr,
    ));
    return layers;
}

pub const PhysicalDevice = struct {
    device: vk.VkPhysicalDevice,
    graphics_queue_family: u32,
    has_properties_2: bool,
    has_validation_cache: bool,
};

pub fn select_physical_device(
    arena_alloc: Allocator,
    vk_instance: vk.VkInstance,
) !PhysicalDevice {
    const physical_devices = try get_physical_devices(arena_alloc, vk_instance);

    for (physical_devices) |physical_device| {
        var properties: vk.VkPhysicalDeviceProperties = undefined;
        vk.vkGetPhysicalDeviceProperties.?(physical_device, &properties);

        log.debug(@src(),
            \\ Physical device:
            \\    Name: {s}
            \\    API version: {d}.{d}.{d}
            \\    Driver version: {d}.{d}.{d}
            \\    Vendor ID: {d}
            \\    Device Id: {d}
            \\    Device type: {d}
        , .{
            properties.deviceName,
            vk.VK_API_VERSION_MAJOR(properties.apiVersion),
            vk.VK_API_VERSION_MINOR(properties.apiVersion),
            vk.VK_API_VERSION_PATCH(properties.apiVersion),
            vk.VK_API_VERSION_MAJOR(properties.driverVersion),
            vk.VK_API_VERSION_MINOR(properties.driverVersion),
            vk.VK_API_VERSION_PATCH(properties.driverVersion),
            properties.vendorID,
            properties.deviceID,
            properties.deviceType,
        });

        const extensions = try get_physical_divece_exensions(arena_alloc, physical_device, null);
        const has_properties_2 = contains_all_extensions(
            &properties.deviceName,
            extensions,
            &.{vk.VK_KHR_GET_PHYSICAL_DEVICE_PROPERTIES_2_EXTENSION_NAME},
        );

        const layers = try get_physical_device_layers(arena_alloc, physical_device);
        if (!contains_all_layers(&properties.deviceName, layers, &VK_VALIDATION_LAYERS_NAMES))
            return error.PhysicalDeviceValidationLayersNotFound;

        // With validation layers being mandatory for now, check if caching of the
        // validation layer is available.
        const validation_extensions = try get_physical_divece_exensions(
            arena_alloc,
            physical_device,
            "VK_LAYER_KHRONOS_validation",
        );
        const has_validation_cache = contains_all_extensions(
            &properties.deviceName,
            validation_extensions,
            &.{vk.VK_EXT_VALIDATION_CACHE_EXTENSION_NAME},
        );

        // Because the exact queue does not matter much,
        // select the first queue with graphics capability.
        var queue_family_count: u32 = 0;
        vk.vkGetPhysicalDeviceQueueFamilyProperties.?(physical_device, &queue_family_count, null);
        const queue_families = try arena_alloc.alloc(
            vk.VkQueueFamilyProperties,
            queue_family_count,
        );
        vk.vkGetPhysicalDeviceQueueFamilyProperties.?(
            physical_device,
            &queue_family_count,
            queue_families.ptr,
        );
        var graphics_queue_family: ?u32 = null;
        for (queue_families, 0..) |qf, i| {
            if (qf.queueFlags & vk.VK_QUEUE_GRAPHICS_BIT != 0) {
                graphics_queue_family = @intCast(i);
                break;
            }
        }

        if (graphics_queue_family != null) {
            log.debug(
                @src(),
                "Selected device: {s} Graphics queue family: {d} Has properties 2: {} Has validation cache: {}",
                .{
                    properties.deviceName,
                    graphics_queue_family.?,
                    has_properties_2,
                    has_validation_cache,
                },
            );
            return .{
                .device = physical_device,
                .graphics_queue_family = graphics_queue_family.?,
                .has_properties_2 = has_properties_2,
                .has_validation_cache = has_validation_cache,
            };
        }
    }
    return error.PhysicalDeviceNotSelected;
}

pub fn create_vk_device(
    arena_alloc: Allocator,
    physical_device: *const PhysicalDevice,
) !vk.VkDevice {
    const queue_priority: f32 = 1.0;
    const queue_create_info = vk.VkDeviceQueueCreateInfo{
        .sType = vk.VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
        .queueFamilyIndex = physical_device.graphics_queue_family,
        .queueCount = 1,
        .pQueuePriorities = &queue_priority,
    };

    var features_2 = vk.VkPhysicalDeviceFeatures2{
        .sType = vk.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2,
    };
    if (physical_device.has_properties_2)
        vk.vkGetPhysicalDeviceFeatures2KHR.?(physical_device.device, &features_2)
    else
        vk.vkGetPhysicalDeviceFeatures.?(physical_device.device, &features_2.features);

    // All extensions will be activated for the device. If it
    // supports validation caching, enable it's extension as well.
    const extensions =
        try get_physical_divece_exensions(arena_alloc, physical_device.device, null);
    var all_extensions_len = extensions.len;
    if (physical_device.has_validation_cache)
        all_extensions_len += 1;
    const all_extension_names = try arena_alloc.alloc([*c]const u8, all_extensions_len);
    for (extensions, 0..) |e, i|
        all_extension_names[i] = &e.extensionName;
    if (physical_device.has_validation_cache)
        all_extension_names[all_extensions_len - 1] = vk.VK_EXT_VALIDATION_CACHE_EXTENSION_NAME;

    const create_info = vk.VkDeviceCreateInfo{
        .sType = vk.VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
        .pQueueCreateInfos = &queue_create_info,
        .queueCreateInfoCount = 1,
        .ppEnabledLayerNames = @ptrCast(&VK_VALIDATION_LAYERS_NAMES),
        .enabledLayerCount = @as(u32, @intCast(VK_VALIDATION_LAYERS_NAMES.len)),
        .ppEnabledExtensionNames = all_extension_names.ptr,
        .enabledExtensionCount = @as(u32, @intCast(all_extension_names.len)),
        .pEnabledFeatures = if (physical_device.has_properties_2) null else &features_2.features,
        .pNext = if (physical_device.has_properties_2) &features_2 else null,
    };

    var vk_device: vk.VkDevice = undefined;
    try vk.check_result(vk.vkCreateDevice.?(
        physical_device.device,
        &create_info,
        null,
        &vk_device,
    ));
    return vk_device;
}
