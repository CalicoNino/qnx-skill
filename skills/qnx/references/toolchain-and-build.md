# Toolchain, building and deploying (QNX SDP 8.0)

## Host requirements
- **x86_64 host only** (no ARM hosts, no macOS for SDP 8.0). Supported: Ubuntu 22.04 LTS (official) / 20.04 LTS, RHEL 9, Windows 10/11 64-bit. WSL2 works (QNX blog guide).
- Free non-commercial license: request at `https://www.qnx.com/getqnx`, then accept/deploy it in **myQNX → License Manager**. Licensing is checked by host tools (qcc, mkqfs, …); license failures exit with codes 129–133.

## Installing SDP 8.0 (QNX Software Center)
1. Download **QNX Software Center 2.0 for Linux hosts** (`qnx-setup-<version>-linux.run`) from qnx.com (login required). Install: `chmod +x qnx-setup-*.run && ./qnx-setup-*.run` → default `~/qnx/qnxsoftwarecenter`.
2. GUI: log in, add the license, install **QNX Software Development Platform 8.0** (`com.qnx.qnx800`) to `~/qnx800`. Then add packages, e.g. Raspberry Pi 4 quick start image `com.qnx.qnx800.quickstart.rpi4` (Pi 5: `...rpi5`), BSPs.
3. Headless alternative (CLI):
   ```bash
   ~/qnx/qnxsoftwarecenter/qnxsoftwarecenter_clt -myqnx.user "$QNX_USER" -myqnx.password "$QNX_PASS" -addLicenseKey "$LICENSE_KEY"
   ~/qnx/qnxsoftwarecenter/qnxsoftwarecenter_clt -myqnx.user "$QNX_USER" -myqnx.password "$QNX_PASS" \
       -cleanInstall -mirrorBaseline qnx800 -installBaseline com.qnx.qnx800 -destination ~/qnx800
   ```
   Don't hard-code credentials in files or shell history; export them in the current shell only.
4. Environment (every new shell, or add to your shell rc behind a function): `source ~/qnx800/qnxsdp-env.sh` (bash; other shells may need adaptation). It sets `QNX_HOST`, `QNX_TARGET`, `PATH`, `MAKEFLAGS`. Verify: running `qcc` with no args prints `cc: no files to process`.

## qcc / q++
- `qcc` = C driver, `q++` = C++ driver; select target with `-V`:
  - Raspberry Pi (aarch64): `-Vgcc_ntoaarch64le` (C), `-Vgcc_ntoaarch64le_cxx` (C++ with LLVM libc++, default), `-Vgcc_ntoaarch64le_gpp` (GNU libstdc++)
  - x86_64 (QEMU/VM): `-Vgcc_ntox86_64`, `_cxx`, `_gpp` — `gcc_ntox86_64` is the default target
  - `qcc -V` lists targets; `qcc -V12.0,gcc_ntoaarch64le -set-default` pins a default.
- Defaults: PIE on (`-nopie` to disable), C `gnu17`, C++ `gnu++17` (`-std=c++20` available). `-pthread` is ignored (threads are in libc). C++ `std::filesystem` needs `-lc++fs`. Link C++ objects with `q++` (or `qcc -lang-c++`).
- Common libs: `-lsocket` (networking, libsocket.so), `-lslog2`, `-lsecpol`, `-lm`. Shared libraries: `-shared`.
- Hardening flags worth adding: `-O2 -D_FORTIFY_SOURCE=2 -Wl,-z,relro,-z,now -fstack-protector-strong`.

Examples:
```bash
qcc -Vgcc_ntoaarch64le -O2 -Wall -o server server.c
q++ -Vgcc_ntoaarch64le_cxx -O2 -std=c++20 -o app app.cpp -lsocket
```

## CMake
CMake has QNX platform support. Minimal toolchain file (`qnx-aarch64.cmake`):
```cmake
set(CMAKE_SYSTEM_NAME QNX)
set(CMAKE_SYSTEM_PROCESSOR aarch64)
set(CMAKE_C_COMPILER qcc)
set(CMAKE_C_COMPILER_TARGET gcc_ntoaarch64le)
set(CMAKE_CXX_COMPILER q++)
set(CMAKE_CXX_COMPILER_TARGET gcc_ntoaarch64le_cxx)
set(CMAKE_SYSROOT $ENV{QNX_TARGET})
set(CMAKE_FIND_ROOT_PATH $ENV{QNX_TARGET} $ENV{QNX_TARGET}/aarch64le)
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
```
`cmake -B build -DCMAKE_TOOLCHAIN_FILE=qnx-aarch64.cmake && cmake --build build` (after sourcing the env script). Note: the VS Code toolkit's CMake template requires CMake ≥3.24, but Ubuntu 22.04 ships 3.22 — install a newer CMake (pip/snap/Kitware apt) or lower the minimum.

## QNX recursive makefiles
QNX's own build convention (used by BSPs and toolkit templates): a tree where each level's `Makefile` includes `recurse.mk`, and the bottom "variant" directories (per OS/CPU/endianness, e.g. `nto-aarch64-le` *(name format unverified in 8.0 docs)*) do the actual build, sharing a `common.mk`. `addvariant` creates the variant directories. Use it when building QNX-style projects/BSPs; plain Makefiles or CMake are fine for applications.

## Ported open-source libraries
`https://github.com/qnx-ports/build-files` (replaced the old GitLab ports group) has build recipes for 8.0 on aarch64le/x86_64: OpenCV, ONNX, protobuf, TensorFlow Lite (native lib + Python `tflite_runtime`, needs NumPy built first), ROS 2, Boost, and many more. Check each port's README/workflows for the supported version before relying on it. QNX also publishes samples, e.g. the AI camera app on GitLab (`gitlab.com/qnx/projects/...`).

## Deploying to the target
- Quick: `scp ./app qnxuser@qnxpi.local:/tmp/ && ssh qnxuser@qnxpi.local /tmp/app`. (`/tmp` is typically RAM-backed; use the user's home or a persistent filesystem for things that must survive reboot — check `df -h` / `mount` on target.)
- Shared libraries you built: copy them too and set `LD_LIBRARY_PATH`, or install into a directory on the target's library path.
- Ports' runtime files (e.g. TFLite `.so`) must be copied from the port's install/staging directory.
- The VS Code toolkit can upload and launch automatically (launch.json `upload`/`files`).
- Script: `scripts/deploy-run.sh` in this skill.

## Images
- **mkifs** builds an image filesystem (IFS) from a **buildfile** (startup program + `procnto-smp-instr` options + boot script + files). BSPs (installed via Software Center, or built with the VS Code toolkit's Raspberry Pi 4 BSP tutorial) contain the reference buildfile, e.g. the Pi driver lines in `rpi-setup.md`.
- **mkqnximage** builds ready-to-run **VM** images (`--type=qemu|vmware|vbox|qvm`, `--arch=x86_64|aarch64le`, `--build`, `--run[=-h]`, `--getip`, `--stop`, `--hostname`, `--policy=path`, `--extra-dirs`, `--config=file`, `--graphics`). Default users: root, qnxuser, user1–6, password = username; images run qconn. QEMU on Ubuntu supports x86_64 and aarch64 guests — handy for developing without the Pi.
- **CTI (Custom Target Image)** for Raspberry Pi 4/5 and QEMU: QNX's buildable equivalent of the quick start image (includes QNX Developer Desktop by default); Linux hosts only; needs extra apt/pip deps listed in the CTI docs (`.../qnxeverywhere/com.qnx.doc.target_images/topic/cti/about.html`).
- **mkqfs** builds QTD / QNX filesystem images (see `security.md`).
