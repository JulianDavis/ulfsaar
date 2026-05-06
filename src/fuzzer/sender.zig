const std = @import("std");

pub const Sender = struct {
    sock: std.Io.net.Socket,
    dest: std.Io.net.IpAddress,
    io: std.Io,

    pub fn init(io: std.Io, target_ip: []const u8, target_port: u16) !Sender {
        var bind_addr = try std.Io.net.IpAddress.parseIp4("0.0.0.0", 0);
        const sock = try bind_addr.bind(io, .{ .mode = .dgram });
        const dest = try std.Io.net.IpAddress.parseIp4(target_ip, target_port);
        return .{ .sock = sock, .dest = dest, .io = io };
    }

    pub fn send(self: *Sender, msg: []const u8) !void {
        try self.sock.send(self.io, &self.dest, msg);
    }

    pub fn deinit(self: *Sender) void {
        self.sock.close(self.io);
    }
};
