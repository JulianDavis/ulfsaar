const std = @import("std");
const signals = @import("watchdog/signals.zig");
const monitor = @import("watchdog/monitor.zig");
const runner = @import("watchdog/runner.zig");
const ipc_mod = @import("watchdog/ipc_writer.zig");

const DEFAULT_FUZZER_PORT: u16 = 9999;
const DEFAULT_POLL_MS: u64 = 100;

fn printUsage() void {
    std.debug.print(
        \\Usage: watchdog --pid <PID> --restart-script <PATH> --fuzzer-ip <IP>
        \\               [--fuzzer-port <PORT>] [--poll-ms <N>]
        \\
        \\  --pid             Initial PID of target process (required)
        \\  --restart-script  Shell script to restart the target (required)
        \\  --fuzzer-ip       IPv4 address of the fuzzer host (required)
        \\  --fuzzer-port     UDP port of fuzzer IPC listener (default: 9999)
        \\  --poll-ms         Poll interval in milliseconds (default: 100)
        \\
    , .{});
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    var initial_pid: ?[]const u8 = null;
    var restart_script: ?[]const u8 = null;
    var fuzzer_ip: ?[]const u8 = null;
    var fuzzer_port: u16 = DEFAULT_FUZZER_PORT;
    var poll_ms: u64 = DEFAULT_POLL_MS;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--pid")) {
            i += 1;
            if (i >= args.len) { printUsage(); return error.MissingArgValue; }
            initial_pid = args[i];
        } else if (std.mem.eql(u8, arg, "--restart-script")) {
            i += 1;
            if (i >= args.len) { printUsage(); return error.MissingArgValue; }
            restart_script = args[i];
        } else if (std.mem.eql(u8, arg, "--fuzzer-ip")) {
            i += 1;
            if (i >= args.len) { printUsage(); return error.MissingArgValue; }
            fuzzer_ip = args[i];
        } else if (std.mem.eql(u8, arg, "--fuzzer-port")) {
            i += 1;
            if (i >= args.len) { printUsage(); return error.MissingArgValue; }
            fuzzer_port = try std.fmt.parseInt(u16, args[i], 10);
        } else if (std.mem.eql(u8, arg, "--poll-ms")) {
            i += 1;
            if (i >= args.len) { printUsage(); return error.MissingArgValue; }
            poll_ms = try std.fmt.parseInt(u64, args[i], 10);
        } else {
            std.debug.print("Unknown argument: {s}\n", .{arg});
            printUsage();
            return error.UnknownArgument;
        }
    }

    if (initial_pid == null) {
        std.debug.print("Error: --pid is required\n", .{});
        printUsage();
        return error.MissingRequiredArg;
    }
    if (restart_script == null) {
        std.debug.print("Error: --restart-script is required\n", .{});
        printUsage();
        return error.MissingRequiredArg;
    }
    if (fuzzer_ip == null) {
        std.debug.print("Error: --fuzzer-ip is required\n", .{});
        printUsage();
        return error.MissingRequiredArg;
    }

    // Read comm name from /proc/<pid>/comm
    var comm_path_buf: [64]u8 = undefined;
    const comm_path = try std.fmt.bufPrint(&comm_path_buf, "/proc/{s}/comm", .{initial_pid.?});
    var comm_buf: [64]u8 = undefined;
    const comm_file = try std.Io.Dir.openFileAbsolute(io, comm_path, .{});
    var read_buf: [256]u8 = undefined;
    var comm_reader = comm_file.reader(io, &read_buf);
    const comm_n = try comm_reader.readSliceShort(&comm_buf);
    comm_file.close(io);
    const target_comm = std.mem.trimRight(u8, comm_buf[0..comm_n], " \t\r\n");

    std.debug.print("[watchdog] monitoring '{s}' (pid {s}), script={s}, fuzzer={s}:{d}, poll={d}ms\n", .{
        target_comm, initial_pid.?, restart_script.?, fuzzer_ip.?, fuzzer_port, poll_ms,
    });

    // Install SIGINT handler
    try signals.install();

    // Init IPC writer
    var ipc = try ipc_mod.IpcWriter.init(io, fuzzer_ip.?, fuzzer_port);
    defer ipc.deinit();

    ipc.sendStart();

    const poll_duration = std.Io.Clock.Duration{
        .raw = .{ .nanoseconds = @as(i96, poll_ms) * std.time.ns_per_ms },
        .clock = .awake,
    };

    while (signals.running.load(.acquire)) {
        poll_duration.sleep(io) catch {};

        if (!monitor.checkAlive(io, target_comm)) {
            std.debug.print("[watchdog] crash detected for '{s}'\n", .{target_comm});
            ipc.sendCrash();

            const rc = runner.runScript(io, restart_script.?) catch |err| {
                std.debug.print("[watchdog] restart script error: {}\n", .{err});
                continue;
            };

            if (rc != 0) {
                std.debug.print("[watchdog] restart script exited with code {d}\n", .{rc});
                continue;
            }

            ipc.sendStart();
        }
    }

    ipc.sendStop();
    std.debug.print("[watchdog] exiting\n", .{});
}
