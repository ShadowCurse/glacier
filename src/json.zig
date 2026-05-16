// Copyright (c) 2026 Egor Lazarchuk
//
// Based in part on simdjson project which is
// Copyright (c) 2018-2025 The simdjson authors
//
// SPDX-License-Identifier: MIT

const std = @import("std");
const builtin = @import("builtin");
const log = @import("log.zig");
const simd = @import("simd.zig");
const Allocator = std.mem.Allocator;

/// Structural characters and their ASCII values:
/// '{' = 0x7B | '}' = 0x7D <- high nibble is 0x7, low nibbles are 0xB and 0xD
/// '[' = 0x5B | ']' = 0x5D <- high nibble is 0x5, low nibbles are 0xB and 0xD
/// ':' = 0x3A              <- high nibble is 0x3, low nibble is 0xA
/// ',' = 0x2C              <- high nibble is 0x2, low nibbles are 0x2 and 0xC
///
/// The set is split into 3 groups {}[], :, ',' each with unique bit set
/// {}[] - bit 2
/// :    - bit 1
/// ,    - bit 0
///
/// Constants are created by setting bits (0, 1, 2) at nibble positons
///
const STRUCTURAL_LO_16: simd.u8x16 = .{
    0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 2, 4, 1, 4, 0, 0,
};
const STRUCTURAL_HI_16: simd.u8x16 = .{
    0, 0, 1, 2, 0, 4, 0, 4,
    0, 0, 0, 0, 0, 0, 0, 0,
};
const STRUCTURAL_LO_32: simd.u8x32 = .{
    0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 2, 4, 1, 4, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 2, 4, 1, 4, 0, 0,
};
const STRUCTURAL_HI_32: simd.u8x32 = .{
    0, 0, 1, 2, 0, 4, 0, 4,
    0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 1, 2, 0, 4, 0, 4,
    0, 0, 0, 0, 0, 0, 0, 0,
};

fn classify_chunk_256(chunk: simd.u8x32) struct { structural: u32, quotes: u32 } {
    const lo_nibbles = chunk & @as(simd.u8x32, @splat(0x0f));
    const hi_nibbles = chunk >> @as(@Vector(32, u3), @splat(4));

    const lo_result = if (builtin.cpu.arch == .x86_64)
        simd.x86_64.vpshufb_256(STRUCTURAL_LO_32, lo_nibbles)
    else if (builtin.cpu.arch == .aarch64)
        simd.aarch64.tbl_256(STRUCTURAL_LO_16, lo_nibbles)
    else
        @compileError("Only x86_64 and aarch64 are supported");

    const hi_result = if (builtin.cpu.arch == .x86_64)
        simd.x86_64.vpshufb_256(STRUCTURAL_HI_32, hi_nibbles)
    else if (builtin.cpu.arch == .aarch64)
        simd.aarch64.tbl_256(STRUCTURAL_HI_16, hi_nibbles)
    else
        @compileError("Only x86_64 and aarch64 are supported");

    // Both must match for a structural character
    const zero: simd.u8x32 = @splat(0x0);
    const is_structural: @Vector(32, bool) = (lo_result & hi_result) != zero;
    const structural: u32 = @bitCast(is_structural);

    // Quote detection: compare directly with '"'
    const quote_vec: simd.u8x32 = @splat(0x22);
    const is_quote = chunk == quote_vec;
    const quotes: u32 = @bitCast(is_quote);

    return .{ .structural = structural, .quotes = quotes };
}

pub fn scan_structure(input: []const u8, positions: []u32) []const u32 {
    log.assert(@src(), input.len <= positions.len, "", .{});

    var pos_count: u32 = 0;
    var in_string: u64 = 0; // Carry bit from previous chunk

    var offset: u32 = 0;

    // 64 byte chunks, e.g. 2 32 bit searches
    while (offset + 64 <= input.len) : (offset += 64) {
        const chunk0: simd.u8x32 = input[offset..][0..32].*;
        const chunk1: simd.u8x32 = input[offset + 32 ..][0..32].*;

        const class0 = classify_chunk_256(chunk0);
        const class1 = classify_chunk_256(chunk1);

        const quote_mask: u64 = (@as(u64, class1.quotes) << 32) | class0.quotes;
        const string_mask = simd.prefix_xor(quote_mask) ^ in_string;
        // Carry to next iteration: convert MSB to all-bits mask (0 or 0xFFFFFFFFFFFFFFFF)
        in_string = @as(u64, 0) -% ((string_mask >> 63) & 1);

        var structural_mask: u64 = (@as(u64, class1.structural) << 32) | class0.structural;
        // Remove structurals that are inside strings
        // But keep quotes since are structural for string boundaries
        structural_mask &= ~string_mask;
        structural_mask |= quote_mask;

        // Extract positions using TZCNT
        while (structural_mask != 0) {
            const bit_pos: u32 = @ctz(structural_mask);
            positions[pos_count] = offset + bit_pos;
            pos_count += 1;
            structural_mask &= structural_mask - 1; // Clear lowest bit (BLSR)
        }
    }

    // Handle remaining bytes with scalar fallback
    while (offset < input.len) : (offset += 1) {
        const c = input[offset];
        const in_str = (in_string & 1) != 0;

        if (c == '"') {
            positions[pos_count] = offset;
            pos_count += 1;
            in_string ^= 1; // Toggle string state
        } else if (!in_str and (c == '{' or c == '}' or c == '[' or c == ']' or c == ':' or c == ',')) {
            positions[pos_count] = offset;
            pos_count += 1;
        }
    }

    return positions[0..pos_count];
}

buffer: []const u8,
positions: []const u32,
position_idx: u32 = 0,
deferred_array_end: bool = false,

const Self = @This();

pub const Token = union(enum) {
    object_begin,
    object_end,
    array_begin,
    array_end,
    string: []const u8,
    number: []const u8,
    // true_,
    // false_,
    // null_,
    end_of_document,
};

pub fn init(alloc: Allocator, buffer: []const u8) Self {
    const p = alloc.alloc(u32, buffer.len + 1) catch unreachable;
    const positions = scan_structure(buffer, p);
    return .{ .buffer = buffer, .positions = positions };
}

pub fn next(self: *Self) Token {
    const Inner = struct {
        // Only trim in unit tests since they are made to be readable. Actual
        // Json payloads will be packed, so no un-needed spaces etc.
        inline fn trim(buffer: []const u8, start: *u32, end: *u32) void {
            if (comptime builtin.is_test) {
                while (std.ascii.isWhitespace(buffer[start.*]) and
                    start.* <= end.*) start.* += 1;
                while (std.ascii.isWhitespace(buffer[end.* - 1]) and
                    start.* <= end.*) end.* -= 1;
            }
        }
    };
    if (self.deferred_array_end) {
        self.deferred_array_end = false;
        return .array_end;
    }

    if (self.position_idx < self.positions.len) {
        blk: switch (self.buffer[self.positions[self.position_idx]]) {
            '{' => {
                self.position_idx += 1;
                return .object_begin;
            },
            '}' => {
                self.position_idx += 1;
                return .object_end;
            },
            '[' => {
                self.position_idx += 1;
                return .array_begin;
            },
            ']' => {
                log.assert(@src(), 0 < self.position_idx, "", .{});
                const prev_char = self.buffer[self.positions[self.position_idx - 1]];
                if (prev_char == '[' or prev_char == ',') {
                    var start_pos = self.positions[self.position_idx - 1];
                    var end_pos = self.positions[self.position_idx];
                    start_pos += 1;
                    Inner.trim(self.buffer, &start_pos, &end_pos);
                    // while (std.ascii.isWhitespace(self.buffer[start_pos]) and
                    //     start_pos <= end_pos) start_pos += 1;
                    // while (std.ascii.isWhitespace(self.buffer[end_pos - 1]) and
                    //     start_pos <= end_pos) end_pos -= 1;
                    if (start_pos < end_pos) {
                        self.deferred_array_end = true;
                        self.position_idx += 1;
                        return .{ .number = self.buffer[start_pos..end_pos] };
                    }
                }
                self.position_idx += 1;
                return .array_end;
            },
            ',' => {
                log.assert(@src(), 0 < self.position_idx, "", .{});
                const prev_char = self.buffer[self.positions[self.position_idx - 1]];
                if (prev_char == '[' or prev_char == ',') {
                    var start_pos = self.positions[self.position_idx - 1];
                    var end_pos = self.positions[self.position_idx];
                    start_pos += 1;
                    Inner.trim(self.buffer, &start_pos, &end_pos);
                    self.position_idx += 1;
                    return .{ .number = self.buffer[start_pos..end_pos] };
                } else {
                    self.position_idx += 1;
                    continue :blk self.buffer[self.positions[self.position_idx]];
                }
            },
            '"' => {
                var current_pos = self.positions[self.position_idx];
                var end_pos = self.positions[self.position_idx + 1];
                log.assert(@src(), self.buffer[end_pos] == '"', "", .{});
                self.position_idx += 2;
                current_pos += 1;
                Inner.trim(self.buffer, &current_pos, &end_pos);
                return .{ .string = self.buffer[current_pos..end_pos] };
            },
            ':' => {
                var current_pos = self.positions[self.position_idx];
                self.position_idx += 1;
                const next_pos = self.positions[self.position_idx];
                const next_char = self.buffer[next_pos];
                switch (next_char) {
                    '"', '{', '[' => continue :blk next_char,
                    '}', ']' => {
                        var end_pos = next_pos;
                        current_pos += 1;
                        Inner.trim(self.buffer, &current_pos, &end_pos);
                        return .{ .number = self.buffer[current_pos..end_pos] };
                    },
                    ',' => {
                        self.position_idx += 1;
                        var end_pos = next_pos;
                        current_pos += 1;
                        Inner.trim(self.buffer, &current_pos, &end_pos);
                        return .{ .number = self.buffer[current_pos..end_pos] };
                    },
                    else => {
                        log.assert(@src(), false, "got {c} after :", .{next_char});
                        unreachable;
                    },
                }
            },
            else => {
                self.position_idx += 1;
                continue :blk self.buffer[self.positions[self.position_idx]];
            },
        }
    } else return .end_of_document;
}

test "classify_chunk_256" {
    // Pad to 32 bytes for AVX2
    const input = "  {\"key\": 123}                  ";
    const chunk: simd.u8x32 = input[0..32].*;
    const result = classify_chunk_256(chunk);

    // Structural chars at positions: 2({), 8(:), 13(})
    const expected_struct: u32 = (1 << 2) | (1 << 8) | (1 << 13);
    try std.testing.expectEqual(expected_struct, result.structural);

    // Quotes at positions 3 and 7
    const expected_quotes: u32 = (1 << 3) | (1 << 7);
    try std.testing.expectEqual(expected_quotes, result.quotes);
}

test "scan_structure_simple" {
    const json = "  {\"key\": 123}                  ";
    var p: [json.len]u32 = undefined;
    const positions = scan_structure(json, &p);

    try std.testing.expectEqual(5, positions.len);
    try std.testing.expectEqual(2, positions[0]); // {
    try std.testing.expectEqual(3, positions[1]); // "
    try std.testing.expectEqual(7, positions[2]); // "
    try std.testing.expectEqual(8, positions[3]); // :
    try std.testing.expectEqual(13, positions[4]); // }
}

test "scan_structure_nested" {
    const json = "{\"a\":{\"b\":2}}";
    var p: [json.len]u32 = undefined;
    const positions = scan_structure(json, &p);
    try std.testing.expectEqual(10, positions.len);
}

test "scan_structure_colon_inside_string" {
    const json = "{\"a:b\":1}";
    var p: [json.len]u32 = undefined;
    const positions = scan_structure(json, &p);

    // The : inside "a:b" should NOT be marked as structural
    // Positions: 0({), 1("), 5("), 6(:), 8(})
    try std.testing.expectEqual(5, positions.len);

    // Verify colon is at position 6, not 3
    var found_colon = false;
    for (positions) |pos| {
        if (json[pos] == ':') {
            try std.testing.expectEqual(@as(u32, 6), pos);
            found_colon = true;
        }
    }
    try std.testing.expect(found_colon);
}

test "json" {
    var buff: [4096]u8 = undefined;
    var allocator = std.heap.FixedBufferAllocator.init(&buff);
    const alloc = allocator.allocator();
    const json =
        \\{
        \\  "version": 6,
        \\  "samplers": {
        \\    "88201fb960ff6465": {
        \\      "flags": 0,
        \\      "minFilter": 0,
        \\      "magFilter": 0
        \\    }
        \\  },
        \\  "other":[{"a":1,"another":[]}]
        \\}
    ;

    var scanner = Self.init(alloc, json);

    // Walk through tokens
    try std.testing.expectEqual(Token.object_begin, scanner.next());
    const version_key = scanner.next();
    try std.testing.expectEqualStrings("version", version_key.string);
    const version_val = scanner.next();
    try std.testing.expectEqualStrings("6", version_val.number);

    const samplers_key = scanner.next();
    try std.testing.expectEqualStrings("samplers", samplers_key.string);
    try std.testing.expectEqual(Token.object_begin, scanner.next());

    const hash_key = scanner.next();
    try std.testing.expectEqualStrings("88201fb960ff6465", hash_key.string);
    try std.testing.expectEqual(Token.object_begin, scanner.next());

    // Parse inner fields
    const flags_key = scanner.next();
    try std.testing.expectEqualStrings("flags", flags_key.string);
    const flags_val = scanner.next();
    try std.testing.expectEqualStrings("0", flags_val.number);

    const min_key = scanner.next();
    try std.testing.expectEqualStrings("minFilter", min_key.string);
    const min_val = scanner.next();
    try std.testing.expectEqualStrings("0", min_val.number);

    const mag_key = scanner.next();
    try std.testing.expectEqualStrings("magFilter", mag_key.string);
    const mag_val = scanner.next();
    try std.testing.expectEqualStrings("0", mag_val.number);

    try std.testing.expectEqual(Token.object_end, scanner.next());
    try std.testing.expectEqual(Token.object_end, scanner.next());

    const other = scanner.next();
    try std.testing.expectEqualStrings("other", other.string);
    try std.testing.expectEqual(Token.array_begin, scanner.next());
    try std.testing.expectEqual(Token.object_begin, scanner.next());
    const a = scanner.next();
    try std.testing.expectEqualStrings("a", a.string);
    const one = scanner.next();
    try std.testing.expectEqualStrings("1", one.number);
    const another = scanner.next();
    try std.testing.expectEqualStrings("another", another.string);
    try std.testing.expectEqual(Token.array_begin, scanner.next());
    try std.testing.expectEqual(Token.array_end, scanner.next());
    try std.testing.expectEqual(Token.object_end, scanner.next());
    try std.testing.expectEqual(Token.array_end, scanner.next());

    try std.testing.expectEqual(Token.object_end, scanner.next());
    try std.testing.expectEqual(Token.end_of_document, scanner.next());
}
