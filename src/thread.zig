const std = @import("std");
const sd = @import("static_dynamic.zig");
const log = @import("log.zig");

handle: std.c.pthread_t,

const Self = @This();

pub fn spawn(
    alloc: std.mem.Allocator,
    fns: *const LibcThreadFns,
    config: std.Thread.SpawnConfig,
    comptime f: anytype,
    args: anytype,
) !Self {
    const Args = @TypeOf(args);

    const Instance = struct {
        fn entry_fn(raw_arg: ?*anyopaque) callconv(.c) ?*anyopaque {
            const args_ptr: *Args = @ptrCast(@alignCast(raw_arg));
            @call(.auto, f, args_ptr.*);
            return null;
        }
    };

    const args_ptr = try alloc.create(Args);
    args_ptr.* = args;
    errdefer alloc.destroy(args_ptr);
    // On successful run there is no reason to free these args since the program
    // will exit shortly after that.

    var attr: std.c.pthread_attr_t = undefined;
    if (fns.pthread_attr_init(&attr) != .SUCCESS) return error.SystemResources;
    defer log.assert(@src(), fns.pthread_attr_destroy(&attr) == .SUCCESS, "", .{});

    // Use the same set of parameters used by the libc-less impl.
    const stack_size = @max(config.stack_size, 16 * 1024);
    const set_stack_size_result = fns.pthread_attr_setstacksize(&attr, stack_size);
    log.assert(
        @src(),
        set_stack_size_result == .SUCCESS,
        "pthread_attr_setstacksize failed with {t}",
        .{set_stack_size_result},
    );
    log.assert(@src(), fns.pthread_attr_setguardsize(&attr, std.heap.pageSize()) == .SUCCESS, "", .{});

    var handle: std.c.pthread_t = undefined;
    switch (fns.pthread_create(
        &handle,
        &attr,
        Instance.entry_fn,
        @ptrCast(args_ptr),
    )) {
        .SUCCESS => return .{ .handle = handle },
        .AGAIN => return error.SystemResources,
        .PERM => unreachable,
        .INVAL => unreachable,
        else => |err| return std.posix.unexpectedErrno(err),
    }
}

pub fn join(self: Self, fns: *const LibcThreadFns) void {
    switch (fns.pthread_join(self.handle, null)) {
        .SUCCESS => {},
        .INVAL => unreachable, // thread handle is not joinable (or another thread is already joining in)
        .SRCH => unreachable, // thread handle is invalid
        .DEADLK => unreachable, // two threads tried to join each other
        else => unreachable,
    }
}

pub const LibcThreadFns = struct {
    pthread_attr_init: *const fn (attr: *std.c.pthread_attr_t) callconv(.c) std.c.E,
    pthread_attr_destroy: *const fn (attr: *std.c.pthread_attr_t) callconv(.c) std.c.E,
    pthread_attr_setstacksize: *const fn (attr: *std.c.pthread_attr_t, stacksize: usize) callconv(.c) std.c.E,
    pthread_attr_setguardsize: *const fn (attr: *std.c.pthread_attr_t, guardsize: usize) callconv(.c) std.c.E,
    pthread_create: *const fn (
        noalias newthread: *std.c.pthread_t,
        noalias attr: ?*const std.c.pthread_attr_t,
        start_routine: *const fn (?*anyopaque) callconv(.c) ?*anyopaque,
        noalias arg: ?*anyopaque,
    ) callconv(.c) std.c.E,
    pthread_join: *const fn (thread: std.c.pthread_t, arg_return: ?*?*anyopaque) callconv(.c) std.c.E,

    pub fn init(libc_handle: *anyopaque) ?LibcThreadFns {
        const pthread_attr_init =
            sd.got.fns.dlsym(libc_handle, "pthread_attr_init") orelse return null;
        const pthread_attr_destroy =
            sd.got.fns.dlsym(libc_handle, "pthread_attr_destroy") orelse return null;
        const pthread_attr_setstacksize =
            sd.got.fns.dlsym(libc_handle, "pthread_attr_setstacksize") orelse return null;
        const pthread_attr_setguardsize =
            sd.got.fns.dlsym(libc_handle, "pthread_attr_setguardsize") orelse return null;
        const pthread_create =
            sd.got.fns.dlsym(libc_handle, "pthread_create") orelse return null;
        const pthread_join =
            sd.got.fns.dlsym(libc_handle, "pthread_join") orelse return null;

        log.debug(@src(), "pthread_attr_init: {p}", .{pthread_attr_init});
        log.debug(@src(), "pthread_attr_destroy: {p}", .{pthread_attr_destroy});
        log.debug(@src(), "pthread_attr_setstacksize: {p}", .{pthread_attr_setstacksize});
        log.debug(@src(), "pthread_attr_setguardsize: {p}", .{pthread_attr_setguardsize});
        log.debug(@src(), "pthread_create: {p}", .{pthread_create});
        log.debug(@src(), "pthread_join : {p}", .{pthread_join});

        return .{
            .pthread_attr_init = @ptrCast(pthread_attr_init),
            .pthread_attr_destroy = @ptrCast(pthread_attr_destroy),
            .pthread_attr_setstacksize = @ptrCast(pthread_attr_setstacksize),
            .pthread_attr_setguardsize = @ptrCast(pthread_attr_setguardsize),
            .pthread_create = @ptrCast(pthread_create),
            .pthread_join = @ptrCast(pthread_join),
        };
    }
};
