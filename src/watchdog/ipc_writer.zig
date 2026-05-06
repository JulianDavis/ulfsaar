const std = @import("std");

pub const IpcWriter = struct {
    sock: std.Io.net.Socket,
    dest: std.Io.net.IpAddress,
    io: std.Io,

    pub fn init(io: std.Io, fuzzer_ip: []const u8, fuzzer_port: u16) !IpcWriter {
        var bind_addr = try std.Io.net.IpAddress.parseIp4("0.0.0.0", 0);
        const sock = try bind_addr.bind(io, .{ .mode = .dgram });
        const dest = try std.Io.net.IpAddress.parseIp4(fuzzer_ip, fuzzer_port);
        return .{ .sock = sock, .dest = dest, .io = io };
    }

    fn sendMsg(self: *IpcWriter, msg: []const u8) void {
        self.sock.send(self.io, &self.dest, msg) catch {};
    }

    pub fn sendStart(self: *IpcWriter) void {
        self.sendMsg("START");
    }

    pub fn sendStop(self: *IpcWriter) void {
        self.sendMsg("STOP");
    }

    pub fn sendCrash(self: *IpcWriter) void {
        self.sendMsg("CRASH");
    }

    pub fn deinit(self: *IpcWriter) void {
        self.sock.close(self.io);
    }
};
