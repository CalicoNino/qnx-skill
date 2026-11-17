---
name: qnx
description: Expert, version-accurate knowledge of QNX OS 8.0 (QNX SDP 8.0 / QNX Neutrino microkernel) — architecture, message passing, resource managers, scheduling, security (secpol, abilities, pathtrust, QTD), QPLMS, tracing/System Profiler, the qcc toolchain, the QNX Toolkit for VS Code, QNX Software Center, and running QNX on a Raspberry Pi 4/5 (QNX Everywhere quick start image). Use this skill whenever the user mentions QNX, Neutrino, procnto, QNX Everywhere, QSTI/CTI images, qcc/q++, Momentics, the QNX VS Code extension, resource managers, MsgSend/MsgReceive/pulses, io-sock, slog2, pidin, tracelogger, secpol, pathtrust, QPLMS/HAM, mkifs/mkqnximage, or is writing, porting, building, debugging or designing software for a QNX target — even if they only say "my Pi running QNX" or "the hackathon board". Also use it before making any claim about what QNX can or can't do versus Linux.
---

# QNX OS 8.0 expert

This skill makes you a careful QNX 8.0 engineer. Most QNX material online (forums, books, Stack Overflow, older docs, even your own training data) describes QNX 6.x/7.x. **QNX 8.0 removed or replaced many of those features**, so a confident answer from memory is often wrong. The single most valuable habit this skill teaches: *check the 8.0 change list before recommending any API, utility or feature, and fetch the official 8.0 doc page when in doubt.*

## The mental model (read this first)

QNX is a **microkernel** OS. The kernel (`procnto-smp-instr`, which also contains the process manager) does only: threads, scheduling, message passing, signals, timers, interrupt dispatch, memory management, and the pathname space. **Everything else is an ordinary user process** — device drivers, filesystems, the network stack (`io-sock`), even `/dev/null`-style devices. These processes are called **resource managers**: they register a pathname (e.g. `/dev/imu`) and service POSIX calls (`open`, `read`, `write`, `devctl`) that the C library turns into **synchronous messages** (`MsgSend` → `MsgReceive` → `MsgReply`).

Consequences that drive almost every QNX design decision:
- A crashed driver is a crashed process: it can be restarted (by QPLMS) without rebooting, and it can't corrupt the kernel or other drivers (MMU isolation).
- IPC is **synchronous, copying, and priority-aware**: a server inherits the priority of the client it is serving (priority inheritance through messages). This is what makes client/server designs real-time safe.
- "Talking to a device" and "talking to a service" are the same thing: open a path, send messages.
- Hard real-time comes from priority-based preemptive scheduling (FIFO/RR/sporadic, priorities 0–255) plus a small, fully preemptible kernel.

Details: `references/architecture.md`.

## QNX 8.0 traps — check these before answering

| If you're about to suggest… | In 8.0 it is… | Use instead |
|---|---|---|
| Adaptive Partitioning (APS) | **Discontinued** | SCHED_SPORADIC + runmasks/clusters + per-thread CPU-time clocks + rlimits |
| Qnet / `/net/node/...` | **Discontinued** (was in io-pkt) | Your own protocol over io-sock (UDP/TCP, DDS, MQTT) |
| io-pkt, `lsm-*`, `nicinfo` | **Discontinued** | `io-sock` (FreeBSD-derived) with `devs-*.so` / `mods-*` |
| HAM / Guardian | **Deprecated** | **QPLMS** (`plms`, `libplms`) |
| PPS / PiPS | **Discontinued** | MQTT, RabbitMQ, FastDDS |
| `InterruptAttach()` (ISRs) | **Removed** | `InterruptAttachThread()` / `InterruptAttachEvent()` + `InterruptWait()` (ISTs) |
| `/dev/mem` | **Discontinued** | `mmap_device_memory()` (needs abilities) |
| `syslogd` | **Discontinued** | `slogger2` / `slog2info` |
| minidrivers / IDA, `mdriver` | **Discontinued** | Fast-boot via IFS ordering |
| `secpol -p` | **Discontinued** | `secpolpush` |
| Sandboxing | **Discontinued** | Security policies + abilities + POSIX perms/ACLs |
| `ClockPeriod()` at runtime | **Unsupported** | `procnto -C` at boot |
| Priority 255 / 254 for your threads | **Reserved** (IPI / clock IST) | ≤253; unprivileged max is 63 by default |
| Process-shared mutex by default | **Not shared by default** | `PTHREAD_PROCESS_SHARED` + shared memory |
| 7.1 binaries | **Won't run** | Rebuild for 8.0 |
| x86 32-bit target | **Unsupported** | x86_64 or aarch64le |
| `__QNXNTO__` | Deprecated | `__QNX__` |

Full list with every API: `references/qnx8-changes.md`. When something isn't in either table and you aren't sure it survived into 8.0, say so and look it up.

## Where to go next (load only what the task needs)

| Task | Read |
|---|---|
| Explain how QNX works, design a system, scheduling, interrupts, memory, timers | `references/architecture.md` |
| Write a server/client, pulses, events, a resource manager, devctl, name_attach | `references/ipc-and-resource-managers.md` |
| Anything about secpol, abilities, pathtrust, QTD/mkqfs, ASLR, rlimits | `references/security.md` |
| Launching/monitoring/restarting processes, safe states | `references/qplms.md` |
| tracelogger, System Profiler, pidin, slog2info, gdb, crash analysis | `references/tracing-and-debugging.md` |
| Install SDP, qcc/q++, CMake/make, cross-compile, deploy, ports (OpenCV, TFLite), mkifs, mkqnximage | `references/toolchain-and-build.md` |
| QNX Toolkit for VS Code (build/run/debug/profile from VS Code) | `references/vscode-toolkit.md` |
| Raspberry Pi 4/5: flash QSTI, Wi-Fi, SSH, users, serial console, BSP drivers | `references/rpi-setup.md` |
| "QNX vs Linux" claims, demo design for judges, what's genuinely unique | `references/linux-comparison.md` |

## Helper scripts

- `scripts/check-host.sh` — verifies the host SDP install (env script sourced, `qcc` present, aarch64 target available, license OK) and optionally that a target is reachable over SSH. Run it first whenever a build or setup problem appears.
- `scripts/deploy-run.sh <file.c|file.cpp|binary> [user@host] [-- args]` — cross-compiles for aarch64le (if given source), copies to the target and runs it. Defaults to `qnxuser@qnxpi.local`.

## Working rules

1. **Version first.** Assume QNX SDP 8.0 (the version in QNX Everywhere and the QNX hackathon) unless the user says otherwise. If they use 7.1 or older, say which parts of your answer change.
2. **Verify, don't recall.** For any API flag, utility option or config key you aren't certain about, fetch the 8.0 page. URL patterns that work:
   - Library: `https://qnx.com/developers/docs/8.0/com.qnx.doc.neutrino.lib_ref/topic/<first-letter>/<function_lowercase>.html` (e.g. `.../topic/c/channelcreate.html`)
   - Utilities: `https://qnx.com/developers/docs/8.0/com.qnx.doc.neutrino.utilities/topic/<letter>/<utility>.html`
   - System Architecture: `.../8.0/com.qnx.doc.neutrino.sys_arch/topic/<page>.html`
   - Discontinued features: `https://www.qnx.com/developers/docs/relnotes8.0/com.qnx.doc.discontinuation_notice/topic/{general,kernel,networking,security}.html`
   - Pi images: `https://www.qnx.com/developers/docs/qnxeverywhere/com.qnx.doc.target_images/topic/qsti/...`
   - The old devblog.qnx.com links now redirect to `qnx.software/en/blog/2026/...`.
   On the target itself, `use <utility>` prints a utility's usage message — the fastest ground truth.
3. **Mark uncertainty.** Things marked *(unverified)* in the references weren't confirmed in 8.0 docs; say so when you rely on them, and suggest the one-line check.
4. **Idiomatic QNX over Linux habits.** Prefer resource managers and message passing over ad-hoc sockets/shared-memory between local processes; user-space drivers over "kernel modules" (there are none); `slog2` over printf-to-file; QPLMS over shell `while true` restart loops; abilities + secpol over running everything as root.
5. **Be honest about Linux.** Before claiming "Linux can't do this", check `references/linux-comparison.md`. QNX experts will judge overclaims harshly.
6. **Safety-certified ≠ free license.** QNX OS for Safety (ISO 26262 / IEC 61508 / IEC 62304 certified) is a separate product; the free QNX Everywhere SDP 8.0 is not a certified build. Architecture claims are fine; certification claims are not.

## Quick command reference

Host (Linux, after `source ~/qnx800/qnxsdp-env.sh`):
```bash
qcc -Vgcc_ntoaarch64le -o hello hello.c          # C for Pi (aarch64)
q++ -Vgcc_ntoaarch64le_cxx -o app app.cpp        # C++ (LLVM libc++, default)
qcc -V                                           # list targets
scp hello qnxuser@qnxpi.local:/tmp/ && ssh qnxuser@qnxpi.local /tmp/hello
```
Target (QNX shell):
```sh
use pidin                 # usage of any utility
pidin                     # processes/threads, states, priorities (f=FIFO r=RR s=sporadic o=other)
pidin -p io-sock threads  # threads of one process
pidin channels            # channels per process (pulse-leak hunting)
pidin abilities           # per-process abilities
slog2info -w              # system log, follow
ls /dev/name/local        # name_attach'd services
slay -f <name>            # kill by name
on -p 20 <cmd>            # run with priority 20 (see `use on`)
tracelogger -s 3 -w -f /dev/shmem/t.kev   # 3 s wide kernel trace (root)
uname -a                  # confirm QNX 8.0 / procnto-smp-instr
su                        # become root on the Pi image (default root password: root)
```
