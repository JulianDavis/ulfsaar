# Ulfsaar SIP Fuzzer — Implementation Specification

## 1. Overview

Ulfsaar is a black-box SIP fuzzer with two components:

| Component | Host | Arch | Role |
|-----------|------|------|------|
| `fuzzer` | Build host | Linux x86-64 | Loads a SIP corpus, mutates messages with radamsa, sends them by UDP to the target, listens on a UDP control port for status from the watchdog, prints stats. |
| `watchdog` | Target device | Linux arm-linux-gnueabihf (32-bit ARM) initially | Watches a named target process, runs a restart shell script on crash, sends `START` / `STOP` / `CRASH` UDP datagrams to the fuzzer's control port. |

Both components are written in Zig 0.16.0. The fuzzer links radamsa as a static library (from https://github.com/JulianDavis/radamsa). The watchdog is pure Zig — no radamsa.

This document is the implementation contract. Anything not specified here is out of scope for the MVP.

## 2. Repository Layout

```
ulfsaar/
├── build.zig
├── build.zig.zon
├── README.md
├── design.md                    (original design notes — do not edit)
├── IMPLEMENTATION.md            (this file)
├── deps/
│   └── radamsa/                 (git submodule: JulianDavis/radamsa)
├── corpus/
│   ├── cancel.sip               (REQUIRED, reserved name, sent verbatim)
│   ├── invite.sip               (example template)
│   └── register.sip             (example template)
└── src/
    ├── fuzzer_main.zig          (entry point: `fuzzer` executable)
    ├── fuzzer/
    │   ├── corpus.zig
    │   ├── template.zig
    │   ├── mutator.zig          (radamsa wrapper)
    │   ├── sender.zig           (UDP send to SIP target)
    │   ├── ipc_reader.zig       (UDP recv from watchdog)
    │   ├── crash_log.zig        (ring buffer + dump-on-CRASH)
    │   └── stats.zig
    ├── watchdog_main.zig        (entry point: `watchdog` executable)
    └── watchdog/
        ├── monitor.zig
        ├── runner.zig           (shell script invocation)
        ├── ipc_writer.zig       (UDP send to fuzzer)
        └── signals.zig          (SIGINT handler)
```

Add `deps/radamsa` as a git submodule pinned to `JulianDavis/radamsa` `develop`:

```
git submodule add https://github.com/JulianDavis/radamsa.git deps/radamsa
```

## 3. Build System (`build.zig`)

Zig 0.16.0 build script must:

1. Define two executables, `fuzzer` and `watchdog`, with separate target options:
   - `fuzzer`: target locked to `x86_64-linux-gnu`.
   - `watchdog`: default native, but accepts `-Dtarget=arm-linux-gnueabihf` (or any other target) via `b.standardTargetOptions`.
2. For the `fuzzer` target:
   - Run a `b.addSystemCommand` step that invokes `make -C deps/radamsa lib/libradamsa.a` (the Makefile produces `deps/radamsa/lib/libradamsa.a` and uses `deps/radamsa/c/radamsa.h`). The fuzzer step depends on this.
   - `addIncludePath` → `deps/radamsa/c`
   - `addObjectFile` → `deps/radamsa/lib/libradamsa.a` (static link; libradamsa is freestanding, no extra link deps required)
   - `linkLibC()` because `radamsa.h` includes `<inttypes.h>`/`<stddef.h>` and we use `@cImport`.
3. Both executables installed via `b.installArtifact(...)`.
4. Build steps:
   - `zig build` → builds both
   - `zig build fuzzer` / `zig build watchdog` → individual

Sample skeleton:

```zig
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

    const fuzzer = b.addExecutable(.{
        .name = "fuzzer",
        .root_source_file = b.path("src/fuzzer_main.zig"),
        .target = fuzzer_target,
        .optimize = optimize,
    });
    fuzzer.step.dependOn(&radamsa_make.step);
    fuzzer.addIncludePath(b.path("deps/radamsa/c"));
    fuzzer.addObjectFile(b.path("deps/radamsa/lib/libradamsa.a"));
    fuzzer.linkLibC();
    b.installArtifact(fuzzer);

    const fuzzer_step = b.step("fuzzer", "Build host fuzzer");
    fuzzer_step.dependOn(&b.addInstallArtifact(fuzzer, .{}).step);

    // ---- watchdog ----
    const watchdog_target = b.standardTargetOptions(.{});
    const watchdog = b.addExecutable(.{
        .name = "watchdog",
        .root_source_file = b.path("src/watchdog_main.zig"),
        .target = watchdog_target,
        .optimize = optimize,
    });
    b.installArtifact(watchdog);

    const watchdog_step = b.step("watchdog", "Build target watchdog");
    watchdog_step.dependOn(&b.addInstallArtifact(watchdog, .{}).step);
}
```

`build.zig.zon`:

```zig
.{
    .name = "ulfsaar",
    .version = "0.0.1",
    .minimum_zig_version = "0.16.0",
    .paths = .{ "build.zig", "build.zig.zon", "src", "deps", "corpus" },
    .dependencies = .{},
}
```

Cross-compiling the watchdog for the device:
```
zig build watchdog -Dtarget=arm-linux-gnueabihf -Doptimize=ReleaseSafe
```

## 4. SIP Corpus Template Format

### 4.1 Format specification

A corpus file is a SIP message with **inline mutation markers**:

```
{{FUZZ}}<seed bytes>{{/FUZZ}}
```

- Anything **outside** a `{{FUZZ}}…{{/FUZZ}}` pair is static and emitted byte-for-byte every iteration.
- Anything **inside** a pair is the *seed* fed to radamsa each iteration. Radamsa returns mutated bytes that replace the seed in the output.
- Markers must not nest. The closing `{{/FUZZ}}` must follow its opener; mismatched markers are a fatal load error.
- Markers themselves are stripped — they never appear on the wire.
- File contents are treated as raw bytes (CRLF preserved). The file's existing line endings flow through unchanged.

Example `corpus/invite.sip`:

```
INVITE sip:{{FUZZ}}alice{{/FUZZ}}@192.168.1.10 SIP/2.0
Via: SIP/2.0/UDP 192.168.1.20:5060;branch=z9hG4bK-{{FUZZ}}776asdhds{{/FUZZ}}
Max-Forwards: {{FUZZ}}70{{/FUZZ}}
From: <sip:tester@192.168.1.20>;tag={{FUZZ}}1928301774{{/FUZZ}}
To: <sip:alice@192.168.1.10>
Call-ID: {{FUZZ}}a84b4c76e66710{{/FUZZ}}@192.168.1.20
CSeq: 314159 INVITE
Contact: <sip:tester@192.168.1.20>
Content-Type: application/sdp
Content-Length: 0

```

### 4.2 Why this format

- `{{` and `}}` do not appear in valid SIP grammar (RFC 3261 token / quoted-string / URI rules), so collisions with real SIP content are essentially impossible.
- Single-pass parser, zero allocator pressure during mutation: parse once at startup into a slice of `Segment` referencing the original file buffer.
- Radamsa is run on each mutable region independently with a fresh seed, so different fields drift independently — this is what we want for SIP, where header semantics are independent.
- No second metadata file to keep in sync with the SIP body.

### 4.3 Reserved file: `cancel.sip`

- The corpus directory **must** contain a file named `cancel.sip`.
- It is loaded as raw bytes (no template parsing). Markers, if present, are passed through literally.
- It is **not** included in the rotation. It is sent verbatim after every fuzzed message.
- If `cancel.sip` is missing, the fuzzer exits with an error at startup.
- Provide a minimal default in `corpus/cancel.sip`:

```
CANCEL sip:alice@192.168.1.10 SIP/2.0
Via: SIP/2.0/UDP 192.168.1.20:5060;branch=z9hG4bK-cancel-static
Max-Forwards: 70
From: <sip:tester@192.168.1.20>;tag=ulfsaar-cancel
To: <sip:alice@192.168.1.10>
Call-ID: ulfsaar-cancel@192.168.1.20
CSeq: 314159 CANCEL
Content-Length: 0

```

(The user is expected to tune `cancel.sip` for their target — Ulfsaar makes no attempt to match transactions.)

### 4.4 Corpus loading rules

1. Iterate the directory non-recursively.
2. Load every regular file ending in `.sip`.
3. The file `cancel.sip` is set aside as the static cancel message.
4. All other `.sip` files become rotation entries, sorted by file name (deterministic ordering).
5. Each rotation file is parsed into `Segments` at load time (see §4.5).
6. After load: there must be ≥ 1 rotation entry and exactly one cancel entry, otherwise fail fast.
7. The template's `name` field stores the basename with the `.sip` extension stripped (e.g. `invite`). The cancel message has no name.

### 4.5 Parser data model (`src/fuzzer/template.zig`)

```zig
const std = @import("std");

pub const Segment = union(enum) {
    static: []const u8,    // borrowed slice into raw file buffer
    fuzz_seed: []const u8, // borrowed slice into raw file buffer
};

pub const Template = struct {
    name: []const u8,        // basename
    raw: []u8,               // owned: full file contents
    segments: []Segment,     // owned slice
};

pub fn parse(allocator: std.mem.Allocator, name: []const u8, raw: []u8) !Template {
    const open = "{{FUZZ}}";
    const close = "{{/FUZZ}}";

    var segments: std.ArrayList(Segment) = .empty;
    errdefer segments.deinit(allocator);

    var i: usize = 0;
    while (i < raw.len) {
        const open_at = std.mem.indexOfPos(u8, raw, i, open) orelse {
            try segments.append(allocator, .{ .static = raw[i..] });
            break;
        };
        if (open_at > i) try segments.append(allocator, .{ .static = raw[i..open_at] });
        const seed_start = open_at + open.len;
        const close_at = std.mem.indexOfPos(u8, raw, seed_start, close)
            orelse return error.UnterminatedFuzzMarker;
        try segments.append(allocator, .{ .fuzz_seed = raw[seed_start..close_at] });
        i = close_at + close.len;
    }

    return .{
        .name = name,
        .raw = raw,
        .segments = try segments.toOwnedSlice(allocator),
    };
}
```

Note: the segment slices are borrowed views into `raw`, so `raw` must outlive the template.

## 5. Fuzzer Component

### 5.1 CLI (`src/fuzzer_main.zig`)

```
fuzzer --target-ip <IP> [--target-port <PORT>] --corpus <DIR> [--ipc-port <PORT>] [--crash-dir <DIR>]
```

| Flag | Default | Description |
|------|---------|-------------|
| `--target-ip` | (required) | IPv4 address of SIP target. |
| `--target-port` | `5060` | UDP port for the SIP target. |
| `--corpus` | (required) | Directory containing `.sip` files including `cancel.sip`. |
| `--ipc-port` | `9999` | UDP port the fuzzer binds to (`0.0.0.0:<port>`) to receive watchdog status datagrams. |
| `--crash-dir` | `./crashes` | Directory under which crash artifacts are written. Created (recursively) if missing. Each crash gets its own timestamped subdirectory. |

Implement a tiny hand-rolled parser; do not pull in a CLI library.

### 5.2 Startup sequence

1. Parse args.
2. Create the **target UDP socket** (`AF_INET`, `SOCK_DGRAM`). Pre-build `sockaddr_in` for the SIP target. Do not `connect()`.
3. Create the **IPC UDP socket** (`AF_INET`, `SOCK_DGRAM`), set `SO_REUSEADDR`, `bind` to `0.0.0.0:<ipc-port>`, and put it in non-blocking mode (`O_NONBLOCK`).
4. Load corpus (§4.4).
4a. Resolve `--crash-dir`. Create it (recursive `makePath`) if it does not exist.
4b. Initialize the crash ring buffer (`crash_log.CrashLog.init(crash_dir)`) — this allocates the 25-slot fixed array. No allocations occur on the hot path after this. See §5.8.
5. Allocate one reusable assembly buffer of `64 KiB` (SIP UDP packets are typically far smaller; this is generous and never grows in the hot path — error out if it would). Allocate a separate small `1 KiB` IPC recv buffer.
6. Call `radamsa_init()` once.
7. Print banner: `ulfsaar fuzzer started, target=<ip>:<port>, corpus=<n> messages, ipc=0.0.0.0:<ipc-port>, crash-dir=<crash-dir>`.
8. Enter main loop.

### 5.3 Main loop (`src/fuzzer_main.zig`)

```
loop forever:
    drain_ipc()                              # may call crash_log.dump on CRASH
    template = corpus[idx % corpus.len]
    msg = assemble_mutated(template)         # fills assembly_buffer
    udp_send(msg)
    udp_send(cancel_buffer)
    crash_log.push(msg, runs, template.name) # copy into ring buffer (memcpy)
    runs += 1
    if runs % 100 == 0:
        print "[runs=N] last=<template name>"
    idx += 1
```

No sleeps. No throttling. Fail-fast on send errors that aren't `EAGAIN` (for `EAGAIN` retry once, then drop the iteration).

`crash_log.push` is a `memcpy` into a pre-allocated slot — no allocation, O(msg.len). The CANCEL is intentionally **not** stored: it is static and known, so storing it would only dilute the retention window.

### 5.4 Assembling a mutated message (`src/fuzzer/mutator.zig`)

```zig
pub fn assemble(
    out: []u8,
    template: *const Template,
    rng: *std.Random.DefaultPrng,
) ![]u8 {
    var w: usize = 0;
    for (template.segments) |seg| switch (seg) {
        .static => |s| {
            if (w + s.len > out.len) return error.AssemblyOverflow;
            @memcpy(out[w..][0..s.len], s);
            w += s.len;
        },
        .fuzz_seed => |s| {
            const seed: c_uint = rng.random().int(c_uint);
            // radamsa wants a non-const ptr; cast away const since it does not write into ptr
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
```

`c` is `@cImport({ @cInclude("radamsa.h"); })` in the file.

### 5.5 UDP sender (`src/fuzzer/sender.zig`)

- Single `socket(AF_INET, SOCK_DGRAM, 0)`.
- `sendto` per message. Do not connect — keep the destination explicit.
- No retransmit logic: SIP fuzzing is best-effort.

### 5.6 IPC reader (`src/fuzzer/ipc_reader.zig`)

- UDP socket bound at startup (§5.2), non-blocking.
- `drain_ipc` calls `recvfrom` in a loop until `EAGAIN`. Each call returns one whole datagram (UDP framing).
- Treat the datagram payload as ASCII. Trim trailing whitespace including any `\n` (be lenient — accept `START`, `START\n`, `start`, etc. via case-insensitive compare).
- Recognized payloads:
  - `START` → print `[ipc] target start`
  - `STOP` → print `[ipc] watchdog stopping`
  - `CRASH` → print `[ipc] target CRASH`, then call `crash_log.dump()`. The dump prints its own line summarizing where artifacts were written, then resets the ring buffer.
  - anything else → print `[ipc] unknown: <bytes-escaped>`
- `EAGAIN` is the normal exit condition for the drain loop.
- No connection state to manage: if the watchdog dies and restarts, datagrams just resume arriving.

### 5.7 Stats (`src/fuzzer/stats.zig`)

Just a `u64 runs` counter and the per-100 print rule. No histograms, no persistence.

### 5.8 Crash log (`src/fuzzer/crash_log.zig`)

Holds the most recent fuzzed messages so they can be persisted when the watchdog reports a crash. Sized for ≥ the worst-case skew between sending a SIP datagram and the watchdog noticing the target's death.

Constants:

- `CAPACITY = 25` — ring buffer size.
- `ENTRY_BUF_SIZE = 64 * 1024` — same as the assembly buffer; nothing larger can be sent.

Skeleton:

```zig
const std = @import("std");

pub const CAPACITY: usize = 25;
pub const ENTRY_BUF_SIZE: usize = 64 * 1024;

const Entry = struct {
    buf: [ENTRY_BUF_SIZE]u8,
    len: usize,
    run: u64,
    template_name: []const u8, // borrowed from Template; lives as long as corpus
};

pub const CrashLog = struct {
    entries: [CAPACITY]Entry,
    head: usize = 0,    // next slot to write
    count: usize = 0,   // valid entries, capped at CAPACITY
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

    /// Write all valid entries (oldest → newest) into a fresh subdirectory of
    /// crash_dir, then reset the ring buffer.
    pub fn dump(self: *CrashLog) !void {
        if (self.count == 0) return;

        const ts_ms = std.time.milliTimestamp();
        var subdir_buf: [64]u8 = undefined;
        const subdir = try std.fmt.bufPrint(&subdir_buf, "crash_{d}", .{ts_ms});

        var crashes = try std.fs.cwd().makeOpenPath(self.crash_dir, .{});
        defer crashes.close();
        try crashes.makePath(subdir);
        var dir = try crashes.openDir(subdir, .{});
        defer dir.close();

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
            var f = try dir.createFile(fname, .{});
            defer f.close();
            try f.writeAll(e.buf[0..e.len]);
        }

        std.debug.print("[crash] dumped {d} cases to {s}/{s}\n", .{
            self.count, self.crash_dir, subdir,
        });

        self.head = 0;
        self.count = 0;
    }
};
```

Behavior notes:

- The ring buffer is reset after each dump. If a second crash happens before the buffer refills, fewer than 25 cases are written — which is exactly right: those are the only cases sent since the last incident.
- Files are written oldest → newest with a 2-digit zero-padded prefix so lexicographic listing matches send order. The most-recent file (last numeric prefix) is the most likely culprit.
- `template_name` does not include the `.sip` extension; it's appended in the output filename.

## 6. Watchdog Component

### 6.1 CLI (`src/watchdog_main.zig`)

```
watchdog --pid <PID> --restart-script <PATH> --fuzzer-ip <IP> [--fuzzer-port <PORT>] [--poll-ms <N>]
```

| Flag | Default | Description |
|------|---------|-------------|
| `--pid` | (required) | Initial PID of the target process. Used to capture the comm name. |
| `--restart-script` | (required) | Shell script invoked on crash. Must return 0 once the target is back up. |
| `--fuzzer-ip` | (required) | IPv4 address of the host running the fuzzer. |
| `--fuzzer-port` | `9999` | UDP port the fuzzer is listening on (must match the fuzzer's `--ipc-port`). |
| `--poll-ms` | `100` | Process-existence poll interval. |

### 6.2 Startup

1. Parse args.
2. Open `/proc/<pid>/comm`; read and trim trailing `\n`. Store as `target_comm` (max 16 bytes per kernel limit, but allocate 64 to be safe).
3. Install SIGINT handler (§6.5).
4. Create UDP socket (`AF_INET`, `SOCK_DGRAM`). Pre-build `sockaddr_in` for the fuzzer's IP/port. Do not `connect()` — just `sendto` per message.
5. Send `START` (the target was already running at startup by the user's contract). UDP send is non-blocking and best-effort; if the fuzzer isn't up yet the datagram is dropped silently — that is fine, the next state change will produce another datagram.
6. Enter main loop.

### 6.3 Main loop (`src/watchdog/monitor.zig`)

```
loop while running:
    sleep(poll_ms)
    if not exactly_one_process_named(target_comm):
        send "CRASH"
        rc = run_restart_script()
        if rc != 0: log error; continue   # try again next tick
        send "START"
        # no need to re-resolve PID — we match by comm name
```

### 6.4 Process detection (`src/watchdog/monitor.zig`)

- Iterate `/proc/*/comm` for entries whose parent dir name is all-digit.
- Read each `comm`, trim, compare to `target_comm`.
- Count matches. Exactly one ⇒ alive. Zero ⇒ crashed. More than one ⇒ treat as alive (log a warning once); the user's design says "one unique instance" but multiple matches at worst means something else with the same name — not a crash signal.
- Use `std.fs.openDirAbsolute("/proc", .{ .iterate = true })`.

### 6.5 Signals (`src/watchdog/signals.zig`)

- Use `std.posix.sigaction` to install a SIGINT handler.
- Handler sets a `volatile bool running = false` flag (use `std.atomic.Value(bool)` to be correct).
- Main loop checks the flag every iteration.
- On exit (whether SIGINT or fatal error), send `STOP` and close the UDP socket.

### 6.6 Restart runner (`src/watchdog/runner.zig`)

- Use `std.process.Child.init(&.{ "/bin/sh", "-c", script_path }, allocator)`.
- `inherit` stdout/stderr so the user sees script output mixed in.
- Wait for completion; return exit code.

## 7. IPC Protocol

### 7.1 Transport

- **UDP**, IPv4. Watchdog → fuzzer only. One datagram per status message.
- Fuzzer binds `0.0.0.0:<ipc-port>` (default `9999`). Watchdog targets `<fuzzer-ip>:<fuzzer-port>`.
- The IPC port is independent of the SIP target port — pick anything not 5060. Ensure firewalls between device and host allow UDP on this port.
- Best-effort: dropped datagrams are tolerable. The watchdog's state machine is monotonic — every transition produces a datagram, so even if one is lost the operator just won't see that single transition logged. No retransmit, no acks.

### 7.2 Wire format

- ASCII payload, no framing, no length prefix, no version byte. Datagram boundary == message boundary.
- Three message payloads only: `START`, `STOP`, `CRASH`.
- A trailing `\n` is permitted but not required. Fuzzer parses leniently (trim whitespace, case-insensitive compare).
- If we ever add fields, we add a new message name — never extend an existing one.

### 7.3 Lifecycle

- Fuzzer binds and starts polling the IPC socket at startup. No connection to establish — UDP is stateless.
- Watchdog creates its UDP socket, sends `START` once it has the target's comm name, then sends `CRASH`/`START` pairs around restarts, and `STOP` on shutdown.
- If the watchdog dies, the fuzzer keeps fuzzing; when the watchdog comes back, datagrams resume. Nothing in the fuzzer needs reconnect logic.
- Startup ordering does not matter. If the watchdog sends `START` before the fuzzer is up, the datagram is silently dropped — the next state transition will report current state.

## 8. End-to-End Verification

This is the smoke test that the MVP is "done."

1. **Build both:**
   ```
   git submodule update --init --recursive
   zig build
   ```
   Result: `zig-out/bin/fuzzer` (x86_64) and `zig-out/bin/watchdog` (native).

2. **Cross-build watchdog for the device:**
   ```
   zig build watchdog -Dtarget=arm-linux-gnueabihf -Doptimize=ReleaseSafe
   ```
   Copy `zig-out/bin/watchdog` to the device. Place restart script next to it.

3. **Loopback smoke test on a single Linux host:**
   - Run a dummy SIP target — `socat UDP-RECVFROM:5060,fork - | head -c 4096` is enough to confirm packets land.
   - In one terminal: `./zig-out/bin/fuzzer --target-ip 127.0.0.1 --corpus ./corpus`
   - Confirm the periodic `[runs=100]` output appears.
   - Confirm `socat` shows incoming SIP-shaped traffic that varies between iterations.

4. **Watchdog round-trip (loopback):**
   - Start a sleeper as the "target": `sleep 3600 & echo $!` — note the PID.
   - Create a restart script `restart.sh`:
     ```
     #!/bin/sh
     sleep 3600 &
     sleep 0.5
     ```
   - Run: `./zig-out/bin/watchdog --pid <PID> --restart-script ./restart.sh --fuzzer-ip 127.0.0.1`
   - In the fuzzer terminal you should see `[ipc] target start`.
   - `kill <PID>` → fuzzer prints `[ipc] target CRASH` then `[ipc] target start`.
   - `Ctrl-C` the watchdog → fuzzer prints `[ipc] watchdog stopping`.

   **On real hardware:** run the fuzzer on the host (e.g. `192.168.55.160`) and the watchdog on the device (e.g. `192.168.55.100`) with `--fuzzer-ip 192.168.55.160`. Make sure UDP on port 9999 is not blocked between the two.

5. **Corpus parsing sanity:**
   - Add a `bad.sip` containing `{{FUZZ}}no-close` → fuzzer must exit at startup with `UnterminatedFuzzMarker`. Remove and re-run.

6. **`cancel.sip` enforcement:**
   - Move `cancel.sip` aside → fuzzer exits with a clear error. Restore.

7. **Crash dump test:**
   - With the loopback setup from steps 3 & 4 running, `kill <PID>` and confirm:
     - Fuzzer prints `[ipc] target CRASH`
     - Fuzzer prints `[crash] dumped 25 cases to ./crashes/crash_<ms>`
     - The directory contains 25 files named `00_run<R>_<template>.sip` … `24_run<R>_<template>.sip`, lexicographically ordered oldest → newest
     - Files contain fuzzed-looking SIP bytes (`head -c 200 ./crashes/crash_*/24_*.sip`)
   - After the dump, restart the target via the watchdog's restart script and trigger a second crash; confirm a fresh `crash_<ms>` subdir is created and that it contains only the cases sent *since* the previous crash (no carry-over).

If 1–7 all pass, the MVP is complete.

## 9. Out of Scope (deliberately)

The following are intentionally **not** part of MVP and must not be added in this pass:

- TCP / TLS / WebSocket SIP transports
- Coverage-guided mutation
- Crash de-duplication / minimization
- Multi-target / multi-threaded sending
- Configurable mutation strategies per FUZZ region
- Persisting interesting inputs
- A library/SDK form of the fuzzer
- Windows or macOS support for either component
- Any IPC payloads beyond `START`/`STOP`/`CRASH`
- Reading from stdin or hot-reloading the corpus
