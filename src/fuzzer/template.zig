const std = @import("std");

pub const Segment = union(enum) {
    static: []const u8,
    fuzz_seed: []const u8,
};

pub const Template = struct {
    name: []const u8,
    raw: []u8,
    segments: []Segment,
};

pub fn parse(allocator: std.mem.Allocator, name: []const u8, raw: []u8) !Template {
    const open = "{{FUZZ}}";
    const close = "{{/FUZZ}}";

    var segments = std.ArrayList(Segment).init(allocator);
    errdefer segments.deinit();

    var i: usize = 0;
    while (i < raw.len) {
        const open_at = std.mem.indexOfPos(u8, raw, i, open) orelse {
            try segments.append(.{ .static = raw[i..] });
            break;
        };
        if (open_at > i) try segments.append(.{ .static = raw[i..open_at] });
        const seed_start = open_at + open.len;
        const close_at = std.mem.indexOfPos(u8, raw, seed_start, close) orelse
            return error.UnterminatedFuzzMarker;
        try segments.append(.{ .fuzz_seed = raw[seed_start..close_at] });
        i = close_at + close.len;
    }

    return .{
        .name = name,
        .raw = raw,
        .segments = try segments.toOwnedSlice(),
    };
}
