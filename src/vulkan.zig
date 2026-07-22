// Copyright (c) 2026 Egor Lazarchuk
//
// Based in part on Fossilize project which is:
// Copyright (c) 2026 Hans-Kristian Arntzen
//
// SPDX-License-Identifier: MIT

const std = @import("std");
const log = @import("log.zig");
const parsing = @import("parsing.zig");
const profiler = @import("profiler.zig");
const vv = @import("vk_validation.zig");
const vu = @import("vk_utils.zig");
const vk = @import("vk.zig");

const Allocator = std.mem.Allocator;
const Database = @import("database.zig");

pub const MEASUREMENTS = profiler.Measurements(
    "vulkan",
    profiler.all_function_names_in_struct(@This()),
);

pub fn init(
    arena_alloc: Allocator,
    tmp_alloc: Allocator,
    db: *const Database,
    enable_vulkan_validation_layers: bool,
    validation: *vv.Validation,
) !struct { vk.VkInstance, vk.VkDevice } {
    const get_proc = try load_vulkan();
    try load_basic_procs(get_proc);

    const instance_api_version = get_instance_api_version();
    log.info(@src(), "Supported vulkan instance version: {f}", .{instance_api_version});
    const default_app_info: vk.VkApplicationInfo = .{
        .pApplicationName = "replayer",
        .applicationVersion = .{ .patch = 1 },
        .pEngineName = "replayer",
        .engineVersion = .{ .patch = 1 },
        .apiVersion = instance_api_version,
        .pNext = null,
    };
    var app_info: *const vk.VkApplicationInfo = &default_app_info;
    var device_features2: ?*const vk.VkPhysicalDeviceFeatures2 = null;
    try configure_app_info(arena_alloc, tmp_alloc, db, &app_info, &device_features2);

    const instance = try create_vk_instance(tmp_alloc, app_info, enable_vulkan_validation_layers);
    try load_instance_procs(get_proc, instance.instance);

    if (enable_vulkan_validation_layers)
        _ = try init_debug_callback(instance.instance);

    const physical_device = try select_physical_device(
        tmp_alloc,
        &instance,
        enable_vulkan_validation_layers,
    );

    const device = try create_vk_device(
        tmp_alloc,
        &instance,
        &physical_device,
        app_info,
        device_features2,
        &validation.pdf,
        &validation.additional_pdf,
        &validation.additional_properties,
        enable_vulkan_validation_layers,
    );
    validation.api_version = instance.api_version;
    validation.extensions = try .init(
        tmp_alloc,
        instance.api_version,
        instance.all_extension_names,
        device.all_extension_names,
    );

    return .{ instance.instance, device.device };
}

// Ensure that the asynchronous writes to the shader cache initiated by the
// driver will finish before the application exits.
// Mesa does the clean up in the disk_cache.c: disk_cache_destroy function which is called by
// drivers on vkDestroyInstance.
pub fn deinit(instance: vk.VkInstance, device: vk.VkDevice) void {
    vkDestroyDevice(device, null);
    vkDestroyInstance(instance, null);
}

const VK_VALIDATION_LAYERS_NAMES = [_][*c]const u8{"VK_LAYER_KHRONOS_validation"};
const VK_ADDITIONAL_EXTENSIONS_NAMES = [_][*c]const u8{"VK_EXT_debug_utils"};

fn load_vulkan() !*const vk.vkGetInstanceProcAddr {
    var lib = std.c.dlopen("libvulkan.so.1", .{ .NOW = true });
    if (lib == null) {
        log.debug(@src(), "Cannot load libvulkan.so.1. Trying libvulkan.so", .{});
        lib = std.c.dlopen("libvulkan.so", .{ .NOW = true });
    }
    if (lib == null) {
        log.err(@src(), "Could not load libvulkan.so.1 or libvulkan.so", .{});
        return error.LoadVulkan;
    }

    const instance_proc_addr: *const vk.vkGetInstanceProcAddr = @ptrCast(@alignCast(std.c.dlsym(lib, "vkGetInstanceProcAddr").?));
    return instance_proc_addr;
}

var vkCreateInstance: *const vk.vkCreateInstance = undefined;
var vkEnumerateInstanceExtensionProperties: *const vk.vkEnumerateInstanceExtensionProperties =
    undefined;
var vkEnumerateInstanceLayerProperties: *const vk.vkEnumerateInstanceLayerProperties = undefined;
var vkEnumerateInstanceVersion: ?*const vk.vkEnumerateInstanceVersion = null;

fn load_basic_procs(get_proc: *const vk.vkGetInstanceProcAddr) !void {
    try load_procs(get_proc, .none, &.{
        "vkCreateInstance",
        "vkEnumerateInstanceExtensionProperties",
        "vkEnumerateInstanceLayerProperties",
        "vkEnumerateInstanceVersion",
    });
}

var vkDestroyInstance: *const vk.vkDestroyInstance = undefined;
var vkCreateDebugReportCallbackEXT: ?*const vk.vkCreateDebugReportCallbackEXT = null;
var vkEnumeratePhysicalDevices: *const vk.vkEnumeratePhysicalDevices = undefined;
var vkGetPhysicalDeviceProperties: *const vk.vkGetPhysicalDeviceProperties = undefined;
var vkGetPhysicalDeviceProperties2KHR: *const vk.vkGetPhysicalDeviceProperties2KHR = undefined;
var vkGetPhysicalDeviceFeatures: *const vk.vkGetPhysicalDeviceFeatures = undefined;
var vkGetPhysicalDeviceFeatures2KHR: *const vk.vkGetPhysicalDeviceFeatures2KHR = undefined;
var vkGetPhysicalDeviceQueueFamilyProperties: *const vk.vkGetPhysicalDeviceQueueFamilyProperties = undefined;
var vkEnumerateDeviceLayerProperties: *const vk.vkEnumerateDeviceLayerProperties = undefined;
var vkEnumerateDeviceExtensionProperties: *const vk.vkEnumerateDeviceExtensionProperties = undefined;
var vkCreateDevice: *const vk.vkCreateDevice = undefined;
var vkDestroyDevice: *const vk.vkDestroyDevice = undefined;
var vkCreatePipelineLayout: *const vk.vkCreatePipelineLayout = undefined;
var vkDestroyPipelineLayout: *const vk.vkDestroyPipelineLayout = undefined;
var vkCreateShaderModule: *const vk.vkCreateShaderModule = undefined;
var vkDestroyShaderModule: *const vk.vkDestroyShaderModule = undefined;
var vkCreateRenderPass: *const vk.vkCreateRenderPass = undefined;
var vkCreateRenderPass2: *const vk.vkCreateRenderPass2 = undefined;
var vkDestroyRenderPass: *const vk.vkDestroyRenderPass = undefined;
var vkCreateGraphicsPipelines: *const vk.vkCreateGraphicsPipelines = undefined;
var vkCreateComputePipelines: *const vk.vkCreateComputePipelines = undefined;
var vkCreateRayTracingPipelinesKHR: *const vk.vkCreateRayTracingPipelinesKHR = undefined;
var vkDestroyPipeline: *const vk.vkDestroyPipeline = undefined;
var vkCreateSampler: *const vk.vkCreateSampler = undefined;
var vkDestroySampler: *const vk.vkDestroySampler = undefined;
var vkCreateDescriptorSetLayout: *const vk.vkCreateDescriptorSetLayout = undefined;
var vkDestroyDescriptorSetLayout: *const vk.vkDestroyDescriptorSetLayout = undefined;

fn load_instance_procs(
    get_proc: *const vk.vkGetInstanceProcAddr,
    instance: vk.VkInstance,
) !void {
    try load_procs(
        get_proc,
        instance,
        &.{
            "vkDestroyInstance",
            "vkCreateDebugReportCallbackEXT",
            "vkEnumeratePhysicalDevices",
            "vkGetPhysicalDeviceProperties",
            "vkGetPhysicalDeviceProperties2KHR",
            "vkGetPhysicalDeviceFeatures",
            "vkGetPhysicalDeviceFeatures2KHR",
            "vkGetPhysicalDeviceQueueFamilyProperties",
            "vkEnumerateDeviceLayerProperties",
            "vkEnumerateDeviceExtensionProperties",
            "vkCreateDevice",
            "vkDestroyDevice",
            "vkCreatePipelineLayout",
            "vkDestroyPipelineLayout",
            "vkCreateShaderModule",
            "vkDestroyShaderModule",
            "vkCreateRenderPass",
            "vkCreateRenderPass2",
            "vkDestroyRenderPass",
            "vkCreateGraphicsPipelines",
            "vkCreateComputePipelines",
            "vkCreateRayTracingPipelinesKHR",
            "vkDestroyPipeline",
            "vkCreateSampler",
            "vkDestroySampler",
            "vkCreateDescriptorSetLayout",
            "vkDestroyDescriptorSetLayout",
        },
    );
}

fn load_procs(
    get_proc: *const vk.vkGetInstanceProcAddr,
    instance: vk.VkInstance,
    comptime names: []const [:0]const u8,
) !void {
    inline for (names) |name| {
        const f = &@field(@This(), name);
        const type_info = @typeInfo(@TypeOf(f));
        const child_type_info = @typeInfo(type_info.pointer.child);
        if (child_type_info != .optional) {
            const proc = get_proc(instance, name);
            log.assert(@src(), proc != null, "Cannot load {s} function", .{name});
            f.* = @ptrCast(proc.?);
        } else {
            log.info(@src(), "Getting optional function: {s}", .{name});
            if (get_proc(instance, name)) |proc| {
                f.* = @ptrCast(proc);
            } else {
                log.warn(@src(), "Cannot load optional {s} function", .{name});
            }
        }
    }
}

fn get_instance_api_version() vk.ApiVersion {
    var version: vk.ApiVersion = vk.VK_API_VERSION_1_0;
    if (vkEnumerateInstanceVersion) |f| {
        if (f(@ptrCast(&version)) != .VK_SUCCESS)
            log.warn(@src(), "Cannot get instance version, defaulting to version 1.0.0", .{});
    } else {
        log.warn(@src(), "No vkEnumerateInstanceVersion available, defaulting to version 1.0.0", .{});
    }
    return version;
}

fn configure_app_info(
    arena_alloc: Allocator,
    tmp_alloc: Allocator,
    db: *const Database,
    app_info: **const vk.VkApplicationInfo,
    device_features2: *?*const vk.VkPhysicalDeviceFeatures2,
) !void {
    const app_infos = db.entries.getPtrConst(.application_info).values();
    if (app_infos.len != 0) {
        const app_info_entry = &app_infos[0];
        const app_info_payload = try app_info_entry.get_payload(arena_alloc, tmp_alloc, db);
        const parsed_application_info = try parsing.parse_application_info(
            arena_alloc,
            tmp_alloc,
            db,
            app_info_payload,
        );
        if (parsed_application_info.version != 6)
            return error.ApllicationInfoVersionMissmatch;

        log.info(
            @src(),
            "Requested app info vulkan version: {f}",
            .{parsed_application_info.application_info.apiVersion},
        );
        if (app_info.*.apiVersion.less(parsed_application_info.application_info.apiVersion)) {
            log.err(@src(), "Requested vulkan api version is above the supported version", .{});
            return error.UnsupportedVulkanApiVersion;
        }

        app_info.* = parsed_application_info.application_info;
        device_features2.* = parsed_application_info.device_features2;
    }
}

fn check_result(result: vk.VkResult) !void {
    if (result != .VK_SUCCESS) {
        log.err(@src(), "vk error: {t}", .{result});
        return error.VkError;
    }
}

pub fn contains_all_extensions(
    log_prefix: ?[]const u8,
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
        if (log_prefix) |lp| {
            const version: vk.ApiVersion = @bitCast(e.specVersion);
            log.debug(
                @src(),
                "({s})({s}) Extension version: {f} Name: {s}",
                .{ required, lp, version, e.extensionName },
            );
        }
    }
    return found_extensions == to_find.len;
}

pub fn contains_all_layers(
    log_prefix: ?[]const u8,
    layers: []const vk.VkLayerProperties,
    to_find: []const [*c]const u8,
) bool {
    const prof_point = MEASUREMENTS.start(@src());
    defer MEASUREMENTS.end(prof_point);

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
        if (log_prefix) |lp| {
            const version: vk.ApiVersion = @bitCast(l.specVersion);
            log.debug(
                @src(),
                "({s})({s}) Layer name: {s} Spec version: {f} Description: {s}",
                .{ required, lp, l.layerName, version, l.description },
            );
        }
    }
    return found_layers == to_find.len;
}

pub fn get_instance_extensions(arena_alloc: Allocator) ![]const vk.VkExtensionProperties {
    const prof_point = MEASUREMENTS.start(@src());
    defer MEASUREMENTS.end(prof_point);

    var extensions_count: u32 = 0;
    try check_result(vkEnumerateInstanceExtensionProperties(
        null,
        &extensions_count,
        null,
    ));
    const extensions = try arena_alloc.alloc(vk.VkExtensionProperties, extensions_count);
    try check_result(vkEnumerateInstanceExtensionProperties(
        null,
        &extensions_count,
        extensions.ptr,
    ));
    return extensions;
}

pub fn get_instance_layer_properties(arena_alloc: Allocator) ![]const vk.VkLayerProperties {
    const prof_point = MEASUREMENTS.start(@src());
    defer MEASUREMENTS.end(prof_point);

    var layer_property_count: u32 = 0;
    try check_result(vkEnumerateInstanceLayerProperties(&layer_property_count, null));
    const layers = try arena_alloc.alloc(vk.VkLayerProperties, layer_property_count);
    try check_result(vkEnumerateInstanceLayerProperties(
        &layer_property_count,
        layers.ptr,
    ));
    return layers;
}

pub const Instance = struct {
    instance: vk.VkInstance,
    api_version: vk.ApiVersion,
    has_properties_2: bool,
    all_extension_names: []const [*c]const u8,
};
pub fn create_vk_instance(
    arena_alloc: Allocator,
    app_info: *const vk.VkApplicationInfo,
    enable_validation: bool,
) !Instance {
    const prof_point = MEASUREMENTS.start(@src());
    defer MEASUREMENTS.end(prof_point);

    const extensions = try get_instance_extensions(arena_alloc);
    if (!contains_all_extensions("Instance", extensions, &VK_ADDITIONAL_EXTENSIONS_NAMES))
        return error.AdditionalExtensionsNotFound;

    const has_properties_2 = contains_all_extensions(
        null,
        extensions,
        &.{"VK_KHR_get_physical_device_properties2"},
    );

    const all_extension_names = try arena_alloc.alloc([*c]const u8, extensions.len);
    for (extensions, 0..) |*e, i|
        all_extension_names[i] = &e.extensionName;

    const enabled_layers = if (enable_validation) blk: {
        const layers = try get_instance_layer_properties(arena_alloc);
        if (!contains_all_layers("Instance", layers, &VK_VALIDATION_LAYERS_NAMES))
            return error.InstanceValidationLayersNotFound;
        break :blk &VK_VALIDATION_LAYERS_NAMES;
    } else &.{};

    {
        log.info(
            @src(),
            "Creating instance with application name: {s} engine name: {s} engine version: {d} api version: {f}",
            .{
                app_info.pApplicationName.?,
                app_info.pEngineName.?,
                @as(u32, @bitCast(app_info.engineVersion)),
                app_info.apiVersion,
            },
        );
    }
    for (all_extension_names) |name|
        log.debug(@src(), "(Inastance) Enabled extension: {s}", .{name});
    for (enabled_layers) |name|
        log.debug(@src(), "(Inastance) Enabled layer: {s}", .{name});

    const instance_create_info = vk.VkInstanceCreateInfo{
        .pApplicationInfo = app_info,
        .ppEnabledExtensionNames = @ptrCast(all_extension_names.ptr),
        .enabledExtensionCount = @as(u32, @intCast(all_extension_names.len)),
        .ppEnabledLayerNames = @ptrCast(enabled_layers.ptr),
        .enabledLayerCount = @as(u32, @intCast(enabled_layers.len)),
    };

    var vk_instance: vk.VkInstance = undefined;
    try check_result(vkCreateInstance(&instance_create_info, null, &vk_instance));
    {
        log.debug(
            @src(),
            "Created instance api version: {f} has_properties_2: {}",
            .{ app_info.apiVersion, has_properties_2 },
        );
    }
    return .{
        .instance = vk_instance,
        .api_version = app_info.apiVersion,
        .has_properties_2 = has_properties_2,
        .all_extension_names = all_extension_names,
    };
}

pub fn init_debug_callback(instance: vk.VkInstance) !vk.VkDebugReportCallbackEXT {
    const prof_point = MEASUREMENTS.start(@src());
    defer MEASUREMENTS.end(prof_point);

    const create_info = vk.VkDebugReportCallbackCreateInfoEXT{
        .pfnCallback = debug_callback,
        .flags = .{
            .VK_DEBUG_REPORT_ERROR_BIT_EXT = true,
            .VK_DEBUG_REPORT_WARNING_BIT_EXT = true,
        },
        .pUserData = null,
    };

    var callback: vk.VkDebugReportCallbackEXT = undefined;
    if (vkCreateDebugReportCallbackEXT) |create|
        try check_result(
            create(
                instance,
                &create_info,
                null,
                &callback,
            ),
        );
    return callback;
}

pub fn debug_callback(
    flags: vk.VkDebugReportFlagsEXT,
    _: vk.VkDebugReportObjectTypeEXT,
    _: u64,
    _: usize,
    _: i32,
    layer: [*c]const u8,
    message: [*c]const u8,
    _: ?*anyopaque,
) callconv(.c) vk.VkBool32 {
    if (flags.VK_DEBUG_REPORT_WARNING_BIT_EXT)
        log.warn(@src(), "Layer: {s} Message: {s}", .{ layer, message });
    if (flags.VK_DEBUG_REPORT_ERROR_BIT_EXT)
        log.err(@src(), "Layer: {s} Message: {s}", .{ layer, message });

    return vk.VK_FALSE;
}

pub fn get_physical_devices(
    arena_alloc: Allocator,
    vk_instance: vk.VkInstance,
) ![]const vk.VkPhysicalDevice {
    const prof_point = MEASUREMENTS.start(@src());
    defer MEASUREMENTS.end(prof_point);

    var physical_device_count: u32 = 0;
    try check_result(vkEnumeratePhysicalDevices(
        vk_instance,
        &physical_device_count,
        null,
    ));
    const physical_devices = try arena_alloc.alloc(
        vk.VkPhysicalDevice,
        physical_device_count,
    );
    try check_result(vkEnumeratePhysicalDevices(
        vk_instance,
        &physical_device_count,
        physical_devices.ptr,
    ));
    return physical_devices;
}

pub fn get_physical_device_exensions(
    arena_alloc: Allocator,
    physical_device: vk.VkPhysicalDevice,
    extension_name: [*c]const u8,
) ![]const vk.VkExtensionProperties {
    const prof_point = MEASUREMENTS.start(@src());
    defer MEASUREMENTS.end(prof_point);

    var extensions_count: u32 = 0;
    try check_result(vkEnumerateDeviceExtensionProperties(
        physical_device,
        extension_name,
        &extensions_count,
        null,
    ));
    const extensions = try arena_alloc.alloc(vk.VkExtensionProperties, extensions_count);
    try check_result(vkEnumerateDeviceExtensionProperties(
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
    const prof_point = MEASUREMENTS.start(@src());
    defer MEASUREMENTS.end(prof_point);

    var layer_property_count: u32 = 0;
    try check_result(vkEnumerateDeviceLayerProperties(
        physical_device,
        &layer_property_count,
        null,
    ));
    const layers = try arena_alloc.alloc(vk.VkLayerProperties, layer_property_count);
    try check_result(vkEnumerateDeviceLayerProperties(
        physical_device,
        &layer_property_count,
        layers.ptr,
    ));
    return layers;
}

pub const PhysicalDevice = struct {
    device: vk.VkPhysicalDevice,
    graphics_queue_family: u32,
    has_validation_cache: bool,
};

pub fn select_physical_device(
    arena_alloc: Allocator,
    instance: *const Instance,
    enable_validation: bool,
) !PhysicalDevice {
    const prof_point = MEASUREMENTS.start(@src());
    defer MEASUREMENTS.end(prof_point);

    const physical_devices = try get_physical_devices(arena_alloc, instance.instance);
    for (physical_devices) |physical_device| {
        var properties: vk.VkPhysicalDeviceProperties = undefined;
        vkGetPhysicalDeviceProperties(physical_device, &properties);

        const api_version: vk.ApiVersion = @bitCast(properties.apiVersion);
        const driver_version: vk.ApiVersion = @bitCast(properties.driverVersion);
        log.debug(@src(),
            \\ Physical device:
            \\    Name: {s}
            \\    API version: {f}
            \\    Driver version: {f}
            \\    Vendor ID: {d}
            \\    Device Id: {d}
            \\    Device type: {d}
        , .{
            properties.deviceName,
            api_version,
            driver_version,
            properties.vendorID,
            properties.deviceID,
            properties.deviceType,
        });

        if (api_version.less(instance.api_version)) {
            log.debug(
                @src(),
                "GPU supported API version {f} is lower than requested API version {f}. Skipping",
                .{ api_version, instance.api_version },
            );
            continue;
        }

        const has_validation_cache = if (enable_validation) blk: {
            const layers = try get_physical_device_layers(arena_alloc, physical_device);
            if (!contains_all_layers(&properties.deviceName, layers, &VK_VALIDATION_LAYERS_NAMES))
                return error.PhysicalDeviceValidationLayersNotFound;

            const validation_extensions = try get_physical_device_exensions(
                arena_alloc,
                physical_device,
                "VK_LAYER_KHRONOS_validation",
            );
            break :blk contains_all_extensions(
                null,
                validation_extensions,
                &.{"VK_EXT_validation_cache"},
            );
        } else false;

        // Because the exact queue does not matter much,
        // select the first queue with graphics capability.
        var queue_family_count: u32 = 0;
        vkGetPhysicalDeviceQueueFamilyProperties(physical_device, &queue_family_count, null);
        const queue_families = try arena_alloc.alloc(
            vk.VkQueueFamilyProperties,
            queue_family_count,
        );
        vkGetPhysicalDeviceQueueFamilyProperties(
            physical_device,
            &queue_family_count,
            queue_families.ptr,
        );
        var graphics_queue_family: ?u32 = null;
        for (queue_families, 0..) |qf, i| {
            if (qf.queueFlags.VK_QUEUE_GRAPHICS_BIT) {
                graphics_queue_family = @intCast(i);
                break;
            }
        }

        if ((properties.deviceType == .VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU or
            properties.deviceType == .VK_PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU) and
            graphics_queue_family != null)
        {
            log.debug(
                @src(),
                "Selected device: {s} Graphics queue family: {d} Has validation cache: {}",
                .{
                    properties.deviceName,
                    graphics_queue_family.?,
                    has_validation_cache,
                },
            );
            return .{
                .device = physical_device,
                .graphics_queue_family = graphics_queue_family.?,
                .has_validation_cache = has_validation_cache,
            };
        }
    }
    return error.PhysicalDeviceNotSelected;
}

pub fn usable_device_extension(
    ext: [*c]const u8,
    all_ext_props: []const vk.VkExtensionProperties,
    api_version: vk.ApiVersion,
) bool {
    const prof_point = MEASUREMENTS.start(@src());
    defer MEASUREMENTS.end(prof_point);

    const e = std.mem.span(ext);
    if (std.mem.eql(u8, e, "VK_AMD_negative_viewport_height"))
        // illigal to enable with maintenance1
        return false;
    if (std.mem.eql(u8, e, "VK_NV_ray_tracing"))
        // causes problems with pipeline replaying
        return false;
    if (std.mem.eql(u8, e, "VK_AMD_shader_info"))
        // Mesa disables shader cache when thisi is enabled.
        return false;
    if (std.mem.eql(u8, e, "VK_EXT_buffer_device_address"))
        for (all_ext_props) |other_ext| {
            const other_e = std.mem.span(@as([*c]const u8, @ptrCast(&other_ext.extensionName)));
            if (std.mem.eql(u8, other_e, "VK_KHR_buffer_device_address"))
                return false;
        };

    const VK_1_1_EXTS: []const [:0]const u8 = &.{
        vk.VK_KHR_shader_subgroup_extended_types_name,
        vk.VK_KHR_spirv_1_4_name,
        vk.VK_KHR_shared_presentable_image_name,
        vk.VK_KHR_shader_float_controls_name,
        vk.VK_KHR_acceleration_structure_name,
        vk.VK_KHR_ray_tracing_pipeline_name,
        vk.VK_KHR_ray_query_name,
        vk.VK_KHR_maintenance4_name,
        vk.VK_KHR_shader_subgroup_uniform_control_flow_name,
        vk.VK_EXT_subgroup_size_control_name,
        vk.VK_NV_shader_sm_builtins_name,
        vk.VK_NV_shader_subgroup_partitioned_name,
        vk.VK_NV_device_generated_commands_name,
    };

    var is_vk_1_1_ext: bool = false;
    for (VK_1_1_EXTS) |vk_1_1_ext|
        if (std.mem.eql(u8, vk_1_1_ext, e)) {
            is_vk_1_1_ext = true;
            break;
        };

    if (@as(u32, @bitCast(api_version)) < @as(u32, @bitCast(vk.VK_API_VERSION_1_1)) and
        is_vk_1_1_ext)
    {
        return false;
    }

    return true;
}

pub fn find_pnext(stype: vk.VkStructureType, item: ?*const anyopaque) ?*anyopaque {
    const prof_point = MEASUREMENTS.start(@src());
    defer MEASUREMENTS.end(prof_point);

    var pnext: ?*const vk.VkBaseInStructure = @ptrCast(@alignCast(item));
    while (pnext) |next| {
        pnext = next.pNext;
        if (next.sType == stype) return @ptrCast(@constCast(next));
    }
    return null;
}

pub fn filter_features(
    current_pdf: *vk.VkPhysicalDeviceFeatures2,
    additional_pdf: *vv.AdditionalPDF,
    wanted_pdf: ?*const vk.VkPhysicalDeviceFeatures2,
) void {
    const prof_point = MEASUREMENTS.start(@src());
    defer MEASUREMENTS.end(prof_point);

    const Inner = struct {
        fn reset(item: anytype) void {
            const child = @typeInfo(@TypeOf(item)).pointer.child;
            const type_info = @typeInfo(child).@"struct";
            inline for (type_info.fields) |field| {
                if (field.type == vk.VkBool32) @field(item, field.name) = vk.VK_FALSE;
            }
        }
        fn apply(comptime T: type, item1: *T, item2: *const T) void {
            const type_info = @typeInfo(T).@"struct";
            inline for (type_info.fields) |field| {
                if (field.type == vk.VkBool32) {
                    @field(item1, field.name) =
                        @field(item1, field.name) & @field(item2, field.name);
                }
            }
        }
    };
    // These feature bits conflict according to validation layers.
    if (additional_pdf.VkPhysicalDeviceFragmentShadingRateFeaturesKHR.pipelineFragmentShadingRate == vk.VK_TRUE or
        additional_pdf.VkPhysicalDeviceFragmentShadingRateFeaturesKHR.attachmentFragmentShadingRate == vk.VK_TRUE or
        additional_pdf.VkPhysicalDeviceFragmentShadingRateFeaturesKHR.primitiveFragmentShadingRate == vk.VK_TRUE)
    {
        additional_pdf.VkPhysicalDeviceShadingRateImageFeaturesNV.shadingRateImage = vk.VK_FALSE;
        additional_pdf.VkPhysicalDeviceShadingRateImageFeaturesNV.shadingRateCoarseSampleOrder = vk.VK_FALSE;
        additional_pdf.VkPhysicalDeviceFragmentDensityMapFeaturesEXT.fragmentDensityMap =
            vk.VK_FALSE;
    }

    // Only enable robustness if requested since it affects compilation on most implementations.
    if (wanted_pdf) |wf| {
        current_pdf.features.robustBufferAccess = current_pdf.features.robustBufferAccess & wf.features.robustBufferAccess;
        const PATCH_TYPES: []const struct { type, []const u8 } = &.{
            .{
                vk.VkPhysicalDeviceRobustness2FeaturesKHR,
                "VkPhysicalDeviceRobustness2FeaturesKHR",
            },
            .{
                vk.VkPhysicalDeviceImageRobustnessFeatures,
                "VkPhysicalDeviceImageRobustnessFeatures",
            },
            .{
                vk.VkPhysicalDeviceFragmentShadingRateEnumsFeaturesNV,
                "VkPhysicalDeviceFragmentShadingRateEnumsFeaturesNV",
            },
            .{
                vk.VkPhysicalDeviceFragmentShadingRateFeaturesKHR,
                "VkPhysicalDeviceFragmentShadingRateFeaturesKHR",
            },
            .{
                vk.VkPhysicalDeviceMeshShaderFeaturesEXT,
                "VkPhysicalDeviceMeshShaderFeaturesEXT",
            },
            .{
                vk.VkPhysicalDeviceMeshShaderFeaturesNV,
                "VkPhysicalDeviceMeshShaderFeaturesNV",
            },
            .{
                vk.VkPhysicalDeviceDescriptorBufferFeaturesEXT,
                "VkPhysicalDeviceDescriptorBufferFeaturesEXT",
            },
            .{
                vk.VkPhysicalDeviceShaderObjectFeaturesEXT,
                "VkPhysicalDeviceShaderObjectFeaturesEXT",
            },
            .{
                vk.VkPhysicalDevicePrimitivesGeneratedQueryFeaturesEXT,
                "VkPhysicalDevicePrimitivesGeneratedQueryFeaturesEXT",
            },
            .{
                vk.VkPhysicalDeviceImage2DViewOf3DFeaturesEXT,
                "VkPhysicalDeviceImage2DViewOf3DFeaturesEXT",
            },
        };
        inline for (PATCH_TYPES) |pt| {
            const T, const field = pt;

            if (find_pnext(
                T.STYPE,
                wf.pNext,
            )) |item| {
                const found: *const T = @ptrCast(@alignCast(item));
                Inner.apply(T, &@field(additional_pdf, field), found);
            } else Inner.reset(&@field(additional_pdf, field));
        }
    } else {
        current_pdf.features.robustBufferAccess = vk.VK_FALSE;
        Inner.reset(&additional_pdf.VkPhysicalDeviceRobustness2FeaturesKHR);
        Inner.reset(&additional_pdf.VkPhysicalDeviceImageRobustnessFeatures);
        Inner.reset(&additional_pdf.VkPhysicalDeviceFragmentShadingRateEnumsFeaturesNV);
        Inner.reset(&additional_pdf.VkPhysicalDeviceFragmentShadingRateFeaturesKHR);
        Inner.reset(&additional_pdf.VkPhysicalDeviceMeshShaderFeaturesEXT);
        Inner.reset(&additional_pdf.VkPhysicalDeviceMeshShaderFeaturesNV);
        Inner.reset(&additional_pdf.VkPhysicalDeviceDescriptorBufferFeaturesEXT);
        Inner.reset(&additional_pdf.VkPhysicalDeviceShaderObjectFeaturesEXT);
        Inner.reset(&additional_pdf.VkPhysicalDevicePrimitivesGeneratedQueryFeaturesEXT);
        Inner.reset(&additional_pdf.VkPhysicalDeviceImage2DViewOf3DFeaturesEXT);
    }
}

pub fn filter_active_extensions(
    current_features: *vk.VkPhysicalDeviceFeatures2,
    all_extenson_names: [][*c]const u8,
) [][*c]const u8 {
    const prof_point = MEASUREMENTS.start(@src());
    defer MEASUREMENTS.end(prof_point);

    const Inner = struct {
        fn all_disabled(item: anytype) bool {
            const child = @typeInfo(@TypeOf(item)).pointer.child;
            const type_info = @typeInfo(child).@"struct";
            inline for (type_info.fields) |field| {
                if (field.type == vk.VkBool32)
                    if (@field(item, field.name) == vk.VK_TRUE)
                        return false;
            }
            return true;
        }
        fn remove_from_slice(slice: [][*c]const u8, value: []const u8) [][*c]const u8 {
            for (slice, 0..) |name, i| {
                const n: [:0]const u8 = std.mem.span(name);
                if (std.mem.eql(u8, n, value)) {
                    slice[i] = slice[slice.len - 1];
                    return slice[0 .. slice.len - 1];
                }
            }
            return slice;
        }
    };
    var current_pnext: ?*const vk.VkBaseInStructure =
        @ptrCast(@alignCast(current_features.pNext));
    current_features.pNext = null;
    var last_pnext: *?*anyopaque = &current_features.pNext;
    var result: [][*c]const u8 = all_extenson_names;
    while (current_pnext) |current| {
        current_pnext = current.pNext;
        var accept: bool = true;

        const PATCH_TYPES: []const struct { type, []const u8 } = &.{
            .{
                vk.VkPhysicalDeviceFragmentShadingRateEnumsFeaturesNV,
                vk.VK_NV_fragment_shading_rate_enums_name,
            },
            .{
                vk.VkPhysicalDeviceFragmentShadingRateFeaturesKHR,
                vk.VK_KHR_fragment_shading_rate_name,
            },
            .{
                vk.VkPhysicalDeviceRobustness2FeaturesEXT,
                vk.VK_EXT_robustness2_name,
            },
            .{
                vk.VkPhysicalDeviceImageRobustnessFeaturesEXT,
                vk.VK_EXT_image_robustness_name,
            },
            .{
                vk.VkPhysicalDeviceMeshShaderFeaturesEXT,
                vk.VK_EXT_mesh_shader_name,
            },
            .{
                vk.VkPhysicalDeviceMeshShaderFeaturesNV,
                vk.VK_EXT_mesh_shader_name,
            },
            .{
                vk.VkPhysicalDeviceDescriptorBufferFeaturesEXT,
                vk.VK_EXT_descriptor_buffer_name,
            },
            .{
                vk.VkPhysicalDeviceShaderObjectFeaturesEXT,
                vk.VK_EXT_shader_object_name,
            },
            .{
                vk.VkPhysicalDevicePrimitivesGeneratedQueryFeaturesEXT,
                vk.VK_EXT_primitives_generated_query_name,
            },
            .{
                vk.VkPhysicalDeviceImage2DViewOf3DFeaturesEXT,
                vk.VK_EXT_image_2d_view_of_3d_name,
            },
        };

        inline for (PATCH_TYPES) |pt| {
            const T, const name = pt;

            if (current.sType == T.STYPE) {
                const feature: *const T = @ptrCast(@alignCast(current));
                if (Inner.all_disabled(feature)) {
                    log.debug(@src(), "Filtering out {s} from device extensions", .{name});
                    result = Inner.remove_from_slice(result, name);
                    accept = false;
                }
            }
        }

        if (accept) {
            last_pnext.* = @ptrCast(@constCast(current));
            last_pnext = @ptrCast(@constCast(&current.pNext));
            last_pnext.* = null;
        }
    }
    return result;
}

pub const Device = struct {
    device: vk.VkDevice,
    all_extension_names: []const [*c]const u8,
};
pub fn create_vk_device(
    arena_alloc: Allocator,
    instance: *const Instance,
    physical_device: *const PhysicalDevice,
    application_create_info: *const vk.VkApplicationInfo,
    wanted_physical_device_features2: ?*const vk.VkPhysicalDeviceFeatures2,
    pdf: *vk.VkPhysicalDeviceFeatures2,
    additional_pdf: *vv.AdditionalPDF,
    additional_properties: *vv.AdditionalProperties,
    enable_validation: bool,
) !Device {
    const prof_point = MEASUREMENTS.start(@src());
    defer MEASUREMENTS.end(prof_point);

    // All extensions will be activated for the device. If it
    // supports validation caching, enable it's extension as well.
    const extensions = try get_physical_device_exensions(arena_alloc, physical_device.device, null);
    var all_extensions_len = extensions.len;
    if (physical_device.has_validation_cache)
        all_extensions_len += 1;
    var all_extension_names = try arena_alloc.alloc([*c]const u8, all_extensions_len);
    all_extensions_len = 0;
    for (extensions) |*e| {
        var enabled: []const u8 = "enabled";
        if (usable_device_extension(&e.extensionName, extensions, instance.api_version)) {
            all_extension_names[all_extensions_len] = &e.extensionName;
            all_extensions_len += 1;
        } else enabled = "filtered";
        const version: vk.ApiVersion = @bitCast(e.specVersion);
        log.debug(
            @src(),
            "(PhysicalDevice)({s:^8}) Extension version: {f} Name: {s}",
            .{ enabled, version, e.extensionName },
        );
    }
    if (physical_device.has_validation_cache) {
        all_extension_names[all_extensions_len] = "VK_EXT_validation_cache";
        all_extensions_len += 1;
    }
    all_extension_names = all_extension_names[0..all_extensions_len];

    pdf.* = .{};
    var stats: vk.VkPhysicalDevicePipelineExecutablePropertiesFeaturesKHR = .{};
    pdf.pNext = &stats;
    if (instance.has_properties_2) {
        additional_pdf.* = .{};
        stats.pNext = additional_pdf.chain_supported(all_extension_names);
        vkGetPhysicalDeviceFeatures2KHR(physical_device.device, pdf);
        stats.pipelineExecutableInfo = vk.VK_FALSE;
    } else vkGetPhysicalDeviceFeatures(physical_device.device, &pdf.features);

    additional_properties.* = .{};
    var pdp: vk.VkPhysicalDeviceProperties2 = .{};
    if (instance.has_properties_2) {
        pdp.pNext = additional_properties.chain_supported(all_extension_names);
        vkGetPhysicalDeviceProperties2KHR(physical_device.device, &pdp);
    } else vkGetPhysicalDeviceProperties(physical_device.device, &pdp.properties);

    // Workaround for older dxvk/vkd3d databases, where robustness2 or VRS was not captured,
    // but we expect them to be present. New databases will capture robustness2.
    var wpdf2: ?*const vk.VkPhysicalDeviceFeatures2 = wanted_physical_device_features2;
    var updf2: vk.VkPhysicalDeviceFeatures2 = undefined;
    var spare_robustness2: vk.VkPhysicalDeviceRobustness2FeaturesEXT = undefined;
    var replacement_fragment_shading_rate: vk.VkPhysicalDeviceFragmentShadingRateFeaturesKHR = undefined;
    if (wanted_physical_device_features2) |df2| {
        const engine_name: []const u8 = std.mem.span(application_create_info.pEngineName.?);

        updf2 = df2.*;
        wpdf2 = &updf2;

        if ((std.mem.eql(u8, engine_name, "DXVK") or std.mem.eql(u8, engine_name, "vkd3d")) and
            find_pnext(.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_ROBUSTNESS_2_FEATURES_KHR, @ptrCast(df2.pNext)) == null)
        {
            spare_robustness2 = .{
                .pNext = updf2.pNext,
                .robustBufferAccess2 = df2.features.robustBufferAccess,
                .robustImageAccess2 = df2.features.robustBufferAccess,
                .nullDescriptor = vk.VK_TRUE,
            };
            updf2.pNext = &spare_robustness2;
        }

        if (std.mem.eql(u8, engine_name, "vkd3d") and
            find_pnext(.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FRAGMENT_SHADING_RATE_FEATURES_KHR, @ptrCast(df2.pNext)) == null)
        {
            replacement_fragment_shading_rate = .{
                .pNext = updf2.pNext,
                .pipelineFragmentShadingRate = vk.VK_TRUE,
                .primitiveFragmentShadingRate = vk.VK_TRUE,
                .attachmentFragmentShadingRate = vk.VK_TRUE,
            };
            updf2.pNext = &replacement_fragment_shading_rate;
        }
    }

    filter_features(pdf, additional_pdf, wpdf2);
    all_extension_names = filter_active_extensions(pdf, all_extension_names);

    const queue_priority: f32 = 1.0;
    const queue_create_info = vk.VkDeviceQueueCreateInfo{
        .queueFamilyIndex = physical_device.graphics_queue_family,
        .queueCount = 1,
        .pQueuePriorities = @ptrCast(&queue_priority),
    };

    const enabled_layers = if (enable_validation) &VK_VALIDATION_LAYERS_NAMES else &.{};

    for (all_extension_names) |name| log.debug(@src(), "(Device) Enabled extension: {s}", .{name});
    for (enabled_layers) |name| log.debug(@src(), "(Device) Enabled layer: {s}", .{name});

    const create_info = vk.VkDeviceCreateInfo{
        .pQueueCreateInfos = @ptrCast(&queue_create_info),
        .queueCreateInfoCount = 1,
        .ppEnabledLayerNames = @ptrCast(enabled_layers.ptr),
        .enabledLayerCount = @as(u32, @intCast(enabled_layers.len)),
        .ppEnabledExtensionNames = @ptrCast(all_extension_names.ptr),
        .enabledExtensionCount = @as(u32, @intCast(all_extension_names.len)),
        .pEnabledFeatures = if (instance.has_properties_2) null else &pdf.features,
        .pNext = if (instance.has_properties_2) pdf else null,
    };

    var vk_device: vk.VkDevice = undefined;
    try check_result(vkCreateDevice(physical_device.device, &create_info, null, &vk_device));
    return .{
        .device = vk_device,
        .all_extension_names = all_extension_names,
    };
}

pub const AnyHandle = u64;

pub fn create_vk_sampler(
    vk_device: vk.VkDevice,
    create_info: *const vk.VkSamplerCreateInfo,
) !AnyHandle {
    const prof_point = MEASUREMENTS.start(@src());
    defer MEASUREMENTS.end(prof_point);

    var result: vk.VkSampler = undefined;
    try check_result(vkCreateSampler(
        vk_device,
        create_info,
        null,
        &result,
    ));
    return @intFromEnum(result);
}

pub fn destroy_vk_sampler(
    vk_device: vk.VkDevice,
    sampler: AnyHandle,
) void {
    const prof_point = MEASUREMENTS.start(@src());
    defer MEASUREMENTS.end(prof_point);

    vkDestroySampler(vk_device, @enumFromInt(sampler), null);
}

pub fn create_descriptor_set_layout(
    vk_device: vk.VkDevice,
    create_info: *const vk.VkDescriptorSetLayoutCreateInfo,
) !AnyHandle {
    const prof_point = MEASUREMENTS.start(@src());
    defer MEASUREMENTS.end(prof_point);

    var result: vk.VkDescriptorSetLayout = undefined;
    try check_result(vkCreateDescriptorSetLayout(
        vk_device,
        create_info,
        null,
        &result,
    ));
    return @intFromEnum(result);
}

pub fn destroy_descriptor_set_layout(
    vk_device: vk.VkDevice,
    layout: AnyHandle,
) void {
    const prof_point = MEASUREMENTS.start(@src());
    defer MEASUREMENTS.end(prof_point);

    vkDestroyDescriptorSetLayout(vk_device, @enumFromInt(layout), null);
}

pub fn create_pipeline_layout(
    vk_device: vk.VkDevice,
    create_info: *const vk.VkPipelineLayoutCreateInfo,
) !AnyHandle {
    const prof_point = MEASUREMENTS.start(@src());
    defer MEASUREMENTS.end(prof_point);

    var result: vk.VkPipelineLayout = undefined;
    try check_result(vkCreatePipelineLayout(
        vk_device,
        create_info,
        null,
        &result,
    ));
    return @intFromEnum(result);
}

pub fn destroy_pipeline_layout(
    vk_device: vk.VkDevice,
    layout: AnyHandle,
) void {
    const prof_point = MEASUREMENTS.start(@src());
    defer MEASUREMENTS.end(prof_point);

    vkDestroyPipelineLayout(vk_device, @enumFromInt(layout), null);
}

pub fn create_shader_module(
    vk_device: vk.VkDevice,
    create_info: *const vk.VkShaderModuleCreateInfo,
) !AnyHandle {
    const prof_point = MEASUREMENTS.start(@src());
    defer MEASUREMENTS.end(prof_point);

    var result: vk.VkShaderModule = undefined;
    try check_result(vkCreateShaderModule(
        vk_device,
        create_info,
        null,
        &result,
    ));
    return @intFromEnum(result);
}

pub fn destroy_shader_module(
    vk_device: vk.VkDevice,
    shader_module: AnyHandle,
) void {
    const prof_point = MEASUREMENTS.start(@src());
    defer MEASUREMENTS.end(prof_point);

    vkDestroyShaderModule(vk_device, @enumFromInt(shader_module), null);
}

pub fn create_render_pass(
    vk_device: vk.VkDevice,
    create_info: *align(8) const anyopaque,
) !AnyHandle {
    const prof_point = MEASUREMENTS.start(@src());
    defer MEASUREMENTS.end(prof_point);

    const base_type: *const vk.VkBaseInStructure = @ptrCast(create_info);
    var result: vk.VkRenderPass = undefined;
    switch (base_type.sType) {
        .VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO,
        => try check_result(vkCreateRenderPass(
            vk_device,
            @ptrCast(create_info),
            null,
            &result,
        )),
        .VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO_2,
        => try check_result(vkCreateRenderPass2(
            vk_device,
            @ptrCast(create_info),
            null,
            &result,
        )),
        else => return error.InvalidCreateInfoForRenderPass,
    }
    return @intFromEnum(result);
}

pub fn destroy_render_pass(
    vk_device: vk.VkDevice,
    render_pass: AnyHandle,
) void {
    const prof_point = MEASUREMENTS.start(@src());
    defer MEASUREMENTS.end(prof_point);

    vkDestroyRenderPass(vk_device, @enumFromInt(render_pass), null);
}

pub fn create_graphics_pipeline(
    vk_device: vk.VkDevice,
    create_info: *const vk.VkGraphicsPipelineCreateInfo,
) !AnyHandle {
    const prof_point = MEASUREMENTS.start(@src());
    defer MEASUREMENTS.end(prof_point);

    var result: vk.VkPipeline = undefined;
    try check_result(vkCreateGraphicsPipelines(
        vk_device,
        .none,
        1,
        @ptrCast(create_info),
        null,
        @ptrCast(&result),
    ));
    return @intFromEnum(result);
}

pub fn create_compute_pipeline(
    vk_device: vk.VkDevice,
    create_info: *const vk.VkComputePipelineCreateInfo,
) !AnyHandle {
    const prof_point = MEASUREMENTS.start(@src());
    defer MEASUREMENTS.end(prof_point);

    var result: vk.VkPipeline = undefined;
    try check_result(vkCreateComputePipelines(
        vk_device,
        .none,
        1,
        @ptrCast(create_info),
        null,
        @ptrCast(&result),
    ));
    return @intFromEnum(result);
}

pub fn create_raytracing_pipeline(
    vk_device: vk.VkDevice,
    create_info: *const vk.VkRayTracingPipelineCreateInfoKHR,
) !AnyHandle {
    const prof_point = MEASUREMENTS.start(@src());
    defer MEASUREMENTS.end(prof_point);

    var result: vk.VkPipeline = undefined;
    try check_result(vkCreateRayTracingPipelinesKHR(
        vk_device,
        .none,
        .none,
        1,
        @ptrCast(create_info),
        null,
        @ptrCast(&result),
    ));
    return @intFromEnum(result);
}

pub fn destroy_pipeline(
    vk_device: vk.VkDevice,
    pipeline: AnyHandle,
) void {
    const prof_point = MEASUREMENTS.start(@src());
    defer MEASUREMENTS.end(prof_point);

    vkDestroyPipeline(vk_device, @enumFromInt(pipeline), null);
}
