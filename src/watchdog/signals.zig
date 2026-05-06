const std = @import("std");

pub var running = std.atomic.Value(bool).init(true);

fn sigintHandler(_: c_int) callconv(.C) void {
    running.store(false, .release);
}

pub fn install() !void {
    const act = std.posix.Sigaction{
        .handler = .{ .handler = sigintHandler },
        .mask = std.posix.empty_sigset,
        .flags = 0,
    };
    try std.posix.sigaction(std.posix.SIG.INT, &act, null);
}
