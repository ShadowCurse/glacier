const std = @import("std");
const os = @import("os.zig");

buffer: []u8,
end: u32,
fd: std.os.linux.fd_t,
alloc: std.mem.Allocator,

const Self = @This();

pub fn init(alloc: std.mem.Allocator, fd: std.os.linux.fd_t) !Self {
    const buffer = try alloc.alloc(u8, 4096 * 12);
    return .{ .buffer = buffer, .end = 0, .fd = fd, .alloc = alloc };
}

pub fn flush(self: *Self) void {
    const b = self.buffer[0..self.end];
    _ = os.write(self.fd, b) catch unreachable;
    self.end = 0;
    os.fsync(self.fd) catch unreachable;
}

pub fn write_bytes(self: *Self, bytes: []const u8) void {
    const new_end = self.end + @as(u32, @truncate(bytes.len));
    if (new_end <= self.buffer.len) {
        @memcpy(self.buffer[self.end..][0..bytes.len], bytes);
        self.end = new_end;
    } else {
        const b = self.buffer[0..self.end];
        _ = os.write(self.fd, b) catch unreachable;
        @memcpy(self.buffer[0..bytes.len], bytes);
        self.end = @truncate(bytes.len);
    }
}

pub fn write(self: *Self, comptime fmt: []const u8, args: anytype) void {
    const line = std.fmt.allocPrint(self.alloc, fmt, args) catch unreachable;
    defer self.alloc.free(line);
    self.write_bytes(line);
}

pub fn write_comment(self: *Self, comment: []const u8, line_start: []const u8) void {
    var iter = std.mem.splitScalar(u8, comment, '\n');
    while (iter.next()) |line| {
        const trimmed_line = std.mem.trimStart(u8, line, " ");
        if (trimmed_line.len == 0) break;

        self.write_bytes(line_start);
        self.write_bytes(trimmed_line);
        self.write_bytes("\n");
    }
}
