const std = @import("std");

pub const LastArgs = struct { values: []const [*:0]const u8 = &.{} };

pub fn parse(comptime T: type) !T {
    const type_fields = @typeInfo(T).@"struct".fields;

    var t: T = .{};
    // The first arg is the binary name, so skip it.
    var args_consumed: u32 = 1;
    inline for (type_fields, 0..) |field, i| {
        if (field.type == LastArgs) {
            if (i != type_fields.len - 1)
                @compileError("The LastArgs valum must be last in the args type definition");
            @field(t, field.name).values = std.os.argv[args_consumed..];
        } else if (find_arg(field)) |arg| {
            switch (field.type) {
                void => {
                    args_consumed += 1;
                },
                bool => {
                    args_consumed += 1;
                    @field(t, field.name) = true;
                },
                ?u32 => {
                    args_consumed += 2;
                    @field(t, field.name) = try std.fmt.parseInt(u32, arg, 10);
                },
                ?[]const u8 => {
                    args_consumed += 2;
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
