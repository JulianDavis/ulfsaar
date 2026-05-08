const std = @import("std");
const crash_log = @import("crash_log.zig");

// Zero-duration timeout used to drain without blocking.
const zero_timeout = std.Io.Timeout{ .duration = .{
    .raw = .{ .nanoseconds = 1 },
    .clock = .awake,
} };

pub const IpcReader = struct {
    sock: std.Io.net.Socket,
    io: std.Io,

    pub fn init(io: std.Io, ipc_port: u16) !IpcReader {
        var bind_addr = try std.Io.net.IpAddress.parseIp4("0.0.0.0", ipc_port);
        const sock = try bind_addr.bind(io, .{ .mode = .dgram });
        return .{ .sock = sock, .io = io };
    }

    pub fn drain(self: *IpcReader, log: *crash_log.CrashLog) void {
        var buf: [1024]u8 = undefined;
        while (true) {
            const msg = self.sock.receiveTimeout(self.io, &buf, zero_timeout) catch |err| {
                if (err == error.Timeout) return;
                std.debug.print("[ipc] recv error: {}\n", .{err});
                return;
            };
            const payload = std.mem.trimEnd(u8, msg.data, " \t\r\n");
            if (std.ascii.eqlIgnoreCase(payload, "START")) {
                std.debug.print("[ipc] target start\n", .{});
            } else if (std.ascii.eqlIgnoreCase(payload, "STOP")) {
                std.debug.print("[ipc] watchdog stopping\n", .{});
            } else if (std.ascii.eqlIgnoreCase(payload, "CRASH")) {
                std.debug.print("[ipc] target CRASH\n", .{});
                log.dump(self.io) catch |err| {
                    std.debug.print("[ipc] crash dump error: {}\n", .{err});
                };
            } else {
                std.debug.print("[ipc] unknown: {s}\n", .{std.fmt.fmtSliceEscapeLower(payload)});
            }
        }
    }

    pub fn deinit(self: *IpcReader) void {
        self.sock.close(self.io);
    }
};
