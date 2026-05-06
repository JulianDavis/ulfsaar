const std = @import("std");
const corpus_mod = @import("fuzzer/corpus.zig");
const mutator = @import("fuzzer/mutator.zig");
const sender_mod = @import("fuzzer/sender.zig");
const ipc_mod = @import("fuzzer/ipc_reader.zig");
const crash_log_mod = @import("fuzzer/crash_log.zig");
const stats_mod = @import("fuzzer/stats.zig");

const ASSEMBLY_BUF_SIZE = 64 * 1024;
const DEFAULT_TARGET_PORT: u16 = 5060;
const DEFAULT_IPC_PORT: u16 = 9999;
const DEFAULT_CRASH_DIR = "./crashes";

fn printUsage() void {
    std.debug.print(
        \\Usage: fuzzer --target-ip <IP> [--target-port <PORT>] --corpus <DIR>
        \\              [--ipc-port <PORT>] [--crash-dir <DIR>]
        \\
        \\  --target-ip    IPv4 address of SIP target (required)
        \\  --target-port  UDP port for SIP target (default: 5060)
        \\  --corpus       Directory containing .sip files (required)
        \\  --ipc-port     UDP port for watchdog IPC (default: 9999)
        \\  --crash-dir    Directory for crash artifacts (default: ./crashes)
        \\
    , .{});
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    var target_ip: ?[]const u8 = null;
    var target_port: u16 = DEFAULT_TARGET_PORT;
    var corpus_dir: ?[]const u8 = null;
    var ipc_port: u16 = DEFAULT_IPC_PORT;
    var crash_dir: []const u8 = DEFAULT_CRASH_DIR;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--target-ip")) {
            i += 1;
            if (i >= args.len) { printUsage(); return error.MissingArgValue; }
            target_ip = args[i];
        } else if (std.mem.eql(u8, arg, "--target-port")) {
            i += 1;
            if (i >= args.len) { printUsage(); return error.MissingArgValue; }
            target_port = try std.fmt.parseInt(u16, args[i], 10);
        } else if (std.mem.eql(u8, arg, "--corpus")) {
            i += 1;
            if (i >= args.len) { printUsage(); return error.MissingArgValue; }
            corpus_dir = args[i];
        } else if (std.mem.eql(u8, arg, "--ipc-port")) {
            i += 1;
            if (i >= args.len) { printUsage(); return error.MissingArgValue; }
            ipc_port = try std.fmt.parseInt(u16, args[i], 10);
        } else if (std.mem.eql(u8, arg, "--crash-dir")) {
            i += 1;
            if (i >= args.len) { printUsage(); return error.MissingArgValue; }
            crash_dir = args[i];
        } else {
            std.debug.print("Unknown argument: {s}\n", .{arg});
            printUsage();
            return error.UnknownArgument;
        }
    }

    if (target_ip == null) {
        std.debug.print("Error: --target-ip is required\n", .{});
        printUsage();
        return error.MissingRequiredArg;
    }
    if (corpus_dir == null) {
        std.debug.print("Error: --corpus is required\n", .{});
        printUsage();
        return error.MissingRequiredArg;
    }

    // Load corpus
    var corpus = corpus_mod.Corpus.load(allocator, io, corpus_dir.?) catch |err| {
        std.debug.print("Failed to load corpus from '{s}': {}\n", .{ corpus_dir.?, err });
        return err;
    };
    defer corpus.deinit();

    // Set up crash dir
    try std.Io.Dir.cwd().createDirPath(io, crash_dir);

    // Init crash log
    var clog = crash_log_mod.CrashLog.init(crash_dir);

    // Init sender
    var sender = try sender_mod.Sender.init(io, target_ip.?, target_port);
    defer sender.deinit();

    // Init IPC reader
    var ipc = try ipc_mod.IpcReader.init(io, ipc_port);
    defer ipc.deinit();

    // Assembly buffer (fixed size — never grows on hot path)
    var assembly_buf: [ASSEMBLY_BUF_SIZE]u8 = undefined;

    // Init radamsa
    mutator.init();

    // RNG
    var rng = std.Random.DefaultPrng.init(@bitCast(std.time.microTimestamp()));

    var stats = stats_mod.Stats{};

    std.debug.print(
        "ulfsaar fuzzer started, target={s}:{d}, corpus={d} messages, ipc=0.0.0.0:{d}, crash-dir={s}\n",
        .{ target_ip.?, target_port, corpus.templates.len, ipc_port, crash_dir },
    );

    var idx: usize = 0;
    while (true) {
        ipc.drain(&clog);

        const tmpl = &corpus.templates[idx % corpus.templates.len];

        const msg = mutator.assemble(&assembly_buf, tmpl, &rng) catch |err| {
            std.debug.print("[warn] assemble failed: {}\n", .{err});
            idx += 1;
            continue;
        };

        sender.send(msg) catch |err| {
            std.debug.print("[error] send failed: {}\n", .{err});
            return err;
        };

        sender.send(corpus.cancel_raw) catch |err| {
            std.debug.print("[error] cancel send failed: {}\n", .{err});
            return err;
        };

        clog.push(msg, stats.runs, tmpl.name);
        stats.tick(tmpl.name);
        idx += 1;
    }
}
