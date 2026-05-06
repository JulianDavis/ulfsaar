const std = @import("std");

pub fn runScript(io: std.Io, script_path: []const u8) !u8 {
    var child = try std.process.spawn(io, .{
        .argv = &.{ "/bin/sh", "-c", script_path },
    });
    const term = try child.wait(io);
    return switch (term) {
        .exited => |code| code,
        else => 1,
    };
}
