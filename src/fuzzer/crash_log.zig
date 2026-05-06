const std = @import("std");

pub const CAPACITY: usize = 25;
pub const ENTRY_BUF_SIZE: usize = 64 * 1024;

const Entry = struct {
    buf: [ENTRY_BUF_SIZE]u8,
    len: usize,
    run: u64,
    template_name: []const u8,
};

pub const CrashLog = struct {
    entries: [CAPACITY]Entry,
    head: usize = 0,
    count: usize = 0,
    crash_dir: []const u8,

    pub fn init(crash_dir: []const u8) CrashLog {
        return .{
            .entries = std.mem.zeroes([CAPACITY]Entry),
            .crash_dir = crash_dir,
        };
    }

    pub fn push(self: *CrashLog, msg: []const u8, run: u64, template_name: []const u8) void {
        const e = &self.entries[self.head];
        const n = @min(msg.len, ENTRY_BUF_SIZE);
        @memcpy(e.buf[0..n], msg[0..n]);
        e.len = n;
        e.run = run;
        e.template_name = template_name;
        self.head = (self.head + 1) % CAPACITY;
        if (self.count < CAPACITY) self.count += 1;
    }

    pub fn dump(self: *CrashLog, io: std.Io) !void {
        if (self.count == 0) return;

        const ts_ms = std.time.milliTimestamp();
        var subdir_buf: [64]u8 = undefined;
        const subdir = try std.fmt.bufPrint(&subdir_buf, "crash_{d}", .{ts_ms});

        var crashes = try std.Io.Dir.cwd().createDirPathOpen(io, self.crash_dir, .{});
        defer crashes.close(io);
        try crashes.createDirPath(io, subdir);
        var dir = try crashes.openDir(io, subdir, .{});
        defer dir.close(io);

        var write_buf: [4096]u8 = undefined;

        const start = (self.head + CAPACITY - self.count) % CAPACITY;
        for (0..self.count) |i| {
            const slot = (start + i) % CAPACITY;
            const e = &self.entries[slot];
            var name_buf: [128]u8 = undefined;
            const fname = try std.fmt.bufPrint(
                &name_buf,
                "{d:0>2}_run{d}_{s}.sip",
                .{ i, e.run, e.template_name },
            );
            var f = try dir.createFile(io, fname, .{});
            defer f.close(io);
            var w = f.writer(io, &write_buf);
            try w.writeAll(e.buf[0..e.len]);
            try w.flush();
        }

        std.debug.print("[crash] dumped {d} cases to {s}/{s}\n", .{
            self.count, self.crash_dir, subdir,
        });

        self.head = 0;
        self.count = 0;
    }
};
