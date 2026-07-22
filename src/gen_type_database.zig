// Copyright (c) 2026 Egor Lazarchuk
// SPDX-License-Identifier: MIT

const std = @import("std");
const Allocator = std.mem.Allocator;
const XmlParser = @import("xml_parser.zig");

pub const TypeDatabase = struct {
    alloc: Allocator,

    types: std.ArrayListUnmanaged(@This().Type) = .empty,

    constants: std.ArrayListUnmanaged(@This().Constant) = .empty,
    handles: std.ArrayListUnmanaged(@This().Handle) = .empty,
    structs: std.ArrayListUnmanaged(@This().Struct) = .empty,
    bitfields: std.ArrayListUnmanaged(@This().Bitfield) = .empty,
    enums: std.ArrayListUnmanaged(@This().Enum) = .empty,
    unions: std.ArrayListUnmanaged(@This().Union) = .empty,
    functions: std.ArrayListUnmanaged(@This().Function) = .empty,

    extensions: std.ArrayListUnmanaged(Extension) = .empty,
    features: std.ArrayListUnmanaged(Extension) = .empty,
    spirv: Spirv = .{},

    pub const Extension = Xml.Extension;
    pub const Spirv = Xml.Spirv;

    pub const BuiltinType = enum {
        void,
        anyopaque,
        bool,
        u8,
        u16,
        i32,
        u32,
        i64,
        u64,
        f32,
        f64,
    };

    pub const BuiltinValue = union(BuiltinType) {
        void: void,
        anyopaque: void,
        bool: bool,
        u8: u8,
        u16: u16,
        i32: i32,
        u32: u32,
        i64: i64,
        u64: u64,
        f32: f32,
        f64: f64,
    };

    pub const Type = union(enum) {
        invalid: void,
        // if name was not resolved, just record that it does exist
        // later it should be resolved by adding some `Base` type
        placeholder: []const u8,
        base: Base,
        alias: Alias,
        pointer: Pointer,
        array: Array,

        pub const Base = union(enum) {
            builtin: BuiltinType,
            constant_idx: Constant.Idx,
            handle_idx: Handle.Idx,
            struct_idx: Struct.Idx,
            bitfield_idx: Bitfield.Idx,
            enum_idx: Enum.Idx,
            union_idx: Union.Idx,
            function_idx: Function.Idx,
        };

        pub const Alias = struct {
            name: []const u8 = &.{},
            type_idx: Type.Idx = .none,
        };

        pub const Pointer = struct {
            base_type_idx: Type.Idx = .none,
            is_slice: bool = false, // [*]
            is_const: bool = false, // *const
            is_zero_terminated: bool = false, // [*:0]
        };

        pub const Array = struct {
            base_type_idx: Type.Idx = .none,
            len: union(enum) {
                // e.g. [3] or [3][4]
                string: []const u8,
                // if some constant
                type_idx: Type.Idx,
            } = .{ .type_idx = .none },
        };

        pub const Idx = enum(u32) {
            none = 0,
            _,
            pub fn init(v: anytype) @This() {
                const result: @This() = @enumFromInt(@as(u32, @truncate(v)));
                return result;
            }
        };

        pub fn is_builtin(self: Type) bool {
            var result: bool = false;
            if (self == .base and self.base == .builtin)
                result = true;
            return result;
        }

        pub fn builtin(self: Type) ?BuiltinType {
            var result: ?BuiltinType = null;
            if (self == .base and self.base == .builtin)
                result = self.base.builtin;
            return result;
        }

        pub fn handle_idx(self: Type) Handle.Idx {
            var result: Handle.Idx = .none;
            if (self == .base) {
                if (self.base == .handle_idx) {
                    result = self.base.handle_idx;
                }
            }
            return result;
        }

        pub fn struct_idx(self: Type) Struct.Idx {
            var result: Struct.Idx = .none;
            if (self == .base) {
                if (self.base == .struct_idx) {
                    result = self.base.struct_idx;
                }
            }
            return result;
        }

        pub fn bitfield_idx(self: Type) Bitfield.Idx {
            var result: Bitfield.Idx = .none;
            if (self == .base) {
                if (self.base == .bitfield_idx) {
                    result = self.base.bitfield_idx;
                }
            }
            return result;
        }

        pub fn enum_idx(self: Type) Enum.Idx {
            var result: Enum.Idx = .none;
            if (self == .base) {
                if (self.base == .enum_idx) {
                    result = self.base.enum_idx;
                }
            }
            return result;
        }

        pub fn union_idx(self: Type) Union.Idx {
            var result: Union.Idx = .none;
            if (self == .base) {
                if (self.base == .union_idx) {
                    result = self.base.union_idx;
                }
            }
            return result;
        }

        pub fn function_idx(self: Type) Function.Idx {
            var result: Function.Idx = .none;
            if (self == .base) {
                if (self.base == .function_idx) {
                    result = self.base.function_idx;
                }
            }
            return result;
        }
    };

    pub const Constant = struct {
        name: []const u8 = &.{},
        value: BuiltinValue = .void,

        pub const Idx = enum(u32) {
            none = 0,
            _,
            pub fn init(v: anytype) @This() {
                const result: @This() = @enumFromInt(@as(u32, @truncate(v)));
                return result;
            }
        };
    };

    pub const Handle = struct {
        name: []const u8 = &.{},
        // metadata
        parent: ?[]const u8 = null,
        objtypeenum: ?[]const u8 = null,
        pub const Idx = enum(u32) {
            none = 0,
            _,
            pub fn init(v: anytype) @This() {
                const result: @This() = @enumFromInt(@as(u32, @truncate(v)));
                return result;
            }
        };
    };

    pub const Struct = struct {
        name: []const u8 = &.{},
        fields: []const Field = &.{},
        extends: []const Type.Idx = &.{},
        extended_by: []const Struct.Idx = &.{},
        enabled_by_extensions: []const []const u8 = &.{},
        // metedata
        comment: ?[]const u8 = null,
        returnedonly: bool = false,
        allowduplicate: bool = false,

        pub const Field = union(enum) {
            single_field: SingleField,
            packed_field: PackedField,
        };

        pub const SingleField = struct {
            name: []const u8 = &.{},
            type_idx: Type.Idx = .none,
            stype_value: ?[]const u8 = null,
            len_expression: ?[]const u8 = null,
            // metadata
            other_struct_field_alias: ?[]const u8 = null,
            api: ?[]const u8 = null,
            stride: ?[]const u8 = null,
            deprecated: ?[]const u8 = null,
            externsync: bool = false,
            optional: bool = false,
            // If member is a union, what field selects the union value
            selector: ?[]const u8 = null,
            // If member is a raw u64 handle, which other member specifies what handle it is
            objecttype: ?[]const u8 = null,
            featurelink: ?[]const u8 = null,
            comment: ?[]const u8 = null,
        };

        pub const PackedField = struct {
            parts: []const @This().Part = &.{},
            backing_integer_width: u32 = 32,

            pub const Part = struct {
                name: []const u8 = &.{},
                bits: u32,
            };
        };

        pub const Idx = enum(u32) {
            none = 0,
            _,
            pub fn init(v: anytype) @This() {
                const result: @This() = @enumFromInt(@as(u32, @truncate(v)));
                return result;
            }
        };

        pub fn stype(self: *const Struct) ?[]const u8 {
            var result: ?[]const u8 = null;
            for (self.fields) |field| {
                if (field == .single_field and
                    field.single_field.stype_value != null)
                {
                    result = field.single_field.stype_value;
                    break;
                }
            }
            return result;
        }

        pub fn single_field_by_name(self: *const Struct, name: []const u8) ?*const SingleField {
            var result: ?*const SingleField = null;
            for (self.fields) |field| {
                if (field == .single_field) {
                    const f = field.single_field;
                    if (std.mem.eql(u8, f.name, name)) {
                        result = &f;
                        break;
                    }
                }
            }
            return result;
        }
    };

    pub const Bitfield = struct {
        name: []const u8 = &.{},
        // backed by unsigned integer
        backing_integer_width: u32 = 32,
        bits: []const Bit = &.{},
        constants: []const @This().Constant = &.{},

        pub const Bit = struct {
            name: []const u8 = &.{},
            bit: u32 = 0,
            // metadata
            enabled_by_extension: ?[]const u8 = null,
            comment: ?[]const u8 = null,
        };

        pub const Constant = struct {
            name: []const u8 = &.{},
            value: u32 = 0,
            // metadata
            comment: ?[]const u8 = null,
        };

        pub const Idx = enum(u32) {
            none = 0,
            _,
            pub fn init(v: anytype) @This() {
                const result: @This() = @enumFromInt(@as(u32, @truncate(v)));
                return result;
            }
        };
    };

    pub const Enum = struct {
        name: []const u8 = &.{},
        // backed by signed integer
        backing_integer_width: u32 = 32,
        values: []const Value = &.{},
        // metadata
        comment: ?[]const u8 = null,

        pub const Value = struct {
            name: []const u8 = &.{},
            value: i64 = 0,
            // metadata
            enabled_by_extension: ?[]const u8 = null,
            comment: ?[]const u8 = null,
        };

        pub const Idx = enum(u32) {
            none = 0,
            _,
            pub fn init(v: anytype) @This() {
                const result: @This() = @enumFromInt(@as(u32, @truncate(v)));
                return result;
            }
        };
    };

    pub const Union = struct {
        name: []const u8 = &.{},
        members: []const Member = &.{},
        // metadata
        comment: ?[]const u8 = null,
        enabled_by_extensions: []const []const u8 = &.{},

        pub const Member = struct {
            name: []const u8 = &.{},
            type_idx: Type.Idx = .none,
            // metadata
            len_expression: ?[]const u8 = null,
            // If member is a union, what field selects the union value
            selection: ?[]const u8 = null,
        };

        pub const Idx = enum(u32) {
            none = 0,
            _,
            pub fn init(v: anytype) @This() {
                const result: @This() = @enumFromInt(@as(u32, @truncate(v)));
                return result;
            }
        };

        pub fn member_by_selection(self: *const Union, selection: []const u8) ?*const Member {
            var result: ?*const Member = null;
            for (self.members) |*member| {
                if (member.selection) |s| {
                    if (std.mem.eql(u8, s, selection)) {
                        result = member;
                        break;
                    }
                }
            }
            return result;
        }
    };

    pub const Function = struct {
        name: []const u8 = &.{},
        return_type_idx: Type.Idx = .none,
        parameters: []const Parameter = &.{},
        // metadata
        queues: ?[]const u8 = null,
        successcodes: ?[]const u8 = null,
        errorcodes: ?[]const u8 = null,
        renderpass: ?[]const u8 = null,
        videocoding: ?[]const u8 = null,
        cmdbufferlevel: ?[]const u8 = null,
        // only valid for `vkCmd..`
        conditionalrendering: ?bool = null,
        allownoqueues: bool = false,
        comment: ?[]const u8 = null,

        pub const Parameter = struct {
            name: []const u8 = &.{},
            type_idx: Type.Idx = .none,
            // metadata
            len_expression: ?[]const u8 = null,
            optional: bool = false,
            // If parameter is a pointer to the base type (VkBaseOutStruct), what types can this
            // pointer point to
            valid_structs: ?[]const u8 = null,
        };

        pub const Idx = enum(u32) {
            none = 0,
            _,
            pub fn init(v: anytype) @This() {
                const result: @This() = @enumFromInt(@as(u32, @truncate(v)));
                return result;
            }
        };
    };

    pub fn from_xml(alloc: Allocator, tmp_alloc: Allocator, buffer: []const u8) !TypeDatabase {
        var xml_types: Xml.Types = undefined;
        var xml_features: std.ArrayListUnmanaged(Xml.Extension) = .empty;
        var xml_extensions: std.ArrayListUnmanaged(Xml.Extension) = .empty;
        var xml_enums: std.ArrayListUnmanaged(Xml.Enum) = .empty;
        var xml_constants: Xml.Constants = undefined;
        var xml_commands: std.ArrayListUnmanaged(Xml.Command) = .empty;
        var xml_spirv: Xml.Spirv = undefined;
        var parser: XmlParser = .init(buffer);
        while (parser.peek_next()) |token| {
            switch (token) {
                .element_start => |es| {
                    if (std.mem.eql(u8, es, "registry")) {
                        _ = parser.next();
                        continue;
                    } else if (std.mem.eql(u8, es, "types")) {
                        xml_types = try Xml.parse_types(tmp_alloc, &parser);
                    } else if (std.mem.eql(u8, es, "extensions")) {
                        xml_extensions = try Xml.parse_extensions(alloc, &parser);
                    } else if (std.mem.eql(u8, es, "commands")) {
                        xml_commands = try Xml.parse_commands(tmp_alloc, &parser);
                    } else if (std.mem.eql(u8, es, "spirvextensions")) {
                        xml_spirv = try Xml.parse_spirv(alloc, &parser);
                    } else if (std.mem.eql(u8, es, "enums")) {
                        if (try Xml.parse_enum(tmp_alloc, &parser)) |e| {
                            try xml_enums.append(tmp_alloc, e);
                        } else {
                            if (try Xml.parse_constants(tmp_alloc, &parser)) |c| {
                                xml_constants = c;
                            } else {
                                parser.skip_current_element();
                            }
                        }
                    } else if (std.mem.eql(u8, es, "feature")) {
                        if (try Xml.parse_extension(alloc, &parser)) |e|
                            try xml_features.append(alloc, e);
                    } else {
                        // <comment>
                        // <platforms>
                        // <tags>
                        // <formats>
                        // <sync/syncstage/syncaccess/syncpipeline>
                        // <videocodecs/videoprofiles/videocapabilities/videoformat>
                        parser.skip_current_element();
                    }
                },
                else => _ = parser.next(),
            }
        }

        var db: TypeDatabase = .{
            .alloc = alloc,
            .extensions = xml_extensions,
            .features = xml_features,
            .spirv = xml_spirv,
        };
        _ = try db.add_builtin(.void);
        _ = try db.add_builtin(.anyopaque);
        _ = try db.add_builtin(.bool);
        const type_idx_u8 = try db.add_builtin(.u8);
        const type_idx_u16 = try db.add_builtin(.u16);
        const type_idx_i32 = try db.add_builtin(.i32);
        const type_idx_u32 = try db.add_builtin(.u32);
        const type_idx_i64 = try db.add_builtin(.i64);
        const type_idx_u64 = try db.add_builtin(.u64);
        const type_idx_f32 = try db.add_builtin(.f32);
        const type_idx_f64 = try db.add_builtin(.f64);

        _ = try db.add_alias(.{ .name = "char", .type_idx = type_idx_u8 });
        _ = try db.add_alias(.{ .name = "uint8_t", .type_idx = type_idx_u8 });
        _ = try db.add_alias(.{ .name = "uint16_t", .type_idx = type_idx_u16 });
        _ = try db.add_alias(.{ .name = "int32_t", .type_idx = type_idx_i32 });
        _ = try db.add_alias(.{ .name = "uint32_t", .type_idx = type_idx_u32 });
        _ = try db.add_alias(.{ .name = "int64_t", .type_idx = type_idx_i64 });
        _ = try db.add_alias(.{ .name = "size_t", .type_idx = type_idx_u64 });
        _ = try db.add_alias(.{ .name = "uint64_t", .type_idx = type_idx_u64 });
        _ = try db.add_alias(.{ .name = "float", .type_idx = type_idx_f32 });
        _ = try db.add_alias(.{ .name = "double", .type_idx = type_idx_f64 });

        const u8_slice_ptr: Type.Pointer = .{
            .base_type_idx = type_idx_u8,
            .is_slice = true,
        };
        const u8_slice_ptr_idx = try db.resolve_pointer(u8_slice_ptr);
        _ = try db.add_alias(.{ .name = "u8_slice", .type_idx = u8_slice_ptr_idx });

        for (xml_constants.items) |*constant| {
            var value: BuiltinValue = .void;
            switch (constant.value) {
                .invalid => {},
                .u32 => |v| value = .{ .u32 = v },
                .u64 => |v| value = .{ .u64 = v },
                .f32 => |v| value = .{ .f32 = v },
            }
            _ = try db.add_constant(.{ .name = constant.name, .value = value });
        }

        for (xml_types.basetypes) |*basetype| {
            var idx = try db.resolve_base(basetype.type);
            if (basetype.pointer) {
                const pointer: Type.Pointer = .{
                    .base_type_idx = idx,
                };
                idx = try db.resolve_pointer(pointer);
            }
            const alias: Type.Alias = .{
                .name = basetype.name,
                .type_idx = idx,
            };
            _ = try db.add_alias(alias);
        }

        for (xml_types.handles) |*handle| {
            if (handle.alias) |alias| {
                const idx = try db.resolve_base(alias);
                const a: Type.Alias = .{
                    .name = handle.name,
                    .type_idx = idx,
                };
                _ = try db.add_alias(a);
            } else {
                const h: Handle = .{
                    .name = handle.name,
                    .parent = handle.parent,
                    .objtypeenum = handle.objtypeenum,
                };
                _ = try db.add_handle(h);
            }
        }

        // bitmasks and enums
        {
            const Inner = struct {
                fn enum_offset(extension_number: i32, offset: i32) i32 {
                    const BASE = 1000000000;
                    const RANGE = 1000;
                    const result = BASE + (extension_number - 1) * RANGE + offset;
                    return result;
                }

                fn less_than_bit(_: void, a: Bitfield.Bit, b: Bitfield.Bit) bool {
                    return a.bit < b.bit;
                }
                fn less_than_enum(_: void, a: Enum.Value, b: Enum.Value) bool {
                    return a.value < b.value;
                }

                fn enum_by_name(xe: []Xml.Enum, enum_name: []const u8) ?*const Xml.Enum {
                    for (xe) |*e| {
                        if (std.mem.eql(u8, e.name, enum_name))
                            return e;
                    }
                    return null;
                }
            };

            for (xml_types.bitmasks) |*bitmask| {
                switch (bitmask.value) {
                    .type => |t| {
                        var bitwidth: u32 = 0;
                        if (std.mem.eql(u8, t, "VkFlags"))
                            bitwidth = 32;
                        if (std.mem.eql(u8, t, "VkFlags64"))
                            bitwidth = 64;
                        const b: Bitfield = .{
                            .name = bitmask.name,
                            .backing_integer_width = bitwidth,
                            .bits = &.{},
                            .constants = &.{},
                        };
                        _ = try db.add_bitfield(b);
                    },
                    .enum_name => |enum_name| {
                        if (Inner.enum_by_name(xml_enums.items, enum_name)) |@"enum"| {
                            var additions: std.ArrayListUnmanaged(struct {
                                ext_name: []const u8,
                                items: Xml.Extension.EnumAdditions,
                            }) = .empty;
                            for (xml_features.items) |ext| {
                                const ex = try ext.enum_additions(alloc, @"enum".name);
                                if (ex.items.len != 0) try additions.append(
                                    alloc,
                                    .{ .ext_name = ext.name, .items = ex },
                                );
                            }
                            for (xml_extensions.items) |ext| {
                                if (ext.supported == .disabled) continue;
                                const ex = try ext.enum_additions(alloc, @"enum".name);
                                if (ex.items.len != 0) try additions.append(
                                    alloc,
                                    .{ .ext_name = ext.name, .items = ex },
                                );
                            }

                            var bits: std.ArrayListUnmanaged(Bitfield.Bit) = .empty;
                            var constants: std.ArrayListUnmanaged(Bitfield.Constant) = .empty;
                            for (@"enum".items) |item| {
                                switch (item.value) {
                                    .bitpos => |bitpos| {
                                        const bit: Bitfield.Bit = .{
                                            .name = item.name,
                                            .bit = bitpos,
                                            .comment = item.comment,
                                        };
                                        try bits.append(alloc, bit);
                                    },
                                    .value => |value| {
                                        try constants.append(
                                            alloc,
                                            .{ .name = item.name, .value = @intCast(value) },
                                        );
                                    },
                                }
                            }
                            for (additions.items) |addition| {
                                for (addition.items.items) |add| {
                                    if (add.value == .bitpos) {
                                        const bit: Bitfield.Bit = .{
                                            .name = add.name,
                                            .bit = add.value.bitpos,
                                            .enabled_by_extension = addition.ext_name,
                                        };
                                        try bits.append(alloc, bit);
                                    } else if (add.value == .value) {
                                        try constants.append(
                                            alloc,
                                            .{ .name = add.name, .value = @intCast(add.value.value) },
                                        );
                                    } else if (add.value == .offset) {
                                        const offset = add.value.offset;
                                        var value = Inner.enum_offset(
                                            @intCast(offset.extnumber),
                                            @intCast(offset.offset),
                                        );
                                        if (offset.negative) value *= -1;
                                        try constants.append(
                                            alloc,
                                            .{ .name = add.name, .value = @intCast(value) },
                                        );
                                    } else if (add.value == .alias) {
                                        const alias = add.value.alias;
                                        for (bits.items) |*bit| {
                                            if (std.mem.eql(u8, bit.name, alias)) {
                                                var b = bit.*;
                                                b.enabled_by_extension = addition.ext_name;
                                                try bits.append(alloc, b);
                                                break;
                                            }
                                        } else {
                                            for (@"enum".items) |item| {
                                                if (std.mem.eql(u8, item.name, alias)) {
                                                    if (item.value == .bitpos) {
                                                        try bits.append(alloc, .{
                                                            .name = add.name,
                                                            .bit = item.value.bitpos,
                                                            .enabled_by_extension = addition.ext_name,
                                                        });
                                                    }
                                                    break;
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                            std.mem.sortUnstable(Bitfield.Bit, bits.items, {}, Inner.less_than_bit);

                            const b: Bitfield = .{
                                .name = bitmask.name,
                                .backing_integer_width = @"enum".bitwidth,
                                .bits = bits.items,
                                .constants = constants.items,
                            };
                            const b_idx = try db.add_bitfield(b);

                            const a: Type.Alias = .{
                                .name = @"enum".name,
                                .type_idx = b_idx,
                            };
                            _ = try db.add_alias(a);
                        }
                    },
                    else => {},
                }
            }

            for (xml_enums.items) |*@"enum"| {
                if (@"enum".type == .@"enum") {
                    var additions: std.ArrayListUnmanaged(struct {
                        ext_name: []const u8,
                        items: Xml.Extension.EnumAdditions,
                    }) = .empty;
                    for (xml_features.items) |ext| {
                        const ex = try ext.enum_additions(alloc, @"enum".name);
                        if (ex.items.len != 0) try additions.append(
                            alloc,
                            .{ .ext_name = ext.name, .items = ex },
                        );
                    }
                    for (xml_extensions.items) |ext| {
                        if (ext.supported == .disabled) continue;
                        const ex = try ext.enum_additions(alloc, @"enum".name);
                        if (ex.items.len != 0) try additions.append(
                            alloc,
                            .{ .ext_name = ext.name, .items = ex },
                        );
                    }

                    var values: std.ArrayListUnmanaged(Enum.Value) = .empty;
                    for (@"enum".items) |item| {
                        if (item.value == .value) {
                            const value = item.value.value;
                            const enum_value: Enum.Value = .{
                                .name = item.name,
                                .value = @intCast(value),
                                .comment = item.comment,
                            };
                            try values.append(alloc, enum_value);
                        }
                    }
                    for (additions.items) |addition| {
                        for (addition.items.items) |add| {
                            if (add.value == .value) {
                                const value = add.value.value;
                                const enum_value: Enum.Value = .{
                                    .name = add.name,
                                    .value = @intCast(value),
                                    .enabled_by_extension = addition.ext_name,
                                };
                                try values.append(alloc, enum_value);
                            } else if (add.value == .offset) {
                                const offset = add.value.offset;
                                var value = Inner.enum_offset(
                                    @intCast(offset.extnumber),
                                    @intCast(offset.offset),
                                );
                                if (offset.negative) value *= -1;
                                const enum_value: Enum.Value = .{
                                    .name = add.name,
                                    .value = value,
                                    .enabled_by_extension = addition.ext_name,
                                };
                                try values.append(alloc, enum_value);
                            } else if (add.value == .alias) {
                                const alias = add.value.alias;
                                for (values.items) |*value| {
                                    if (std.mem.eql(u8, value.name, alias)) {
                                        var v = value.*;
                                        v.enabled_by_extension = addition.ext_name;
                                        try values.append(alloc, v);
                                        break;
                                    }
                                } else {
                                    for (@"enum".items) |item| {
                                        if (std.mem.eql(u8, item.name, alias)) {
                                            if (item.value == .value) {
                                                try values.append(alloc, .{
                                                    .name = add.name,
                                                    .value = @intCast(item.value.value),
                                                    .enabled_by_extension = addition.ext_name,
                                                });
                                            }
                                            break;
                                        }
                                    }
                                }
                            }
                        }
                    }
                    std.mem.sortUnstable(Enum.Value, values.items, {}, Inner.less_than_enum);
                    const e: Enum = .{
                        .name = @"enum".name,
                        .backing_integer_width = @"enum".bitwidth,
                        .values = values.items,
                    };
                    _ = try db.add_enum(e);
                }
            }

            for (xml_types.enum_aliases) |enum_alias| {
                const idx = try db.resolve_base(enum_alias.alias);
                const a: Type.Alias = .{
                    .name = enum_alias.name,
                    .type_idx = idx,
                };
                _ = try db.add_alias(a);
            }
        }

        outer: for (xml_types.structs) |@"struct"| {
            if (@"struct".alias) |alias| {
                const type_idx = try db.resolve_base(alias);
                const a: Type.Alias = .{
                    .name = @"struct".name,
                    .type_idx = type_idx,
                };
                _ = try db.add_alias(a);
            } else {
                var enabled_by_extensions: std.ArrayListUnmanaged([]const u8) = .empty;

                for (xml_types.structs) |s2| {
                    if (s2.alias) |alias| {
                        if (std.mem.eql(u8, @"struct".name, alias)) {
                            for (xml_features.items) |ext| {
                                if (ext.unlocks_type(s2.name)) {
                                    try enabled_by_extensions.append(alloc, ext.name);
                                    break;
                                }
                            }
                            for (xml_extensions.items) |ext| {
                                if (ext.unlocks_type(s2.name)) {
                                    if (ext.supported == .disabled) {
                                        continue :outer;
                                    } else {
                                        try enabled_by_extensions.append(alloc, ext.name);
                                        break;
                                    }
                                }
                            }
                        }
                    }
                }

                for (xml_features.items) |ext| {
                    if (ext.unlocks_type(@"struct".name)) {
                        try enabled_by_extensions.append(alloc, ext.name);
                        break;
                    }
                }
                for (xml_extensions.items) |ext| {
                    if (ext.unlocks_type(@"struct".name)) {
                        if (ext.supported == .disabled) {
                            continue :outer;
                        } else {
                            try enabled_by_extensions.append(alloc, ext.name);
                            break;
                        }
                    }
                }

                var extends: std.ArrayListUnmanaged(Type.Idx) = .empty;
                if (@"struct".extends) |ext| {
                    var iter = std.mem.splitScalar(u8, ext, ',');
                    while (iter.next()) |name| {
                        const type_idx = try db.resolve_base(name);
                        try extends.append(alloc, type_idx);
                    }
                }

                var fields: std.ArrayListUnmanaged(Struct.Field) = .empty;
                var field_idx: u32 = 0;
                while (field_idx < @"struct".members.len) {
                    var member = @"struct".members[field_idx];
                    if (member.dimensions != null and member.dimensions.?[0] == ':') {
                        var parts: std.ArrayListUnmanaged(Struct.PackedField.Part) = .empty;
                        while (field_idx < @"struct".members.len) : (field_idx += 1) {
                            member = @"struct".members[field_idx];
                            if (member.dimensions == null or member.dimensions.?[0] != ':') {
                                break;
                            } else {
                                const bits = try std.fmt.parseInt(u32, member.dimensions.?[1..], 10);
                                const part: Struct.PackedField.Part = .{
                                    .name = member.name,
                                    .bits = bits,
                                };
                                try parts.append(alloc, part);
                            }
                        }
                        const packed_field: Struct.PackedField = .{
                            .parts = parts.items,
                        };
                        try fields.append(alloc, .{ .packed_field = packed_field });
                    } else {
                        const type_idx = try db.c_type_parts_to_type(
                            member.type_front,
                            member.type_middle,
                            member.type_back,
                            member.dimensions,
                            member.len,
                            false,
                        );
                        const single_field: Struct.SingleField = .{
                            .name = member.name,
                            .type_idx = type_idx,
                            .stype_value = member.value,
                            .len_expression = member.len,
                            .other_struct_field_alias = member.other_struct_field_alias,
                            .api = member.api,
                            .stride = member.stride,
                            .deprecated = member.deprecated,
                            .externsync = member.externsync,
                            .optional = member.optional,
                            .selector = member.selector,
                            .objecttype = member.objecttype,
                            .featurelink = member.featurelink,
                            .comment = member.comment,
                        };
                        try fields.append(alloc, .{ .single_field = single_field });
                        field_idx += 1;
                    }
                }

                const s: Struct = .{
                    .name = @"struct".name,
                    .fields = fields.items,
                    .extends = extends.items,
                    .enabled_by_extensions = enabled_by_extensions.items,
                    .comment = @"struct".comment,
                    .returnedonly = @"struct".returnedonly,
                    .allowduplicate = @"struct".allowduplicate,
                };
                _ = try db.add_struct(s);
            }
        }

        outer: for (xml_types.unions) |@"union"| {
            if (@"union".alias) |alias| {
                const type_idx = try db.resolve_base(alias);
                const a: Type.Alias = .{
                    .name = @"union".name,
                    .type_idx = type_idx,
                };
                _ = try db.add_alias(a);
            } else {
                var enabled_by_extensions: std.ArrayListUnmanaged([]const u8) = .empty;

                for (xml_types.unions) |un2| {
                    if (un2.alias) |alias| {
                        if (std.mem.eql(u8, @"union".name, alias)) {
                            for (xml_features.items) |ext| {
                                if (ext.unlocks_type(un2.name)) {
                                    try enabled_by_extensions.append(alloc, ext.name);
                                    break;
                                }
                            }
                            for (xml_extensions.items) |ext| {
                                if (ext.unlocks_type(un2.name)) {
                                    if (ext.supported == .disabled) {
                                        continue :outer;
                                    } else {
                                        try enabled_by_extensions.append(alloc, ext.name);
                                        break;
                                    }
                                }
                            }
                        }
                    }
                }

                for (xml_features.items) |ext| {
                    if (ext.unlocks_type(@"union".name))
                        try enabled_by_extensions.append(alloc, ext.name);
                }
                for (xml_extensions.items) |ext| {
                    if (ext.unlocks_type(@"union".name)) {
                        if (ext.supported == .disabled) {
                            continue :outer;
                        } else {
                            try enabled_by_extensions.append(alloc, ext.name);
                        }
                    }
                }

                var members: std.ArrayListUnmanaged(Union.Member) = .empty;
                for (@"union".members) |member| {
                    const type_idx = try db.c_type_parts_to_type(
                        member.type_front,
                        member.type_middle,
                        member.type_back,
                        member.dimensions,
                        null,
                        false,
                    );
                    const m: Union.Member = .{
                        .name = member.name,
                        .type_idx = type_idx,
                        .len_expression = member.len,
                        .selection = member.selection,
                    };
                    try members.append(alloc, m);
                }

                const s: Union = .{
                    .name = @"union".name,
                    .members = members.items,
                    .comment = @"union".comment,
                    .enabled_by_extensions = enabled_by_extensions.items,
                };
                _ = try db.add_union(s);
            }
        }

        const Inner = struct {
            fn add_function(
                _alloc: Allocator,
                _db: *TypeDatabase,
                visited: *std.StringArrayHashMapUnmanaged(void),
                command: *const Xml.Command,
            ) !void {
                if (visited.get(command.name) != null) return;
                try visited.put(_alloc, command.name, {});

                if (command.alias) |alias| {
                    const idx = try _db.resolve_base(alias);
                    const a: Type.Alias = .{
                        .name = command.name,
                        .type_idx = idx,
                    };
                    _ = try _db.add_alias(a);
                } else {
                    var parameters: std.ArrayListUnmanaged(Function.Parameter) = .empty;
                    for (command.parameters) |parameter| {
                        const type_idx = try _db.c_type_parts_to_type(
                            parameter.type_front,
                            parameter.type_middle,
                            parameter.type_back,
                            parameter.dimensions,
                            parameter.len,
                            true,
                        );
                        const m: Function.Parameter = .{
                            .name = parameter.name,
                            .type_idx = type_idx,
                            .len_expression = parameter.len,
                            .optional = parameter.optional,
                            .valid_structs = parameter.valid_structs,
                        };
                        try parameters.append(_alloc, m);
                    }

                    const return_type_idx = try _db.resolve_base(command.return_type);
                    const f: Function = .{
                        .name = command.name,
                        .return_type_idx = return_type_idx,
                        .parameters = parameters.items,
                        .queues = command.queues,
                        .successcodes = command.successcodes,
                        .errorcodes = command.errorcodes,
                        .renderpass = command.renderpass,
                        .videocoding = command.videocoding,
                        .cmdbufferlevel = command.cmdbufferlevel,
                        .conditionalrendering = command.conditionalrendering,
                        .allownoqueues = command.allownoqueues,
                        .comment = command.comment,
                    };
                    const fn_idx = try _db.add_function(f);

                    const p: Type.Pointer = .{
                        .base_type_idx = fn_idx,
                        .is_const = true,
                    };
                    const p_idx = try _db.resolve_pointer(p);

                    const a: Type.Alias = .{
                        .name = try std.fmt.allocPrint(_alloc, "PFN_{s}", .{command.name}),
                        .type_idx = p_idx,
                    };
                    _ = try _db.add_alias(a);
                }
            }
        };

        var visited: std.StringArrayHashMapUnmanaged(void) = .empty;
        for (xml_commands.items) |*command| try Inner.add_function(alloc, &db, &visited, command);
        for (xml_types.funcpointers) |*command| try Inner.add_function(alloc, &db, &visited, command);

        for (db.structs.items) |*s| {
            var extended_by: std.ArrayListUnmanaged(Struct.Idx) = .empty;
            for (db.structs.items, 0..) |*s2, i| {
                for (s2.extends) |type_idx| {
                    const struct_idx = db.get_type_follow_alias(type_idx).base.struct_idx;
                    const ext = db.get_struct(struct_idx);
                    if (std.mem.eql(u8, ext.name, s.name)) {
                        try extended_by.append(alloc, .init(i + 1));
                        break;
                    }
                }
            }
            s.extended_by = extended_by.items;
        }

        return db;
    }

    pub fn extension_by_name(self: *const TypeDatabase, extension_name: []const u8) ?*const Extension {
        var result: ?*const Extension = null;
        for (self.extensions.items) |*ext| {
            if (std.mem.eql(u8, ext.name, extension_name)) {
                result = ext;
                break;
            }
        }
        return result;
    }

    pub fn get_type(
        self: *const TypeDatabase,
        type_idx: TypeDatabase.Type.Idx,
    ) *TypeDatabase.Type {
        if (type_idx == .none) {
            const Dummy = struct {
                var dummy: TypeDatabase.Type = .invalid;
            };
            return &Dummy.dummy;
        } else {
            const idx: u32 = @intFromEnum(type_idx) - 1;
            return &self.types.items[idx];
        }
    }

    pub fn get_type_follow_alias(
        self: *const TypeDatabase,
        type_idx: TypeDatabase.Type.Idx,
    ) *TypeDatabase.Type {
        if (type_idx == .none) {
            const Dummy = struct {
                var dummy: TypeDatabase.Type = .invalid;
            };
            return &Dummy.dummy;
        } else {
            const idx: u32 = @intFromEnum(type_idx) - 1;
            var result = &self.types.items[idx];
            if (result.* == .alias)
                result = self.get_type(result.alias.type_idx);
            return result;
        }
    }

    pub fn get_constant(
        self: *const TypeDatabase,
        constant_idx: Constant.Idx,
    ) *Constant {
        if (constant_idx == .none) {
            const Dummy = struct {
                var dummy: TypeDatabase.Constant = .{ .name = "dummy" };
            };
            return &Dummy.dummy;
        } else {
            const idx: u32 = @intFromEnum(constant_idx) - 1;
            return &self.constants.items[idx];
        }
    }

    pub fn get_handle(
        self: *const TypeDatabase,
        handle_idx: Handle.Idx,
    ) *Handle {
        if (handle_idx == .none) {
            const Dummy = struct {
                var dummy: Handle = .{ .name = "dummy" };
            };
            return &Dummy.dummy;
        } else {
            const idx: u32 = @intFromEnum(handle_idx) - 1;
            return &self.handles.items[idx];
        }
    }

    pub fn get_struct(
        self: *const TypeDatabase,
        struct_idx: Struct.Idx,
    ) *Struct {
        if (struct_idx == .none) {
            const Dummy = struct {
                var dummy: Struct = .{ .name = "dummy" };
            };
            return &Dummy.dummy;
        } else {
            const idx: u32 = @intFromEnum(struct_idx) - 1;
            return &self.structs.items[idx];
        }
    }

    pub fn get_bitfield(
        self: *const TypeDatabase,
        bitfield_idx: Bitfield.Idx,
    ) *Bitfield {
        if (bitfield_idx == .none) {
            const Dummy = struct {
                var dummy: Bitfield = .{ .name = "dummy" };
            };
            return &Dummy.dummy;
        } else {
            const idx: u32 = @intFromEnum(bitfield_idx) - 1;
            return &self.bitfields.items[idx];
        }
    }

    pub fn get_enum(
        self: *const TypeDatabase,
        enum_idx: Enum.Idx,
    ) *Enum {
        if (enum_idx == .none) {
            const Dummy = struct {
                var dummy: Enum = .{ .name = "dummy" };
            };
            return &Dummy.dummy;
        } else {
            const idx: u32 = @intFromEnum(enum_idx) - 1;
            return &self.enums.items[idx];
        }
    }

    pub fn get_enum_by_name(
        self: *const TypeDatabase,
        name: []const u8,
    ) ?*Enum {
        var result: ?*Enum = null;
        for (self.enums.items) |*e| {
            if (std.mem.eql(u8, e.name, name)) {
                result = e;
                break;
            }
        }
        return result;
    }

    pub fn get_union(
        self: *const TypeDatabase,
        union_idx: Union.Idx,
    ) *Union {
        if (union_idx == .none) {
            const Dummy = struct {
                var dummy: Union = .{ .name = "dummy" };
            };
            return &Dummy.dummy;
        } else {
            const idx: u32 = @intFromEnum(union_idx) - 1;
            return &self.unions.items[idx];
        }
    }

    pub fn get_function(
        self: *const TypeDatabase,
        function_idx: Function.Idx,
    ) *Function {
        if (function_idx == .none) {
            const Dummy = struct {
                var dummy: Function = .{ .name = "dummy" };
            };
            return &Dummy.dummy;
        } else {
            const idx: u32 = @intFromEnum(function_idx) - 1;
            return &self.functions.items[idx];
        }
    }

    pub fn find_placeleholder(self: *const TypeDatabase, name: []const u8) Type.Idx {
        var result: Type.Idx = .none;
        for (self.types.items, 1..) |t, i| {
            switch (t) {
                .placeholder => |n| {
                    if (std.mem.eql(u8, n, name)) {
                        result = .init(i);
                        break;
                    }
                },
                else => {},
            }
        }
        return result;
    }

    pub fn add_placeholder(self: *TypeDatabase, name: []const u8) !Type.Idx {
        const placeholder = self.find_placeleholder(name);
        var type_idx: Type.Idx = undefined;
        if (placeholder != .none) {
            type_idx = placeholder;
        } else {
            try self.types.append(self.alloc, .{ .placeholder = name });
            type_idx = .init(self.types.items.len);
        }
        return type_idx;
    }

    pub fn add_alias(
        self: *TypeDatabase,
        alias: Type.Alias,
    ) !Type.Idx {
        var type_idx: Type.Idx = undefined;
        const placeholder = self.find_placeleholder(alias.name);
        if (placeholder != .none) {
            type_idx = placeholder;
            const t = self.get_type(type_idx);
            t.* = .{ .alias = alias };
        } else {
            try self.types.append(self.alloc, .{ .alias = alias });
            type_idx = .init(self.types.items.len);
        }
        return type_idx;
    }

    pub fn add_builtin(self: *TypeDatabase, builtin: BuiltinType) !Type.Idx {
        try self.types.append(self.alloc, .{ .base = .{ .builtin = builtin } });
        const type_idx: Type.Idx = .init(self.types.items.len);
        return type_idx;
    }

    pub fn add_constant(self: *TypeDatabase, constant: Constant) !Type.Idx {
        try self.constants.append(self.alloc, constant);
        const constant_idx: Constant.Idx = .init(self.constants.items.len);

        var type_idx: Type.Idx = undefined;
        const placeholder = self.find_placeleholder(constant.name);
        if (placeholder != .none) {
            type_idx = placeholder;
            const t = self.get_type(type_idx);
            t.* = .{ .base = .{ .constant_idx = constant_idx } };
        } else {
            try self.types.append(self.alloc, .{ .base = .{ .constant_idx = constant_idx } });
            type_idx = .init(self.types.items.len);
        }
        return type_idx;
    }

    pub fn add_handle(self: *TypeDatabase, handle: Handle) !Type.Idx {
        try self.handles.append(self.alloc, handle);
        const handle_idx: Handle.Idx = .init(self.handles.items.len);

        var type_idx: Type.Idx = undefined;
        const placeholder = self.find_placeleholder(handle.name);
        if (placeholder != .none) {
            type_idx = placeholder;
            const t = self.get_type(type_idx);
            t.* = .{ .base = .{ .handle_idx = handle_idx } };
        } else {
            try self.types.append(self.alloc, .{ .base = .{ .handle_idx = handle_idx } });
            type_idx = .init(self.types.items.len);
        }
        return type_idx;
    }

    pub fn add_struct(self: *TypeDatabase, @"struct": Struct) !Type.Idx {
        try self.structs.append(self.alloc, @"struct");
        const struct_idx: Struct.Idx = .init(self.structs.items.len);

        var type_idx: Type.Idx = undefined;
        const placeholder = self.find_placeleholder(@"struct".name);
        if (placeholder != .none) {
            type_idx = placeholder;
            const t = self.get_type(type_idx);
            t.* = .{ .base = .{ .struct_idx = struct_idx } };
        } else {
            try self.types.append(self.alloc, .{ .base = .{ .struct_idx = struct_idx } });
            type_idx = .init(self.types.items.len);
        }
        return type_idx;
    }

    pub fn add_bitfield(self: *TypeDatabase, bitfield: Bitfield) !Type.Idx {
        try self.bitfields.append(self.alloc, bitfield);
        const bitfield_idx: Bitfield.Idx = .init(self.bitfields.items.len);

        var type_idx: Type.Idx = undefined;
        const placeholder = self.find_placeleholder(bitfield.name);
        if (placeholder != .none) {
            type_idx = placeholder;
            const t = self.get_type(type_idx);
            t.* = .{ .base = .{ .bitfield_idx = bitfield_idx } };
        } else {
            try self.types.append(self.alloc, .{ .base = .{ .bitfield_idx = bitfield_idx } });
            type_idx = .init(self.types.items.len);
        }

        return type_idx;
    }

    pub fn add_enum(self: *TypeDatabase, @"enum": Enum) !Type.Idx {
        try self.enums.append(self.alloc, @"enum");
        const enum_idx: Enum.Idx = .init(self.enums.items.len);

        var type_idx: Type.Idx = undefined;
        const placeholder = self.find_placeleholder(@"enum".name);
        if (placeholder != .none) {
            type_idx = placeholder;
            const t = self.get_type(type_idx);
            t.* = .{ .base = .{ .enum_idx = enum_idx } };
        } else {
            try self.types.append(self.alloc, .{ .base = .{ .enum_idx = enum_idx } });
            type_idx = .init(self.types.items.len);
        }

        return type_idx;
    }

    pub fn add_union(self: *TypeDatabase, @"union": Union) !Type.Idx {
        try self.unions.append(self.alloc, @"union");
        const union_idx: Union.Idx = .init(self.unions.items.len);

        var type_idx: Type.Idx = undefined;
        const placeholder = self.find_placeleholder(@"union".name);
        if (placeholder != .none) {
            type_idx = placeholder;
            const t = self.get_type(type_idx);
            t.* = .{ .base = .{ .union_idx = union_idx } };
        } else {
            try self.types.append(self.alloc, .{ .base = .{ .union_idx = union_idx } });
            type_idx = .init(self.types.items.len);
        }

        return type_idx;
    }

    pub fn add_function(self: *TypeDatabase, function: Function) !Type.Idx {
        try self.functions.append(self.alloc, function);
        const function_idx: Function.Idx = .init(self.functions.items.len);

        var type_idx: Type.Idx = undefined;
        const placeholder = self.find_placeleholder(function.name);
        if (placeholder != .none) {
            type_idx = placeholder;
            const t = self.get_type(type_idx);
            t.* = .{ .base = .{ .function_idx = function_idx } };
        } else {
            try self.types.append(self.alloc, .{ .base = .{ .function_idx = function_idx } });
            type_idx = .init(self.types.items.len);
        }

        return type_idx;
    }

    pub fn find_base(self: *const TypeDatabase, name: []const u8) Type.Idx {
        var result: Type.Idx = .none;
        for (self.types.items, 1..) |t, i| {
            switch (t) {
                .base => |base| {
                    switch (base) {
                        .builtin => |builtin| {
                            if (std.mem.eql(u8, name, "void") and builtin == .void) {
                                result = .init(i);
                                break;
                            }
                            if (std.mem.eql(u8, name, "anyopaque") and builtin == .anyopaque) {
                                result = .init(i);
                                break;
                            }
                            if (std.mem.eql(u8, name, "bool") and builtin == .bool) {
                                result = .init(i);
                                break;
                            }
                            if (std.mem.eql(u8, name, "u8") and builtin == .u8) {
                                result = .init(i);
                                break;
                            }
                            if (std.mem.eql(u8, name, "u16") and builtin == .u16) {
                                result = .init(i);
                                break;
                            }
                            if (std.mem.eql(u8, name, "i32") and builtin == .i32) {
                                result = .init(i);
                                break;
                            }
                            if (std.mem.eql(u8, name, "u32") and builtin == .u32) {
                                result = .init(i);
                                break;
                            }
                            if (std.mem.eql(u8, name, "i64") and builtin == .i64) {
                                result = .init(i);
                                break;
                            }
                            if (std.mem.eql(u8, name, "u64") and builtin == .u64) {
                                result = .init(i);
                                break;
                            }
                            if (std.mem.eql(u8, name, "f32") and builtin == .f32) {
                                result = .init(i);
                                break;
                            }
                            if (std.mem.eql(u8, name, "f64") and builtin == .f64) {
                                result = .init(i);
                                break;
                            }
                        },
                        .constant_idx => |idx| {
                            const s = self.get_constant(idx);
                            if (std.mem.eql(u8, name, s.name)) {
                                result = .init(i);
                                break;
                            }
                        },
                        .handle_idx => |idx| {
                            const s = self.get_handle(idx);
                            if (std.mem.eql(u8, name, s.name)) {
                                result = .init(i);
                                break;
                            }
                        },
                        .struct_idx => |idx| {
                            const s = self.get_struct(idx);
                            if (std.mem.eql(u8, name, s.name)) {
                                result = .init(i);
                                break;
                            }
                        },
                        .bitfield_idx => |idx| {
                            const s = self.get_bitfield(idx);
                            if (std.mem.eql(u8, name, s.name)) {
                                result = .init(i);
                                break;
                            }
                        },
                        .enum_idx => |idx| {
                            const s = self.get_enum(idx);
                            if (std.mem.eql(u8, name, s.name)) {
                                result = .init(i);
                                break;
                            }
                        },
                        .union_idx => |idx| {
                            const s = self.get_union(idx);
                            if (std.mem.eql(u8, name, s.name)) {
                                result = .init(i);
                                break;
                            }
                        },
                        .function_idx => |idx| {
                            const s = self.get_function(idx);
                            if (std.mem.eql(u8, name, s.name)) {
                                result = .init(i);
                                break;
                            }
                        },
                    }
                },
                .alias => |alias| {
                    if (std.mem.eql(u8, alias.name, name)) {
                        result = alias.type_idx;
                        break;
                    }
                },
                else => {},
            }
        }
        return result;
    }

    pub fn resolve_base(self: *TypeDatabase, name: []const u8) !Type.Idx {
        var result: Type.Idx = .none;
        result = self.find_base(name);
        if (result == .none)
            result = try self.add_placeholder(name);
        return result;
    }

    pub fn resolve_alias(
        self: *TypeDatabase,
        alias: Type.Alias,
    ) !Type.Idx {
        var result: Type.Idx = .none;
        for (self.types.items, 1..) |t, i| {
            switch (t) {
                .alias => |a| {
                    if (std.mem.eql(u8, a.name, alias.name)) {
                        // should not be able to add 2 aliases for the same type
                        std.debug.assert(a.type_idx == alias.type_idx);
                        result = .init(i);
                        break;
                    }
                },
                else => {},
            }
        }
        if (result == .none)
            result = try self.add_alias(alias);
        return result;
    }

    pub fn resolve_pointer(
        self: *TypeDatabase,
        _pointer: Type.Pointer,
    ) !Type.Idx {
        var pointer = _pointer;
        // if this is a `void*` style pointer, change it to `anyopaque` pointer
        var actual_base_type_idx = pointer.base_type_idx;
        const base_type = self.get_type(pointer.base_type_idx);
        switch (base_type.*) {
            .base => |base| {
                if (base == .builtin) {
                    switch (base.builtin) {
                        .void => {
                            actual_base_type_idx = try self.resolve_base("anyopaque");
                            pointer.is_slice = false;
                        },
                        else => {},
                    }
                }
            },
            else => {},
        }
        var result: Type.Idx = .none;
        for (self.types.items, 1..) |t, i| {
            switch (t) {
                .pointer => |p| {
                    if (p.base_type_idx == actual_base_type_idx and
                        p.is_slice == pointer.is_slice and
                        p.is_const == pointer.is_const and
                        p.is_zero_terminated == pointer.is_zero_terminated)
                    {
                        result = .init(i);
                        break;
                    }
                },
                else => {},
            }
        }
        if (result == .none) {
            try self.types.append(self.alloc, .{ .pointer = .{
                .base_type_idx = actual_base_type_idx,
                .is_slice = pointer.is_slice,
                .is_const = pointer.is_const,
                .is_zero_terminated = pointer.is_zero_terminated,
            } });
            result = .init(self.types.items.len);
        }
        return result;
    }

    pub fn resolve_array(self: *TypeDatabase, array: Type.Array) !Type.Idx {
        var result: Type.Idx = .none;
        for (self.types.items, 1..) |t, i| {
            switch (t) {
                .array => |a| {
                    if (a.base_type_idx == array.base_type_idx) {
                        switch (a.len) {
                            .string => |s1| {
                                switch (array.len) {
                                    .string => |s2| if (std.mem.eql(u8, s1, s2)) {
                                        result = .init(i);
                                        break;
                                    },
                                    else => {},
                                }
                            },
                            .type_idx => |idx1| {
                                switch (array.len) {
                                    .type_idx => |idx2| if (idx1 == idx2) {
                                        result = .init(i);
                                        break;
                                    },
                                    else => {},
                                }
                            },
                        }
                    }
                },
                else => {},
            }
        }
        if (result == .none) {
            try self.types.append(self.alloc, .{ .array = array });
            result = .init(self.types.items.len);
        }
        return result;
    }

    pub fn type_name(self: *const TypeDatabase, type_idx: Type.Idx) []const u8 {
        var result: []const u8 = &.{};
        const t = self.get_type(type_idx);
        switch (t.*) {
            .base => |base| {
                switch (base) {
                    .builtin => |builtin| {
                        result = @tagName(builtin);
                    },
                    .constant_idx => |idx| {
                        const s = self.get_constant(idx);
                        result = s.name;
                    },
                    .handle_idx => |idx| {
                        const s = self.get_handle(idx);
                        result = s.name;
                    },
                    .struct_idx => |idx| {
                        const s = self.get_struct(idx);
                        result = s.name;
                    },
                    .bitfield_idx => |idx| {
                        const s = self.get_bitfield(idx);
                        result = s.name;
                    },
                    .enum_idx => |idx| {
                        const s = self.get_enum(idx);
                        result = s.name;
                    },
                    .union_idx => |idx| {
                        const s = self.get_union(idx);
                        result = s.name;
                    },
                    .function_idx => |idx| {
                        const s = self.get_function(idx);
                        result = s.name;
                    },
                }
            },
        }
        return result;
    }

    pub fn type_string(
        self: *const TypeDatabase,
        alloc: Allocator,
        type_idx: Type.Idx,
    ) ![]const u8 {
        const t = self.get_type(type_idx);
        var result: []const u8 = &.{};
        switch (t.*) {
            .invalid => {
                result = "invalid";
            },
            .placeholder => |placeholder| {
                result = placeholder;
            },
            .base => |base| {
                switch (base) {
                    .builtin => |builtin| {
                        result = @tagName(builtin);
                    },
                    .constant_idx => |idx| {
                        result = self.get_constant(idx).name;
                    },
                    .handle_idx => |idx| {
                        result = self.get_handle(idx).name;
                    },
                    .struct_idx => |idx| {
                        result = self.get_struct(idx).name;
                    },
                    .bitfield_idx => |idx| {
                        result = self.get_bitfield(idx).name;
                    },
                    .enum_idx => |idx| {
                        result = self.get_enum(idx).name;
                    },
                    .union_idx => |idx| {
                        result = self.get_union(idx).name;
                    },
                    .function_idx => |idx| {
                        result = self.get_function(idx).name;
                    },
                }
            },
            .alias => |alias| {
                result = try self.type_string(alloc, alias.type_idx);
            },
            .pointer => |pointer| {
                const base_type_str = try self.type_string(alloc, pointer.base_type_idx);
                var ptr_str: []const u8 = &.{};
                if (pointer.is_slice) {
                    if (pointer.is_zero_terminated) {
                        ptr_str = "[*:0]";
                    } else {
                        ptr_str = "[*]";
                    }
                } else {
                    ptr_str = "*";
                }
                const const_str = if (pointer.is_const) "const " else &.{};
                result = try std.fmt.allocPrint(
                    alloc,
                    "{[ptr_str]s}{[const_str]s}{[base_type_str]s}",
                    .{
                        .ptr_str = ptr_str,
                        .const_str = const_str,
                        .base_type_str = base_type_str,
                    },
                );
            },
            .array => |array| {
                const base_type_str = try self.type_string(alloc, array.base_type_idx);
                var buffer: [128]u8 = undefined;
                var array_str: []const u8 = &.{};
                switch (array.len) {
                    .string => |s| {
                        array_str = s;
                    },
                    .type_idx => |idx| {
                        const constant_str = try self.type_string(alloc, idx);
                        array_str = try std.fmt.bufPrint(&buffer, "[{s}]", .{constant_str});
                    },
                }
                result = try std.fmt.allocPrint(
                    alloc,
                    "{[array_str]s}{[base_type_str]s}",
                    .{
                        .array_str = array_str,
                        .base_type_str = base_type_str,
                    },
                );
            },
        }
        return result;
    }

    pub fn c_type_parts_to_type(
        self: *TypeDatabase,
        front: []const u8,
        middle: []const u8,
        back: []const u8,
        dimensions: ?[]const u8,
        len: ?[]const u8,
        // C function arguments pretend that `const float[4]` is a pointer
        is_function_argument: bool,
    ) !Type.Idx {
        const first_asterisc = std.mem.indexOfScalar(u8, back, '*');
        const last_asterisc = std.mem.lastIndexOfScalar(u8, back, '*');
        const front_const = std.mem.indexOf(u8, front, "const");
        const back_const = std.mem.indexOf(u8, back, "const");
        var first_slice: bool = false;
        var first_zero_terminated: bool = false;
        var second_slice: bool = false;
        var second_zero_terminated: bool = false;
        if (len) |l| {
            var iter = std.mem.splitScalar(u8, l, ',');
            if (iter.next()) |v| {
                if (std.mem.eql(u8, v, "1")) {
                    //
                } else if (std.mem.eql(u8, v, "null-terminated")) {
                    first_slice = true;
                    first_zero_terminated = true;
                } else {
                    first_slice = true;
                }
            }
            if (iter.next()) |v| {
                if (std.mem.eql(u8, v, "1")) {
                    //
                } else if (std.mem.eql(u8, v, "null-terminated")) {
                    second_slice = true;
                    second_zero_terminated = true;
                } else {
                    second_slice = true;
                }
            }
        }
        var type_idx = try self.resolve_base(middle);
        if (dimensions) |dim| {
            var array: Type.Array = .{ .base_type_idx = type_idx };
            if (dim[0] == '[' or dim[0] == ':') {
                array.len = .{ .string = dim };
            } else {
                const idx = try self.resolve_base(dim);
                array.len = .{ .type_idx = idx };
            }
            type_idx = try self.resolve_array(array);
        }
        if (first_asterisc) |fa| {
            if (fa == last_asterisc.?) {
                if (first_slice) {
                    // single slice
                    const pointer: Type.Pointer = .{
                        .base_type_idx = type_idx,
                        .is_slice = true,
                        .is_zero_terminated = first_zero_terminated,
                        .is_const = front_const != null,
                    };
                    type_idx = try self.resolve_pointer(pointer);
                } else {
                    // single pointer
                    const pointer: Type.Pointer = .{
                        .base_type_idx = type_idx,
                        .is_const = front_const != null,
                    };
                    type_idx = try self.resolve_pointer(pointer);
                }
            } else {
                // doulble pointer
                if (second_slice) {
                    // second level slice
                    const pointer: Type.Pointer = .{
                        .base_type_idx = type_idx,
                        .is_slice = true,
                        .is_zero_terminated = second_zero_terminated,
                        .is_const = front_const != null,
                    };
                    type_idx = try self.resolve_pointer(pointer);
                } else {
                    // second level pointer
                    const pointer: Type.Pointer = .{
                        .base_type_idx = type_idx,
                        .is_const = front_const != null,
                    };
                    type_idx = try self.resolve_pointer(pointer);
                }
                if (first_slice) {
                    // first level slice
                    const pointer: Type.Pointer = .{
                        .base_type_idx = type_idx,
                        .is_slice = true,
                        .is_zero_terminated = first_zero_terminated,
                        .is_const = back_const != null,
                    };
                    type_idx = try self.resolve_pointer(pointer);
                } else {
                    // first level pointer
                    const pointer: Type.Pointer = .{
                        .base_type_idx = type_idx,
                        .is_const = back_const != null,
                    };
                    type_idx = try self.resolve_pointer(pointer);
                }
            }
        } else {
            if (is_function_argument and dimensions != null) {
                const pointer: Type.Pointer = .{
                    .base_type_idx = type_idx,
                    .is_const = front_const != null,
                };
                type_idx = try self.resolve_pointer(pointer);
            }
        }
        return type_idx;
    }
};

test "filtered_database" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var db: TypeDatabase = .{ .alloc = alloc };
    std.debug.print("void idx: {any}\n", .{try db.add_builtin(.void)});
    std.debug.print("anyopaque idx: {any}\n", .{try db.add_builtin(.anyopaque)});
    std.debug.print("bool idx: {any}\n", .{try db.add_builtin(.bool)});
    std.debug.print("u8 idx: {any}\n", .{try db.add_builtin(.u8)});
    std.debug.print("u16 idx: {any}\n", .{try db.add_builtin(.u16)});
    std.debug.print("i32 idx: {any}\n", .{try db.add_builtin(.i32)});
    std.debug.print("u32 idx: {any}\n", .{try db.add_builtin(.u32)});
    std.debug.print("i64 idx: {any}\n", .{try db.add_builtin(.i64)});
    std.debug.print("u64 idx: {any}\n", .{try db.add_builtin(.u64)});
    std.debug.print("f32 idx: {any}\n", .{try db.add_builtin(.f32)});
    std.debug.print("f64 idx: {any}\n", .{try db.add_builtin(.f64)});

    const c0 = try db.add_constant(.{ .name = "c0", .value = .{ .u32 = 69 } });
    std.debug.print("c0 const idx: {any}\n", .{c0});
    const s0 = try db.add_struct(.{
        .name = "s0",
        .fields = &.{
            .{ .single_field = .{ .name = "f0", .type_idx = try db.resolve_base("u32") } },
            .{ .single_field = .{ .name = "f1", .type_idx = try db.resolve_base("u64") } },
        },
    });
    std.debug.print("s0 struct idx: {any}\n", .{s0});
    const b0 = try db.add_bitfield(.{
        .name = "b0",
        .bits = &.{
            .{ .name = "f0", .bit = 0 },
            .{ .name = "f1", .bit = 1 },
        },
    });
    std.debug.print("b0 bitfield idx: {any}\n", .{b0});
    const e0 = try db.add_enum(.{
        .name = "e0",
        .values = &.{
            .{ .name = "v0", .value = 0 },
            .{ .name = "v1", .value = 1 },
        },
    });
    std.debug.print("e0 enum idx: {any}\n", .{e0});
    const _u0 = try db.add_union(.{
        .name = "u0",
        .members = &.{
            .{ .name = "m0", .type_idx = try db.resolve_base("f32") },
            .{ .name = "m1", .type_idx = try db.resolve_base("s0") },
        },
    });
    std.debug.print("u0 union idx: {any}\n", .{_u0});
    const f0 = try db.add_function(.{
        .name = "f0",
        .return_type_idx = try db.resolve_base("e0"),
        .parameters = &.{
            .{ .name = "p0", .type_idx = try db.resolve_base("bool") },
            .{ .name = "p1", .type_idx = try db.resolve_base("u0") },
        },
    });
    std.debug.print("f0 function idx: {any}\n", .{f0});

    const placeholder = db.resolve_base("c1");
    std.debug.print("placeholder for c1 const idx: {any}\n", .{placeholder});
    const c1 = try db.add_constant(.{ .name = "c1", .value = .{ .u64 = 96 } });
    std.debug.print("c1 const idx: {any}\n", .{c1});
    try std.testing.expectEqual(placeholder, c1);
    const c0_t = db.get_type(c0);
    std.debug.print("c0: {any}\n", .{c0_t});
    const c1_t = db.get_type(c1);
    std.debug.print("c1: {any}\n", .{c1_t});

    const array: TypeDatabase.Type.Array = .{
        .base_type_idx = try db.resolve_base("u32"),
        .len = .{ .type_idx = c0 },
    };
    const a0 = try db.resolve_array(array);
    const array_str = try db.type_string(alloc, a0);
    std.debug.print("a0 array idx: {any} str: {s}\n", .{ a0, array_str });

    const pointer: TypeDatabase.Type.Pointer = .{
        .base_type_idx = a0,
        .is_slice = true,
        .is_const = true,
        .is_zero_terminated = true,
    };
    const p0 = try db.resolve_pointer(pointer);
    const pointer_str = try db.type_string(alloc, p0);
    std.debug.print("p0 pointer idx: {any} str: {s}\n", .{ p0, pointer_str });
}

test "c_type_parts_to_type" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var db: TypeDatabase = .{ .alloc = alloc };
    _ = try db.add_builtin(.u32);
    _ = try db.add_builtin(.void);
    _ = try db.add_constant(.{ .name = "c0", .value = .{ .u32 = 69 } });

    {
        const t = try db.c_type_parts_to_type("", "u32", "", null, null, false);
        const t_str = try db.type_string(alloc, t);
        try std.testing.expectEqualSlices(u8, "u32", t_str);
    }

    {
        const t = try db.c_type_parts_to_type("", "u32", "*", null, null, false);
        const t_str = try db.type_string(alloc, t);
        try std.testing.expectEqualSlices(u8, "*u32", t_str);
    }

    {
        const t = try db.c_type_parts_to_type("", "u32", "*", null, "A", false);
        const t_str = try db.type_string(alloc, t);
        try std.testing.expectEqualSlices(u8, "[*]u32", t_str);
    }

    {
        const t = try db.c_type_parts_to_type("const", "u32", "*", null, null, false);
        const t_str = try db.type_string(alloc, t);
        try std.testing.expectEqualSlices(u8, "*const u32", t_str);
    }

    {
        const t = try db.c_type_parts_to_type("const", "u32", "*", "c0", null, false);
        const t_str = try db.type_string(alloc, t);
        try std.testing.expectEqualSlices(u8, "*const [c0]u32", t_str);
    }

    {
        const t = try db.c_type_parts_to_type("const", "u32", "", "c0", null, true);
        const t_str = try db.type_string(alloc, t);
        try std.testing.expectEqualSlices(u8, "*const [c0]u32", t_str);
    }

    {
        const t = try db.c_type_parts_to_type("const", "u32", "*", "[2]", null, false);
        const t_str = try db.type_string(alloc, t);
        try std.testing.expectEqualSlices(u8, "*const [2]u32", t_str);
    }

    {
        const t = try db.c_type_parts_to_type("const", "u32", "", "[2]", null, true);
        const t_str = try db.type_string(alloc, t);
        try std.testing.expectEqualSlices(u8, "*const [2]u32", t_str);
    }

    {
        const t = try db.c_type_parts_to_type("const", "u32", "* const*", null, "A,B", false);
        const t_str = try db.type_string(alloc, t);
        try std.testing.expectEqualSlices(u8, "[*]const [*]const u32", t_str);
    }

    {
        const t = try db.c_type_parts_to_type(
            "const",
            "u32",
            "* const*",
            null,
            "1,null-terminated",
            false,
        );
        const t_str = try db.type_string(alloc, t);
        try std.testing.expectEqualSlices(u8, "*const [*:0]const u32", t_str);
    }

    {
        const t = try db.c_type_parts_to_type(
            "const",
            "u32",
            "* const*",
            null,
            "A,null-terminated",
            false,
        );
        const t_str = try db.type_string(alloc, t);
        try std.testing.expectEqualSlices(u8, "[*]const [*:0]const u32", t_str);
    }

    {
        // `const void*` pointing to the array of values should be converted
        // to normal pointer `*const anyopaque` since `[*]const anyopaque` is invalid syntax
        const t = try db.c_type_parts_to_type(
            "const",
            "void",
            "*",
            null,
            "A",
            true,
        );
        const t_str = try db.type_string(alloc, t);
        try std.testing.expectEqualSlices(u8, "*const anyopaque", t_str);
    }
}

// Descriptions of XML tags/attributes:
// https://registry.khronos.org/vulkan/specs/latest/registry.html
pub const Xml = struct {
    fn parse_attributes(
        comptime PREFIX: []const u8,
        comptime PEEK: bool,
        parser: *XmlParser,
        value: anytype,
        comptime ATTRS: []const struct { []const u8, ?[]const u8 },
    ) void {
        const Inner = struct {
            fn process(v: anytype, attr: XmlParser.Attribute) void {
                var parsed: bool = false;
                inline for (ATTRS) |tuple| {
                    const attr_name, const maybe_field_name = tuple;
                    const field_name = maybe_field_name orelse attr_name;
                    if (std.mem.eql(u8, attr.name, attr_name)) {
                        switch (@TypeOf(@field(v, field_name))) {
                            u32,
                            ?u32,
                            => @field(v, field_name) = std.fmt.parseInt(u32, attr.value, 10) catch |e| blk: {
                                std.log.err("Error parsing u32: {s}: {t}", .{ attr.value, e });
                                break :blk 0;
                            },
                            ?[]const u8,
                            []const u8,
                            => @field(v, field_name) = attr.value,
                            ?bool,
                            bool,
                            => @field(v, field_name) = std.mem.eql(u8, attr.value, "true"),
                            Extension.Type,
                            => @field(v, field_name) = if (std.mem.eql(u8, attr.value, "device"))
                                .device
                            else
                                .instance,
                            Extension.Supported,
                            => {
                                if (std.mem.eql(u8, attr.value, "disabled"))
                                    @field(v, field_name) = .disabled;
                            },
                            Extension.Require.Enum.Negative,
                            => @field(v, field_name) = .{true},
                            else => |e| @compileError(std.fmt.comptimePrint(
                                "Unknown type: {s}",
                                .{@typeName(e)},
                            )),
                        }
                        parsed = true;
                    }
                }
                if (!parsed) std.log.warn(
                    "{s}: skipping attribute {s}={s}",
                    .{ PREFIX, attr.name, attr.value },
                );
            }
        };
        if (PEEK) {
            while (parser.peek_attribute()) |attr| {
                _ = parser.attribute();
                Inner.process(value, attr);
            }
        } else {
            while (parser.attribute()) |attr| {
                Inner.process(value, attr);
            }
        }
    }

    // Also <feature> tags
    pub const Extension = struct {
        name: []const u8 = &.{},
        number: []const u8 = &.{},
        author: ?[]const u8 = null,
        type: Type = .invalid,
        depends: ?[]const u8 = null,
        platform: ?[]const u8 = null,
        supported: Supported = .supported,
        promotedto: ?[]const u8 = null,
        deprecatedby: ?[]const u8 = null,
        obsoletedby: ?[]const u8 = null,
        comment: ?[]const u8 = null,

        require: []const Require = &.{},

        pub const Type = enum {
            invalid,
            instance,
            device,
        };

        pub const Supported = enum {
            supported,
            disabled,
        };

        pub const Require = struct {
            depends: ?[]const u8 = null,
            comment: ?[]const u8 = null,
            items: []const Item = &.{},

            pub const Item = union(enum) {
                comment: []const u8,
                command: Require.Command,
                @"enum": Require.Enum,
                type: Require.Type,
                feature: Require.Feature,
            };

            pub const Command = struct {
                name: []const u8 = &.{},
                comment: ?[]const u8 = null,
            };

            pub const Enum = struct {
                name: []const u8 = &.{},
                comment: ?[]const u8 = null,

                value: ?[]const u8 = null,
                bitpos: ?u32 = null,
                extends: ?[]const u8 = null,
                extnumber: ?u32 = null,
                offset: ?u32 = null,
                negative: @This().Negative = .{false},
                alias: ?[]const u8 = null,

                pub const Negative = struct { bool };
            };

            pub const Type = struct {
                name: []const u8 = &.{},
            };

            pub const Feature = struct {
                name: []const u8 = &.{},
                @"struct": ?[]const u8 = null,
                comment: ?[]const u8 = null,
            };
        };

        pub fn unlocks_type(self: *const Extension, type_name: []const u8) bool {
            for (self.require) |require| {
                for (require.items) |item| {
                    switch (item) {
                        .type => |t| {
                            if (std.mem.eql(u8, t.name, type_name)) return true;
                        },
                        else => {},
                    }
                }
            }
            return false;
        }

        pub fn unlocks_command(self: *const Extension, command_name: []const u8) bool {
            for (self.require) |require| {
                for (require.items) |item| {
                    switch (item) {
                        .command => |c| {
                            if (std.mem.eql(u8, c.name, command_name)) return true;
                        },
                        else => {},
                    }
                }
            }
            return false;
        }

        pub const EnumAddition = union(enum) {
            value: i32,
            offset: struct {
                offset: u32,
                extnumber: u32,
                negative: bool,
            },
            bitpos: u32,
            alias: []const u8,
        };
        pub const EnumAdditions =
            std.ArrayListUnmanaged(struct {
                name: []const u8,
                value: EnumAddition,
            });
        pub fn enum_additions(
            self: *const Extension,
            alloc: Allocator,
            enum_name: []const u8,
        ) !EnumAdditions {
            var result: EnumAdditions = .empty;
            for (self.require) |require| {
                for (require.items) |item| {
                    switch (item) {
                        .@"enum" => |e| {
                            if (e.extends) |ext| {
                                if (std.mem.eql(u8, ext, enum_name)) {
                                    if (e.value) |v| try result.append(
                                        alloc,
                                        .{ .name = e.name, .value = .{
                                            .value = try std.fmt.parseInt(i32, v, 10),
                                        } },
                                    );
                                    if (e.bitpos) |v| try result.append(
                                        alloc,
                                        .{ .name = e.name, .value = .{ .bitpos = v } },
                                    );
                                    if (e.offset) |v| try result.append(
                                        alloc,
                                        .{ .name = e.name, .value = .{ .offset = .{
                                            .offset = v,
                                            .extnumber = e.extnumber orelse
                                                try std.fmt.parseInt(u32, self.number, 10),
                                            .negative = e.negative[0],
                                        } } },
                                    );
                                    if (e.alias) |v| try result.append(
                                        alloc,
                                        .{ .name = e.name, .value = .{ .alias = v } },
                                    );
                                }
                            }
                        },
                        else => {},
                    }
                }
            }
            return result;
        }
    };

    pub fn parse_extension_require(alloc: Allocator, original_parser: *XmlParser) !?Extension.Require {
        if (!original_parser.check_peek_element_start("require")) return null;

        var parser = original_parser.*;
        _ = parser.element_start();

        var result: Extension.Require = .{};
        if (parser.state == .attribute) {
            parse_attributes("parse_extension_require", true, &parser, &result, &.{
                .{ "depends", null },
                .{ "comment", null },
            });
        }
        const attributes_end = parser.skip_attributes() orelse .attribute_list_end;
        if (attributes_end == .attribute_list_end_contained) return null;

        var items: std.ArrayListUnmanaged(Extension.Require.Item) = .empty;
        while (parser.element_start()) |es| {
            if (std.mem.eql(u8, es, "comment")) {
                try items.append(alloc, .{ .comment = parser.text() orelse return null });
                parser.skip_to_specific_element_end("comment");
            } else if (std.mem.eql(u8, es, "command")) {
                var e: Extension.Require.Command = .{};
                parse_attributes("parse_extension_require_command", false, &parser, &e, &.{
                    .{ "name", null },
                    .{ "comment", null },
                });
                try items.append(alloc, .{ .command = e });
            } else if (std.mem.eql(u8, es, "enum")) {
                var e: Extension.Require.Enum = .{};
                parse_attributes("parse_extension_require_enum", false, &parser, &e, &.{
                    .{ "name", null },
                    .{ "comment", null },
                    .{ "value", null },
                    .{ "bitpos", null },
                    .{ "extends", null },
                    .{ "extnumber", null },
                    .{ "offset", null },
                    .{ "dir", "negative" },
                    .{ "alias", null },
                });
                try items.append(alloc, .{ .@"enum" = e });
            } else if (std.mem.eql(u8, es, "type")) {
                var e: Extension.Require.Type = .{};
                parse_attributes("parse_extension_require_type", false, &parser, &e, &.{
                    .{ "name", null },
                });
                try items.append(alloc, .{ .type = e });
            } else if (std.mem.eql(u8, es, "feature")) {
                var e: Extension.Require.Feature = .{};
                parse_attributes("parse_extension_require_feature", false, &parser, &e, &.{
                    .{ "name", null },
                    .{ "struct", null },
                    .{ "comment", null },
                });
                try items.append(alloc, .{ .feature = e });
            } else {
                parser.skip_to_specific_element_end(es);
            }
        }
        result.items = items.items;
        original_parser.* = parser;
        return result;
    }

    test "parse_extension_require" {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        {
            const text =
                \\<require>
                \\    <comment>C</comment>
                \\    <enum value="1" name="A"/>
                \\    <enum value="&quot;B&quot;" name="B"/>
                \\    <enum offset="0" extends="E1" dir="-" name="C"/>
                \\    <enum bitpos="0" extends="E2" name="D" alias="F"/>
                \\    <type name="G"/>
                \\    <command name="E"/>
                \\    <feature name="F2" struct="S"/>
                \\</require>----
            ;

            var parser: XmlParser = .init(text);
            const r = (try parse_extension_require(alloc, &parser)).?;
            try std.testing.expectEqualSlices(u8, "----", parser.buffer);

            const expected: Extension.Require = .{
                .items = &.{
                    .{ .comment = "C" },
                    .{ .@"enum" = .{ .name = "A", .value = "1" } },
                    .{ .@"enum" = .{ .name = "B", .value = "&quot;B&quot;" } },
                    .{ .@"enum" = .{ .name = "C", .offset = 0, .extends = "E1", .negative = .{true} } },
                    .{ .@"enum" = .{ .name = "D", .bitpos = 0, .extends = "E2", .alias = "F" } },
                    .{ .type = .{ .name = "G" } },
                    .{ .command = .{ .name = "E" } },
                    .{ .feature = .{ .name = "F2", .@"struct" = "S" } },
                },
            };
            try std.testing.expectEqualDeep(expected, r);
        }
        {
            const text =
                \\<require depends="Y" comment="Z">
                \\    <comment>C</comment>
                \\    <enum value="1" name="A"/>
                \\    <enum value="&quot;B&quot;" name="B"/>
                \\    <enum offset="0" extends="E1" dir="-" name="C"/>
                \\    <enum bitpos="0" extends="E2" name="D" alias="F"/>
                \\    <type name="G"/>
                \\    <command name="E"/>
                \\    <feature name="F2" struct="S"/>
                \\</require>----
            ;

            var parser: XmlParser = .init(text);
            const r = (try parse_extension_require(alloc, &parser)).?;
            try std.testing.expectEqualSlices(u8, "----", parser.buffer);

            const expected: Extension.Require = .{
                .depends = "Y",
                .comment = "Z",
                .items = &.{
                    .{ .comment = "C" },
                    .{ .@"enum" = .{ .name = "A", .value = "1" } },
                    .{ .@"enum" = .{ .name = "B", .value = "&quot;B&quot;" } },
                    .{ .@"enum" = .{ .name = "C", .offset = 0, .extends = "E1", .negative = .{true} } },
                    .{ .@"enum" = .{ .name = "D", .bitpos = 0, .extends = "E2", .alias = "F" } },
                    .{ .type = .{ .name = "G" } },
                    .{ .command = .{ .name = "E" } },
                    .{ .feature = .{ .name = "F2", .@"struct" = "S" } },
                },
            };
            try std.testing.expectEqualDeep(expected, r);
        }
        {
            const text =
                \\<require comment="A"/>----
            ;
            var parser: XmlParser = .init(text);
            const r = try parse_extension_require(alloc, &parser);
            try std.testing.expectEqual(null, r);
        }
    }

    pub fn parse_extension(alloc: Allocator, original_parser: *XmlParser) !?Extension {
        if (!original_parser.check_peek_element_start("extension") and
            !original_parser.check_peek_element_start("feature")) return null;

        var parser = original_parser.*;
        _ = parser.element_start();

        var result: Extension = .{};
        parse_attributes("parse_extension_require", false, &parser, &result, &.{
            .{ "name", null },
            .{ "number", null },
            .{ "author", null },
            .{ "type", null },
            .{ "depends", null },
            .{ "platform", null },
            .{ "supported", null },
            .{ "promotedto", null },
            .{ "deprecatedby", null },
            .{ "obsoletedby", null },
            .{ "comment", null },
        });

        var fields: std.ArrayListUnmanaged(Extension.Require) = .empty;
        while (parser.peek_element_start()) |next_es| {
            if (std.mem.eql(u8, next_es, "require")) {
                if (try parse_extension_require(alloc, &parser)) |r|
                    try fields.append(alloc, r)
                else
                    parser.skip_current_element();
            } else {
                // <remove>
                // <deprecate>
                parser.skip_current_element();
            }
        }
        result.require = fields.items;
        _ = parser.element_end();

        original_parser.* = parser;
        return result;
    }

    test "parse_single_extension" {
        const text =
            \\<extension name="A" number="1" type="device" author="B" depends="C" platform="P" contact="D" supported="disabled" promotedto="E" ratified="F" deprecatedby="G">
            \\    <require>
            \\        <comment>C</comment>
            \\        <enum value="1" name="A"/>
            \\    </require>
            \\    <require depends="B">
            \\        <comment>C</comment>
            \\        <enum value="2" name="B"/>
            \\    </require>
            \\    <deprecate explanationlink="D">
            \\        <command name="D"/>
            \\    </deprecate>
            \\</extension>----
        ;

        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        var parser: XmlParser = .init(text);
        const e = (try parse_extension(alloc, &parser)).?;
        try std.testing.expectEqualSlices(u8, "----", parser.buffer);
        const expected: Extension = .{
            .name = "A",
            .number = "1",
            .author = "B",
            .type = .device,
            .depends = "C",
            .platform = "P",
            .supported = .disabled,
            .promotedto = "E",
            .deprecatedby = "G",
            .require = &.{
                .{
                    .items = &.{
                        .{ .comment = "C" },
                        .{ .@"enum" = .{ .name = "A", .value = "1" } },
                    },
                },
                .{
                    .depends = "B",
                    .items = &.{
                        .{ .comment = "C" },
                        .{ .@"enum" = .{ .name = "B", .value = "2" } },
                    },
                },
            },
        };
        try std.testing.expectEqualDeep(expected, e);
    }

    test "parse_single_feature" {
        const text =
            \\<feature api="vulkan,vulkansc,vulkanbase" apitype="internal" name="N" number="1.1" depends="D">
            \\    <require>
            \\        <type name="N"/>
            \\    </require>
            \\    <require comment="C">
            \\        <command name="Q"/>
            \\    </require>
            \\</feature>----
        ;

        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        var parser: XmlParser = .init(text);
        const e = (try parse_extension(alloc, &parser)).?;
        try std.testing.expectEqualSlices(u8, "----", parser.buffer);
        const expected: Extension = .{
            .name = "N",
            .number = "1.1",
            .depends = "D",
            .require = &.{
                .{
                    .items = &.{
                        .{ .type = .{ .name = "N" } },
                    },
                },
                .{
                    .comment = "C",
                    .items = &.{
                        .{ .command = .{ .name = "Q" } },
                    },
                },
            },
        };
        try std.testing.expectEqualDeep(expected, e);
    }

    pub fn parse_extensions(alloc: Allocator, parser: *XmlParser) !std.ArrayListUnmanaged(Extension) {
        if (!parser.check_peek_element_start("extensions")) return .empty;

        _ = parser.element_start();
        _ = parser.skip_attributes();

        var extensions: std.ArrayListUnmanaged(Extension) = .empty;
        while (true) {
            switch (parser.peek_next() orelse break) {
                .element_end => |es| if (std.mem.eql(u8, es, "extensions")) break,
                else => {},
            }

            if (try parse_extension(alloc, parser)) |ext|
                try extensions.append(alloc, ext)
            else
                parser.skip_current_element();
        }
        _ = parser.next();
        return extensions;
    }

    test "parse_extensions" {
        const text =
            \\<extensions comment="Text">
            \\  <extension name="A" number="1" type="device" author="G" depends="B" contact="G" supported="S" promotedto="C" ratified="G">
            \\      <require>
            \\      </require>
            \\  </extension>
            \\  <extension name="D" number="2" type="instance" author="G" depends="E" contact="G" supported="S" promotedto="F" ratified="G">
            \\      <require>
            \\      </require>
            \\  </extension>
            \\</extensions>----
        ;

        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        var parser: XmlParser = .init(text);
        const e = try parse_extensions(alloc, &parser);
        try std.testing.expectEqualSlices(u8, "----", parser.buffer);
        const expected: []const Extension = &.{
            .{
                .name = "A",
                .number = "1",
                .author = "G",
                .type = .device,
                .depends = "B",
                .supported = .supported,
                .promotedto = "C",
                .require = &.{.{}},
            },
            .{
                .name = "D",
                .number = "2",
                .author = "G",
                .type = .instance,
                .depends = "E",
                .supported = .supported,
                .promotedto = "F",
                .require = &.{.{}},
            },
        };
        try std.testing.expectEqualDeep(expected, e.items);
    }

    pub const Types = struct {
        basetypes: []const Basetype = &.{},
        handles: []const Handle = &.{},
        bitmasks: []const Bitmask = &.{},
        enum_aliases: []const EnumAlias = &.{},
        funcpointers: []const Command = &.{},
        structs: []const Struct = &.{},
        unions: []const Union = &.{},
    };

    pub const Basetype = struct {
        name: []const u8 = &.{},
        type: []const u8 = &.{},
        pointer: bool = false,
    };

    pub fn parse_basetype(original_parser: *XmlParser) ?Basetype {
        if (!original_parser.check_peek_element_start("type")) return null;

        var parser = original_parser.*;
        _ = parser.element_start();

        const first_attr = parser.attribute() orelse return null;
        if (!std.mem.eql(u8, first_attr.name, "category") or
            !std.mem.eql(u8, first_attr.value, "basetype"))
            return null;
        _ = parser.skip_attributes();

        var result: Basetype = .{};
        _ = parser.skip_text();
        const start = parser.element_start() orelse return null;
        if (std.mem.eql(u8, start, "type")) {
            result.type = parser.text() orelse return null;
            parser.skip_to_specific_element_end("type");

            // Special case just for VkRemoteAddressNV, since it defineds itself
            // over multiple `text` segments where the second one does not normally
            // exist, but just for NVIDIA there is an exception apparently.
            if (parser.peek_text()) |text2| {
                result.pointer = std.mem.indexOf(u8, text2, "*") != null;
            }

            parser.skip_to_specific_element_start("name");
            result.name = parser.text() orelse return null;
            parser.skip_to_specific_element_end("type");
        } else {
            return null;
        }

        original_parser.* = parser;
        return result;
    }

    test "parse_basetype" {
        {
            const text =
                \\<type category="basetype">#ifdef __OBJC__
                \\@class CAMetalLayer;
                \\#else
                \\typedef void <name>A</name>;
                \\#endif</type>----
            ;
            var parser: XmlParser = .init(text);
            const b = parse_basetype(&parser);
            try std.testing.expectEqual(null, b);
        }
        {
            const text =
                \\<type category="basetype">typedef <type>uint32_t</type> <name>A</name>;</type>----
            ;
            var parser: XmlParser = .init(text);
            const b = parse_basetype(&parser).?;
            try std.testing.expectEqualSlices(u8, "----", parser.buffer);
            const expected: Basetype = .{
                .name = "A",
                .type = "uint32_t",
            };
            try std.testing.expectEqualDeep(expected, b);
        }
        {
            const text =
                \\<type category="basetype">typedef <type>void</type>* <name>A</name>;</type>----
            ;
            var parser: XmlParser = .init(text);
            const b = parse_basetype(&parser).?;
            try std.testing.expectEqualSlices(u8, "----", parser.buffer);
            const expected: Basetype = .{
                .name = "A",
                .type = "void",
                .pointer = true,
            };
            try std.testing.expectEqualDeep(expected, b);
        }
    }

    pub const Handle = struct {
        name: []const u8 = &.{},
        alias: ?[]const u8 = null,
        parent: ?[]const u8 = null,
        objtypeenum: ?[]const u8 = null,
    };

    pub fn parse_handle(original_parser: *XmlParser) ?Handle {
        if (!original_parser.check_peek_element_start("type")) return null;

        var parser = original_parser.*;
        _ = parser.element_start();

        const first_attr = parser.attribute() orelse return null;
        if (!std.mem.eql(u8, first_attr.name, "category") or
            !std.mem.eql(u8, first_attr.value, "handle"))
            return null;

        var result: Handle = .{};
        parse_attributes("parse_handle", false, &parser, &result, &.{
            .{ "name", null },
            .{ "alias", null },
            .{ "parent", null },
            .{ "objtypeenum", null },
        });

        if (result.alias == null) {
            parser.skip_to_specific_element_start("name");
            result.name = parser.text() orelse return null;
            parser.skip_to_specific_element_end("type");
        }

        original_parser.* = parser;
        return result;
    }

    test "parse_handle" {
        {
            const text =
                \\<type category="handle" parent="P" objtypeenum="O"><type>T</type>(<name>N</name>)</type>----
            ;
            var parser: XmlParser = .init(text);
            const b = parse_handle(&parser).?;
            try std.testing.expectEqualSlices(u8, "----", parser.buffer);
            const expected: Handle = .{
                .name = "N",
                .parent = "P",
                .objtypeenum = "O",
            };
            try std.testing.expectEqualDeep(expected, b);
        }
        {
            const text =
                \\<type category="handle" name="N"   alias="A"/>----
            ;
            var parser: XmlParser = .init(text);
            const b = parse_handle(&parser).?;
            try std.testing.expectEqualSlices(u8, "----", parser.buffer);
            const expected: Handle = .{
                .name = "N",
                .alias = "A",
            };
            try std.testing.expectEqualDeep(expected, b);
        }
    }

    pub const Bitmask = struct {
        name: []const u8 = &.{},
        value: union(enum) {
            invalid: void,
            enum_name: []const u8,
            type: []const u8,
            alias: []const u8,
        } = .invalid,
    };

    pub fn parse_bitmask(original_parser: *XmlParser) ?Bitmask {
        if (!original_parser.check_peek_element_start("type")) return null;

        var parser = original_parser.*;
        _ = parser.element_start();

        var found_category: bool = false;
        var result: Bitmask = .{};
        if (parser.state == .attribute) {
            while (parser.attribute()) |attr| {
                if (std.mem.eql(u8, attr.name, "requires")) {
                    result.value = .{ .enum_name = attr.value };
                } else if (std.mem.eql(u8, attr.name, "bitvalues")) {
                    result.value = .{ .enum_name = attr.value };
                } else if (std.mem.eql(u8, attr.name, "name")) {
                    result.name = attr.value;
                } else if (std.mem.eql(u8, attr.name, "alias")) {
                    result.value = .{ .alias = attr.value };
                } else if (std.mem.eql(u8, attr.name, "api")) {
                    if (std.mem.eql(u8, attr.value, "vulkansc"))
                        return null;
                } else if (std.mem.eql(u8, attr.name, "category")) {
                    if (!std.mem.eql(u8, attr.value, "bitmask"))
                        return null
                    else
                        found_category = true;
                }
            }
        }
        if (!found_category) return null;

        if (result.value != .alias) {
            // Bitmasks not attached to enums need to parse <type>...</type> just in
            // case
            if (result.value == .invalid) {
                parser.skip_to_specific_element_start("type");
                const text = parser.text() orelse return null;
                result.value = .{ .type = text };
            }

            parser.skip_to_specific_element_start("name");
            result.name = parser.text() orelse return null;
            parser.skip_to_specific_element_end("type");
        }

        original_parser.* = parser;
        return result;
    }

    test "parse_bitmask" {
        {
            const text =
                \\<type requires="B" category="bitmask">typedef <type>VkFlags</type> <name>A</name>;</type>----
            ;
            var parser: XmlParser = .init(text);
            const b = parse_bitmask(&parser).?;
            try std.testing.expectEqualSlices(u8, "----", parser.buffer);
            const expected: Bitmask = .{
                .name = "A",
                .value = .{ .enum_name = "B" },
            };
            try std.testing.expectEqualDeep(expected, b);
        }
        {
            const text =
                \\<type category="bitmask">typedef <type>VkFlags</type> <name>A</name>;</type>----
            ;
            var parser: XmlParser = .init(text);
            const b = parse_bitmask(&parser).?;
            try std.testing.expectEqualSlices(u8, "----", parser.buffer);
            const expected: Bitmask = .{
                .name = "A",
                .value = .{ .type = "VkFlags" },
            };
            try std.testing.expectEqualDeep(expected, b);
        }
        {
            const text =
                \\<type category="bitmask" name="N" alias="A"/>----
            ;
            var parser: XmlParser = .init(text);
            const b = parse_bitmask(&parser).?;
            try std.testing.expectEqualSlices(u8, "----", parser.buffer);
            const expected: Bitmask = .{
                .name = "N",
                .value = .{ .alias = "A" },
            };
            try std.testing.expectEqualDeep(expected, b);
        }
    }

    pub fn parse_funcpointer(alloc: Allocator, original_parser: *XmlParser) !?Command {
        if (!original_parser.check_peek_element_start("type")) return null;

        var parser = original_parser.*;
        _ = parser.element_start();

        const first_attr = parser.attribute() orelse return null;
        if (!std.mem.eql(u8, first_attr.name, "category") or
            !std.mem.eql(u8, first_attr.value, "funcpointer"))
            return null;

        var result: Command = .{};
        parser.skip_to_specific_element_start("proto");
        parser.skip_to_specific_element_start("type");
        result.return_type = parser.text() orelse return null;
        parser.skip_to_specific_element_end("type");
        if (parser.peek_text()) |text| {
            // "void*" -> "u8_slice" since commands usually only have 1 part for return type, but
            // here there are 2, so we cheat a bit
            if (text[0] == '*') {
                result.return_type = "u8_slice";
            }
        }
        parser.skip_to_specific_element_start("name");

        // Functions must have their pure name (so without `PFN_` prefix)
        // During addition of functions to the TypeDatabase, the additional
        // pointer type will be added like `*const ...` to be an alias for
        // other `PFN_*` usages within structs. This way when struct resolves
        // it's `PFN_*` member type, it will get the `*const ...` pointer.
        result.name = parser.text() orelse return null;
        if (!std.mem.startsWith(u8, result.name, "PFN_")) return null;
        result.name = result.name["PFN_".len..];

        parser.skip_to_specific_element_end("proto");

        var values: std.ArrayListUnmanaged(Command.Parameter) = .empty;
        while (true) {
            switch (parser.peek_next() orelse break) {
                .element_end => |es| if (std.mem.eql(u8, es, "type")) break,
                else => {},
            }
            if (parse_command_parameter(&parser)) |t| {
                try values.append(alloc, t);
            } else {
                if (parser.peek_element_start()) |_|
                    parser.skip_current_element()
                else {
                    parser.skip_to_specific_element_end("type");
                    break;
                }
            }
        }
        _ = parser.next();
        result.parameters = values.items;

        original_parser.* = parser;
        return result;
    }

    test "parse_funcpointer" {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const alloc = arena.allocator();
        {
            const text =
                \\<type category="funcpointer">
                \\    <proto><type>void</type> <name>PFN_vkInternalAllocationNotification</name></proto>
                \\    <param><type>void</type>*                       <name>pUserData</name></param>
                \\    <param><type>size_t</type>                      <name>size</name></param>
                \\    <param><type>VkInternalAllocationType</type>    <name>allocationType</name></param>
                \\    <param><type>VkSystemAllocationScope</type>     <name>allocationScope</name></param>
                \\</type>----
            ;

            var parser: XmlParser = .init(text);
            const f = (try parse_funcpointer(alloc, &parser)).?;

            const expected: Command = .{
                .name = "vkInternalAllocationNotification",
                .return_type = "void",
                .parameters = &.{
                    .{
                        .name = "pUserData",
                        .type_middle = "void",
                        .type_back = "*                       ",
                    },
                    .{
                        .name = "size",
                        .type_middle = "size_t",
                    },
                    .{
                        .name = "allocationType",
                        .type_middle = "VkInternalAllocationType",
                    },
                    .{
                        .name = "allocationScope",
                        .type_middle = "VkSystemAllocationScope",
                    },
                },
            };
            try std.testing.expectEqualDeep(expected, f);
        }
        {
            const text =
                \\<type category="funcpointer">
                \\    <proto><type>void</type> <name>PFN_vkInternalFreeNotification</name></proto>
                \\    <param><type>void</type>*                       <name>pUserData</name></param>
                \\    <param><type>size_t</type>                      <name>size</name></param>
                \\    <param><type>VkInternalAllocationType</type>    <name>allocationType</name></param>
                \\    <param><type>VkSystemAllocationScope</type>     <name>allocationScope</name></param>
                \\</type>----
            ;

            var parser: XmlParser = .init(text);
            const f = (try parse_funcpointer(alloc, &parser)).?;

            const expected: Command = .{
                .name = "vkInternalFreeNotification",
                .return_type = "void",
                .parameters = &.{
                    .{
                        .name = "pUserData",
                        .type_middle = "void",
                        .type_back = "*                       ",
                    },
                    .{
                        .name = "size",
                        .type_middle = "size_t",
                    },
                    .{
                        .name = "allocationType",
                        .type_middle = "VkInternalAllocationType",
                    },
                    .{
                        .name = "allocationScope",
                        .type_middle = "VkSystemAllocationScope",
                    },
                },
            };
            try std.testing.expectEqualDeep(expected, f);
        }
        {
            const text =
                \\<type category="funcpointer">
                \\    <proto><type>void</type>* <name>PFN_vkReallocationFunction</name></proto>
                \\    <param><type>void</type>*                       <name>pUserData</name></param>
                \\    <param><type>void</type>*                       <name>pOriginal</name></param>
                \\    <param><type>size_t</type>                      <name>size</name></param>
                \\    <param><type>size_t</type>                      <name>alignment</name></param>
                \\    <param><type>VkSystemAllocationScope</type>     <name>allocationScope</name></param>
                \\</type>----
            ;

            var parser: XmlParser = .init(text);
            const f = (try parse_funcpointer(alloc, &parser)).?;

            const expected: Command = .{
                .name = "vkReallocationFunction",
                .return_type = "u8_slice",
                .parameters = &.{
                    .{
                        .name = "pUserData",
                        .type_middle = "void",
                        .type_back = "*                       ",
                    },
                    .{
                        .name = "pOriginal",
                        .type_middle = "void",
                        .type_back = "*                       ",
                    },
                    .{
                        .name = "size",
                        .type_middle = "size_t",
                    },
                    .{
                        .name = "alignment",
                        .type_middle = "size_t",
                    },
                    .{
                        .name = "allocationScope",
                        .type_middle = "VkSystemAllocationScope",
                    },
                },
            };
            try std.testing.expectEqualDeep(expected, f);
        }
        {
            const text =
                \\<type category="funcpointer">
                \\    <proto><type>void</type>* <name>PFN_vkAllocationFunction</name></proto>
                \\    <param><type>void</type>*                       <name>pUserData</name></param>
                \\    <param><type>size_t</type>                      <name>size</name></param>
                \\    <param><type>size_t</type>                      <name>alignment</name></param>
                \\    <param><type>VkSystemAllocationScope</type>     <name>allocationScope</name></param>
                \\</type>----
            ;

            var parser: XmlParser = .init(text);
            const f = (try parse_funcpointer(alloc, &parser)).?;

            const expected: Command = .{
                .name = "vkAllocationFunction",
                .return_type = "u8_slice",
                .parameters = &.{
                    .{
                        .name = "pUserData",
                        .type_middle = "void",
                        .type_back = "*                       ",
                    },
                    .{
                        .name = "size",
                        .type_middle = "size_t",
                    },
                    .{
                        .name = "alignment",
                        .type_middle = "size_t",
                    },
                    .{
                        .name = "allocationScope",
                        .type_middle = "VkSystemAllocationScope",
                    },
                },
            };
            try std.testing.expectEqualDeep(expected, f);
        }
        {
            const text =
                \\<type category="funcpointer">
                \\    <proto><type>void</type> <name>PFN_vkFreeFunction</name></proto>
                \\    <param><type>void</type>*                       <name>pUserData</name></param>
                \\    <param><type>void</type>*                       <name>pMemory</name></param>
                \\</type>----
            ;

            var parser: XmlParser = .init(text);
            const f = (try parse_funcpointer(alloc, &parser)).?;

            const expected: Command = .{
                .name = "vkFreeFunction",
                .return_type = "void",
                .parameters = &.{
                    .{
                        .name = "pUserData",
                        .type_middle = "void",
                        .type_back = "*                       ",
                    },
                    .{
                        .name = "pMemory",
                        .type_middle = "void",
                        .type_back = "*                       ",
                    },
                },
            };
            try std.testing.expectEqualDeep(expected, f);
        }
        {
            const text =
                \\<type category="funcpointer">
                \\    <proto><type>void</type> <name>PFN_vkVoidFunction</name></proto>
                \\</type>----
            ;

            var parser: XmlParser = .init(text);
            const f = (try parse_funcpointer(alloc, &parser)).?;

            const expected: Command = .{
                .name = "vkVoidFunction",
                .return_type = "void",
                .parameters = &.{},
            };
            try std.testing.expectEqualDeep(expected, f);
        }
        {
            const text =
                \\<type category="funcpointer">
                \\    <proto><type>VkBool32</type> <name>PFN_vkDebugReportCallbackEXT</name></proto>
                \\    <param><type>VkDebugReportFlagsEXT</type>       <name>flags</name></param>
                \\    <param><type>VkDebugReportObjectTypeEXT</type>  <name>objectType</name></param>
                \\    <param><type>uint64_t</type>                    <name>object</name></param>
                \\    <param><type>size_t</type>                      <name>location</name></param>
                \\    <param><type>int32_t</type>                     <name>messageCode</name></param>
                \\    <param>const <type>char</type>*                 <name>pLayerPrefix</name></param>
                \\    <param>const <type>char</type>*                 <name>pMessage</name></param>
                \\    <param><type>void</type>*                       <name>pUserData</name></param>
                \\</type>----
            ;

            var parser: XmlParser = .init(text);
            const f = (try parse_funcpointer(alloc, &parser)).?;

            const expected: Command = .{
                .name = "vkDebugReportCallbackEXT",
                .return_type = "VkBool32",
                .parameters = &.{
                    .{
                        .name = "flags",
                        .type_middle = "VkDebugReportFlagsEXT",
                    },
                    .{
                        .name = "objectType",
                        .type_middle = "VkDebugReportObjectTypeEXT",
                    },
                    .{
                        .name = "object",
                        .type_middle = "uint64_t",
                    },
                    .{
                        .name = "location",
                        .type_middle = "size_t",
                    },
                    .{
                        .name = "messageCode",
                        .type_middle = "int32_t",
                    },
                    .{
                        .name = "pLayerPrefix",
                        .type_front = "const ",
                        .type_middle = "char",
                        .type_back = "*                 ",
                    },
                    .{
                        .name = "pMessage",
                        .type_front = "const ",
                        .type_middle = "char",
                        .type_back = "*                 ",
                    },
                    .{
                        .name = "pUserData",
                        .type_middle = "void",
                        .type_back = "*                       ",
                    },
                },
            };
            try std.testing.expectEqualDeep(expected, f);
        }
        {
            const text =
                \\<type category="funcpointer">
                \\    <proto><type>void</type> <name>PFN_vkFaultCallbackFunction</name></proto>
                \\    <param><type>VkBool32</type>                    <name>unrecordedFaults</name></param>
                \\    <param><type>uint32_t</type>                    <name>faultCount</name></param>
                \\    <param>const <type>VkFaultData</type>*          <name>pFaults</name></param>
                \\</type>----
            ;

            var parser: XmlParser = .init(text);
            const f = (try parse_funcpointer(alloc, &parser)).?;

            const expected: Command = .{
                .name = "vkFaultCallbackFunction",
                .return_type = "void",
                .parameters = &.{
                    .{
                        .name = "unrecordedFaults",
                        .type_middle = "VkBool32",
                    },
                    .{
                        .name = "faultCount",
                        .type_middle = "uint32_t",
                    },
                    .{
                        .name = "pFaults",
                        .type_front = "const ",
                        .type_middle = "VkFaultData",
                        .type_back = "*          ",
                    },
                },
            };
            try std.testing.expectEqualDeep(expected, f);
        }

        {
            const text =
                \\<type category="funcpointer" requires="VkDeviceMemoryReportCallbackDataEXT">
                \\    <proto><type>void</type> <name>PFN_vkDeviceMemoryReportCallbackEXT</name></proto>
                \\    <param>const <type>VkDeviceMemoryReportCallbackDataEXT</type>*  <name>pCallbackData</name></param>
                \\    <param><type>void</type>*                                       <name>pUserData</name></param>
                \\</type>----
            ;

            var parser: XmlParser = .init(text);
            const f = (try parse_funcpointer(alloc, &parser)).?;

            const expected: Command = .{
                .name = "vkDeviceMemoryReportCallbackEXT",
                .return_type = "void",
                .parameters = &.{
                    .{
                        .name = "pCallbackData",
                        .type_front = "const ",
                        .type_middle = "VkDeviceMemoryReportCallbackDataEXT",
                        .type_back = "*  ",
                    },
                    .{
                        .name = "pUserData",
                        .type_middle = "void",
                        .type_back = "*                                       ",
                    },
                },
            };
            try std.testing.expectEqualDeep(expected, f);
        }
        {
            const text =
                \\<type category="funcpointer" requires="VkInstance">
                \\    <proto><type>PFN_vkVoidFunction</type> <name>PFN_vkGetInstanceProcAddrLUNARG</name></proto>
                \\    <param><type>VkInstance</type>                  <name>instance</name></param>
                \\    <param>const <type>char</type>*                 <name>pName</name></param>
                \\</type>----
            ;

            var parser: XmlParser = .init(text);
            const f = (try parse_funcpointer(alloc, &parser)).?;

            const expected: Command = .{
                .name = "vkGetInstanceProcAddrLUNARG",
                .return_type = "PFN_vkVoidFunction",
                .parameters = &.{
                    .{
                        .name = "instance",
                        .type_middle = "VkInstance",
                    },
                    .{
                        .name = "pName",
                        .type_front = "const ",
                        .type_middle = "char",
                        .type_back = "*                 ",
                    },
                },
            };
            try std.testing.expectEqualDeep(expected, f);
        }
    }

    pub const EnumAlias = struct {
        name: []const u8 = &.{},
        alias: []const u8 = &.{},
    };

    pub fn parse_enum_alias(original_parser: *XmlParser) ?EnumAlias {
        if (!original_parser.check_peek_element_start("type")) return null;

        var parser = original_parser.*;
        _ = parser.element_start();

        var found_category: bool = false;
        var result: EnumAlias = .{};
        if (parser.state == .attribute) {
            while (parser.attribute()) |attr| {
                if (std.mem.eql(u8, attr.name, "name")) {
                    result.name = attr.value;
                } else if (std.mem.eql(u8, attr.name, "alias")) {
                    result.alias = attr.value;
                } else if (std.mem.eql(u8, attr.name, "category")) {
                    if (!std.mem.eql(u8, attr.value, "enum"))
                        return null
                    else
                        found_category = true;
                }
            }
        }
        if (!found_category or result.alias.len == 0) return null;

        original_parser.* = parser;
        return result;
    }

    test "parse_enum_alias" {
        {
            const text =
                \\<type name="N" category="enum"/>----
            ;
            var parser: XmlParser = .init(text);
            const b = parse_enum_alias(&parser);
            try std.testing.expectEqual(null, b);
        }
        {
            const text =
                \\<type name="N" category="enum" alias="A"/>----
            ;
            var parser: XmlParser = .init(text);
            const b = parse_enum_alias(&parser).?;
            try std.testing.expectEqualSlices(u8, "----", parser.buffer);
            const expected: EnumAlias = .{
                .name = "N",
                .alias = "A",
            };
            try std.testing.expectEqualDeep(expected, b);
        }
    }

    pub const Struct = struct {
        name: []const u8 = &.{},
        alias: ?[]const u8 = null,
        comment: ?[]const u8 = null,
        returnedonly: bool = false,
        extends: ?[]const u8 = null,
        allowduplicate: bool = false,

        members: []const Member = &.{},

        pub const Member = struct {
            name: []const u8 = &.{},

            type_front: []const u8 = &.{},
            type_middle: []const u8 = &.{},
            type_back: []const u8 = &.{},
            // In case the type is [4]f32 or [3][4]f32
            dimensions: ?[]const u8 = null,
            // Also known as altlen since actual `len` is a LaTex nonsence
            // How to determine the length of the array of array of arrays
            len: ?[]const u8 = null,

            // This is has a form of OTHER_TYPE::other_member as if C++ was the
            // only thing missing from this xml
            other_struct_field_alias: ?[]const u8 = null,
            value: ?[]const u8 = null,
            api: ?[]const u8 = null,
            stride: ?[]const u8 = null,
            deprecated: ?[]const u8 = null,
            externsync: bool = false,
            optional: bool = false,
            // If member is a union, what field selects the union value
            selector: ?[]const u8 = null,
            // If member is a raw u64 handle, which other member specifies what handle it is
            objecttype: ?[]const u8 = null,
            featurelink: ?[]const u8 = null,
            comment: ?[]const u8 = null,
        };

        pub fn stype(self: *const Struct) ?[]const u8 {
            for (self.members) |*member| {
                if (std.mem.eql(u8, member.name, "sType")) return member.value;
            }
            return null;
        }

        pub fn has_member(self: *const Struct, name: []const u8) bool {
            for (self.members) |*m|
                if (std.mem.eql(u8, m.name, name)) return true;
            return false;
        }
    };

    pub fn parse_struct_member(original_parser: *XmlParser) ?Struct.Member {
        if (!original_parser.check_peek_element_start("member")) return null;

        var parser = original_parser.*;
        _ = parser.element_start();

        var result: Struct.Member = .{};
        if (parser.state == .attribute) {
            parse_attributes("parse_struct_member", false, &parser, &result, &.{
                .{ "values", "value" },
                .{ "api", null },
                .{ "len", "len" },
                .{ "altlen", "len" },
                .{ "stride", null },
                .{ "deprecated", null },
                .{ "externsync", null },
                .{ "optional", null },
                .{ "selector", null },
                .{ "objecttype", null },
                .{ "featurelink", null },
            });
        }
        // skip `vulkansc` members since they just duplicate existing fields for no reason
        if (result.api) |api| if (std.mem.eql(u8, api, "vulkansc")) return null;

        if (parser.peek_text()) |text|
            result.type_front = text;

        parser.skip_to_specific_element_start("type");
        result.type_middle = parser.text() orelse return null;
        parser.skip_to_specific_element_end("type");

        if (parser.peek_text()) |text|
            result.type_back = text;

        parser.skip_to_specific_element_start("name");
        if (parser.peek_attribute()) |attr| {
            if (std.mem.eql(u8, attr.name, "alias"))
                result.other_struct_field_alias = attr.value;
            _ = parser.skip_attributes();
        }
        result.name = parser.text() orelse return null;
        parser.skip_to_specific_element_end("name");

        if (parser.peek_text()) |text| {
            _ = parser.text();
            result.dimensions = text;
            // If the length of the array is determined by the CONSTANT, then
            // it is obviously needs to be inside ENUM element
            if (parser.peek_element_start()) |next| {
                if (std.mem.eql(u8, next, "enum")) {
                    _ = parser.element_start();
                    result.dimensions = parser.text();
                    parser.skip_to_specific_element_end("enum");
                }
            }
        }

        if (parser.peek_element_start()) |next| {
            if (std.mem.eql(u8, next, "comment")) {
                _ = parser.element_start();
                result.comment = parser.text();
            }
        }

        parser.skip_to_specific_element_end("member");

        original_parser.* = parser;
        return result;
    }

    test "parse_struct_member" {
        {
            const text =
                \\<member><type>T</type> <name>N</name><comment>C</comment></member>----
            ;
            var parser: XmlParser = .init(text);
            const m = parse_struct_member(&parser).?;
            try std.testing.expectEqualSlices(u8, "----", parser.buffer);
            const expected: Struct.Member = .{
                .name = "N",
                .type_middle = "T",
                .comment = "C",
            };
            try std.testing.expectEqualDeep(expected, m);
        }
        {
            const text =
                \\<member values="V"><type>T</type> <name>N</name><comment>C</comment></member>----
            ;
            var parser: XmlParser = .init(text);
            const m = parse_struct_member(&parser).?;
            try std.testing.expectEqualSlices(u8, "----", parser.buffer);
            const expected: Struct.Member = .{
                .name = "N",
                .type_middle = "T",
                .value = "V",
                .comment = "C",
            };
            try std.testing.expectEqualDeep(expected, m);
        }
        {
            const text =
                \\<member noautovalidity="true" optional="true">const <type>T</type>* <name>N</name><comment>C</comment></member>----
            ;
            var parser: XmlParser = .init(text);
            const m = parse_struct_member(&parser).?;
            try std.testing.expectEqualSlices(u8, "----", parser.buffer);
            const expected: Struct.Member = .{
                .name = "N",
                .type_front = "const ",
                .type_middle = "T",
                .type_back = "* ",
                .optional = true,
                .comment = "C",
            };
            try std.testing.expectEqualDeep(expected, m);
        }
        {
            const text =
                \\<member optional="true"><type>T</type> <name>N</name></member>----
            ;
            var parser: XmlParser = .init(text);
            const m = parse_struct_member(&parser).?;
            try std.testing.expectEqualSlices(u8, "----", parser.buffer);
            const expected: Struct.Member = .{
                .name = "N",
                .type_middle = "T",
                .optional = true,
            };
            try std.testing.expectEqualDeep(expected, m);
        }
        {
            const text =
                \\<member len="null-terminated"> <type>T</type> <name>N</name></member>----
            ;
            var parser: XmlParser = .init(text);
            const m = parse_struct_member(&parser).?;
            try std.testing.expectEqualSlices(u8, "----", parser.buffer);
            const expected: Struct.Member = .{
                .name = "N",
                .type_middle = "T",
                .len = "null-terminated",
            };
            try std.testing.expectEqualDeep(expected, m);
        }
        {
            const text =
                \\<member len="L">const <type>T</type>* <name>N</name></member>----
            ;
            var parser: XmlParser = .init(text);
            const m = parse_struct_member(&parser).?;
            try std.testing.expectEqualSlices(u8, "----", parser.buffer);
            const expected: Struct.Member = .{
                .name = "N",
                .type_front = "const ",
                .type_middle = "T",
                .type_back = "* ",
                .len = "L",
            };
            try std.testing.expectEqualDeep(expected, m);
        }
        {
            const text =
                \\<member len="L,null-terminated">const <type>T</type>* <name>N</name></member>----
            ;
            var parser: XmlParser = .init(text);
            const m = parse_struct_member(&parser).?;
            try std.testing.expectEqualSlices(u8, "----", parser.buffer);
            const expected: Struct.Member = .{
                .name = "N",
                .type_front = "const ",
                .type_middle = "T",
                .type_back = "* ",
                .len = "L,null-terminated",
            };
            try std.testing.expectEqualDeep(expected, m);
        }
        {
            const text =
                \\<member len="L,null-terminated" deprecated="I">const <type>T</type>* const*      <name>N</name><comment>C</comment></member>----
            ;
            var parser: XmlParser = .init(text);
            const m = parse_struct_member(&parser).?;
            try std.testing.expectEqualSlices(u8, "----", parser.buffer);
            const expected: Struct.Member = .{
                .name = "N",
                .type_front = "const ",
                .type_middle = "T",
                .type_back = "* const*      ",
                .len = "L,null-terminated",
                .deprecated = "I",
                .comment = "C",
            };
            try std.testing.expectEqualDeep(expected, m);
        }
        {
            const text =
                \\<member><type>T</type> <name>N</name>[3][4]</member>----
            ;
            var parser: XmlParser = .init(text);
            const m = parse_struct_member(&parser).?;
            try std.testing.expectEqualSlices(u8, "----", parser.buffer);
            const expected: Struct.Member = .{
                .name = "N",
                .type_middle = "T",
                .dimensions = "[3][4]",
            };
            try std.testing.expectEqualDeep(expected, m);
        }
        {
            const text =
                \\<member len="null-terminated"><type>T</type> <name>N</name>[<enum>L</enum>]</member>----
            ;
            var parser: XmlParser = .init(text);
            const m = parse_struct_member(&parser).?;
            try std.testing.expectEqualSlices(u8, "----", parser.buffer);
            const expected: Struct.Member = .{
                .name = "N",
                .type_middle = "T",
                .len = "null-terminated",
                .dimensions = "L",
            };
            try std.testing.expectEqualDeep(expected, m);
        }
        {
            const text =
                \\<member selector="S"><type>T</type> <name>N</name></member>----
            ;
            var parser: XmlParser = .init(text);
            const m = parse_struct_member(&parser).?;
            try std.testing.expectEqualSlices(u8, "----", parser.buffer);
            const expected: Struct.Member = .{
                .name = "N",
                .type_middle = "T",
                .selector = "S",
            };
            try std.testing.expectEqualDeep(expected, m);
        }
        {
            const text =
                \\<member api="vulkansc"><type>T</type> <name>N</name></member>----
            ;
            var parser: XmlParser = .init(text);
            const m = parse_struct_member(&parser);
            try std.testing.expectEqual(null, m);
        }
        {
            const text =
                \\<member><type>T</type><name alias="AAA::bbb">N</name></member>----
            ;
            var parser: XmlParser = .init(text);
            const m = parse_struct_member(&parser).?;
            try std.testing.expectEqualSlices(u8, "----", parser.buffer);
            const expected: Struct.Member = .{
                .name = "N",
                .type_middle = "T",
                .other_struct_field_alias = "AAA::bbb",
            };
            try std.testing.expectEqualDeep(expected, m);
        }
    }

    pub fn parse_struct(alloc: Allocator, original_parser: *XmlParser) !?Struct {
        if (!original_parser.check_peek_element_start("type")) return null;

        var parser = original_parser.*;
        _ = parser.element_start();
        if (parser.state != .attribute) return null;

        var result: Struct = .{};
        const first_attr = parser.attribute().?;
        if (!std.mem.eql(u8, first_attr.name, "category") or
            !std.mem.eql(u8, first_attr.value, "struct"))
            return null;

        parse_attributes("parse_struct", true, &parser, &result, &.{
            .{ "name", null },
            .{ "alias", null },
            .{ "comment", null },
            .{ "returnedonly", null },
            .{ "structextends", "extends" },
            .{ "allowduplicate", null },
        });

        const attributes_end = parser.skip_attributes() orelse return null;
        if (attributes_end != .attribute_list_end_contained) {
            var members: std.ArrayListUnmanaged(Struct.Member) = .empty;
            while (true) {
                if (parse_struct_member(&parser)) |member| {
                    try members.append(alloc, member);
                } else {
                    if (parser.peek_element_start()) |_|
                        parser.skip_current_element()
                    else {
                        parser.skip_to_specific_element_end("type");
                        break;
                    }
                }
            }

            result.members = members.items;
        }
        original_parser.* = parser;
        return result;
    }

    test "parse_single_struct" {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        {
            const text =
                \\<type category="struct" name="N" structextends="E">
                \\    <member values="V"><type>T1</type> <name>N1</name></member>
                \\    <member optional="true"><type>T2</type>* <name>N2</name></member>
                \\    <member><type>T3</type> <name>N3</name></member>
                \\    <member><type>T4</type> <name>N4</name></member>
                \\</type>----
            ;
            var parser: XmlParser = .init(text);
            const s = (try parse_struct(alloc, &parser)).?;
            try std.testing.expectEqualSlices(u8, "----", parser.buffer);
            const expected: Struct = .{
                .name = "N",
                .extends = "E",
                .alias = null,
                .members = &.{
                    .{ .name = "N1", .type_middle = "T1", .value = "V" },
                    .{ .name = "N2", .type_middle = "T2", .type_back = "* ", .optional = true },
                    .{ .name = "N3", .type_middle = "T3" },
                    .{ .name = "N4", .type_middle = "T4" },
                },
            };
            try std.testing.expectEqualDeep(expected, s);
        }

        {
            const text =
                \\<type category="struct" name="N" structextends="E">
                \\      <comment>C</comment>
                \\    <member values="V"><type>T1</type> <name>N1</name></member>
                \\    <member optional="true"><type>T2</type>* <name>N2</name></member>
                \\      <comment>C2</comment>
                \\    <member><type>T3</type> <name>N3</name></member>
                \\      <comment>C3</comment>
                \\    <member><type>T4</type> <name>N4</name></member>
                \\</type>----
            ;
            var parser: XmlParser = .init(text);
            const s = (try parse_struct(alloc, &parser)).?;
            try std.testing.expectEqualSlices(u8, "----", parser.buffer);
            const expected: Struct = .{
                .name = "N",
                .extends = "E",
                .alias = null,
                .members = &.{
                    .{ .name = "N1", .type_middle = "T1", .value = "V" },
                    .{ .name = "N2", .type_middle = "T2", .type_back = "* ", .optional = true },
                    .{ .name = "N3", .type_middle = "T3" },
                    .{ .name = "N4", .type_middle = "T4" },
                },
            };
            try std.testing.expectEqualDeep(expected, s);
        }

        {
            const text =
                \\<type category="struct" name="N" alias="A"/>----
            ;
            var parser: XmlParser = .init(text);
            const s = (try parse_struct(alloc, &parser)).?;
            try std.testing.expectEqualSlices(u8, "----", parser.buffer);
            const expected: Struct = .{
                .name = "N",
                .extends = null,
                .alias = "A",
                .members = &.{},
            };
            try std.testing.expectEqualDeep(expected, s);
        }
    }

    pub const Union = struct {
        name: []const u8 = &.{},
        alias: ?[]const u8 = null,
        comment: ?[]const u8 = null,

        members: []const Member = &.{},

        pub const Member = struct {
            name: []const u8 = &.{},

            type_front: []const u8 = &.{},
            type_middle: []const u8 = &.{},
            type_back: []const u8 = &.{},

            len: ?[]const u8 = null,
            // If member is a union, what field selects the union value
            selection: ?[]const u8 = null,
            // In case the type is [4]f32 or [3][4]f32
            dimensions: ?[]const u8 = null,
        };
    };

    pub fn parse_union_member(original_parser: *XmlParser) ?Union.Member {
        if (!original_parser.check_peek_element_start("member")) return null;

        var parser = original_parser.*;
        _ = parser.element_start();

        var result: Union.Member = .{};
        if (parser.state == .attribute) {
            parse_attributes("parse_union_member", false, &parser, &result, &.{
                .{ "len", null },
                .{ "selection", null },
            });
        }

        if (parser.peek_text()) |text|
            result.type_front = text;

        parser.skip_to_specific_element_start("type");
        result.type_middle = parser.text() orelse return null;
        parser.skip_to_specific_element_end("type");

        if (parser.peek_text()) |text|
            result.type_back = text;

        parser.skip_to_specific_element_start("name");
        result.name = parser.text() orelse return null;
        parser.skip_to_specific_element_end("name");

        if (parser.peek_text()) |text| {
            _ = parser.text();
            result.dimensions = text;
        }

        parser.skip_to_specific_element_end("member");

        original_parser.* = parser;
        return result;
    }

    test "parse_union_member" {
        {
            const text =
                \\<member noautovalidity="true"><type>T</type> <name>N</name></member>----
            ;
            var parser: XmlParser = .init(text);
            const m = parse_union_member(&parser).?;
            try std.testing.expectEqualSlices(u8, "----", parser.buffer);
            const expected: Union.Member = .{
                .name = "N",
                .type_middle = "T",
            };
            try std.testing.expectEqualDeep(expected, m);
        }
        {
            const text =
                \\<member noautovalidity="true">const <type>T</type>* <name>N</name></member>----
            ;
            var parser: XmlParser = .init(text);
            const m = parse_union_member(&parser).?;
            try std.testing.expectEqualSlices(u8, "----", parser.buffer);
            const expected: Union.Member = .{
                .name = "N",
                .type_front = "const ",
                .type_middle = "T",
                .type_back = "* ",
            };
            try std.testing.expectEqualDeep(expected, m);
        }
        {
            const text =
                \\<member selection="S"><type>T</type> <name>N</name></member>----
            ;
            var parser: XmlParser = .init(text);
            const m = parse_union_member(&parser).?;
            try std.testing.expectEqualSlices(u8, "----", parser.buffer);
            const expected: Union.Member = .{
                .name = "N",
                .type_middle = "T",
                .selection = "S",
            };
            try std.testing.expectEqualDeep(expected, m);
        }
        {
            const text =
                \\<member len="null-terminated"><type>T</type> <name>N</name>[4]</member>----
            ;
            var parser: XmlParser = .init(text);
            const m = parse_union_member(&parser).?;
            try std.testing.expectEqualSlices(u8, "----", parser.buffer);
            const expected: Union.Member = .{
                .name = "N",
                .type_middle = "T",
                .len = "null-terminated",
                .dimensions = "[4]",
            };
            try std.testing.expectEqualDeep(expected, m);
        }
    }

    pub fn parse_union(alloc: Allocator, original_parser: *XmlParser) !?Union {
        if (!original_parser.check_peek_element_start("type")) return null;

        var parser = original_parser.*;
        _ = parser.element_start();
        if (parser.state != .attribute) return null;

        var result: Union = .{};
        const first_attr = parser.attribute().?;
        if (!std.mem.eql(u8, first_attr.name, "category") or
            !std.mem.eql(u8, first_attr.value, "union"))
            return null;

        parse_attributes("parse_struct", false, &parser, &result, &.{
            .{ "name", null },
            .{ "comment", null },
        });

        var members: std.ArrayListUnmanaged(Union.Member) = .empty;
        while (parse_union_member(&parser)) |member|
            try members.append(alloc, member);
        parser.skip_to_specific_element_end("type");
        result.members = members.items;

        original_parser.* = parser;
        return result;
    }

    test "parse_single_union" {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        {
            const text =
                \\<type category="union" name="N" comment="C">
                \\    <member><type>T1</type> <name>N1</name>[4]</member>
                \\    <member><type>T2</type> <name>N2</name>[4]</member>
                \\    <member><type>T3</type> <name>N3</name>[4]</member>
                \\</type>----
            ;
            var parser: XmlParser = .init(text);
            const s = (try parse_union(alloc, &parser)).?;
            try std.testing.expectEqualSlices(u8, "----", parser.buffer);
            const expected: Union = .{
                .name = "N",
                .comment = "C",
                .members = &.{
                    .{ .name = "N1", .type_middle = "T1", .dimensions = "[4]" },
                    .{ .name = "N2", .type_middle = "T2", .dimensions = "[4]" },
                    .{ .name = "N3", .type_middle = "T3", .dimensions = "[4]" },
                },
            };
            try std.testing.expectEqualDeep(expected, s);
        }
    }

    pub fn parse_types(alloc: Allocator, parser: *XmlParser) !Types {
        if (!parser.check_peek_element_start("types")) return .{};

        _ = parser.element_start();
        _ = parser.skip_attributes();

        var basetypes: std.ArrayListUnmanaged(Basetype) = .empty;
        var handles: std.ArrayListUnmanaged(Handle) = .empty;
        var bitmasks: std.ArrayListUnmanaged(Bitmask) = .empty;
        var enum_aliases: std.ArrayListUnmanaged(EnumAlias) = .empty;
        var funcpointers: std.ArrayListUnmanaged(Command) = .empty;
        var structs: std.ArrayListUnmanaged(Struct) = .empty;
        var unions: std.ArrayListUnmanaged(Union) = .empty;
        while (true) {
            if (parse_basetype(parser)) |v| {
                try basetypes.append(alloc, v);
            } else if (parse_handle(parser)) |v| {
                try handles.append(alloc, v);
            } else if (parse_bitmask(parser)) |v| {
                try bitmasks.append(alloc, v);
            } else if (parse_enum_alias(parser)) |v| {
                try enum_aliases.append(alloc, v);
            } else if (try parse_funcpointer(alloc, parser)) |v| {
                try funcpointers.append(alloc, v);
            } else if (try parse_struct(alloc, parser)) |v| {
                try structs.append(alloc, v);
            } else if (try parse_union(alloc, parser)) |v| {
                try unions.append(alloc, v);
            } else {
                parser.skip_current_element();
            }
            switch (parser.peek_next() orelse break) {
                .element_end => |es| if (std.mem.eql(u8, es, "types")) break,
                else => {},
            }
        }
        _ = parser.next();

        return .{
            .basetypes = basetypes.items,
            .handles = handles.items,
            .bitmasks = bitmasks.items,
            .enum_aliases = enum_aliases.items,
            .funcpointers = funcpointers.items,
            .structs = structs.items,
            .unions = unions.items,
        };
    }

    test "parse_types" {
        const text =
            \\<types comment="AAAA">
            \\    <type name="a" category="include">A</type>
            \\        <comment>AAA</comment>
            \\    <type category="include" name="X11/Xlib.h"/>
            \\    <type category="struct" name="A" alias="A"/>
            \\    <type category="struct" name="S">
            \\        <member values="V"><type>T</type> <name>N</name></member>
            \\    </type>
            \\    <type category="union" name="U">
            \\        <member><type>T</type> <name>N</name>[4]</member>
            \\    </type>
            \\    <type requires="R" category="bitmask"><type>T</type><name>N</name>;</type>
            \\</types>----
        ;

        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        var parser: XmlParser = .init(text);
        const types = try parse_types(alloc, &parser);
        try std.testing.expectEqualSlices(u8, "----", parser.buffer);

        const expected: Types = .{
            .basetypes = &.{},
            .bitmasks = &.{.{
                .name = "N",
                .value = .{ .enum_name = "R" },
            }},
            .structs = &.{
                .{
                    .name = "A",
                    .alias = "A",
                    .members = &.{},
                },
                .{
                    .name = "S",
                    .members = &.{.{ .name = "N", .type_middle = "T", .value = "V" }},
                },
            },
            .unions = &.{.{
                .name = "U",
                .members = &.{.{ .name = "N", .type_middle = "T", .dimensions = "[4]" }},
            }},
        };
        try std.testing.expectEqualDeep(expected, types);
    }

    pub const Constants = struct {
        items: []const Item = &.{},

        pub const Item = struct {
            value: union(enum) {
                invalid: void,
                u32: u32,
                u64: u64,
                f32: f32,
            } = .invalid,
            name: []const u8 = &.{},
        };
    };

    pub fn parse_constants_item(original_parser: *XmlParser) !?Constants.Item {
        if (!original_parser.check_peek_element_start("enum")) return null;

        var parser = original_parser.*;
        _ = parser.element_start();

        var result: Constants.Item = .{};
        var type_str: []const u8 = &.{};
        while (parser.attribute()) |attr| {
            if (std.mem.eql(u8, attr.name, "type")) {
                type_str = attr.value;
            } else if (std.mem.eql(u8, attr.name, "value")) {
                if (std.mem.eql(u8, type_str, "uint32_t")) {
                    var s = attr.value;
                    var inversed: bool = false;
                    if (std.mem.startsWith(u8, attr.value, "(~")) {
                        inversed = true;
                        s = s["(~".len .. s.len - "U)".len];
                    }
                    var value = std.fmt.parseInt(u32, s, 10) catch |e| {
                        std.log.err("Error parsing u32 constant: {s}: {t}", .{ s, e });
                        return e;
                    };
                    if (inversed) value = ~value;
                    result.value = .{ .u32 = value };
                } else if (std.mem.eql(u8, type_str, "uint64_t")) {
                    var s = attr.value;
                    var inversed: bool = false;
                    if (std.mem.startsWith(u8, attr.value, "(~")) {
                        inversed = true;
                        s = s["(~".len .. s.len - "ULL)".len];
                    }
                    var value = std.fmt.parseInt(u64, s, 10) catch |e| {
                        std.log.err("Error parsing u64 constant: {s}: {t}", .{ s, e });
                        return e;
                    };
                    if (inversed) value = ~value;
                    result.value = .{ .u64 = value };
                } else if (std.mem.eql(u8, type_str, "float")) {
                    const value = std.fmt.parseFloat(
                        f32,
                        attr.value[0 .. attr.value.len - 1],
                    ) catch |e| {
                        std.log.err("Error parsing f32 constant: {s}: {t}", .{ attr.value, e });
                        return e;
                    };
                    result.value = .{ .f32 = value };
                } else {
                    return null;
                }
            } else if (std.mem.eql(u8, attr.name, "name")) {
                result.name = attr.value;
            }
        }

        original_parser.* = parser;
        return result;
    }

    test "parse_single_constants_item" {
        {
            const text =
                \\<enum type="uint32_t" value="256" name="A"/>----
            ;
            var parser: XmlParser = .init(text);
            const e = (try parse_constants_item(&parser)).?;
            try std.testing.expectEqualSlices(u8, "----", parser.buffer);
            const expected: Constants.Item = .{
                .value = .{ .u32 = 256 },
                .name = "A",
            };
            try std.testing.expectEqualDeep(expected, e);
        }

        {
            const text =
                \\<enum type="uint32_t" value="(~0U)" name="A"/>----
            ;
            var parser: XmlParser = .init(text);
            const e = (try parse_constants_item(&parser)).?;
            try std.testing.expectEqualSlices(u8, "----", parser.buffer);
            const expected: Constants.Item = .{
                .value = .{ .u32 = ~@as(u32, 0) },
                .name = "A",
            };
            try std.testing.expectEqualDeep(expected, e);
        }

        {
            const text =
                \\<enum type="float" value="1000.0F" name="A"/>----
            ;
            var parser: XmlParser = .init(text);
            const e = (try parse_constants_item(&parser)).?;
            try std.testing.expectEqualSlices(u8, "----", parser.buffer);
            const expected: Constants.Item = .{
                .value = .{ .f32 = 1000.0 },
                .name = "A",
            };
            try std.testing.expectEqualDeep(expected, e);
        }

        {
            const text =
                \\<enum type="uint64_t" value="(~0ULL)" name="A"/>----
            ;
            var parser: XmlParser = .init(text);
            const e = (try parse_constants_item(&parser)).?;
            try std.testing.expectEqualSlices(u8, "----", parser.buffer);
            const expected: Constants.Item = .{
                .value = .{ .u64 = ~@as(u64, 0) },
                .name = "A",
            };
            try std.testing.expectEqualDeep(expected, e);
        }
    }

    pub fn parse_constants(alloc: Allocator, original_parser: *XmlParser) !?Constants {
        if (!original_parser.check_peek_element_start("enums")) return null;

        var parser = original_parser.*;
        _ = parser.element_start();
        if (!parser.skip_to_attribute(.{ .name = "type", .value = "constants" })) return null;

        var result: Constants = undefined;
        _ = parser.skip_attributes();

        var values: std.ArrayListUnmanaged(Constants.Item) = .empty;
        while (true) {
            switch (parser.peek_next() orelse break) {
                .element_end => |es| if (std.mem.eql(u8, es, "enums")) break,
                else => {},
            }
            if (try parse_constants_item(&parser)) |t| {
                try values.append(alloc, t);
            } else {
                parser.skip_current_element();
            }
        }
        _ = parser.next();
        result.items = values.items;

        original_parser.* = parser;
        return result;
    }

    test "parse_constants" {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const alloc = arena.allocator();
        {
            const text =
                \\<enums name="N" type="constants" comment="C">
                \\    <enum type="uint32_t" value="256"       name="32"/>
                \\    <enum type="uint64_t" value="512"       name="64"/>
                \\    <enum type="uint32_t" value="(~0U)"     name="~32"/>
                \\    <enum type="uint64_t" value="(~0ULL)"   name="~64"/>
                \\    <enum type="float"    value="1000.0F"   name="F"/>
                \\</enums>----
            ;
            var parser: XmlParser = .init(text);
            const e = (try parse_constants(alloc, &parser)).?;
            try std.testing.expectEqualSlices(u8, "----", parser.buffer);
            const expected: Constants = .{
                .items = &.{
                    .{ .value = .{ .u32 = 256 }, .name = "32" },
                    .{ .value = .{ .u64 = 512 }, .name = "64" },
                    .{ .value = .{ .u32 = ~@as(u32, 0) }, .name = "~32" },
                    .{ .value = .{ .u64 = ~@as(u64, 0) }, .name = "~64" },
                    .{ .value = .{ .f32 = 1000.0 }, .name = "F" },
                },
            };
            try std.testing.expectEqualDeep(expected, e);
        }
    }

    pub const Enum = struct {
        name: []const u8 = &.{},
        type: enum { invalid, @"enum", bitmask } = .invalid,
        comment: ?[]const u8 = null,
        bitwidth: u32 = 0,

        items: []const Item = &.{},

        pub const Item = struct {
            value: union(enum) { value: i32, bitpos: u32 } = undefined,
            name: []const u8 = &.{},
            comment: ?[]const u8 = null,
        };
    };

    pub fn parse_enum_item(original_parser: *XmlParser) !?Enum.Item {
        if (!original_parser.check_peek_element_start("enum")) return null;

        var parser = original_parser.*;
        _ = parser.element_start();

        var has_value: bool = false;
        var result: Enum.Item = .{};
        while (parser.attribute()) |attr| {
            // if theres is an `api="vulkan"` then this value is deprecated/aliased, so useless
            if (std.mem.eql(u8, attr.name, "api")) {
                return null;
            } else if (std.mem.eql(u8, attr.name, "value")) {
                const value = if (std.mem.startsWith(u8, attr.value, "0x"))
                    std.fmt.parseInt(i32, attr.value[2..], 16) catch |e| {
                        std.log.err(
                            "Error parsing enum item value as hext: {s}: {t}",
                            .{ attr.value, e },
                        );
                        return e;
                    }
                else
                    std.fmt.parseInt(i32, attr.value, 10) catch |e| {
                        std.log.err(
                            "Error parsing enum item value as dec: {s}: {t}",
                            .{ attr.value, e },
                        );
                        return e;
                    };
                result.value = .{ .value = value };
                has_value = true;
            } else if (std.mem.eql(u8, attr.name, "bitpos")) {
                const bitpos = std.fmt.parseInt(u32, attr.value, 10) catch |e| {
                    std.log.err("Error parsing enum item bitpos as dec: {s}: {t}", .{ attr.value, e });
                    return e;
                };
                result.value = .{ .bitpos = bitpos };
                has_value = true;
            } else if (std.mem.eql(u8, attr.name, "name")) {
                result.name = attr.value;
            } else if (std.mem.eql(u8, attr.name, "comment")) {
                result.comment = attr.value;
            }
        }
        if (!has_value) return null;
        original_parser.* = parser;
        return result;
    }

    test "parse_single_enum_item" {
        {
            const text =
                \\<enum value="8" name="A"/>----
            ;
            var parser: XmlParser = .init(text);
            const e = (try parse_enum_item(&parser)).?;
            try std.testing.expectEqualSlices(u8, "----", parser.buffer);
            const expected: Enum.Item = .{
                .value = .{ .value = 8 },
                .name = "A",
                .comment = null,
            };
            try std.testing.expectEqualDeep(expected, e);
        }
        {
            const text =
                \\<enum value="8" name="A" comment="C"/>----
            ;
            var parser: XmlParser = .init(text);
            const e = (try parse_enum_item(&parser)).?;
            try std.testing.expectEqualSlices(u8, "----", parser.buffer);
            const expected: Enum.Item = .{
                .value = .{ .value = 8 },
                .name = "A",
                .comment = "C",
            };
            try std.testing.expectEqualDeep(expected, e);
        }
        {
            const text =
                \\<enum value="0x8" name="A" comment="C"/>----
            ;
            var parser: XmlParser = .init(text);
            const e = (try parse_enum_item(&parser)).?;
            try std.testing.expectEqualSlices(u8, "----", parser.buffer);
            const expected: Enum.Item = .{
                .value = .{ .value = 0x8 },
                .name = "A",
                .comment = "C",
            };
            try std.testing.expectEqualDeep(expected, e);
        }
        {
            const text =
                \\<enum bitpos="8" name="A" comment="C"/>----
            ;
            var parser: XmlParser = .init(text);
            const e = (try parse_enum_item(&parser)).?;
            try std.testing.expectEqualSlices(u8, "----", parser.buffer);
            const expected: Enum.Item = .{
                .value = .{ .bitpos = 8 },
                .name = "A",
                .comment = "C",
            };
            try std.testing.expectEqualDeep(expected, e);
        }

        {
            const text =
                \\<enum api="vulkan" name="A" alias="B" deprecated="aliased"/>
            ;
            var parser: XmlParser = .init(text);
            const e = try parse_enum_item(&parser);
            try std.testing.expectEqualSlices(u8, text, parser.buffer);
            try std.testing.expectEqual(null, e);
        }
    }

    pub fn parse_enum(alloc: Allocator, original_parser: *XmlParser) !?Enum {
        if (!original_parser.check_peek_element_start("enums")) return null;

        var parser = original_parser.*;
        _ = parser.element_start();

        var result: Enum = .{};
        result.bitwidth = 32;
        while (parser.attribute()) |attr| {
            if (std.mem.eql(u8, attr.name, "name")) {
                result.name = attr.value;
            } else if (std.mem.eql(u8, attr.name, "type")) {
                if (std.mem.eql(u8, attr.value, "enum"))
                    result.type = .@"enum"
                else if (std.mem.eql(u8, attr.value, "bitmask"))
                    result.type = .bitmask
                else {
                    std.log.warn("Skipping enums block with type: {s}", .{attr.value});
                    return null;
                }
            } else if (std.mem.eql(u8, attr.name, "comment")) {
                result.comment = attr.value;
            } else if (std.mem.eql(u8, attr.name, "bitwidth")) {
                result.bitwidth = try std.fmt.parseInt(u32, attr.value, 10);
            }
        }

        var values: std.ArrayListUnmanaged(Enum.Item) = .empty;
        while (true) {
            switch (parser.peek_next() orelse break) {
                .element_end => |es| if (std.mem.eql(u8, es, "enums")) break,
                else => {},
            }
            if (try parse_enum_item(&parser)) |t| {
                try values.append(alloc, t);
            } else {
                parser.skip_current_element();
            }
        }
        _ = parser.next();
        result.items = values.items;

        original_parser.* = parser;
        return result;
    }

    test "parse_enum" {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const alloc = arena.allocator();
        {
            const text =
                \\<enums name="A" type="bitmask" bitwidth="64">
                \\    <enum bitpos="0" name="B" comment="C"/>
                \\    <enum bitpos="1" name="D" comment="E"/>
                \\    <enum value="3" name="F" comment="G"/>
                \\    <enum value="0x00000069" name="H" comment="I"/>
                \\    <enum api="vulkan"  name="N" alias="T" deprecated="Q"/>
                \\</enums>----
            ;
            var parser: XmlParser = .init(text);
            const e = (try parse_enum(alloc, &parser)).?;
            try std.testing.expectEqualSlices(u8, "----", parser.buffer);
            const expected: Enum = .{
                .type = .bitmask,
                .name = "A",
                .bitwidth = 64,
                .items = &.{
                    .{ .value = .{ .bitpos = 0 }, .name = "B", .comment = "C" },
                    .{ .value = .{ .bitpos = 1 }, .name = "D", .comment = "E" },
                    .{ .value = .{ .value = 3 }, .name = "F", .comment = "G" },
                    .{ .value = .{ .value = 0x69 }, .name = "H", .comment = "I" },
                },
            };
            try std.testing.expectEqualDeep(expected, e);
        }

        {
            const text =
                \\<enums name="A" type="bitmask">
                \\</enums>----
            ;
            var parser: XmlParser = .init(text);
            const e = (try parse_enum(alloc, &parser)).?;
            try std.testing.expectEqualSlices(u8, "----", parser.buffer);
            const expected: Enum = .{
                .type = .bitmask,
                .name = "A",
                .bitwidth = 32,
                .items = &.{},
            };
            try std.testing.expectEqualDeep(expected, e);
        }
    }

    pub const Command = struct {
        name: []const u8 = &.{},
        alias: ?[]const u8 = null,
        return_type: []const u8 = &.{},

        // tasks
        queues: ?[]const u8 = null,
        successcodes: ?[]const u8 = null,
        errorcodes: ?[]const u8 = null,
        renderpass: ?[]const u8 = null,
        videocoding: ?[]const u8 = null,
        cmdbufferlevel: ?[]const u8 = null,
        // only valid for `vkCmd..`
        conditionalrendering: ?bool = null,
        allownoqueues: bool = false,
        comment: ?[]const u8 = null,

        parameters: []const Parameter = &.{},

        pub const Parameter = struct {
            name: []const u8 = &.{},

            type_front: []const u8 = &.{},
            type_middle: []const u8 = &.{},
            type_back: []const u8 = &.{},

            len: ?[]const u8 = null,
            // In case the type is [4]f32 or [3][4]f32
            dimensions: ?[]const u8 = null,
            optional: bool = false,
            // If parameter is a pointer to the base type (VkBaseOutStruct), what types can this
            // pointer point to
            valid_structs: ?[]const u8 = null,
        };
    };

    pub fn parse_command_parameter(original_parser: *XmlParser) ?Command.Parameter {
        if (!original_parser.check_peek_element_start("param")) return null;

        var parser = original_parser.*;
        _ = parser.element_start();

        var result: Command.Parameter = .{};
        if (parser.state == .attribute) {
            while (parser.attribute()) |attr| {
                if (std.mem.eql(u8, attr.name, "len")) {
                    result.len = attr.value;
                } else if (std.mem.eql(u8, attr.name, "altlen")) {
                    result.len = attr.value;
                } else if (std.mem.eql(u8, attr.name, "optional")) {
                    result.optional = std.mem.eql(u8, attr.value, "true");
                } else if (std.mem.eql(u8, attr.name, "validstructs")) {
                    result.valid_structs = attr.value;
                } else if (std.mem.eql(u8, attr.name, "api")) {
                    if (std.mem.eql(u8, attr.value, "vulkansc"))
                        return null;
                }
            }
        }

        if (parser.peek_text()) |text|
            result.type_front = text;

        parser.skip_to_specific_element_start("type");
        result.type_middle = parser.text() orelse return null;
        parser.skip_to_specific_element_end("type");

        if (parser.peek_text()) |text|
            result.type_back = text;

        parser.skip_to_specific_element_start("name");
        result.name = parser.text() orelse return null;
        parser.skip_to_specific_element_end("name");

        if (parser.peek_text()) |text| {
            _ = parser.text();
            result.dimensions = text;
        }

        parser.skip_to_specific_element_end("param");

        original_parser.* = parser;
        return result;
    }

    test "parse_command_parameter" {
        {
            const text =
                \\<param><type>T</type> <name>N</name></param>----
            ;
            var parser: XmlParser = .init(text);
            const m = parse_command_parameter(&parser).?;
            try std.testing.expectEqualSlices(u8, "----", parser.buffer);
            const expected: Command.Parameter = .{
                .name = "N",
                .type_middle = "T",
            };
            try std.testing.expectEqualDeep(expected, m);
        }
        {
            const text =
                \\<param len="L">const <type>T</type>* <name>N</name></param>----
            ;
            var parser: XmlParser = .init(text);
            const m = parse_command_parameter(&parser).?;
            try std.testing.expectEqualSlices(u8, "----", parser.buffer);
            const expected: Command.Parameter = .{
                .name = "N",
                .type_front = "const ",
                .type_middle = "T",
                .type_back = "* ",
                .len = "L",
            };
            try std.testing.expectEqualDeep(expected, m);
        }

        {
            const text =
                \\<param noautovalidity="true" validstructs="S"><type>T</type>* <name>N</name></param>----
            ;
            var parser: XmlParser = .init(text);
            const m = parse_command_parameter(&parser).?;
            try std.testing.expectEqualSlices(u8, "----", parser.buffer);
            const expected: Command.Parameter = .{
                .name = "N",
                .type_middle = "T",
                .type_back = "* ",
                .valid_structs = "S",
            };
            try std.testing.expectEqualDeep(expected, m);
        }

        {
            const text =
                \\<param><type>T</type> <name>N</name>[4]</param>----
            ;
            var parser: XmlParser = .init(text);
            const m = parse_command_parameter(&parser).?;
            try std.testing.expectEqualSlices(u8, "----", parser.buffer);
            const expected: Command.Parameter = .{
                .name = "N",
                .type_middle = "T",
                .dimensions = "[4]",
            };
            try std.testing.expectEqualDeep(expected, m);
        }

        {
            const text =
                \\<param api="vulkansc">const <type>T</type>* <name>N</name></param>----
            ;
            var parser: XmlParser = .init(text);
            const m = parse_command_parameter(&parser);
            try std.testing.expectEqual(null, m);
        }
    }

    pub fn parse_command(alloc: Allocator, original_parser: *XmlParser) !?Command {
        if (!original_parser.check_peek_element_start("command")) return null;

        var parser = original_parser.*;
        _ = parser.element_start();

        var result: Command = .{};
        while (parser.attribute()) |attr| {
            if (std.mem.eql(u8, attr.name, "name")) {
                result.name = attr.value;
            } else if (std.mem.eql(u8, attr.name, "alias")) {
                result.alias = attr.value;
            } else if (std.mem.eql(u8, attr.name, "queues")) {
                result.queues = attr.value;
            } else if (std.mem.eql(u8, attr.name, "successcodes")) {
                result.successcodes = attr.value;
            } else if (std.mem.eql(u8, attr.name, "errorcodes")) {
                result.errorcodes = attr.value;
            } else if (std.mem.eql(u8, attr.name, "renderpass")) {
                result.renderpass = attr.value;
            } else if (std.mem.eql(u8, attr.name, "videocoding")) {
                result.videocoding = attr.value;
            } else if (std.mem.eql(u8, attr.name, "cmdbufferlevel")) {
                result.cmdbufferlevel = attr.value;
            } else if (std.mem.eql(u8, attr.name, "conditionalrendering")) {
                result.conditionalrendering = std.mem.eql(u8, attr.value, "true");
            } else if (std.mem.eql(u8, attr.name, "allownoqueues")) {
                result.allownoqueues = std.mem.eql(u8, attr.value, "true");
            } else if (std.mem.eql(u8, attr.name, "comment")) {
                result.comment = attr.value;
            }
        }

        // If definition is not an alias
        if (result.alias == null) {
            parser.skip_to_specific_element_start("type");
            result.return_type = parser.text() orelse return null;
            parser.skip_to_specific_element_start("name");
            result.name = parser.text() orelse return null;
            parser.skip_to_specific_element_end("proto");

            var values: std.ArrayListUnmanaged(Command.Parameter) = .empty;
            while (true) {
                switch (parser.peek_next() orelse break) {
                    .element_end => |es| if (std.mem.eql(u8, es, "command")) break,
                    else => {},
                }
                if (parse_command_parameter(&parser)) |t| {
                    try values.append(alloc, t);
                } else {
                    if (parser.peek_element_start()) |_|
                        parser.skip_current_element()
                    else {
                        parser.skip_to_specific_element_end("command");
                        break;
                    }
                }
            }
            _ = parser.next();
            result.parameters = values.items;
        }

        original_parser.* = parser;
        return result;
    }

    test "parse_command" {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const alloc = arena.allocator();
        {
            const text =
                \\<command export="E" successcodes="S" errorcodes="E">
                \\    <proto><type>R</type><name>A</name></proto>
                \\    <param><type>T1</type><name>B</name></param>
                \\    <param><type>T2</type><name>C</name></param>
                \\    <implicitexternsyncparams>
                \\        <param>P</param>
                \\    </implicitexternsyncparams>
                \\</command>----
            ;
            var parser: XmlParser = .init(text);
            const e = (try parse_command(alloc, &parser)).?;
            try std.testing.expectEqualSlices(u8, "----", parser.buffer);
            const expected: Command = .{
                .name = "A",
                .return_type = "R",
                .successcodes = "S",
                .errorcodes = "E",
                .parameters = &.{
                    .{ .name = "B", .type_middle = "T1" },
                    .{ .name = "C", .type_middle = "T2" },
                },
            };
            try std.testing.expectEqualDeep(expected, e);
        }

        {
            const text =
                \\<command name="N" alias="A"/>----
            ;
            var parser: XmlParser = .init(text);
            const e = (try parse_command(alloc, &parser)).?;
            try std.testing.expectEqualSlices(u8, "----", parser.buffer);
            const expected: Command = .{
                .name = "N",
                .alias = "A",
            };
            try std.testing.expectEqualDeep(expected, e);
        }
    }

    pub fn parse_commands(alloc: Allocator, parser: *XmlParser) !std.ArrayListUnmanaged(Command) {
        if (!parser.check_peek_element_start("commands")) return .empty;

        _ = parser.element_start();
        _ = parser.skip_attributes();

        var commands: std.ArrayListUnmanaged(Command) = .empty;
        while (true) {
            switch (parser.peek_next() orelse break) {
                .element_end => |es| if (std.mem.eql(u8, es, "commands")) break,
                else => {},
            }

            if (try parse_command(alloc, parser)) |ext|
                try commands.append(alloc, ext)
            else
                parser.skip_current_element();
        }
        _ = parser.next();
        return commands;
    }

    test "parse_commands" {
        const text =
            \\<commands comment="C">
            \\    <command export="E1" successcodes="S" errorcodes="E">
            \\        <proto><type>T1</type> <name>N1</name></proto>
            \\        <param><type>T2</type>* <name>N2</name></param>
            \\        <param>const <type>T3</type>* <name>N3</name></param>
            \\    </command>
            \\    <command export="E2">
            \\        <proto><type>T4</type> <name>N4</name></proto>
            \\        <param optional="true" externsync="true"><type>T5</type> <name>N5</name></param>
            \\        <implicitexternsyncparams>
            \\            <param>P</param>
            \\        </implicitexternsyncparams>
            \\    </command>
            \\</commands>----
        ;

        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        var parser: XmlParser = .init(text);
        const e = try parse_commands(alloc, &parser);
        try std.testing.expectEqualSlices(u8, "----", parser.buffer);
        const expected: []const Command = &.{
            .{
                .name = "N1",
                .return_type = "T1",
                .successcodes = "S",
                .errorcodes = "E",
                .parameters = &.{
                    .{ .name = "N2", .type_middle = "T2", .type_back = "* " },
                    .{
                        .name = "N3",
                        .type_front = "const ",
                        .type_middle = "T3",
                        .type_back = "* ",
                    },
                },
            },
            .{
                .name = "N4",
                .return_type = "T4",
                .parameters = &.{
                    .{ .name = "N5", .type_middle = "T5", .optional = true },
                },
            },
        };
        try std.testing.expectEqualDeep(expected, e.items);
    }

    pub const Spirv = struct {
        extensions: []const Spirv.Extension = &.{},
        capabilities: []const Spirv.Capability = &.{},

        pub const Extension = struct {
            name: []const u8 = &.{},
            version: ?[]const u8 = null,
            extension: []const u8 = &.{},
        };
        pub const Capability = struct {
            name: []const u8 = &.{},
            enable: []const Capability.Enable = &.{},

            pub const Enable = union(enum) {
                sfr: Enable.Sfr,
                property: Enable.Property,
                version: []const u8,
                extension: []const u8,

                pub const Sfr = struct {
                    @"struct": []const u8 = &.{},
                    feature: []const u8 = &.{},
                    requires: []const u8 = &.{},
                };

                pub const Property = struct {
                    property: []const u8 = &.{},
                    member: []const u8 = &.{},
                    value: []const u8 = &.{},
                    requires: []const u8 = &.{},
                };
            };
        };
    };

    pub fn parse_spirv_extension(original_parser: *XmlParser) ?Spirv.Extension {
        if (!original_parser.check_peek_element_start("spirvextension")) return null;

        var parser = original_parser.*;
        _ = parser.element_start();

        var result: Spirv.Extension = .{};
        const name = parser.attribute() orelse return null;
        result.name = name.value;
        _ = parser.skip_attributes();

        while (true) {
            switch (parser.peek_next() orelse break) {
                .element_end => |es| if (std.mem.eql(u8, es, "spirvextension")) break,
                else => {},
            }
            _ = parser.element_start() orelse return null;
            const attr = parser.attribute() orelse return null;
            if (std.mem.eql(u8, attr.name, "version")) {
                result.version = attr.value;
                _ = parser.skip_attributes();
            } else if (std.mem.eql(u8, attr.name, "extension")) {
                result.extension = attr.value;
                _ = parser.skip_attributes();
            }
        }
        _ = parser.next();

        original_parser.* = parser;
        return result;
    }

    test "parse_spirv_extension" {
        {
            const text =
                \\<spirvextension name="N">
                \\    <enable extension="E"/>
                \\</spirvextension>----
            ;
            var parser: XmlParser = .init(text);
            const e = parse_spirv_extension(&parser).?;
            try std.testing.expectEqualSlices(u8, "----", parser.buffer);
            const expected: Spirv.Extension = .{
                .name = "N",
                .version = null,
                .extension = "E",
            };
            try std.testing.expectEqualDeep(expected, e);
        }
        {
            const text =
                \\<spirvextension name="N">
                \\    <enable version="V"/>
                \\    <enable extension="E"/>
                \\</spirvextension>----
            ;
            var parser: XmlParser = .init(text);
            const e = parse_spirv_extension(&parser).?;
            try std.testing.expectEqualSlices(u8, "----", parser.buffer);
            const expected: Spirv.Extension = .{
                .name = "N",
                .version = "V",
                .extension = "E",
            };
            try std.testing.expectEqualDeep(expected, e);
        }
    }

    pub fn parse_spirv_capability(alloc: Allocator, original_parser: *XmlParser) !?Spirv.Capability {
        if (!original_parser.check_peek_element_start("spirvcapability")) return null;

        var parser = original_parser.*;
        _ = parser.element_start();

        var result: Spirv.Capability = .{};
        const name = parser.attribute() orelse return null;
        result.name = name.value;
        _ = parser.skip_attributes();

        var items: std.ArrayListUnmanaged(Spirv.Capability.Enable) = .empty;
        while (true) {
            switch (parser.peek_next() orelse break) {
                .element_end => |es| if (std.mem.eql(u8, es, "spirvcapability")) break,
                else => {},
            }
            _ = parser.element_start() orelse return null;

            const first = parser.attribute() orelse return null;
            if (std.mem.eql(u8, first.name, "version")) {
                try items.append(alloc, .{ .version = first.value });
            } else if (std.mem.eql(u8, first.name, "extension")) {
                try items.append(alloc, .{ .extension = first.value });
            } else if (std.mem.eql(u8, first.name, "struct")) {
                var sfr: Spirv.Capability.Enable.Sfr = .{};
                sfr.@"struct" = first.value;

                const feature = parser.attribute() orelse return null;
                if (!std.mem.eql(u8, feature.name, "feature")) return null;
                sfr.feature = feature.value;

                const requires = parser.attribute() orelse return null;
                if (!std.mem.eql(u8, requires.name, "requires")) return null;
                sfr.requires = requires.value;

                try items.append(alloc, .{ .sfr = sfr });
            } else if (std.mem.eql(u8, first.name, "property")) {
                var prop: Spirv.Capability.Enable.Property = .{};
                prop.property = first.value;

                const member = parser.attribute() orelse return null;
                if (!std.mem.eql(u8, member.name, "member")) return null;
                prop.member = member.value;

                const value = parser.attribute() orelse return null;
                if (!std.mem.eql(u8, value.name, "value")) return null;
                prop.value = value.value;

                const requires = parser.attribute() orelse return null;
                if (!std.mem.eql(u8, requires.name, "requires")) return null;
                prop.requires = requires.value;

                try items.append(alloc, .{ .property = prop });
            }

            _ = parser.skip_attributes();
        }
        _ = parser.next();

        result.enable = items.items;
        original_parser.* = parser;
        return result;
    }

    test "parse_spirv_capability" {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const alloc = arena.allocator();
        {
            const text =
                \\<spirvcapability name="N">
                \\    <enable version="V"/>
                \\</spirvcapability>----
            ;
            var parser: XmlParser = .init(text);
            const c = (try parse_spirv_capability(alloc, &parser)).?;
            try std.testing.expectEqualSlices(u8, "----", parser.buffer);
            const expected: Spirv.Capability = .{
                .name = "N",
                .enable = &.{
                    .{ .version = "V" },
                },
            };
            try std.testing.expectEqualDeep(expected, c);
        }
        {
            const text =
                \\<spirvcapability name="N">
                \\    <enable struct="S1" feature="F1" requires="R1"/>
                \\    <enable struct="S2" feature="F2" requires="R2"/>
                \\    <enable struct="S3" feature="F3" requires="R3"/>
                \\</spirvcapability>----
            ;
            var parser: XmlParser = .init(text);
            const c = (try parse_spirv_capability(alloc, &parser)).?;
            try std.testing.expectEqualSlices(u8, "----", parser.buffer);
            const expected: Spirv.Capability = .{
                .name = "N",
                .enable = &.{
                    .{ .sfr = .{ .@"struct" = "S1", .feature = "F1", .requires = "R1" } },
                    .{ .sfr = .{ .@"struct" = "S2", .feature = "F2", .requires = "R2" } },
                    .{ .sfr = .{ .@"struct" = "S3", .feature = "F3", .requires = "R3" } },
                },
            };
            try std.testing.expectEqualDeep(expected, c);
        }
        {
            const text =
                \\<spirvcapability name="N">
                \\    <enable struct="S" feature="F" requires="R"/>
                \\    <enable version="V"/>
                \\    <enable extension="E"/>
                \\</spirvcapability>----
            ;
            var parser: XmlParser = .init(text);
            const c = (try parse_spirv_capability(alloc, &parser)).?;
            try std.testing.expectEqualSlices(u8, "----", parser.buffer);
            const expected: Spirv.Capability = .{
                .name = "N",
                .enable = &.{
                    .{ .sfr = .{ .@"struct" = "S", .feature = "F", .requires = "R" } },
                    .{ .version = "V" },
                    .{ .extension = "E" },
                },
            };
            try std.testing.expectEqualDeep(expected, c);
        }
        {
            const text =
                \\<spirvcapability name="N">
                \\    <enable property="P" member="M" value="V" requires="R"/>
                \\</spirvcapability>----
            ;
            var parser: XmlParser = .init(text);
            const c = (try parse_spirv_capability(alloc, &parser)).?;
            try std.testing.expectEqualSlices(u8, "----", parser.buffer);
            const expected: Spirv.Capability = .{
                .name = "N",
                .enable = &.{
                    .{ .property = .{
                        .property = "P",
                        .member = "M",
                        .value = "V",
                        .requires = "R",
                    } },
                },
            };
            try std.testing.expectEqualDeep(expected, c);
        }
    }

    pub fn parse_spirv(alloc: Allocator, parser: *XmlParser) !Spirv {
        if (!parser.check_peek_element_start("spirvextensions")) return .{};
        _ = parser.element_start();
        _ = parser.skip_attributes();

        var extensions: std.ArrayListUnmanaged(Spirv.Extension) = .empty;
        while (true) {
            switch (parser.peek_next() orelse break) {
                .element_end => |es| if (std.mem.eql(u8, es, "spirvextensions")) break,
                else => {},
            }

            if (parse_spirv_extension(parser)) |v|
                try extensions.append(alloc, v)
            else
                parser.skip_current_element();
        }
        _ = parser.next();

        if (!parser.check_peek_element_start("spirvcapabilities")) return .{};
        _ = parser.element_start();
        _ = parser.skip_attributes();

        var capabilities: std.ArrayListUnmanaged(Spirv.Capability) = .empty;
        while (true) {
            switch (parser.peek_next() orelse break) {
                .element_end => |es| if (std.mem.eql(u8, es, "spirvcapabilities")) break,
                else => {},
            }

            if (try parse_spirv_capability(alloc, parser)) |v|
                try capabilities.append(alloc, v)
            else
                parser.skip_current_element();
        }
        _ = parser.next();
        return .{
            .extensions = extensions.items,
            .capabilities = capabilities.items,
        };
    }

    test "parse_spirv" {
        const text =
            \\<spirvextensions comment="C">
            \\    <spirvextension name="N1">
            \\        <enable extension="X1"/>
            \\    </spirvextension>
            \\    <spirvextension name="N2">
            \\        <enable version="V2"/>
            \\        <enable extension="X2"/>
            \\    </spirvextension>
            \\</spirvextensions>
            \\<spirvcapabilities comment="C">
            \\    <spirvcapability name="N1">
            \\        <enable struct="S" feature="F" requires="R"/>
            \\    </spirvcapability>
            \\    <spirvcapability name="N2">
            \\        <enable struct="S" feature="F" requires="R"/>
            \\    </spirvcapability>
            \\</spirvcapabilities>----
        ;

        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        var parser: XmlParser = .init(text);
        const s = try parse_spirv(alloc, &parser);
        try std.testing.expectEqualSlices(u8, "----", parser.buffer);
        const expected: Spirv = .{
            .extensions = &.{
                .{ .name = "N1", .version = null, .extension = "X1" },
                .{ .name = "N2", .version = "V2", .extension = "X2" },
            },
            .capabilities = &.{
                .{
                    .name = "N1",
                    .enable = &.{
                        .{ .sfr = .{ .@"struct" = "S", .feature = "F", .requires = "R" } },
                    },
                },
                .{
                    .name = "N2",
                    .enable = &.{
                        .{ .sfr = .{ .@"struct" = "S", .feature = "F", .requires = "R" } },
                    },
                },
            },
        };
        try std.testing.expectEqualDeep(expected, s);
    }
};
