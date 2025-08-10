const std = @import("std");

pub fn parse(comptime T: type) !T {
    const type_fields = @typeInfo(T).@"struct".fields;

    var t: T = .{};
    inline for (type_fields) |field| {
        if (find_arg(field)) |arg| {
            switch (field.type) {
                void => {},
                bool => {
                    @field(t, field.name) = true;
                },
                ?u32 => {
                    @field(t, field.name) = try std.fmt.parseInt(u32, arg, 10);
                },
                ?[]const u8 => {
                    @field(t, field.name) = arg;
                },
                else => unreachable,
            }
        }
    }
    return t;
}

fn find_arg(comptime field: std.builtin.Type.StructField) ?[]const u8 {
    const name = std.fmt.comptimePrint("--{s}", .{field.name});
    var arg_name: [name.len]u8 = undefined;
    _ = std.mem.replace(u8, name, "_", "-", &arg_name);

    var args_iter = std.process.args();

    while (args_iter.next()) |arg| {
        if (std.mem.eql(u8, arg, &arg_name)) {
            return switch (field.type) {
                void, bool => field.name,
                else => args_iter.next(),
            };
        }
    }
    return null;
}

pub fn print_help(comptime T: type) !void {
    const type_fields = comptime @typeInfo(T).@"struct".fields;

    const stdout = std.io.getStdOut();
    const writer = stdout.writer();
    try writer.print("Usage:\n", .{});

    inline for (type_fields) |field| {
        const name = std.fmt.comptimePrint("--{s}", .{field.name});
        var arg_name: [name.len]u8 = undefined;
        _ = std.mem.replace(u8, name, "_", "-", &arg_name);
        try writer.print("\t{s}\n", .{arg_name});
    }
}
