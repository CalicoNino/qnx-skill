# QNX OS 8.0 architecture

## Contents
1. Microkernel and process manager
2. Pathname space and resource managers
3. Interprocess communication (overview)
4. Priority inheritance and server boost
5. Scheduling
6. Multicore: runmasks and clusters
7. Interrupts
8. Time and timers
9. Memory and device access
10. Synchronization
11. Signals and process lifecycle
12. Boot: IFS and startup

---

## 1. Microkernel and process manager
- The kernel binary is **`procnto-smp-instr`** (SMP, instrumented — only instrumented builds ship in 8.0, so kernel tracing is always available). It combines the **microkernel** (threads, scheduling, IPC, signals, timers, interrupt dispatch, synchronization) and the **process manager** (process creation/`posix_spawn`, memory management, pathname space, abilities). Check with `uname -a` / `uname -ak`.
- Everything else is a user process: filesystems (`devb-*` + `fs-*.so`), network (`io-sock`), serial (`devc-*`), USB (`io-usb-otg`), GPIO (`io-gpio`), I2C/SPI drivers, `slogger2`, `pci-server`, etc.
- There are **no loadable kernel modules**. "Writing a driver" means writing a user process (usually a resource manager) that gets I/O privileges and maps device memory.
- 8.0 kernel facts (from the migration guide): the kernel is superlocked by default; lazy stack allocation is disabled (`procnto -n` ignored); `procnto` runs tickless; timers are per-core hardware timers; event tracing is per CPU; new uncatchable `SIGDOOM` signal when a process lacks stack/memory to handle a signal/event.
- Useful `procnto` options (set in the boot image buildfile): `-P priority` (top of unprivileged range = priority−1; default 64 → unprivileged max 63), `-C tick_hz[,clock_IST_prio]` (default 1 kHz, IST prio 254), `-qt` (enable **pathtrust**), `-m r`/`~r` (ASLR on by default), `-m X` (deny exec-mmap of non-exec files), `-F n` (max fds per process, default 1000), `-T secs` (close timeout on termination, default 30), `-iu`/`-i~u` (unexpected interrupt → ignore / design-safe state). Env: `PROC_THREAD_POOL=low,high,max`.

## 2. Pathname space and resource managers
- The process manager owns a **pathname space**. A resource manager calls `resmgr_attach()` (needs `PROCMGR_AID_PATHSPACE`) to own a prefix such as `/dev/imu` or `/fs/sd`.
- When a client calls `open("/dev/imu/...")`, libc asks the process manager who owns the longest matching prefix, connects to that server's channel, and sends an `_IO_CONNECT` message; subsequent `read`/`write`/`devctl`/`close` become `_IO_READ`/`_IO_WRITE`/`_IO_DEVCTL`/`_IO_CLOSE` messages on that connection.
- Multiple managers can overlay the same prefix (union mounts); the longest/most-recent match wins.
- `name_attach()` (still supported in 8.0) registers a simple service name under `/dev/name/local/<name>`; clients use `name_open()`. `NAME_FLAG_ATTACH_GLOBAL`/`gns` relied on Qnet-era networking — treat global names as unavailable in 8.0 *(unverified; name_attach page no longer mentions it)*.

## 3. Interprocess communication (overview)
Native IPC is **synchronous message passing** implemented in the kernel:
- A server creates a **channel** (`ChannelCreate()` or via `dispatch_create()`/`name_attach()`); clients create a **connection** to it (`ConnectAttach()`, `name_open()`, or implicitly via `open()`).
- `MsgSend()` (client) blocks: **SEND-blocked** until the server receives, then **REPLY-blocked** until it replies. `MsgReceive()` (server) blocks **RECEIVE-blocked** until a message/pulse arrives. `MsgReply()`/`MsgError()` unblock the client. Data is copied directly between address spaces (no shared buffers to corrupt). IOV variants (`MsgSendv`, `MsgReplyv`) avoid extra copies.
- **Pulses**: tiny non-blocking messages (8-bit code + 32/64-bit value) — `MsgSendPulse()`. Used for notifications, timers, interrupts, kernel events (disconnect, unblock, thread death).
- **Events** (`struct sigevent`): a client gives a server a pre-built event (pulse/signal/thread) that the server later delivers with `MsgDeliverEvent()` — the standard way to do asynchronous notification without the server blocking on the client. **8.0 does not support unregistered events** (`_NTO_COF_UNREGEVENTS`, `procnto -U` gone): clients register events first with `MsgRegisterEvent()` *(verify exact usage on the MsgRegisterEvent page)*.
- Other IPC: POSIX signals (kernel), POSIX message queues (now in the kernel; `libmq` gone), shared memory (`shm_open`/`mmap`, process manager), pipes/FIFOs (`pipe` process), sockets (io-sock).
- Message size: small-message kernel buffer is 1200 bytes (5296 with `procnto -x`) — larger messages still work, they're just copied differently.

Code patterns: `references/ipc-and-resource-managers.md`.

## 4. Priority inheritance and server boost
- **Message-driven priority inheritance**: a server thread that receives a message runs at the **sender's priority**; pulses carry a priority too. Requests are received in priority order. If a higher-priority client becomes SEND-blocked while the server is busy, the server is boosted **at send time**, so a low-priority client can't hold up a high-priority one (classic priority-inversion fix, applied to IPC — e.g. a shared driver serving a control loop and a logger).
- Limit: if the client's priority is above the unprivileged range and the server lacks `PROCMGR_AID_PRIORITY`, the boost is capped at the unprivileged max (63 by default).
- The boosted priority **does not revert at reply**; it changes when the next message/pulse is received (higher or lower), or by explicit `pthread_setschedparam()`/`pthread_setschedprio()`.
- **Disable** per channel with `_NTO_CHF_FIXED_PRIORITY` (`ChannelCreate()` flag 0x0001; with the resmgr framework pass it through `dispatch_create_channel()`), e.g. for sporadic-scheduled servers or for an A/B demonstration.
- **Server boost**: if no server thread is RECEIVE-blocked when a client sends, the kernel boosts a server thread associated with the channel (the docs are inconsistent on "one thread" vs "all threads that received before"). Keep at least one thread RECEIVE-blocked in multithreaded servers.
- Note (8.0.3): **io-sock threads no longer inherit client priority**. Demonstrate inheritance on your own resource managers, not through the network stack.
- Mutexes support `PTHREAD_PRIO_INHERIT` (default in QNX) and `PTHREAD_PRIO_PROTECT` (ceiling).

## 5. Scheduling
- Priorities **0–255**: 0 = idle thread; **255 reserved for inter-processor interrupts**; **254 reserved by default for the clock IST** (configurable via `procnto -C`). Unprivileged processes can use 1–63 by default (`procnto -P`); higher needs `PROCMGR_AID_PRIORITY`. In practice use ≤253.
- Policies (per thread): **SCHED_FIFO** (run until block/preempt), **SCHED_RR** (FIFO with timeslice among equals), **SCHED_SPORADIC**, **SCHED_OTHER** (currently RR-like). `pidin` shows them as `f`, `r`, `s`, `o` after the priority.
- **Sporadic scheduling** (the 8.0 way to bound a thread's CPU use, since APS is gone): parameters *initial budget C* (`sched_ss_init_budget`), *replenishment period T* (`sched_ss_repl_period`), *normal priority N* (`sched_priority`), *low priority L* (`sched_ss_low_priority`), *max replenishments* (`sched_ss_max_repl`; QNX allows at most one pending replenishment). When the budget is exhausted the thread drops to L — **it is not a hard cap**: it still runs at L when the CPU is otherwise idle or nothing above L is ready. If anything above L is always ready, the thread gets ≤ C/T of a CPU. Blocking erodes the budget. Set with `pthread_attr_setschedpolicy/param` or `pthread_setschedparam()`. Pair with `_NTO_CHF_FIXED_PRIORITY` on servers it talks to.
- To genuinely contain a misbehaving process in 8.0: sporadic budgets **plus** `RLIMIT_NTHR` (cap thread count) **plus** denying `PROCMGR_AID_PRIORITY`/`SPAWN` abilities **plus** watching per-thread CPU-time clocks (`pthread_getcpuclockid()`/`clock_gettime()`) and stopping offenders (e.g. via QPLMS), **plus** runmask isolation of critical threads.
- Utilities: `on -p prio[policy] cmd`, `slay -P prio`, `renice`; programmatically `pthread_setschedparam()`, `SchedSet()`.

## 6. Multicore: runmasks and clusters
- A **runmask** restricts which CPUs a thread may run on (`ThreadCtl(_NTO_TCTL_RUNMASK_GET_AND_SET_INHERIT, …)`, `pthread_spawnattr_setrunmask_np()`; `posix_spawnattr_setrunmask()` is deprecated). `pidin rmasks` shows them.
- **8.0: runmasks must correspond to a cluster.** Predefined clusters: one with all CPUs and one per CPU. Define more with the startup program's `-c` option. Runmask updates apply only to the calling (active) thread.
- `_NTO_CHF_INHERIT_RUNMASK`: a receiving server thread adopts the sender's runmask.
- Pattern for determinism: pin the control loop to a dedicated core, keep ML/logging/network on other cores.

## 7. Interrupts
- **8.0 removed ISRs** (`InterruptAttach()`, `InterruptAttachArray()`). Use **interrupt service threads (ISTs)**: `InterruptAttachThread()` (new in 8.0) then loop on `InterruptWait()`, or `InterruptAttachEvent()` to get a pulse/event per interrupt. `SIGEV_INTR` is deprecated.
- Needs only `PROCMGR_AID_INTERRUPT` (the old `INTERRUPTEVENT` ability is gone). Unmask after servicing (`InterruptUnmask()`), and keep the IST at a suitably high priority.
- Exact flags for `InterruptAttachThread()`/`InterruptWait()`: fetch `.../lib_ref/topic/i/interruptattachthread.html` before writing code *(unverified here)*.

## 8. Time and timers
- Tickless; `CLOCK_MONOTONIC`/`CLOCK_REALTIME` resolve to hardware granularity. New fast calls: `clock_gettime_ns()`, `clock_gettime_mon_ns()`, `clock_gettime_rt_ns()`.
- Periodic work: `timer_create()` with a `SIGEV_PULSE` event targeting your own channel, `timer_settime()`; receive the pulse in your `MsgReceive` loop. High-resolution timers (`PROCMGR_AID_HIGH_RESOLUTION_TIMER`) take precedence. Timer tolerance (`pidin tolerance`) can coalesce wakeups.
- `nap()`/`napms()` are gone → `delay()`/`nanosleep()`.
- Runtime `ClockPeriod()` changes are unsupported; use `procnto -C` at boot.

## 9. Memory and device access
- Full MMU protection per process; stacks and heap are non-executable by default; ASLR on by default (PIE is the default for qcc).
- Device registers: `mmap_device_memory()` / `mmap_device_io()` (need `PROCMGR_AID_MEM_PHYS` / `PROCMGR_AID_IO`). `/dev/mem` is discontinued.
- Shared memory: `shm_open()` + `ftruncate()` + `mmap()`; typed memory (`posix_typed_mem_open()`) for physically constrained regions (e.g. DMA below 1 GB on the Pi — the BSP drivers use `mem name=below1G`).
- `RLIMIT_AS`, `RLIMIT_DATA`, etc. via `prlimit()`/`setrlimit()`.

## 10. Synchronization
- POSIX mutexes (priority inheritance by default), condvars, semaphores, rwlocks, barriers, spinlocks; atomics.
- **8.0: primitives are not process-shared by default** — set `PTHREAD_PROCESS_SHARED` and place them in shared memory if two processes use them.
- `pthread_sleepon_*` and `_sleepon_*` are discontinued → condvars + mutexes. `pthread_rwlockattr_setclock()` replaced by `pthread_rwlock_clockrdlock()/clockwrlock()`.

## 11. Signals and process lifecycle
- POSIX signals; QNX extends them with signal-to-thread and message-unblocking semantics (a signal can unblock a SEND/REPLY-blocked client; the server sees `_PULSE_CODE_UNBLOCK` if it created the channel with `_NTO_CHF_UNBLOCK`).
- `sigblock()`/`sigsetmask()` etc. are gone → `sigprocmask()`.
- Process creation: `posix_spawn()` (preferred), `spawn*()`, `fork()`+`exec*()`.
- Supervision: **QPLMS** (`references/qplms.md`). Death notification: `_NTO_CHF_DISCONNECT`/`_NTO_CHF_COID_DISCONNECT` pulses, `procmgr_event_notify()`.

## 12. Boot: IFS and startup
- Boot loader (on the Pi: GPU firmware → `config.txt` → QNX IFS) loads the **image filesystem (IFS)**, built on the host by `mkifs` from a **buildfile**. The IFS contains the startup program (`startup-bcm2711-rpi4 ...`), `procnto-smp-instr` with its options, and a boot script that launches drivers in order.
- Boot time is dominated on the Pi by GPU firmware (seconds, outside QNX's control). What QNX controls: IFS size/compression and the **order** in which the boot script starts drivers — start safety-critical managers first. Measure from kernel start (tracelogger / `slog2info` timestamps), and say so.
- The primary IFS is implicitly trusted (pathtrust); its integrity comes from secure boot, which depends on SoC support.
