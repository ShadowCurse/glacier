// Copyright (c) 2026 Egor Lazarchuk
// SPDX-License-Identifier: MIT

const std = @import("std");
const builtin = @import("builtin");

pub const m128i = @Vector(2, u64);
pub const u8x16 = @Vector(16, u8);
pub const u8x32 = @Vector(32, u8);
pub const u8x64 = @Vector(64, u8);

// Shift the whole 16 bytes right by `bytes` nuber of bytes
pub inline fn shift_right(a: m128i, comptime bytes: u8) m128i {
    const b: @Vector(16, u8) = @bitCast(a);
    // The `shift left` is because shift is done with a @shuffle
    // with selection mask shifted by `bytes` to the left
    // orig:      0 [ 0 0 0 0 a b c   d ]
    // shuffle: [ 0   0 0 0 0 a b c ] d
    // final:   [0 0 0 0 0 a b c]
    const c = std.simd.shiftElementsLeft(b, bytes, 0);
    return @bitCast(c);
}

/// Prefix XOR
/// Each bit in result = XOR of all bits at positions <= i in input
pub inline fn prefix_xor(mask: u64) u64 {
    const all_ones = m128i{ 0xFFFFFFFFFFFFFFFF, 0xFFFFFFFFFFFFFFFF };
    const input = m128i{ mask, 0 };
    const result = if (builtin.cpu.arch == .x86_64)
        x86_64.pclmulqdq(input, all_ones, 0x00)
    else if (builtin.cpu.arch == .aarch64)
        aarch64.pmull(input, all_ones)
    else
        @compileError("Only x86_64 and aarch64 are supported");
    return result[0];
}

pub const x86_64 = struct {
    // PCLMULQDQ - Carry-less multiplication
    pub inline fn pclmulqdq(a: m128i, b: m128i, comptime mask: u64) m128i {
        const assembly = std.fmt.comptimePrint("pclmulqdq ${d}, %[b], %[a]", .{mask});
        return asm volatile (assembly
            : [ret] "=x" (-> m128i),
            : [a] "0" (a),
              [b] "x" (b),
        );
    }

    // VPSHUFB - Packed Shuffle Bytes
    pub inline fn vpshufb_128(table: u8x16, indices: u8x16) u8x16 {
        const has_avx2 = comptime std.Target.x86.featureSetHas(builtin.cpu.features, .avx2);
        if (has_avx2) {
            return asm volatile ("vpshufb %[indices], %[table], %[ret]"
                : [ret] "=x" (-> u8x16),
                : [table] "x" (table),
                  [indices] "x" (indices),
            );
        } else {
            var ret: u8x16 = table;
            asm volatile ("pshufb %[indices], %[ret]"
                : [ret] "+x" (ret),
                : [indices] "x" (indices),
            );
            return ret;
        }
    }

    /// VPSHUFB - Packed Shuffle Bytes
    pub inline fn vpshufb_256(table: u8x32, indices: u8x32) u8x32 {
        const has_avx2 = comptime std.Target.x86.featureSetHas(builtin.cpu.features, .avx2);
        if (has_avx2) {
            return asm volatile ("vpshufb %[indices], %[table], %[ret]"
                : [ret] "=x" (-> u8x32),
                : [table] "x" (table),
                  [indices] "x" (indices),
            );
        } else {
            const table_low: u8x16 = @as([32]u8, table)[0..16].*;
            const table_high: u8x16 = @as([32]u8, table)[16..32].*;

            const indices_low: u8x16 = @as([32]u8, indices)[0..16].*;
            const indices_high: u8x16 = @as([32]u8, indices)[16..32].*;

            var res_low: u8x16 = undefined;
            var res_high: u8x16 = undefined;

            res_low = table_low;
            res_high = table_high;
            asm volatile (
                \\pshufb %[indices_l], %[res_l]
                \\pshufb %[indices_h], %[res_h]
                : [res_l] "=&x" (res_low),
                  [res_h] "=&x" (res_high),
                : [indices_l] "x" (indices_low),
                  [indices_h] "x" (indices_high),
                  [table_l_tied] "0" (res_low),
                  [table_h_tied] "1" (res_high),
            );

            return std.simd.join(res_low, res_high);
        }
    }

    test "prefix_xor" {
        const mask: u64 = 0b100001;
        const result = prefix_xor(mask);
        try std.testing.expectEqual(@as(u64, 0b011111), result);
    }

    test "prefix_xor_multiple_strings" {
        const mask: u64 = 0b100100101;
        const result = prefix_xor(mask);
        try std.testing.expectEqual(@as(u64, 0b011100011), result);
    }
};

pub const aarch64 = struct {
    // CRC32X - crc32 from 64 bit reg
    pub inline fn crc32x(crc: u32, value: u64) u32 {
        return asm volatile ("crc32x %[ret:w], %[c:w], %[v:x]"
            : [ret] "=r" (-> u32),
            : [c] "r" (crc),
              [v] "r" (value),
        );
    }

    // CRC32X - crc32 from 32 bit reg
    pub inline fn crc32w(crc: u32, value: u32) u32 {
        return asm volatile ("crc32w %[ret:w], %[c:w], %[v:w]"
            : [ret] "=r" (-> u32),
            : [c] "r" (crc),
              [v] "r" (value),
        );
    }

    // CRC32X - crc32 from 16 bit reg
    pub inline fn crc32h(crc: u32, value: u16) u32 {
        return asm volatile ("crc32h %[ret:w], %[c:w], %[v:w]"
            : [ret] "=r" (-> u32),
            : [c] "r" (crc),
              [v] "r" (value),
        );
    }

    // CRC32X - crc32 from 8 bit reg
    pub inline fn crc32b(crc: u32, value: u8) u32 {
        return asm volatile ("crc32b %[ret:w], %[c:w], %[v:w]"
            : [ret] "=r" (-> u32),
            : [c] "r" (crc),
              [v] "r" (value),
        );
    }

    // TBL - tabel lookup on 128bit reg
    pub inline fn tbl_128(table: u8x16, indices: u8x16) u8x16 {
        return asm volatile ("tbl %[ret].16b, {%[table].16b}, %[indices].16b"
            : [ret] "=w" (-> u8x16),
            : [table] "w" (table),
              [indices] "w" (indices),
        );
    }

    // TBL - tabel lookup on 256bit value split into 2 128bit reg
    pub inline fn tbl_256(table: u8x16, indices: u8x32) u8x32 {
        const i_low: u8x16 = @as([32]u8, indices)[0..16].*;
        const i_high: u8x16 = @as([32]u8, indices)[16..32].*;

        var res_low: u8x16 = undefined;
        var res_high: u8x16 = undefined;

        asm volatile (
            \\tbl %[res_l].16b, {%[t].16b}, %[i_l].16b
            \\tbl %[res_h].16b, {%[t].16b}, %[i_h].16b
            : [res_l] "=&w" (res_low),
              [res_h] "=&w" (res_high),
            : [t] "w" (table),
              [i_l] "w" (i_low),
              [i_h] "w" (i_high),
        );

        return std.simd.join(res_low, res_high);
    }

    // PMULL - Polynomial multiplication over { 0, 1 }
    pub inline fn pmull(a: m128i, b: m128i) m128i {
        return asm volatile ("pmull %[ret].1q, %[a].1d, %[b].1d"
            : [ret] "=w" (-> m128i),
            : [a] "w" (a),
              [b] "w" (b),
        );
    }
};

comptime {
    if (builtin.cpu.arch == .x86_64)
        _ = x86_64
    else if (builtin.cpu.arch == .aarch64)
        _ = aarch64
    else
        @compileError("Only x86_64 and aarch64 are supported");
}
