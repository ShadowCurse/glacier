// Copyright (c) 2026 Egor Lazarchuk
//
// Based in part on miniz project which is:
// Copyright (c) 2013-2014 RAD Game Tools and Valve Software
// Copyright (c) 2010-2014 Rich Geldreich and Tenacious Software LLC
//
// Based in part on chromium project which is:
// Copyright (c) 2017 The Chromium Authors
//
// SPDX-License-Identifier: MIT

const std = @import("std");
const builtin = @import("builtin");
const miniz = @import("miniz");
const simd = @import("simd.zig");
const profiler = @import("profiler.zig");

// Implementation from miniz
// https://github.com/richgel999/miniz/blob/master/miniz.c#L95
pub fn crc32(init_crc: u32, bytes: []align(16) const u8) u32 {
    // zig fmt: off
    const s_crc_table: [256]u32 = .{
        0x00000000, 0x77073096, 0xEE0E612C, 0x990951BA, 0x076DC419, 0x706AF48F, 0xE963A535,
        0x9E6495A3, 0x0EDB8832, 0x79DCB8A4, 0xE0D5E91E, 0x97D2D988, 0x09B64C2B, 0x7EB17CBD,
        0xE7B82D07, 0x90BF1D91, 0x1DB71064, 0x6AB020F2, 0xF3B97148, 0x84BE41DE, 0x1ADAD47D,
        0x6DDDE4EB, 0xF4D4B551, 0x83D385C7, 0x136C9856, 0x646BA8C0, 0xFD62F97A, 0x8A65C9EC,
        0x14015C4F, 0x63066CD9, 0xFA0F3D63, 0x8D080DF5, 0x3B6E20C8, 0x4C69105E, 0xD56041E4,
        0xA2677172, 0x3C03E4D1, 0x4B04D447, 0xD20D85FD, 0xA50AB56B, 0x35B5A8FA, 0x42B2986C,
        0xDBBBC9D6, 0xACBCF940, 0x32D86CE3, 0x45DF5C75, 0xDCD60DCF, 0xABD13D59, 0x26D930AC,
        0x51DE003A, 0xC8D75180, 0xBFD06116, 0x21B4F4B5, 0x56B3C423, 0xCFBA9599, 0xB8BDA50F,
        0x2802B89E, 0x5F058808, 0xC60CD9B2, 0xB10BE924, 0x2F6F7C87, 0x58684C11, 0xC1611DAB,
        0xB6662D3D, 0x76DC4190, 0x01DB7106, 0x98D220BC, 0xEFD5102A, 0x71B18589, 0x06B6B51F,
        0x9FBFE4A5, 0xE8B8D433, 0x7807C9A2, 0x0F00F934, 0x9609A88E, 0xE10E9818, 0x7F6A0DBB,
        0x086D3D2D, 0x91646C97, 0xE6635C01, 0x6B6B51F4, 0x1C6C6162, 0x856530D8, 0xF262004E,
        0x6C0695ED, 0x1B01A57B, 0x8208F4C1, 0xF50FC457, 0x65B0D9C6, 0x12B7E950, 0x8BBEB8EA,
        0xFCB9887C, 0x62DD1DDF, 0x15DA2D49, 0x8CD37CF3, 0xFBD44C65, 0x4DB26158, 0x3AB551CE,
        0xA3BC0074, 0xD4BB30E2, 0x4ADFA541, 0x3DD895D7, 0xA4D1C46D, 0xD3D6F4FB, 0x4369E96A,
        0x346ED9FC, 0xAD678846, 0xDA60B8D0, 0x44042D73, 0x33031DE5, 0xAA0A4C5F, 0xDD0D7CC9,
        0x5005713C, 0x270241AA, 0xBE0B1010, 0xC90C2086, 0x5768B525, 0x206F85B3, 0xB966D409,
        0xCE61E49F, 0x5EDEF90E, 0x29D9C998, 0xB0D09822, 0xC7D7A8B4, 0x59B33D17, 0x2EB40D81,
        0xB7BD5C3B, 0xC0BA6CAD, 0xEDB88320, 0x9ABFB3B6, 0x03B6E20C, 0x74B1D29A, 0xEAD54739,
        0x9DD277AF, 0x04DB2615, 0x73DC1683, 0xE3630B12, 0x94643B84, 0x0D6D6A3E, 0x7A6A5AA8,
        0xE40ECF0B, 0x9309FF9D, 0x0A00AE27, 0x7D079EB1, 0xF00F9344, 0x8708A3D2, 0x1E01F268,
        0x6906C2FE, 0xF762575D, 0x806567CB, 0x196C3671, 0x6E6B06E7, 0xFED41B76, 0x89D32BE0,
        0x10DA7A5A, 0x67DD4ACC, 0xF9B9DF6F, 0x8EBEEFF9, 0x17B7BE43, 0x60B08ED5, 0xD6D6A3E8,
        0xA1D1937E, 0x38D8C2C4, 0x4FDFF252, 0xD1BB67F1, 0xA6BC5767, 0x3FB506DD, 0x48B2364B,
        0xD80D2BDA, 0xAF0A1B4C, 0x36034AF6, 0x41047A60, 0xDF60EFC3, 0xA867DF55, 0x316E8EEF,
        0x4669BE79, 0xCB61B38C, 0xBC66831A, 0x256FD2A0, 0x5268E236, 0xCC0C7795, 0xBB0B4703,
        0x220216B9, 0x5505262F, 0xC5BA3BBE, 0xB2BD0B28, 0x2BB45A92, 0x5CB36A04, 0xC2D7FFA7,
        0xB5D0CF31, 0x2CD99E8B, 0x5BDEAE1D, 0x9B64C2B0, 0xEC63F226, 0x756AA39C, 0x026D930A,
        0x9C0906A9, 0xEB0E363F, 0x72076785, 0x05005713, 0x95BF4A82, 0xE2B87A14, 0x7BB12BAE,
        0x0CB61B38, 0x92D28E9B, 0xE5D5BE0D, 0x7CDCEFB7, 0x0BDBDF21, 0x86D3D2D4, 0xF1D4E242,
        0x68DDB3F8, 0x1FDA836E, 0x81BE16CD, 0xF6B9265B, 0x6FB077E1, 0x18B74777, 0x88085AE6,
        0xFF0F6A70, 0x66063BCA, 0x11010B5C, 0x8F659EFF, 0xF862AE69, 0x616BFFD3, 0x166CCF45,
        0xA00AE278, 0xD70DD2EE, 0x4E048354, 0x3903B3C2, 0xA7672661, 0xD06016F7, 0x4969474D,
        0x3E6E77DB, 0xAED16A4A, 0xD9D65ADC, 0x40DF0B66, 0x37D83BF0, 0xA9BCAE53, 0xDEBB9EC5,
        0x47B2CF7F, 0x30B5FFE9, 0xBDBDF21C, 0xCABAC28A, 0x53B39330, 0x24B4A3A6, 0xBAD03605,
        0xCDD70693, 0x54DE5729, 0x23D967BF, 0xB3667A2E, 0xC4614AB8, 0x5D681B02, 0x2A6F2B94,
        0xB40BBE37, 0xC30C8EA1, 0x5A05DF1B, 0x2D02EF8D
    };
    // zig fmt: on

    var crc: u32 = init_crc;
    crc = ~crc;

    const full_4_bytes_len = bytes.len - (bytes.len % 4);
    const bytes_u32: []const u32 = @ptrCast(bytes[0..full_4_bytes_len]);
    for (bytes_u32) |item| {
        const b: []const u8 = @ptrCast(&item);
        crc = (crc >> 8) ^ s_crc_table[(@as(u8, @truncate(crc)) ^ b[0]) & 0xFF];
        crc = (crc >> 8) ^ s_crc_table[(@as(u8, @truncate(crc)) ^ b[1]) & 0xFF];
        crc = (crc >> 8) ^ s_crc_table[(@as(u8, @truncate(crc)) ^ b[2]) & 0xFF];
        crc = (crc >> 8) ^ s_crc_table[(@as(u8, @truncate(crc)) ^ b[3]) & 0xFF];
    }

    for (bytes[full_4_bytes_len..]) |byte| {
        crc = (crc >> 8) ^ s_crc_table[(crc ^ byte) & 0xFF];
    }

    return ~crc;
}

// https://chromium.googlesource.com/chromium/src/+/a0771caebe87477558454cc6d793562e3afe74ac/third_party/zlib/crc32_simd.c#24
// Paper: "Fast CRC Computation for Generic Polynomials Using PCLMULQDQ Instruction" *  V. Gopal, E. Ozturk, et al., 2009
pub const crc32_simd = if (builtin.cpu.arch == .x86_64)
    crc32_simd_x86_64
else if (builtin.cpu.arch == .aarch64)
    crc32_simd_aarch64
else
    @compileError("Only x86_64 and aarch64 are supported");

fn crc32_simd_x86_64(init_crc: u32, bytes: []align(64) const u8) u32 {
    if (bytes.len < 64) return crc32(init_crc, bytes);

    const k1k2 = simd.m128i{ 0x0154442bd4, 0x01c6e41596 };
    const k3k4 = simd.m128i{ 0x01751997d0, 0x00ccaa009e };
    const k5k0 = simd.m128i{ 0x0163cd6124, 0x0000000000 };
    const poly = simd.m128i{ 0x01db710641, 0x01f7011641 };

    var x0: simd.m128i = undefined;
    var x1: simd.m128i = undefined;
    var x2: simd.m128i = undefined;
    var x3: simd.m128i = undefined;
    var x4: simd.m128i = undefined;
    var x5: simd.m128i = undefined;
    var x6: simd.m128i = undefined;
    var x7: simd.m128i = undefined;
    var x8: simd.m128i = undefined;
    var y5: simd.m128i = undefined;
    var y6: simd.m128i = undefined;
    var y7: simd.m128i = undefined;
    var y8: simd.m128i = undefined;

    const chunks_64_len = bytes.len - (bytes.len % 64);
    var chunks_64: []const [4]simd.m128i = @ptrCast(bytes[0..chunks_64_len]);
    const remaining_bytes_64: []align(64) const u8 = @alignCast(bytes[chunks_64_len..]);
    // There's at least one block of 64
    {
        x1 = chunks_64[0][0];
        x2 = chunks_64[0][1];
        x3 = chunks_64[0][2];
        x4 = chunks_64[0][3];
        x1 = x1 ^ @as(simd.m128i, @bitCast(@Vector(4, u32){ ~init_crc, 0, 0, 0 }));
        x0 = k1k2;
        chunks_64 = chunks_64[1..];
    }

    // Parallel fold blocks of 64, if any
    for (chunks_64) |*chunk| {
        x5 = simd.pclmulqdq(x1, x0, 0x00);
        x6 = simd.pclmulqdq(x2, x0, 0x00);
        x7 = simd.pclmulqdq(x3, x0, 0x00);
        x8 = simd.pclmulqdq(x4, x0, 0x00);
        x1 = simd.pclmulqdq(x1, x0, 0x11);
        x2 = simd.pclmulqdq(x2, x0, 0x11);
        x3 = simd.pclmulqdq(x3, x0, 0x11);
        x4 = simd.pclmulqdq(x4, x0, 0x11);

        y5 = chunk[0];
        y6 = chunk[1];
        y7 = chunk[2];
        y8 = chunk[3];

        x1 = x1 ^ x5;
        x2 = x2 ^ x6;
        x3 = x3 ^ x7;
        x4 = x4 ^ x8;
        x1 = x1 ^ y5;
        x2 = x2 ^ y6;
        x3 = x3 ^ y7;
        x4 = x4 ^ y8;
    }

    // Fold into 128-bits
    x0 = k3k4;
    x5 = simd.pclmulqdq(x1, x0, 0x00);
    x1 = simd.pclmulqdq(x1, x0, 0x11);
    x1 = x1 ^ x2;
    x1 = x1 ^ x5;
    x5 = simd.pclmulqdq(x1, x0, 0x00);
    x1 = simd.pclmulqdq(x1, x0, 0x11);
    x1 = x1 ^ x3;
    x1 = x1 ^ x5;
    x5 = simd.pclmulqdq(x1, x0, 0x00);
    x1 = simd.pclmulqdq(x1, x0, 0x11);
    x1 = x1 ^ x4;
    x1 = x1 ^ x5;

    const chunks_16_len = remaining_bytes_64.len - (remaining_bytes_64.len % 16);
    const chunks_16: []const simd.m128i =
        @ptrCast(@alignCast(remaining_bytes_64[0..chunks_16_len]));
    const remaining_bytes_16: []align(16) const u8 =
        @alignCast(remaining_bytes_64[chunks_16_len..]);

    // Single fold blocks of 16, if any
    for (chunks_16) |chunk| {
        x2 = chunk;
        x5 = simd.pclmulqdq(x1, x0, 0x00);
        x1 = simd.pclmulqdq(x1, x0, 0x11);
        x1 = x1 ^ x2;
        x1 = x1 ^ x5;
    }

    // Fold 128-bits to 64-bits
    x2 = simd.pclmulqdq(x1, x0, 0x10);
    x3 = @bitCast(@Vector(4, u32){ ~@as(u32, 0), @as(u32, 0), ~@as(u32, 0), @as(u32, 0) });
    x1 = simd.shift_right(x1, 8);
    x1 = x1 ^ x2;
    x0 = k5k0;
    x2 = simd.shift_right(x1, 4);
    x1 = x1 & x3;
    x1 = simd.pclmulqdq(x1, x0, 0x00);
    x1 = x1 ^ x2;

    // Barret reduce to 32-bits
    x0 = poly;
    x2 = x1 & x3;
    x2 = simd.pclmulqdq(x2, x0, 0x10);
    x2 = x2 & x3;
    x2 = simd.pclmulqdq(x2, x0, 0x00);
    x1 = x1 ^ x2;

    const v: [4]u32 = @bitCast(x1);
    const crc = v[1];

    if (remaining_bytes_16.len != 0)
        return crc32(~crc, remaining_bytes_16)
    else
        return ~crc;
}

fn crc32_simd_aarch64(init_crc: u32, bytes: []align(64) const u8) u32 {
    var crc = ~init_crc;

    const u64s_len = bytes.len / @sizeOf(u64);
    var u64s: []const u64 = undefined;
    u64s.ptr = @ptrCast(bytes.ptr);
    u64s.len = u64s_len;
    for (u64s) |v| crc = simd.aarch64.crc32x(crc, v);

    var rem = bytes.len % @sizeOf(u64);
    var rem_ptr = bytes.ptr + u64s_len * @sizeOf(u64);
    if (@sizeOf(u32) <= rem) {
        const v: *const u32 = @ptrCast(@alignCast(rem_ptr));
        crc = simd.aarch64.crc32w(crc, v.*);
        rem_ptr += @sizeOf(u32);
        rem -= @sizeOf(u32);
    }
    if (@sizeOf(u16) <= rem) {
        const v: *const u16 = @ptrCast(@alignCast(rem_ptr));
        crc = simd.aarch64.crc32h(crc, v.*);
        rem_ptr += @sizeOf(u16);
        rem -= @sizeOf(u16);
    }
    if (@sizeOf(u8) <= rem) {
        const v: *const u8 = @ptrCast(@alignCast(rem_ptr));
        crc = simd.aarch64.crc32b(crc, v.*);
    }
    return ~crc;
}

test "crc32_correctness" {
    const Stats = struct {
        total: u64 = 0,
        min: u64 = std.math.maxInt(u64),
        max: u64 = 0,
        last: u64 = 0,
        count: u64 = 0,

        fn update(self: *@This(), v: u64) void {
            self.last = v;
            self.count += 1;
            self.total += v;
            self.min = @min(self.min, v);
            self.max = @max(self.max, v);
        }

        fn print(self: *@This(), name: []const u8) void {
            std.debug.print(
                "{s:>20} | Count: {d} Total: {d:>12} Min: {d:>12} Max: {d:>12} Average: {d:>12} Last: {d:>12}\n",
                .{
                    name,
                    self.count,
                    self.total,
                    self.min,
                    self.max,
                    self.total / self.count,
                    self.last,
                },
            );
        }
    };

    var pcg: std.Random.Pcg = .init(0x69);
    const random = pcg.random();

    var buf align(4096) = [_]u8{0} ** (1 << 20);

    var miniz_stats: Stats = .{};
    var crc32_stats: Stats = .{};
    var crc32_simd_stats: Stats = .{};
    var len: u64 = 1;
    // Increment by 9 bytes to make buffer lengths more interestin
    while (len < 16 << 10) : (len += 1) {
        const b: []align(4096) u8 = @alignCast(buf[0..len]);
        random.bytes(b);

        const miniz_start = profiler.get_perf_counter();
        const miniz_answer = miniz.mz_crc32(
            miniz.MZ_CRC32_INIT,
            b.ptr,
            b.len,
        );
        const miniz_end = profiler.get_perf_counter();
        miniz_stats.update(miniz_end - miniz_start);

        const crc32_start = profiler.get_perf_counter();
        const crc32_answer = crc32(0, b);
        const crc32_end = profiler.get_perf_counter();
        crc32_stats.update(crc32_end - crc32_start);

        const crc32_simd_stard = profiler.get_perf_counter();
        const crc32_simd_answer = crc32_simd(0, b);
        const crc32_simd_end = profiler.get_perf_counter();
        crc32_simd_stats.update(crc32_simd_end - crc32_simd_stard);

        try std.testing.expectEqual(miniz_answer, crc32_answer);
        try std.testing.expectEqual(miniz_answer, crc32_simd_answer);
    }

    miniz_stats.print("Miniz");
    crc32_stats.print("crc32");
    crc32_simd_stats.print("crc32_simd");
}
