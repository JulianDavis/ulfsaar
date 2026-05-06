const std = @import("std");

pub const Stats = struct {
    runs: u64 = 0,

    pub fn tick(self: *Stats, template_name: []const u8) void {
        self.runs += 1;
        if (self.runs % 100 == 0) {
            std.debug.print("[runs={d}] last={s}\n", .{ self.runs, template_name });
        }
    }
};
