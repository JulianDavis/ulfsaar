const std = @import("std");

pub var running = std.atomic.Value(bool).init(true);

fn sigintHandler(_: std.posix.SIG) callconv(.c) void {
    running.store(false, .release);
}

pub fn install() void {
    const act = std.posix.Sigaction{
        .handler = .{ .handler = sigintHandler },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.INT, &act, null);
}
