# IPC and resource managers (QNX 8.0)

## Contents
1. Choosing a pattern
2. Raw message-passing server/client with name_attach
3. Pulses and timers
4. Asynchronous notification with events
5. Channel flags (ChannelCreate)
6. Resource manager skeleton
7. read / write / devctl handlers
8. Multithreaded resource managers
9. Common mistakes

All code targets QNX 8.0. Build with `qcc -Vgcc_ntoaarch64le` (Pi) or `-Vgcc_ntox86_64`.

---

## 1. Choosing a pattern
| Need | Use |
|---|---|
| A device/service other programs reach with `open/read/write/devctl`, shell tools (`cat /dev/x`), permissions, secpol path rules | **Resource manager** (`resmgr_attach`) |
| Private request/response protocol between your own processes | `name_attach()` + `MsgSend/MsgReceive/MsgReply` |
| One-way notification, timer ticks, interrupt notification | **Pulses** |
| Server must notify a client later without blocking on it | Client registers a `sigevent`; server calls `MsgDeliverEvent()` |
| Bulk data streaming between processes | Shared memory + pulses/condvars for signalling |
| Off-board communication | io-sock sockets (Qnet is gone in 8.0) |

Resource managers are the idiomatic QNX answer and the one QNX experts expect to see.

## 2. Raw message-passing server/client with name_attach
Messages should start with a 16-bit `type` so the server can tell your messages from system messages (`_IO_CONNECT` from `name_open()`, etc.). Keep your types above `_IO_MAX`.

```c
/* common.h */
#include <sys/iomsg.h>
#define SERVICE_NAME "imu_svc"
#define MSG_GET_SAMPLE (_IO_MAX + 1)
typedef struct { uint16_t type; uint16_t subtype; } msg_hdr_t;
typedef struct { msg_hdr_t hdr; } get_sample_msg_t;
typedef struct { float ax, ay, az; uint64_t t_ns; } sample_reply_t;
```

```c
/* server.c */
#include <stdio.h>
#include <stdlib.h>
#include <errno.h>
#include <time.h>
#include <sys/dispatch.h>
#include <sys/neutrino.h>
#include "common.h"

typedef union {
    uint16_t          type;
    struct _pulse     pulse;
    get_sample_msg_t  get;
} recv_buf_t;

int main(void) {
    name_attach_t *att = name_attach(NULL, SERVICE_NAME, 0);   /* creates channel (UNBLOCK|DISCONNECT|COID_DISCONNECT) */
    if (!att) { perror("name_attach"); return EXIT_FAILURE; }

    for (;;) {
        recv_buf_t msg;
        rcvid_t rcvid = MsgReceive(att->chid, &msg, sizeof msg, NULL);  /* rcvid_t is 64-bit in 8.0 */
        if (rcvid == -1) { perror("MsgReceive"); continue; }

        if (rcvid == 0) {                              /* pulse */
            switch (msg.pulse.code) {
            case _PULSE_CODE_DISCONNECT:               /* client went away: free its server connection */
                ConnectDetach(msg.pulse.scoid);
                break;
            case _PULSE_CODE_UNBLOCK:                  /* client wants out of REPLY-blocked state */
                break;
            default: /* your own pulse codes */ break;
            }
            continue;
        }

        if (msg.type == _IO_CONNECT) {                 /* name_open() handshake */
            MsgReply(rcvid, EOK, NULL, 0);
            continue;
        }
        if (msg.type > _IO_BASE && msg.type <= _IO_MAX) {  /* other system msgs we don't handle */
            MsgError(rcvid, ENOSYS);
            continue;
        }

        switch (msg.type) {
        case MSG_GET_SAMPLE: {
            sample_reply_t r = { .ax = 0, .ay = 0, .az = 9.81f, .t_ns = clock_gettime_mon_ns() };
            MsgReply(rcvid, EOK, &r, sizeof r);
            break;
        }
        default:
            MsgError(rcvid, ENOSYS);
        }
    }
}
```

```c
/* client.c */
#include <stdio.h>
#include <sys/dispatch.h>
#include <sys/neutrino.h>
#include "common.h"

int main(void) {
    int coid = name_open(SERVICE_NAME, 0);
    if (coid == -1) { perror("name_open"); return 1; }
    get_sample_msg_t m = { .hdr.type = MSG_GET_SAMPLE };
    sample_reply_t r;
    if (MsgSend(coid, &m, sizeof m, &r, sizeof r) == -1) { perror("MsgSend"); return 1; }
    printf("az=%.2f t=%llu\n", r.az, (unsigned long long)r.t_ns);
    name_close(coid);
}
```
Notes: `clock_gettime_mon_ns()` is 8.0-only (use `clock_gettime(CLOCK_MONOTONIC)` for portability). `name_attach()` with a public channel needs `PROCMGR_AID_PUBLIC_CHANNEL`; under a security policy also `PROCMGR_AID_PATHSPACE`. Only one process may attach a given local name. Services appear in `/dev/name/local/`.

## 3. Pulses and timers
```c
#include <time.h>
#include <sys/siginfo.h>
#define PULSE_TICK (_PULSE_CODE_MINAVAIL + 0)

int chid = ChannelCreate(_NTO_CHF_PRIVATE);                    /* private: no public-channel ability needed */
int coid = ConnectAttach(0, 0, chid, _NTO_SIDE_CHANNEL, 0);
struct sigevent ev;
SIGEV_PULSE_INIT(&ev, coid, SIGEV_PULSE_PRIO_INHERIT, PULSE_TICK, 0);
timer_t tid;
timer_create(CLOCK_MONOTONIC, &ev, &tid);
struct itimerspec it = { .it_value = {0, 1000000}, .it_interval = {0, 1000000} };  /* 1 kHz */
timer_settime(tid, 0, &it, NULL);

for (;;) {
    struct _pulse p;
    if (MsgReceivePulse(chid, &p, sizeof p, NULL) == 0 && p.code == PULSE_TICK) {
        /* control loop iteration */
    }
}
```
- User pulse codes: `_PULSE_CODE_MINAVAIL` … `_PULSE_CODE_MAXAVAIL`. Negative codes are kernel/system pulses.
- `MsgSendPulse(coid, priority, code, value)` sends one from any process holding a connection.
- Sub-millisecond periods may need `PROCMGR_AID_HIGH_RESOLUTION_TIMER` and timer-tolerance settings; verify jitter with tracelogger rather than assuming.

## 4. Asynchronous notification with events
Client builds a `struct sigevent` (usually a pulse to its own channel), **registers** it (8.0 rejects unregistered events), and sends it to the server in a message. The server stores the event and the client's `rcvid`/`scoid`, replies immediately, and later calls `MsgDeliverEvent(rcvid, &ev)` when data is ready. Check `MsgRegisterEvent()` and `MsgDeliverEvent()` 8.0 pages for exact signatures *(unverified here)*. For resource managers, the standard mechanism is `ionotify()`/`select()` support via `iofunc_notify*()`.

## 5. Channel flags (ChannelCreate, 8.0)
| Flag | Value | Effect |
|---|---|---|
| `_NTO_CHF_FIXED_PRIORITY` | 0x0001 | Disable priority inheritance on receive |
| `_NTO_CHF_UNBLOCK` | 0x0002 | Pulse `_PULSE_CODE_UNBLOCK` (value = rcvid) when a REPLY-blocked client tries to unblock (signal/timeout) — server must then reply/error |
| `_NTO_CHF_THREAD_DEATH` | 0x0004 | Pulse `_PULSE_CODE_THREADDEATH` (value = tid) when any thread in the process dies |
| `_NTO_CHF_DISCONNECT` | 0x0008 | Pulse `_PULSE_CODE_DISCONNECT` when all of a client's connections close; server **must** `ConnectDetach(scoid)` or leak |
| `_NTO_CHF_COID_DISCONNECT` | 0x0040 | Pulse `_PULSE_CODE_COIDDEATH` (value = coid) per connection when the server's channel goes away |
| `_NTO_CHF_PULSE_POOL` | 0x0100 | Private pulse pool (`ChannelCreatePulsePool()`) |
| `_NTO_CHF_PRIVATE` | 0x1000 | Others can't `ConnectAttach` (EPERM). Without it, creating the channel needs `PROCMGR_AID_PUBLIC_CHANNEL` |
| `_NTO_CHF_INHERIT_RUNMASK` | 0x4000 | Receiving thread adopts sender's runmask |

## 6. Resource manager skeleton
This follows the 8.0 "simple single-threaded resource manager" example. It creates `/dev/sample`, which behaves like `/dev/null` until you override handlers.

```c
#include <errno.h>
#include <stdio.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/iofunc.h>
#include <sys/dispatch.h>     /* after iofunc.h */

static resmgr_connect_funcs_t connect_funcs;
static resmgr_io_funcs_t      io_funcs;
static iofunc_attr_t          attr;

int main(int argc, char **argv) {
    dispatch_t *dpp = dispatch_create_channel(-1, DISPATCH_FLAG_NOLOCK);  /* dispatch_create() == (-1, 0) */
    if (dpp == NULL) { perror("dispatch_create_channel"); return EXIT_FAILURE; }

    resmgr_attr_t resmgr_attr;
    memset(&resmgr_attr, 0, sizeof resmgr_attr);
    resmgr_attr.nparts_max   = 1;
    resmgr_attr.msg_max_size = 2048;

    iofunc_func_init(_RESMGR_CONNECT_NFUNCS, &connect_funcs, _RESMGR_IO_NFUNCS, &io_funcs);
    /* override handlers here, e.g.: io_funcs.read = io_read; io_funcs.write = io_write; io_funcs.devctl = io_devctl; */

    iofunc_attr_init(&attr, S_IFNAM | 0666, 0, 0);

    int id = resmgr_attach(dpp, &resmgr_attr, "/dev/sample", _FTYPE_ANY, 0,
                           &connect_funcs, &io_funcs, &attr);
    if (id == -1) { perror("resmgr_attach"); return EXIT_FAILURE; }

    dispatch_context_t *ctp = dispatch_context_alloc(dpp);
    for (;;) {
        if ((ctp = dispatch_block(ctp)) == NULL) { perror("dispatch_block"); return EXIT_FAILURE; }
        dispatch_handler(ctp);
    }
}
```
Rules: call `resmgr_attach()` for all paths **before** `dispatch_context_alloc()` (attaching a larger message size afterwards fails with EINVAL). To disable priority inheritance for the A/B demo, pass `_NTO_CHF_FIXED_PRIORITY` as the second argument's channel flags via `dispatch_create_channel(-1, …)` *(check the dispatch_create_channel page for how channel flags are passed)*. `resmgr_attach()` needs `PROCMGR_AID_PATHSPACE` (root has it; under secpol it must be granted). Use `iofunc_attr_init(..., S_IFCHR | 0666, ...)` for a character-device-like node.

## 7. read / write / devctl handlers
```c
/* read: return a string, honouring file offset */
static char buf[] = "hello from /dev/sample\n";

static int io_read(resmgr_context_t *ctp, io_read_t *msg, RESMGR_OCB_T *ocb) {
    int status = iofunc_read_verify(ctp, msg, ocb, NULL);
    if (status != EOK) return status;
    if ((msg->i.xtype & _IO_XTYPE_MASK) != _IO_XTYPE_NONE) return ENOSYS;

    size_t len    = sizeof buf - 1;
    size_t off    = ocb->offset;
    size_t nbytes = off < len ? len - off : 0;
    if (nbytes > _IO_READ_GET_NBYTES(msg)) nbytes = _IO_READ_GET_NBYTES(msg);

    _IO_SET_READ_NBYTES(ctp, nbytes);
    if (nbytes) {
        SETIOV(ctp->iov, buf + off, nbytes);
        ocb->offset += nbytes;
        ocb->attr->flags |= IOFUNC_ATTR_ATIME;
        return _RESMGR_NPARTS(1);
    }
    return _RESMGR_NPARTS(0);
}

/* write: read the client's data out of the message */
static int io_write(resmgr_context_t *ctp, io_write_t *msg, RESMGR_OCB_T *ocb) {
    int status = iofunc_write_verify(ctp, msg, ocb, NULL);
    if (status != EOK) return status;
    if ((msg->i.xtype & _IO_XTYPE_MASK) != _IO_XTYPE_NONE) return ENOSYS;

    size_t nbytes = _IO_WRITE_GET_NBYTES(msg);
    char data[256];
    if (nbytes > sizeof data) nbytes = sizeof data;
    if (resmgr_msgget(ctp, data, nbytes, sizeof msg->i) == -1) return errno;  /* resmgr_msgread() on older docs */
    _IO_SET_WRITE_NBYTES(ctp, nbytes);
    ocb->attr->flags |= IOFUNC_ATTR_MTIME | IOFUNC_ATTR_CTIME;
    /* act on data */
    return _RESMGR_NPARTS(0);
}
```
devctl (custom commands — the QNX equivalent of ioctl):
```c
#include <devctl.h>
#define DCMD_SAMPLE_GET_RATE __DIOF(_DCMD_MISC, 1, int)   /* data from server */
#define DCMD_SAMPLE_SET_RATE __DIOT(_DCMD_MISC, 2, int)   /* data to server */
static int rate_hz = 100;

static int io_devctl(resmgr_context_t *ctp, io_devctl_t *msg, RESMGR_OCB_T *ocb) {
    int status = iofunc_devctl_default(ctp, msg, ocb);
    if (status != _RESMGR_DEFAULT) return status;            /* handled a generic command */

    void *data = _DEVCTL_DATA(msg->i);
    int nbytes = 0;
    switch (msg->i.dcmd) {
    case DCMD_SAMPLE_GET_RATE: *(int *)data = rate_hz; nbytes = sizeof(int); break;
    case DCMD_SAMPLE_SET_RATE: rate_hz = *(int *)data; break;
    default: return ENOSYS;
    }
    memset(&msg->o, 0, sizeof msg->o);
    msg->o.ret_val = 0;
    msg->o.nbytes  = nbytes;
    return _RESMGR_PTR(ctp, &msg->o, sizeof msg->o + nbytes);
}
```
Client side: `devctl(fd, DCMD_SAMPLE_GET_RATE, &rate, sizeof rate, NULL)`. 8.0: return errno values directly from handlers (`_RESMGR_ERRNO()` is deprecated). Verify `resmgr_msgget()` vs `resmgr_msgread()` naming on the 8.0 lib_ref page before compiling *(unverified)*.

## 8. Multithreaded resource managers
Replace the `dispatch_block`/`dispatch_handler` loop with a thread pool (`thread_pool_create()` with `dispatch_block`, `dispatch_handler`, `dispatch_context_alloc` callbacks; `lo_water`, `hi_water`, `increment`, `maximum`). Protect shared `attr`/state — the iofunc layer locks the attribute structure per request (`iofunc_attr_lock`). Keep at least one thread RECEIVE-blocked so server boost and priority inheritance behave predictably.

## 9. Common mistakes
- Not handling `_PULSE_CODE_DISCONNECT` → server-connection leaks (watch `pidin channels`/`pidin fds`).
- Replying twice, or never replying → client stuck REPLY-blocked forever (`pidin` shows `REPLY` state with the server pid in "Blocked").
- Doing slow work (I/O, sleeps) inside a single-threaded server → every client waits; use a pool or reply later with the saved `rcvid`.
- Using `printf` debugging in a driver at high priority → use `slog2f()` (`<sys/slog2.h>`, link `-lslog2`).
- Forgetting abilities: running as root during development hides missing `PATHSPACE`/`PUBLIC_CHANNEL`/`IO`/`INTERRUPT` abilities that break under a security policy. Test as non-root early.
- Assuming io-sock inherits priority (it doesn't in 8.0.3+).
