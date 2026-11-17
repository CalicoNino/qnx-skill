# QNX Toolkit for VS Code (QVSC 1.1)

The VS Code replacement/alternative for the Eclipse-based Momentics IDE.

## Install
- Extension ID **`qnx.qnx-vscode`** — `code --install-extension qnx.qnx-vscode` or Marketplace "QNX Toolkit".
- Prerequisites: Linux or Windows x86_64 host; QNX SDP 8.0 with a license (minimum license package version `8.0.0.00075T202404171128L`); Microsoft C/C++ extension `ms-vscode.cpptools`; CMake for CMake projects; a QNX target reachable over IP or a local VM.
- Avoid installing other (non-QNX) Makefile extensions — they can conflict with the QNX makefile support.
- The workspace must be **trusted** (in Restricted Mode the QNX icons don't appear).
- 1.1: System Profiler is built in (older docs mention Java 17 + "QNX Trace Compass"; not needed for 1.1).

## Configure
- QNX icon in the Activity Bar → **QNX COMMANDS → Open QNX Toolkit Walkthrough**.
- Settings: `qnx.sdpPath` (e.g. `~/qnx800`) and `qnx.config.defaultProjectsRoot` (default `~/qnxprojects`). After setting the SDP path the toolkit checks the license; without it some features are disabled.
- Add a target (IP address of the Pi, e.g. `qnxpi.local` / its IP, user `qnxuser`) in the toolkit's target view, or create a local VM target (VM creation supports only x86_64 VMware Workstation or VirtualBox 6.1; QEMU targets via mkqnximage can be added by IP).

## Projects
- Templates: **CMake** and **QNX Recursive Makefiles**, C or C++, multiple CPU variants (pick aarch64le for the Pi). Other build systems need manual task configuration.
- Build: **QNX → Build Active Project**; errors appear in the Problems panel. Build config lives in `.vscode/tasks.json`.
- Known issue: CMake template sets `cmake_minimum_required(3.24)`; Ubuntu 22.04 has 3.22 → upgrade CMake or edit the template.

## Run / debug
- `.vscode/launch.json` is generated at project creation; debugger type **`qnx-gdb`**. Modes: run without debugger, run with debugger, **Attach Debugger to QNX Process**.
- Program output appears in its own terminal (1.1).
- Not supported: post-mortem core debugging in the UI (workaround via GDB console), intercepting crash signals, watchpoints, follow child after fork, detach, locals in non-function scope. Disassembly/advanced features via the GDB console.
- Known issues: on Windows you can't pause after disabling breakpoints (terminate & restart, or attach instead); "Add Configuration…" may write to the wrong launch.json when there are several.

## System Profiler / tracing
- Run a kernel trace via a launch config, a task, or directly; e.g. this launch config runs tracelogger on the target and downloads the trace:
  ```json
  {
    "type": "qnx-gdb", "request": "launch", "name": "tracelogger",
    "gdb": "none", "program": "tracelogger",
    "args": ["-s3", "-w", "-f/dev/shmem/trace.kev"],
    "qnxtarget": "default", "upload": false,
    "files": [{ "operation": "download", "remotePath": "/dev/shmem/trace.kev",
                "hostPath": "trace_${command:qnx.timestamp}.kev" }]
  }
  ```
- 1.1 views: Timeline (incl. IPC between threads), CPU Usage (Auto Scale), CSV export, multicore-aware. Large `.kev` (≥1.4 GB) can crash VS Code → right-click → **Save Filtered File**.

## Versus Momentics
| | Momentics | VS Code toolkit |
|---|---|---|
| Workspace | directory | `.code-workspace` |
| Settings | preferences GUI | JSON (`settings.json`, `.vscode/*.json`) |
| Build config | `.project` | `tasks.json` |
| Target monitoring | full | limited; remote filesystem ops supported |
| System Profiler | full | built in, fewer views |
| Memory Analysis / Application Profiler | UI | data collected, **no results UI** |
| Code coverage / Valgrind | built in | via third-party VS Code extensions |
| BSP build | yes | Raspberry Pi 4 BSP tutorial |

Help: QNX Discord (`discord.gg/Jj4EkkrFTT`), r/QNX, docs at `qnx.com/developers/docs/qnxtoolkit/`.
