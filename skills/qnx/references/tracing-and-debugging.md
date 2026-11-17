# Tracing, logging and debugging on QNX 8.0

## Kernel tracing (tracelogger + System Profiler)
Every 8.0 kernel is instrumented, so tracing is always available. Tracing captures kernel calls, interrupts, scheduling (thread state changes), IPC (send/receive/reply, pulses), process/thread events, and your own user events — with timestamps. It's how you **prove** latency and deadline claims.

`tracelogger` (target, **must run as root**, only one instance; don't combine with IDE/qconn tracing):
```sh
tracelogger -s 3 -w -f /dev/shmem/run.kev      # 3 seconds, wide events
tracelogger -n 12 -w -f /dev/shmem/t.kev       # 12 buffers then stop
tracelogger -r -b 5                            # ring mode: write on SIGINT / _NTO_TRACE_STOP
tracelogger -d1 -c -E -w -F2                   # daemon, continuous, filter out interrupts
tracelogger -s1 -A MACHINE_NAME=pi4 -A RUN=baseline   # tag the log
```
Options: `-s secs` (time mode), `-n N` (iterations, default 32; 0 = unlimited), `-c` continuous, `-r` ring, `-d1` daemon (app controls via `TraceEvent()`; add `-E` to enable events), `-w` wide events (more detail), `-f file` (default `/dev/shmem/tracebuffer.kev`; `-` = stdout; a FIFO streams), `-M -S size` shared-memory output, `-F n` class filter (1 kernel calls, 2 interrupts, 3 process, 4 thread, 6 communication, 7 system), `-a` security events, `-b N` dynamic buffers, `-k N` kernel buffers per CPU (default 8 × ~16 KB), `-D secs` periodic flush, `-P`/`-R` persist/reuse buffers, `-A name=value` attributes.

Getting the trace to the host: `scp root@qnxpi.local:/dev/shmem/run.kev .` (or a VS Code launch config with a `download` file operation). Open it in the **System Profiler** (QNX Toolkit for VS Code 1.1 has it built in: timeline, IPC timeline between threads, CPU usage, CSV export; very large .kev files ≥1.4 GB can crash VS Code — filter first). `traceprinter` prints a .kev as text on target/host.

User events from your code (mark loop start/end, deadlines):
```c
#include <sys/trace.h>
TraceEvent(_NTO_TRACE_INSERTUSRSTREVENT, 100, "adcs:tick");   /* string event, user code 100 */
TraceEvent(_NTO_TRACE_INSERTSUSEREVENT, 101, value1, value2); /* simple user event */
```
Only `PROCMGR_AID_TRACE` is needed. In 8.0 event tracing is per-CPU: an app driving tracing itself must call `TraceEvent(_NTO_TRACE_WAITBUFFER)` from a thread bound to each CPU to collect everything.

**Measuring worst-case latency honestly:** run the same scenario for long enough (minutes, not seconds), with and without the stressor; report max and p99.9 from the trace (not averages); state the trace configuration; repeat a few times.

## Logging (slogger2)
- Write: `#include <sys/slog2.h>`, register a buffer set with `slog2_register()`, log with `slog2f(handle, code, SLOG2_INFO, "fmt", ...)`; link `-lslog2`. Fast, lock-free, survives app crashes.
- Read: `slog2info` (needs `slogger2` running). `-w` follow, `-W` new only, `-b name` filter buffer set, `-s 0-7`/`-S SLOG2_WARNING` severity, `-t tid`, `-f` epoch timestamps, `-c` clear, `-l file` (in `/dev/shmem/slogger2/`), `-a` colour, `-r` logs through last reset.
- `syslogd` is gone in 8.0.

## Process/thread inspection
- `pidin` (default columns pid, tid, name, priority+policy, state, blocked-on). Shorthands: `threads`, `channels`, `fds`, `mem`/`memory`, `mapinfo`, `sched`, `rmasks`, `abilities`, `rlimits`, `timers`, `irqs`, `signals`, `syspage`, `info`, `libs`, `env`, `arguments`, `times`, `backtrace`, `family`, `session`, `users`. `-p name|pid` one process, `-P pid` family, `-l -d 10` loop every 1 s, `-F "%a %b %N %p %J %B"` custom format.
  - States worth knowing: `RECEIVE` (server idle), `SEND`/`REPLY` (client waiting on server — "Blocked" column shows which pid), `MUTEX`, `CONDVAR`, `SEM`, `NANOSLEEP`, `READY`, `RUNNING`, `INTR` (IST waiting), `DEAD` (zombie).
- `hogs` — CPU usage per process; `top` *(availability on target image — check)*.
- `showmem` / `pidin mem` — memory.
- `use <utility>` — usage message (built-in docs on target).

## Debugging
- **VS Code (QNX Toolkit)**: launch/attach configs of type `qnx-gdb` in `.vscode/launch.json`; supports launch with/without debugger and "Attach Debugger to QNX Process". Not supported: post-mortem core debugging in the UI (use gdb console), watchpoints, follow-fork, detach. See `vscode-toolkit.md`.
- **Command line**: the SDP ships cross gdb for each target (`ntoaarch64-gdb` for the Pi) talking to a target-side agent (`pdebug` over TCP/serial, or `qconn` which the QSTI/mkqnximage images run) *(exact 8.0 workflow unverified — prefer the VS Code toolkit, which handles it)*.
- **Core files**: the `dumper` utility writes core files for crashing processes (check whether it's running on your image: `pidin | grep dumper`); load them in gdb with the matching binary.
- **Memory errors**: `libmalloc` debug variants / QNX Memory Analysis (no results UI in VS Code yet), Valgrind (via VS Code extensions), `-fsanitize=address` *(availability per target — verify)*.
- **Typical hangs**: a client in `REPLY` forever → server never replied (or crashed after receive without `_NTO_CHF_UNBLOCK` handling); a server in `SEND` → two servers sending to each other (deadlock — design send hierarchy so messages only flow "down"). `pidin` blocked-on column tells you who.
