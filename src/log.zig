const std = @import("std");

const DEFAULT_COLOR = "\x1b[0m";
const WHITE = "\x1b[37m";
const HIGH_WHITE = "\x1b[90m";
const YELLOW = "\x1b[33m";
const RED = "\x1b[31m";

pub const LogLevel = enum {
    Err,
    Warn,
    Info,
    Debug,
};
pub const Options = struct {
    colors: bool = true,
    level: LogLevel = .Info,
    asserts: bool = true,

    const Self = @This();
    pub fn log_enabled(self: Self, level: LogLevel) bool {
        const self_level_int = @intFromEnum(self.level);
        const level_int = @intFromEnum(level);
        return level_int <= self_level_int;
    }
};

const root = @import("root");
pub const options: Options = if (@hasDecl(root, "log_options"))
    root.log_options
else
    .{};

pub fn comptime_err(
    comptime src: std.builtin.SourceLocation,
    comptime format: []const u8,
    comptime args: anytype,
) noreturn {
    const header = std.fmt.comptimePrint("[{s}:{}:COMPILE]", .{ src.file, src.line });
    const T = make_struct(@TypeOf(args));
    const t = fill_struct(T, header, args);
    if (comptime options.colors)
        @compileError(std.fmt.comptimePrint(RED ++ "{s} " ++ format ++ DEFAULT_COLOR, t))
    else
        @compileError(std.fmt.comptimePrint("{s} " ++ format, t));
}

pub fn panic(
    comptime src: std.builtin.SourceLocation,
    comptime format: []const u8,
    args: anytype,
) noreturn {
    const header = std.fmt.comptimePrint("[{s}:{}:PANIC]", .{ src.file, src.line });
    const T = make_struct(@TypeOf(args));
    const t = fill_struct(T, header, args);
    if (comptime options.colors)
        std.debug.panic(RED ++ "{s} " ++ format ++ DEFAULT_COLOR, t)
    else
        std.debug.panic("{s} " ++ format, t);
}

pub fn assert(
    comptime src: std.builtin.SourceLocation,
    ok: bool,
    comptime format: []const u8,
    args: anytype,
) void {
    if (comptime !options.asserts) return;

    if (!ok) {
        @branchHint(.cold);
        const header = std.fmt.comptimePrint("[{s}:{}:ASSERT]", .{ src.file, src.line });
        const T = make_struct(@TypeOf(args));
        const t = fill_struct(T, header, args);
        if (comptime options.colors)
            std.debug.panic(RED ++ "{s} " ++ format ++ DEFAULT_COLOR, t)
        else
            std.debug.panic("{s} " ++ format, t);
    }
}

pub fn info(
    comptime src: std.builtin.SourceLocation,
    comptime format: []const u8,
    args: anytype,
) void {
    if (comptime !options.log_enabled(.Info)) return;

    const header = std.fmt.comptimePrint("[{s}:{}:INFO]", .{ src.file, src.line });
    const T = make_struct(@TypeOf(args));
    const t = fill_struct(T, header, args);
    if (comptime options.colors)
        output(WHITE ++ "{s} " ++ format ++ DEFAULT_COLOR, t)
    else
        output("{s} " ++ format, t);
}

pub fn debug(
    comptime src: std.builtin.SourceLocation,
    comptime format: []const u8,
    args: anytype,
) void {
    if (comptime !options.log_enabled(.Debug)) return;

    const header = std.fmt.comptimePrint("[{s}:{}:DEBUG]", .{ src.file, src.line });
    const T = make_struct(@TypeOf(args));
    const t = fill_struct(T, header, args);
    if (comptime options.colors)
        output(HIGH_WHITE ++ "{s} " ++ format ++ DEFAULT_COLOR, t)
    else
        output("{s} " ++ format, t);
}

pub fn warn(
    comptime src: std.builtin.SourceLocation,
    comptime format: []const u8,
    args: anytype,
) void {
    if (comptime !options.log_enabled(.Warn)) return;

    const header = std.fmt.comptimePrint("[{s}:{}:WARN]", .{ src.file, src.line });
    const T = make_struct(@TypeOf(args));
    const t = fill_struct(T, header, args);
    if (comptime options.colors)
        output(YELLOW ++ "{s} " ++ format ++ DEFAULT_COLOR, t)
    else
        output("{s} " ++ format, t);
}

pub fn err(
    comptime src: std.builtin.SourceLocation,
    comptime format: []const u8,
    args: anytype,
) void {
    if (comptime !options.log_enabled(.Err)) return;

    const header = std.fmt.comptimePrint("[{s}:{}:ERROR]", .{ src.file, src.line });
    const T = make_struct(@TypeOf(args));
    const t = fill_struct(T, header, args);
    if (comptime options.colors)
        output(RED ++ "{s} " ++ format ++ DEFAULT_COLOR, t)
    else
        output("{s} " ++ format, t);
}

fn output(
    comptime format: []const u8,
    args: anytype,
) void {
    const stderr = std.io.getStdErr().writer();
    var bw = std.io.bufferedWriter(stderr);
    const writer = bw.writer();

    std.debug.lockStdErr();
    defer std.debug.unlockStdErr();
    nosuspend {
        writer.print(format ++ "\n", args) catch return;
        bw.flush() catch return;
    }
}

fn fill_struct(comptime T: type, comptime header: [:0]const u8, args: anytype) T {
    const args_fields = comptime @typeInfo(@TypeOf(args)).@"struct".fields;
    var t: T = undefined;

    @field(t, "0") = header;

    // need to inline so the loop would be unrolled
    // because these fields are assigned at runtime
    // but we need to generate indexes at comptime
    inline for (args_fields, 0..) |_, i| {
        const t_index = std.fmt.comptimePrint("{}", .{1 + i});
        const args_index = std.fmt.comptimePrint("{}", .{i});
        @field(t, t_index) = @field(args, args_index);
    }
    return t;
}

fn make_struct(comptime T: type) type {
    const type_fields = comptime @typeInfo(T).@"struct".fields;
    var fields: [type_fields.len + 1]std.builtin.Type.StructField = undefined;
    // header
    fields[0] = .{
        .name = "0",
        .type = [:0]const u8,
        .default_value_ptr = null,
        .is_comptime = false,
        .alignment = @alignOf([:0]const u8),
    };
    for (type_fields, 1..) |f, i| {
        var ff = f;
        ff.name = std.fmt.comptimePrint("{}", .{i});
        ff.is_comptime = false;
        ff.default_value_ptr = null;
        fields[i] = ff;
    }

    return @Type(.{
        .@"struct" = .{
            .layout = .auto,
            .fields = fields[0..],
            .decls = &[_]std.builtin.Type.Declaration{},
            .is_tuple = true,
        },
    });
}
