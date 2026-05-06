const std = @import("std");

pub fn checkAlive(io: std.Io, target_comm: []const u8) bool {
    var proc_dir = std.Io.Dir.openDirAbsolute(io, "/proc", .{ .iterate = true }) catch return true;
    defer proc_dir.close(io);

    var count: usize = 0;
    var iter = proc_dir.iterate();
    while (iter.next(io) catch null) |entry| {
        if (entry.kind != .directory) continue;

        var all_digit = true;
        for (entry.name) |ch| {
            if (ch < '0' or ch > '9') { all_digit = false; break; }
        }
        if (!all_digit) continue;

        var comm_buf: [64]u8 = undefined;
        var path_buf: [32]u8 = undefined;
        const comm_rel = std.fmt.bufPrint(&path_buf, "{s}/comm", .{entry.name}) catch continue;

        const data = proc_dir.readFile(io, comm_rel, &comm_buf) catch continue;
        const comm = std.mem.trimRight(u8, data, " \t\r\n");

        if (std.mem.eql(u8, comm, target_comm)) count += 1;
    }

    if (count > 1) {
        std.debug.print("[watchdog] warning: {d} processes named '{s}' found, treating as alive\n", .{ count, target_comm });
        return true;
    }
    return count == 1;
}
