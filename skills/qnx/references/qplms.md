# QPLMS — QNX Process Launch and Monitor Service (8.0)

QPLMS replaces the deprecated HAM/Guardian. It launches processes from a configuration file, resolves start-order dependencies as a DAG, monitors them (death + optional heartbeat watchdog), and recovers (restart, stop, fault, or **Defined Safe State**).

Docs: `https://qnx.com/developers/docs/8.0/com.qnx.doc.plms/topic/plms_overview.html`, `plms_binary.html`, `config_plms.html`.

## Components
- `plms` — the service.
- `libplms` — client/control library (also how monitored processes send heartbeats; watchdog uses anonymous shared memory). Access is ability-gated.
- `plmsctrl` — debug utility; **not allowed in production**.

Component states: Starting, Started, Idle, Stopping, Session stopped, Fault, **Defined Safe State (DSS)** — DSS restarts the system via `sysmgr_reboot()`.

## Command line
`plms [options] config_file` (config file last; negative numbers not accepted)

| Option | Meaning (default) |
|---|---|
| `-d` | Dry run: parse config and exit — use it to validate syntax |
| `-s component` | Component/module to start at launch (`all` = everything) |
| `-k` / `-x` | With `-s`: run until component started then exit / on failure call `sysmgr_reboot()` |
| `-D max_tries=N,repair=NONE\|STOP\|RESTART\|DSS\|FAULT,restart_wait_time=ms,term_timeout=ms,path=...` | Defaults for all components (3, STOP, 100 ms, 100 ms, $PATH) |
| `-h ms` | Heartbeat interval (1000; min 500) |
| `-m ms` | Watchdog monitor interval (100; 10…3600000) |
| `-p prio[r\|f]` | plms's own priority/policy (30r) |
| `-w N` | Worker threads (4; 1–32); `-C clusters` per worker (8.x) |
| `-i name` | Instance path under /dev (`/dev/plms`) |
| `-n N` | Notification slots (4) |
| `-t type` | Initial secpol type (needed with `-U` when non-root) |
| `-U uid[:gid]` | Drop identity (8.x) |
| `-T max_nodes=N` | Graph size (1024) |
| `-v…` | Verbosity (up to 7 levels) |

## Configuration structure
```
include "path"
component "name" {
    depend = ["other:session", "lib:stateless"]
    coptions = ["NOTIFY_ALL"]
    start_sequence = [main]
    stop_sequence  = [stop]
    on_fault = "DSS"            // or a fault task name
    task "main"     { ...keys and actions... }
    task "stop"     { signal ...  term_timeout ...  options = [TERMINATE_CHILD] }
    task "recovery" { repair = "RESTART"  max_tries = 5  wait_time = 100 }
    task "monitor"  { interval = 500  max_miss = 3  start_delay = 1000 }
}
module "name" { "compA" "compB" }
```
`task "main"` keys: `command`, `args`, `stype` (security policy type), `runmask`, `priority` ("policy:priority:parameters"), `ability = [...]`, `cwd`, `groups`, `user` ("uid", ":gid", "uid:gid"), `stdin/stdout/stderr` ("file:mode"), `tty`, `aslr` ("on|off"), `rlimits = ["rlimit:cur[:max]"]`, `options = ["PATHNAME", "CLEAR_ENV_LOGIN", "CLEAR_ENV_ALL", "CRITICAL"]`, `env = ["VAR=value"]`. (An `aps` key exists in the schema but APS is discontinued in 8.0.)

Actions inside tasks: `exec()`, `exec_waitfor_exit(timeout)`, `exec_expect_exit(value, timeout)`, `waitfor_pathname("path", poll, timeout)`, `waitfor_attachname("path", timeout)`, `waitfor_delay(ms)`, `pathmgr_symlink("path","link")`, `pathmgr_unlink("path")`, `test_env("VAR","value")`, `load_config("file")`, `start_components("name")`, `stop_components("name")`.

Syntax: numbers decimal/octal(0)/hex(0x), no negatives; strings may not contain quotes; `//` comments.

## Illustrative example (verify punctuation against config_plms.html, then `plms -d`)
```
// imu driver: restart up to 5 times, heartbeat-monitored
component "imu_drv" {
    start_sequence = [main]
    task "main" {
        command = "/opt/app/bin/imu-resmgr"
        args = ["-r", "1000"]
        priority = "f:40"
        user = "1001:1001"
        rlimits = ["RLIMIT_NTHR:8"]
        exec()
        waitfor_attachname("/dev/imu", 2000)
    }
    task "recovery" { repair = "RESTART"  max_tries = 5  wait_time = 100 }
    task "monitor"  { interval = 500  max_miss = 3 }
}

// control loop depends on the driver's session: restarted with it
component "adcs" {
    depend = ["imu_drv:session"]
    start_sequence = [main]
    on_fault = "DSS"
    task "main" { command = "/opt/app/bin/adcs"  priority = "f:50"  exec() }
    task "recovery" { repair = "RESTART"  max_tries = 3  wait_time = 100 }
}

module "flight" { "imu_drv" "adcs" }
```
Run: `plms -d /opt/app/etc/flight.plms` (validate) then `plms -s flight /opt/app/etc/flight.plms`.

## Demo moments QPLMS enables
- `slay imu-resmgr` → RESTART within `wait_time`; dependent `adcs` restarted per its `session` dependency; visible as a staged chain in System Profiler.
- A frozen (not crashed) process misses heartbeats → `max_miss` triggers recovery.
- Repeated failure exhausts `max_tries` → FAULT (quarantine) or DSS (safe state/reboot).
- `depend` graph guarantees boot order (driver before consumer) — combine with IFS ordering for fast "control authority" time.
