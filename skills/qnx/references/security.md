# Security in QNX 8.0

QNX's own guidance: a production system needs at least **security policies** and **POSIX access controls**. Everything else layers on top.

## Feature map
| Layer | Feature |
|---|---|
| Process protection | Non-executable stacks and heap (default), stack canaries (prebuilt QNX binaries), heap cookies, `-D_FORTIFY_SOURCE=1|2`, RELRO, deny exec / write+exec mappings via policy type, `procnto -m X` |
| Privilege | **Process manager abilities** (`procmgr_ability()`), **security policies** (`secpol*`), POSIX permissions + ACLs, rlimits (`prlimit()`) |
| Code provenance | **Pathtrust** (only trusted filesystems may supply executables/libraries) + **QNX Trusted Disk (QTD)** integrity + secure boot (SoC-dependent) |
| Memory layout | ASLR (default on, needs PIE — qcc builds PIE by default) |
| Data | Power-Safe filesystem `fs-qnx6.so` file encryption; `qcrypto` framework; bundled OpenSSL; `/dev/random` |
| Isolation | Drivers, filesystems, networking are user processes |
| Auth | OpenPAM |

## Abilities (procmgr_ability)
- Named `PROCMGR_AID_<NAME>`. **Unprivileged** (allowed without privilege): FORK, MAP_FIXED, PGRP, PROT_EXEC, PROT_WRITE_AND_EXEC, PUBLIC_CHANNEL, SIGEV_THREAD, SPAWN, UNTRUSTED_EXEC (and RCONSTRAINT, unused). **Everything else is privileged**, e.g. IO, INTERRUPT, MEM_PHYS, PATHSPACE, PRIORITY, SCHEDULE, SETUID, SETGID, SPAWN_SETUID, TRACE, REBOOT, MOUNTIFS, PATH_TRUST, MAC_POLICY, XPROCESS_DEBUG, HIGH_RESOLUTION_TIMER, CHANNEL_CONNECT, RLIMIT, CLOCKSET.
- Key ones: `PATHSPACE` (resmgr_attach, symlinks), `PUBLIC_CHANNEL` (public `ChannelCreate`), `PRIORITY` (above unprivileged max, normally 63), `INTERRUPT`, `IO`, `MEM_PHYS`, `TRACE` (only ability tracing needs), `PATH_TRUST`, `MAC_POLICY` (change policy — `secpolpush`), `REBOOT` (`sysmgr_reboot()`).
- Custom abilities exist (e.g. io-sock `network/admin`, `network/privport`, `network/rawsocket`; io-gpio `io-gpio/all`; block I/O `vfs/mount-blk`); create your own with `procmgr_ability_create()`/`procmgr_ability_lookup()`.
- Pattern: start as root, acquire what you need early (`procmgr_ability()` with `PROCMGR_ADN_ROOT|PROCMGR_AOP_ALLOW|PROCMGR_AOP_LOCK`…), drop root (`setuid`), lock the rest. Inspect live with `pidin abilities` or `pidin -p name abilities`.

## Security policies (secpol)
- A compiled policy describes **types** (one per kind of process) and what each type may do: abilities, which paths it may attach to in the pathname space, which channels it may connect to, whether it may exec untrusted code, etc. — things `procmgr_ability()` alone can't express.
- Utilities:
  - `secpolgenerate` (target): run the system in "learning" mode; it records what processes actually do and writes `/dev/secpolgenerate/errors` and `/dev/secpolgenerate/unused`.
  - `secpolpush` (target): load a policy into procnto (replaces `secpol -p`; needs `MAC_POLICY`).
  - `secpolcompile` (host): compile the policy source for inclusion in the IFS.
  - Libraries: `libsecpol` (`secpol.h`, e.g. `secpol_transition_type()` to switch type at runtime) and `libsecpolev`.
- Workflow: generate on a dev system → push mock policy → review and edit the policy language → compile with `secpolcompile` → deploy (IFS) and push. Launchers set each process's type (QPLMS `stype`, `on -T type`? *(verify)*; `plms -t`).
- Whether the Pi quick-start image boots with a policy in force is not documented — check on target before relying on it.

## Pathtrust
- Controls what may be **executed** (process loader) and **loaded as a library** (loader and `dlopen()`).
- Enable with `procnto -qt`. The primary IFS is implicitly trusted.
- Mounting a filesystem as trusted requires `PROCMGR_AID_PATH_TRUST` for both the mounting process and the `devb-*` driver serving it, and the filesystem should sit on integrity-protected storage such as QTD:
  ```sh
  mount -t qtd  -o trusted,key=/path/to/public.pem /dev/hd0t178 /qtd
  mount -t qnx6 -o ro,trusted /qtd /fs
  mount -f        # shows the trusted option; also df -g
  ```
- setuid/setgid bits on untrusted filesystems are ignored (implicit `nosuid`).
- Decide trust by **provenance** (who signed it), not just integrity — e.g. a third-party app store on QTD should not be mounted trusted.
- Interpreters (Python) should live on untrusted filesystems; pathtrust can't stop scripts.
- Programmatic check: `fchecktrust()` (replaces `fdistrusted()`).

## QNX Trusted Disk (QTD)
- **Read-only** integrity layer (`fs-qtd.so`) between the block device and the real filesystem (e.g. `fs-qnx6.so`). Every block read is verified against a Merkle tree whose **root hash is signed**; failures return errors. Extends secure boot to on-disk binaries/config.
- Can also be used as a file package: QTD images mounted from files ("app model"), and **nested QTD images** inside QTD images — the right way to ship separately signed application bundles.
- Images are built on the host with **`mkqfs`** (needs a valid QNX license):
  ```
  mkqfs qtd -B 4096 -H sha256 -S <rsa-sha256|ecdsa-sha256|eddsa-25519|eddsa-448> -K private.pem \
        [-R rollback_version] [-P partition_size] -o out.qtd input_fs.img
  ```
  Mandatory: `-B` chunk size (512…32768), `-H` digest (sha256, sha512, sha512-256, blake2s256, blake2b256, blake2b512, blake3), `-S` signature algorithm, `-K` key (private when building, public when verifying with `-y`). `-R` anti-rollback version pairs with the driver's rollback mount option (`qtdctl` queries it). `-X` re-signs; `-Z` uses an external signing command. Keys: PEM, private PKCS#8, public X.509. (Exact spelling of the Ed25519 algorithm name printed in the docs as `eddsa-25519` — verify with `mkqfs -h`.)
- QTD's signature is classical (RSA/ECDSA/EdDSA). If your design uses post-quantum signatures (e.g. LMS manifests), have the manifest commit to the QTD root/image hash.
- Keep the mounting public key on a different filesystem from the one being mounted (e.g. in the IFS), not served by the same `devb` process.

## rlimits and ASLR
- `prlimit()`/`setrlimit()`: CPU, memory, open files, **`RLIMIT_NTHR`** (thread count — QNX-specific and important for containing misbehaving processes), etc. QPLMS tasks accept `rlimits = ["rlimit:cur[:max]"]`.
- ASLR: on by default (`procnto -m r`); requires PIE (qcc default `-pie`). QPLMS can set `aslr = "on|off"` per task.

## Practical checklist for a demo/product
1. Run every component as a non-root user with only the abilities it needs (use `pidin abilities` to audit).
2. Generate a policy with `secpolgenerate`, review it, and push it; show denials on camera (`slog2info` shows policy violations).
3. Enable pathtrust (`procnto -qt`); put your signed binaries on a QTD-backed trusted mount; prove an unsigned binary gets "exec denied".
4. Use rlimits (`RLIMIT_NTHR`, memory) for untrusted components.
5. Don't claim certification — the free SDP is not QNX OS for Safety.
