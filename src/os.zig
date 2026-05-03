const std = @import("std");

pub fn open(path: [*:0]const u8, flags: std.os.linux.O, perm: std.os.linux.mode_t) !std.os.linux.fd_t {
    const r = std.os.linux.open(path, flags, perm);
    switch (std.os.linux.errno(r)) {
        .SUCCESS => return @intCast(r),
        else => |e| return std.posix.unexpectedErrno(e),
    }
}

pub fn close(fd: std.os.linux.fd_t) void {
    _ = std.os.linux.close(fd);
}

pub fn statx(fd: std.os.linux.fd_t) !std.os.linux.Statx {
    var stx = std.mem.zeroes(std.os.linux.Statx);
    const r = std.os.linux.statx(
        fd,
        "\x00",
        std.os.linux.AT.EMPTY_PATH,
        .{ .TYPE = true, .MODE = true, .ATIME = true, .MTIME = true, .BTIME = true },
        &stx,
    );

    switch (std.os.linux.errno(r)) {
        .SUCCESS => return stx,
        else => |e| return std.posix.unexpectedErrno(e),
    }
}

pub fn read(fd: std.os.linux.fd_t, buf: []u8) !usize {
    const r = std.os.linux.read(fd, buf.ptr, buf.len);
    switch (std.os.linux.errno(r)) {
        .SUCCESS => return r,
        else => |e| return std.posix.unexpectedErrno(e),
    }
}

pub fn pread(fd: std.os.linux.fd_t, buf: []u8, offset: u64) !usize {
    const r = std.os.linux.pread(fd, buf.ptr, buf.len, @intCast(offset));
    switch (std.os.linux.errno(r)) {
        .SUCCESS => return r,
        else => |e| return std.posix.unexpectedErrno(e),
    }
}

pub fn write(fd: std.os.linux.fd_t, buf: []const u8) !usize {
    const r = std.os.linux.write(fd, buf.ptr, buf.len);
    switch (std.os.linux.errno(r)) {
        .SUCCESS => return r,
        else => |e| return std.posix.unexpectedErrno(e),
    }
}

pub fn fsync(fd: std.os.linux.fd_t) !void {
    const r = std.os.linux.fsync(fd);
    switch (std.os.linux.errno(r)) {
        .SUCCESS => return,
        else => |e| return std.posix.unexpectedErrno(e),
    }
}

pub fn unlink(path: [*:0]const u8) !void {
    const r = std.os.linux.unlink(path);
    switch (std.os.linux.errno(r)) {
        .SUCCESS => return,
        else => |e| return std.posix.unexpectedErrno(e),
    }
}

pub fn fadvise(fd: std.os.linux.fd_t, offset: i64, len: i64, advice: usize) !void {
    const r = std.os.linux.fadvise(fd, offset, len, advice);
    switch (std.os.linux.errno(r)) {
        .SUCCESS => return,
        else => |e| return std.posix.unexpectedErrno(e),
    }
}

pub fn futex2_wait(uaddr: *const anyopaque, val: usize) !void {
    const r = std.os.linux.futex2_wait(
        uaddr,
        val,
        0xffffffff,
        .{ .size = .U32, .private = true },
        null,
        .MONOTONIC,
    );
    switch (std.os.linux.errno(r)) {
        .SUCCESS => return,
        else => |e| return std.posix.unexpectedErrno(e),
    }
}

pub fn futex2_wake(uaddr: *const anyopaque, nr_wake: i32) !void {
    const r = std.os.linux.futex2_wake(
        uaddr,
        0xffffffff,
        nr_wake,
        .{ .size = .U32, .private = true },
    );
    switch (std.os.linux.errno(r)) {
        .SUCCESS => return,
        else => |e| return std.posix.unexpectedErrno(e),
    }
}
