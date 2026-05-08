# ulfsaar

A black-box SIP fuzzer written in Zig 0.16.0. Sends mutated SIP messages to a target over UDP, with a companion watchdog process that monitors the target for crashes and signals the fuzzer.

## Components

| Component | Target | Role |
|-----------|--------|------|
| `fuzzer` | Linux x86-64 | Loads SIP corpus, mutates with radamsa, sends to target, logs crashes |
| `watchdog` | Linux (any arch) | Monitors target process, runs restart script on crash, signals fuzzer |

## Requirements

- [Zig 0.16.0](https://ziglang.org/download/)
- `make` and a C toolchain (for building radamsa — Linux/WSL only)

## Building

### First-time setup

Initialize the radamsa submodule:

```sh
git submodule update --init --recursive
```

### Build both components (Linux / WSL)

```sh
zig build
```

Outputs:
- `zig-out/bin/fuzzer` — x86-64 Linux binary
- `zig-out/bin/watchdog` — native binary

### Build individually

```sh
zig build fuzzer
zig build watchdog
```

### Cross-compile watchdog for ARM device

```sh
zig build watchdog -Dtarget=arm-linux-gnueabihf -Doptimize=ReleaseSafe
```

Copy `zig-out/bin/watchdog` to the target device.

> **Note:** The fuzzer must be built on Linux or WSL. The `radamsa` dependency is built via `make` as part of `zig build fuzzer` and requires Linux tooling. The watchdog has no native dependencies and cross-compiles cleanly from any host.

## Usage

### Fuzzer

```
fuzzer --target-ip <IP> [--target-port <PORT>] --corpus <DIR>
       [--ipc-port <PORT>] [--crash-dir <DIR>]

  --target-ip    IPv4 address of SIP target (required)
  --target-port  UDP port of SIP target (default: 5060)
  --corpus       Directory containing .sip corpus files (required)
  --ipc-port     UDP port to receive watchdog signals (default: 9999)
  --crash-dir    Directory for crash artifacts (default: ./crashes)
```

Example:

```sh
./zig-out/bin/fuzzer --target-ip 192.168.1.10 --corpus ./corpus
```

### Watchdog

```
watchdog --pid <PID> --restart-script <PATH> --fuzzer-ip <IP>
         [--fuzzer-port <PORT>] [--poll-ms <N>]

  --pid             PID of the target process at startup (required)
  --restart-script  Shell script that restarts the target (required)
  --fuzzer-ip       IPv4 address of the fuzzer host (required)
  --fuzzer-port     UDP port of fuzzer IPC listener (default: 9999)
  --poll-ms         Process poll interval in milliseconds (default: 100)
```

Example:

```sh
./watchdog --pid 1234 --restart-script ./restart.sh --fuzzer-ip 192.168.1.20
```

The restart script should start the target process and return exit code 0 once it is ready. Example:

```sh
#!/bin/sh
/path/to/target &
sleep 1
```

## Corpus format

Each corpus file is a SIP message with `{{FUZZ}}...{{/FUZZ}}` markers around fields to mutate. Everything outside a marker is sent verbatim.

```
INVITE sip:{{FUZZ}}alice{{/FUZZ}}@192.168.1.10 SIP/2.0
Via: SIP/2.0/UDP 192.168.1.20:5060;branch=z9hG4bK-{{FUZZ}}776asdhds{{/FUZZ}}
...
```

The corpus directory must contain `cancel.sip`, which is sent verbatim after every fuzzed message. All other `.sip` files are loaded as mutation templates and rotated in filename order.

## Crash artifacts

When the watchdog reports a crash, the fuzzer writes the last 25 sent messages to a timestamped subdirectory under `--crash-dir`:

```
crashes/
└── crash_1746000000000/
    ├── 00_run142_invite.sip
    ├── 01_run143_register.sip
    └── ...
```

Files are ordered oldest to newest; the highest-numbered file is the most likely crash trigger.
