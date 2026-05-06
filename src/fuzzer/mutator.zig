const std = @import("std");
const template = @import("template.zig");
const c = @cImport(@cInclude("radamsa.h"));

pub fn assemble(
    out: []u8,
    tmpl: *const template.Template,
    rng: *std.Random.DefaultPrng,
) ![]u8 {
    var w: usize = 0;
    for (tmpl.segments) |seg| switch (seg) {
        .static => |s| {
            if (w + s.len > out.len) return error.AssemblyOverflow;
            @memcpy(out[w..][0..s.len], s);
            w += s.len;
        },
        .fuzz_seed => |s| {
            const seed: c_uint = rng.random().int(c_uint);
            const written = c.radamsa(
                @constCast(s.ptr),
                s.len,
                out.ptr + w,
                out.len - w,
                seed,
            );
            if (written == 0 or written == std.math.maxInt(usize)) return error.RadamsaFailed;
            w += written;
        },
    };
    return out[0..w];
}

pub fn init() void {
    c.radamsa_init();
}
