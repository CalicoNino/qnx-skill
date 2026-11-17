# QNX vs Linux — honest comparison (for design and for judges)

QNX experts will mark down overclaims. Use this to pick demos that prove something Linux genuinely can't do, and to state fair comparisons for the rest.

## Genuinely QNX-distinctive (headline material)
| Capability | Why Linux can't trivially copy it | How to show it |
|---|---|---|
| **Drivers, filesystems and the network stack are restartable user processes** | On Linux these run in the kernel: a driver bug is an oops/panic, and you can't fairly kill and restart the in-kernel network stack or SPI driver under a running control loop | `slay` a driver resmgr or `io-sock` mid-operation; QPLMS restarts it; tracelogger shows the control loop missed zero deadlines |
| **Message-driven priority inheritance through IPC servers** | Linux has PI futexes for mutexes, not for request/response servers | A/B: same resmgr with vs without `_NTO_CHF_FIXED_PRIORITY`, high-prio client + low-prio floods; worst-case latency only bounded in A |
| **Uniform resource-manager model** (every device/service is a pathname served by messages, permission- and policy-controlled per path) | FUSE/CUSE approximate it with much more overhead and less integration | Custom device with `open/read/devctl` usable from the shell; secpol rules on its path |
| **Fault containment campaign** (inject faults into a driver: process dies, system lives) | Same injected fault in an in-kernel Linux driver tends to crash or corrupt the kernel — but run the *same* injector on both and report measured outcomes, don't assume | Outcome table (contained / restart / reboot / silent corruption) per OS |
| **Always-on instrumented kernel tracing with message-passing-level events** | ftrace/LTTng exist and are good — the QNX advantage is that it's always present and IPC-aware; present as convenience + insight, not impossibility | Timeline of client→server→reply chains |

## Comparable on Linux (present as idiomatic, not unique)
| QNX | Linux equivalent |
|---|---|
| SCHED_SPORADIC budgets | SCHED_DEADLINE (arguably stronger: real CBS reservation) |
| Runmasks / clusters | CPU affinity, `isolcpus`, cpusets |
| secpol + abilities | SELinux/AppArmor + capabilities + seccomp |
| pathtrust + QTD | IMA appraisal + dm-verity |
| QPLMS restart/dependencies | systemd units (Restart=, Requires=, watchdog) |
| Low latency | PREEMPT_RT (good, but large kernel; drivers still in kernel) |
| rlimits | rlimits + cgroups (cgroups can hard-cap CPU; **QNX 8.0 has no APS**, so it can't) |

## Where Linux is ahead (be upfront)
- Hard CPU partitioning/quotas (cgroups) — QNX 8.0 dropped APS.
- Driver/hardware breadth (cameras, GPUs, NPUs, Wi-Fi chips); ML accelerators (Coral/Hailo) likely lack QNX drivers.
- Ecosystem/package availability (QNX relies on ported libraries — see `github.com/qnx-ports/build-files`).

## Rules for a fair comparison demo
1. Tune the Linux side properly (PREEMPT_RT, SCHED_FIFO, `isolcpus`, cgroups, systemd watchdog, SELinux) and say so.
2. Use the same hardware, workload and fault injector on both.
3. Report max and p99.9 latency and outcome counts from traces, over long runs — not single screenshots.
4. Pick attacks/faults where architecture, not tuning, decides: kernel-resident driver/stack faults, IPC priority inversion.
5. Never claim safety certification for the free SDP (QNX OS for Safety is a separate product).
