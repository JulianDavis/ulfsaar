const std = @import("std");

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});

    // ---- fuzzer ----
    const fuzzer_target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .linux,
        .abi = .gnu,
    });

    const radamsa_make = b.addSystemCommand(&.{
        "make", "-C", "deps/radamsa", "lib/libradamsa.a",
    });

    const fuzzer_mod = b.createModule(.{
        .root_source_file = b.path("src/fuzzer_main.zig"),
        .target = fuzzer_target,
        .optimize = optimize,
        .link_libc = true,
    });
    fuzzer_mod.addIncludePath(b.path("deps/radamsa/c"));
    fuzzer_mod.addObjectFile(b.path("deps/radamsa/lib/libradamsa.a"));

    const fuzzer = b.addExecutable(.{
        .name = "fuzzer",
        .root_module = fuzzer_mod,
    });
    fuzzer.step.dependOn(&radamsa_make.step);
    b.installArtifact(fuzzer);

    const fuzzer_step = b.step("fuzzer", "Build host fuzzer");
    fuzzer_step.dependOn(&b.addInstallArtifact(fuzzer, .{}).step);

    // ---- watchdog ----
    const watchdog_target = b.standardTargetOptions(.{});

    const watchdog_mod = b.createModule(.{
        .root_source_file = b.path("src/watchdog_main.zig"),
        .target = watchdog_target,
        .optimize = optimize,
    });

    const watchdog = b.addExecutable(.{
        .name = "watchdog",
        .root_module = watchdog_mod,
    });
    b.installArtifact(watchdog);

    const watchdog_step = b.step("watchdog", "Build target watchdog");
    watchdog_step.dependOn(&b.addInstallArtifact(watchdog, .{}).step);
}
