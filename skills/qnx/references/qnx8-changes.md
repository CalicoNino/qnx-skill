# What changed in QNX SDP 8.0 (vs 7.1 and older)

Source: QNX 8.0 discontinuation notice (general, kernel, networking, security pages) and migration guide, read Nov 2026. Re-check the live pages for 8.0.x point releases:
`https://www.qnx.com/developers/docs/relnotes8.0/com.qnx.doc.discontinuation_notice/topic/<general|kernel|networking|security>.html`
`https://qnx.com/developers/docs/8.0/com.qnx.doc.qnxsdp.migration/topic/<kernel|networking|migrate_app|migrate_from_io-sock_71>.html`

## General / system
| Feature | Status | Replacement |
|---|---|---|
| Adaptive Partitioning Scheduler (APS) | Discontinued | none (use sporadic scheduling, runmasks, rlimits) |
| High Availability Framework / HAM (incl. Guardian) | Deprecated, to be removed | QPLMS |
| PPS, PiPS | Discontinued | MQTT, RabbitMQ, FastDDS |
| minidrivers / Instant Device Activation, mdriver | Discontinued | — |
| syslogd | Discontinued | slogger2 |
| QDB | Discontinued | SQLite |
| LUA, Perl | Discontinued | Python |
| devf-generic | Discontinued | — |
| PCI legacy interface | Discontinued | PCIe implementation |
| `resmgr_handle_tune()`, `resmgr_handle_grow()` | Discontinued | `dispatch_set_hash_size()` |
| `DISPATCH_FLAG_CHANNEL_COIDDEATH` | Discontinued | — |
| `DCMD_I2C_SET_SLAVE_ADDR`, `DCMD_I2C_MASTER_SEND/RECV` | Discontinued | `DCMD_I2C_SEND`/`DCMD_I2C_RECV` with slave in `i2c_send_t`/`i2c_recv_t` |
| `DCMD_PROC_WAITSTOP` | Discontinued | — |
| `_smalloc()` family | Discontinued | `malloc()` |
| `modem_*()` | Discontinued | — |
| `__QNXNTO__` | Deprecated | `__QNX__` |
| SMMU `-safety` variants | Deprecated | — |

## Kernel / process manager
- **ISRs removed**: `InterruptAttach()`, `InterruptAttachArray()`, `InterruptHookIdle2()`, `InterruptHookTrace()` → `InterruptAttachThread()` (new) or `InterruptAttachEvent()` + `InterruptWait()`. `SIGEV_INTR` deprecated. Only `PROCMGR_AID_INTERRUPT` needed.
- `/dev/mem` discontinued → `mmap_device_memory()`.
- `nap()`, `napms()` → `delay()`. `pthread_sleepon_*`, `_sleepon_*` → condvars + mutexes.
- Discontinued legacy kernel features: mutex events (`SyncMutexEvent()`, `SyncMutexRevive()`), Guardian process, global channels, on-demand paging, lazy FPU switching, persistent threads, idle hook (`PowerSetActive()` etc.), `MsgKeyData()`, `MsgReceivePulsev()`; `MsgPause()` deprecated. Direct `ThreadCreate()` as a pthread substitute is deprecated (and now needs a pre-allocated stack) → `pthread_create()`.
- Abilities removed: `PROCMGR_AID_XTHREAD_THREADCTL`, `CLOCKPERIOD`, `V86`, `KEYDATA`, `INTERRUPTEVENT`.
- `posix_spawnattr_get/setrunmask()` deprecated → `pthread_spawnattr_get/setrunmask_np()`.
- `_RESMGR_ERRNO()` deprecated → return the errno value directly from handlers.
- `sigblock()`, `sigpause()`, `sigsetmask()`, `sigunblock()` → `sigprocmask()`.
- `iofunc_lock_calloc()/free()` discontinued.
- Trace classes `_NTO_TRACE_INT*` and some `__KER_*` trace events discontinued.
- Behavioural changes:
  - All binaries from earlier OS versions must be **rebuilt**.
  - Tickless kernel; per-core timers; `qtime->nsec` obsolete; new `clock_gettime_ns()` family.
  - Runtime `ClockPeriod()` changes unsupported → `procnto -C`.
  - Priority 255 reserved (IPIs); 254 reserved for clock IST by default.
  - Kernel superlocked by default (don't use `procnto -m` superlock options); lazy stack allocation disabled.
  - `procmgr_ability()` calls on locked abilities don't fail by default (`-b~l` restores old behaviour).
  - `rcvid_t` is now 64-bit signed.
  - Runmasks must match a cluster (startup `-c` defines extra clusters).
  - Unregistered events unsupported (`_NTO_COF_UNREGEVENTS`, `procnto -U` gone) → register events (`MsgRegisterEvent()`).
  - Sync primitives not process-shared by default.
  - Event tracing per CPU; `TraceEvent()` needs only the TRACE ability.
  - Message queues are in the kernel; `libmq` gone.
  - New `SIGDOOM` (uncatchable) when stack/memory for a signal/event can't be allocated.
  - x86 32-bit unsupported.

## Networking
- **io-pkt discontinued → io-sock** (FreeBSD-derived). **Qnet discontinued** (it lived in io-pkt).
- Drivers are `devs-*.so`; buses/PHY are modules `mods-phy`, `mods-pci.so`, `mods-usb.so`, `mods-fdt.so`, `mods-phy_fdt.so` loaded with `-m` (e.g. `io-sock -m phy -m fdt -m phy_fdt -d genet`). Old `ignore_*`, `dtb`, `npnp_*` options became defaults/sysctls (`qnx.pnp.*`, `qnx.priority`, `net.isr.maxthreads`, `qnx.iolevel`).
- Link `libsocket.so` (no static io-sock libsocket). Some headers need explicit includes (`net/if.h`, `sys/types.h`).
- Behaviour differences: four-part addresses only in `/etc/hosts`; io-sock ships its own `etc/protocols`; `accept()` on a locally closed socket → `EINTR`; `connect()` after `shutdown()` → `EINTR`; UNIX socket credentials follow FreeBSD.
- io-sock abilities: `network/privport`, `network/rawsocket`, `network/reuseport`, `network/ipsec`, `network/admin`, `network/jailroot`.
- Discontinued utilities: brconfig, DHCP relay/server, DNS server, FTP/TELNET/TFTP client+server, inetd, mrouted, ping6, ptpd-avb, routed, nicinfo, dhclient, autoipd, rtsold; Racoon → strongSwan; ntptrace → `ntpq -p`; QNX Wireless Framework discontinued (use vendor stacks); fs-cifs → third-party SMBv3. DHCP client is **dhcpcd**.
- 8.0.3: io-sock threads no longer inherit client priority.

## Security
- `fdistrusted()` → `fchecktrust()`.
- `devr-drng.so` folded into `random`.
- **Sandboxing discontinued** → security policies + abilities + POSIX perms/ACLs.
- `secpol -p` → `secpolpush`.

## Things that DID survive (people often assume otherwise)
Message passing, pulses, resource managers and the dispatch/iofunc library, `name_attach()`/`name_open()` (local), sporadic scheduling, priority inheritance, HAM (deprecated but present), secpol/pathtrust/QTD, tracelogger/System Profiler, slogger2, `pidin`, `on`, `slay`, `use`, `devctl()`, POSIX message queues, `mmap_device_memory()`, Screen graphics, NASA cFS support (new), QNX Hypervisor 8.0 (free in QNX Everywhere).
