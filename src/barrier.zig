// Copyright (c) 2026 Egor Lazarchuk
// SPDX-License-Identifier: MIT

const std = @import("std");
const os = @import("os.zig");

total_threads: u32 = 0,
count: std.atomic.Value(u32) = .init(0),
futex: std.atomic.Value(u32) = .init(0),

const Self = @This();

pub fn wait(self: *Self) void {
    const current_futex = self.futex.load(.acquire);
    const count = self.count.fetchAdd(1, .acq_rel) + 1;
    if (count == self.total_threads) {
        self.futex.store(current_futex + 1, .release);
        _ = os.futex2_wake(&self.futex, @intCast(self.total_threads - 1)) catch unreachable;
        return;
    }
    while (self.futex.load(.acquire) == current_futex) {
        _ = os.futex2_wait(&self.futex, current_futex) catch unreachable;
    }
}
