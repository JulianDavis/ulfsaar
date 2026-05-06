const std = @import("std");
const template = @import("template.zig");

pub const Corpus = struct {
    allocator: std.mem.Allocator,
    templates: []template.Template,
    cancel_raw: []u8,

    pub fn load(allocator: std.mem.Allocator, io: std.Io, dir_path: []const u8) !Corpus {
        var dir = try std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true });
        defer dir.close(io);

        var rotation = std.ArrayList(template.Template).init(allocator);
        errdefer {
            for (rotation.items) |*t| {
                allocator.free(t.raw);
                allocator.free(t.segments);
            }
            rotation.deinit();
        }

        var cancel_raw: ?[]u8 = null;
        errdefer if (cancel_raw) |b| allocator.free(b);

        var names = std.ArrayList([]u8).init(allocator);
        defer {
            for (names.items) |n| allocator.free(n);
            names.deinit();
        }

        var iter = dir.iterate();
        while (try iter.next(io)) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".sip")) continue;
            try names.append(try allocator.dupe(u8, entry.name));
        }

        std.mem.sort([]u8, names.items, {}, struct {
            fn lt(_: void, a: []u8, b: []u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
        }.lt);

        for (names.items) |name| {
            const raw = try dir.readFileAlloc(io, name, allocator, .unlimited);
            errdefer allocator.free(raw);

            if (std.mem.eql(u8, name, "cancel.sip")) {
                cancel_raw = raw;
                continue;
            }

            const base = name[0 .. name.len - 4];
            const owned_name = try allocator.dupe(u8, base);
            errdefer allocator.free(owned_name);

            const t = try template.parse(allocator, owned_name, raw);
            try rotation.append(t);
        }

        if (cancel_raw == null) return error.MissingCancelSip;
        if (rotation.items.len == 0) return error.EmptyCorpus;

        return .{
            .allocator = allocator,
            .templates = try rotation.toOwnedSlice(),
            .cancel_raw = cancel_raw.?,
        };
    }

    pub fn deinit(self: *Corpus) void {
        for (self.templates) |*t| {
            self.allocator.free(t.raw);
            self.allocator.free(t.segments);
        }
        self.allocator.free(self.templates);
        self.allocator.free(self.cancel_raw);
    }
};
