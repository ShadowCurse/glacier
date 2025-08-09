const vk = @cImport({
    @cInclude("volk.h");
});
const log = @import("log.zig");

pub usingnamespace vk;

pub fn check_result(result: vk.VkResult) !void {
    switch (result) {
        vk.VK_SUCCESS => return,
        vk.VK_NOT_READY => {
            log.err(@src(), "Vulkan error: VK_NOT_READY", .{});
            return error.VK_NOT_READY;
        },
        vk.VK_TIMEOUT => {
            log.err(@src(), "Vulkan error: VK_TIMEOUT", .{});
            return error.VK_TIMEOUT;
        },
        vk.VK_EVENT_SET => {
            log.err(@src(), "Vulkan error: VK_EVENT_SET", .{});
            return error.VK_EVENT_SET;
        },
        vk.VK_EVENT_RESET => {
            log.err(@src(), "Vulkan error: VK_EVENT_RESET", .{});
            return error.VK_EVENT_RESET;
        },
        vk.VK_INCOMPLETE => {
            log.err(@src(), "Vulkan error: VK_INCOMPLETE", .{});
            return error.VK_INCOMPLETE;
        },
        vk.VK_ERROR_OUT_OF_HOST_MEMORY => {
            log.err(@src(), "Vulkan error: VK_ERROR_OUT_OF_HOST_MEMORY", .{});
            return error.VK_ERROR_OUT_OF_HOST_MEMORY;
        },
        vk.VK_ERROR_OUT_OF_DEVICE_MEMORY => {
            log.err(@src(), "Vulkan error: VK_ERROR_OUT_OF_DEVICE_MEMORY", .{});
            return error.VK_ERROR_OUT_OF_DEVICE_MEMORY;
        },
        vk.VK_ERROR_INITIALIZATION_FAILED => {
            log.err(@src(), "Vulkan error: VK_ERROR_INITIALIZATION_FAILED", .{});
            return error.VK_ERROR_INITIALIZATION_FAILED;
        },
        vk.VK_ERROR_DEVICE_LOST => {
            log.err(@src(), "Vulkan error: VK_ERROR_DEVICE_LOST", .{});
            return error.VK_ERROR_DEVICE_LOST;
        },
        vk.VK_ERROR_MEMORY_MAP_FAILED => {
            log.err(@src(), "Vulkan error: VK_ERROR_MEMORY_MAP_FAILED", .{});
            return error.VK_ERROR_MEMORY_MAP_FAILED;
        },
        vk.VK_ERROR_LAYER_NOT_PRESENT => {
            log.err(@src(), "Vulkan error: VK_ERROR_LAYER_NOT_PRESENT", .{});
            return error.VK_ERROR_LAYER_NOT_PRESENT;
        },
        vk.VK_ERROR_EXTENSION_NOT_PRESENT => {
            log.err(@src(), "Vulkan error: VK_ERROR_EXTENSION_NOT_PRESENT", .{});
            return error.VK_ERROR_EXTENSION_NOT_PRESENT;
        },
        vk.VK_ERROR_FEATURE_NOT_PRESENT => {
            log.err(@src(), "Vulkan error: VK_ERROR_FEATURE_NOT_PRESENT", .{});
            return error.VK_ERROR_FEATURE_NOT_PRESENT;
        },
        vk.VK_ERROR_INCOMPATIBLE_DRIVER => {
            log.err(@src(), "Vulkan error: VK_ERROR_INCOMPATIBLE_DRIVER", .{});
            return error.VK_ERROR_INCOMPATIBLE_DRIVER;
        },
        vk.VK_ERROR_TOO_MANY_OBJECTS => {
            log.err(@src(), "Vulkan error: VK_ERROR_TOO_MANY_OBJECTS", .{});
            return error.VK_ERROR_TOO_MANY_OBJECTS;
        },
        vk.VK_ERROR_FORMAT_NOT_SUPPORTED => {
            log.err(@src(), "Vulkan error: VK_ERROR_FORMAT_NOT_SUPPORTED", .{});
            return error.VK_ERROR_FORMAT_NOT_SUPPORTED;
        },
        vk.VK_ERROR_FRAGMENTED_POOL => {
            log.err(@src(), "Vulkan error: VK_ERROR_FRAGMENTED_POOL", .{});
            return error.VK_ERROR_FRAGMENTED_POOL;
        },
        vk.VK_ERROR_UNKNOWN => {
            log.err(@src(), "Vulkan error: VK_ERROR_UNKNOWN", .{});
            return error.VK_ERROR_UNKNOWN;
        },
        vk.VK_ERROR_OUT_OF_POOL_MEMORY => {
            log.err(@src(), "Vulkan error: VK_ERROR_OUT_OF_POOL_MEMORY", .{});
            return error.VK_ERROR_OUT_OF_POOL_MEMORY;
        },
        vk.VK_ERROR_INVALID_EXTERNAL_HANDLE => {
            log.err(@src(), "Vulkan error: VK_ERROR_INVALID_EXTERNAL_HANDLE", .{});
            return error.VK_ERROR_INVALID_EXTERNAL_HANDLE;
        },
        vk.VK_ERROR_FRAGMENTATION => {
            log.err(@src(), "Vulkan error: VK_ERROR_FRAGMENTATION", .{});
            return error.VK_ERROR_FRAGMENTATION;
        },
        vk.VK_ERROR_INVALID_OPAQUE_CAPTURE_ADDRESS => {
            log.err(@src(), "Vulkan error: VK_ERROR_INVALID_OPAQUE_CAPTURE_ADDRESS", .{});
            return error.VK_ERROR_INVALID_OPAQUE_CAPTURE_ADDRESS;
        },
        vk.VK_PIPELINE_COMPILE_REQUIRED => {
            log.err(@src(), "Vulkan error: VK_PIPELINE_COMPILE_REQUIRED", .{});
            return error.VK_PIPELINE_COMPILE_REQUIRED;
        },
        vk.VK_ERROR_SURFACE_LOST_KHR => {
            log.err(@src(), "Vulkan error: VK_ERROR_SURFACE_LOST_KHR", .{});
            return error.VK_ERROR_SURFACE_LOST_KHR;
        },
        vk.VK_ERROR_NATIVE_WINDOW_IN_USE_KHR => {
            log.err(@src(), "Vulkan error: VK_ERROR_NATIVE_WINDOW_IN_USE_KHR", .{});
            return error.VK_ERROR_NATIVE_WINDOW_IN_USE_KHR;
        },
        vk.VK_SUBOPTIMAL_KHR => {
            log.err(@src(), "Vulkan error: VK_SUBOPTIMAL_KHR", .{});
            return error.VK_SUBOPTIMAL_KHR;
        },
        vk.VK_ERROR_OUT_OF_DATE_KHR => {
            log.err(@src(), "Vulkan error: VK_ERROR_OUT_OF_DATE_KHR", .{});
            return error.VK_ERROR_OUT_OF_DATE_KHR;
        },
        vk.VK_ERROR_INCOMPATIBLE_DISPLAY_KHR => {
            log.err(@src(), "Vulkan error: VK_ERROR_INCOMPATIBLE_DISPLAY_KHR", .{});
            return error.VK_ERROR_INCOMPATIBLE_DISPLAY_KHR;
        },
        vk.VK_ERROR_VALIDATION_FAILED_EXT => {
            log.err(@src(), "Vulkan error: VK_ERROR_VALIDATION_FAILED_EXT", .{});
            return error.VK_ERROR_VALIDATION_FAILED_EXT;
        },
        vk.VK_ERROR_INVALID_SHADER_NV => {
            log.err(@src(), "Vulkan error: VK_ERROR_INVALID_SHADER_NV", .{});
            return error.VK_ERROR_INVALID_SHADER_NV;
        },
        vk.VK_ERROR_IMAGE_USAGE_NOT_SUPPORTED_KHR => {
            log.err(@src(), "Vulkan error: VK_ERROR_IMAGE_USAGE_NOT_SUPPORTED_KHR", .{});
            return error.VK_ERROR_IMAGE_USAGE_NOT_SUPPORTED_KHR;
        },
        vk.VK_ERROR_VIDEO_PICTURE_LAYOUT_NOT_SUPPORTED_KHR => {
            log.err(@src(), "Vulkan error: VK_ERROR_VIDEO_PICTURE_LAYOUT_NOT_SUPPORTED_KHR", .{});
            return error.VK_ERROR_VIDEO_PICTURE_LAYOUT_NOT_SUPPORTED_KHR;
        },
        vk.VK_ERROR_VIDEO_PROFILE_OPERATION_NOT_SUPPORTED_KHR => {
            log.err(@src(), "Vulkan error: VK_ERROR_VIDEO_PROFILE_OPERATION_NOT_SUPPORTED_KHR", .{});
            return error.VK_ERROR_VIDEO_PROFILE_OPERATION_NOT_SUPPORTED_KHR;
        },
        vk.VK_ERROR_VIDEO_PROFILE_FORMAT_NOT_SUPPORTED_KHR => {
            log.err(@src(), "Vulkan error: VK_ERROR_VIDEO_PROFILE_FORMAT_NOT_SUPPORTED_KHR", .{});
            return error.VK_ERROR_VIDEO_PROFILE_FORMAT_NOT_SUPPORTED_KHR;
        },
        vk.VK_ERROR_VIDEO_PROFILE_CODEC_NOT_SUPPORTED_KHR => {
            log.err(@src(), "Vulkan error: VK_ERROR_VIDEO_PROFILE_CODEC_NOT_SUPPORTED_KHR", .{});
            return error.VK_ERROR_VIDEO_PROFILE_CODEC_NOT_SUPPORTED_KHR;
        },
        vk.VK_ERROR_VIDEO_STD_VERSION_NOT_SUPPORTED_KHR => {
            log.err(@src(), "Vulkan error: VK_ERROR_VIDEO_STD_VERSION_NOT_SUPPORTED_KHR", .{});
            return error.VK_ERROR_VIDEO_STD_VERSION_NOT_SUPPORTED_KHR;
        },
        vk.VK_ERROR_INVALID_DRM_FORMAT_MODIFIER_PLANE_LAYOUT_EXT => {
            log.err(@src(), "Vulkan error: VK_ERROR_INVALID_DRM_FORMAT_MODIFIER_PLANE_LAYOUT_EXT", .{});
            return error.VK_ERROR_INVALID_DRM_FORMAT_MODIFIER_PLANE_LAYOUT_EXT;
        },
        vk.VK_ERROR_NOT_PERMITTED_KHR => {
            log.err(@src(), "Vulkan error: VK_ERROR_NOT_PERMITTED_KHR", .{});
            return error.VK_ERROR_NOT_PERMITTED_KHR;
        },
        vk.VK_ERROR_FULL_SCREEN_EXCLUSIVE_MODE_LOST_EXT => {
            log.err(@src(), "Vulkan error: VK_ERROR_FULL_SCREEN_EXCLUSIVE_MODE_LOST_EXT", .{});
            return error.VK_ERROR_FULL_SCREEN_EXCLUSIVE_MODE_LOST_EXT;
        },
        vk.VK_THREAD_IDLE_KHR => {
            log.err(@src(), "Vulkan error: VK_THREAD_IDLE_KHR", .{});
            return error.VK_THREAD_IDLE_KHR;
        },
        vk.VK_THREAD_DONE_KHR => {
            log.err(@src(), "Vulkan error: VK_THREAD_DONE_KHR", .{});
            return error.VK_THREAD_DONE_KHR;
        },
        vk.VK_OPERATION_DEFERRED_KHR => {
            log.err(@src(), "Vulkan error: VK_OPERATION_DEFERRED_KHR", .{});
            return error.VK_OPERATION_DEFERRED_KHR;
        },
        vk.VK_OPERATION_NOT_DEFERRED_KHR => {
            log.err(@src(), "Vulkan error: VK_OPERATION_NOT_DEFERRED_KHR", .{});
            return error.VK_OPERATION_NOT_DEFERRED_KHR;
        },
        vk.VK_ERROR_INVALID_VIDEO_STD_PARAMETERS_KHR => {
            log.err(@src(), "Vulkan error: VK_ERROR_INVALID_VIDEO_STD_PARAMETERS_KHR", .{});
            return error.VK_ERROR_INVALID_VIDEO_STD_PARAMETERS_KHR;
        },
        vk.VK_ERROR_COMPRESSION_EXHAUSTED_EXT => {
            log.err(@src(), "Vulkan error: VK_ERROR_COMPRESSION_EXHAUSTED_EXT", .{});
            return error.VK_ERROR_COMPRESSION_EXHAUSTED_EXT;
        },
        vk.VK_INCOMPATIBLE_SHADER_BINARY_EXT => {
            log.err(@src(), "Vulkan error: VK_INCOMPATIBLE_SHADER_BINARY_EXT", .{});
            return error.VK_INCOMPATIBLE_SHADER_BINARY_EXT;
        },
        vk.VK_RESULT_MAX_ENUM => {
            log.err(@src(), "Vulkan error: VK_RESULT_MAX_ENUM", .{});
            return error.VK_RESULT_MAX_ENUM;
        },
        else => {
            log.err(@src(), "Vulkan error: UNKNOWN {}", .{result});
            return error.UNKNOWN;
        },
    }
}
