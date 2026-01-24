# Beyond io_uring: FreeBSD AIO as a Secure Foundation for Modern Databases

## A Technical Architecture for Security-Conscious Database Deployments

*An educational exploration of async I/O alternatives for stateful systems*

---

## Executive Summary

Linux's io_uring has become the default choice for high-performance database I/O, but its growing security attack surface has led to it being disabled in Docker, Android, ChromeOS, and many enterprise environments. This document explores **FreeBSD AIO + kqueue** as a mature, secure alternative that provides equivalent async I/O capabilities without the security concerns.

**Key findings:**
- FreeBSD AIO provides true asynchronous disk I/O (not thread-pool simulation)
- ZFS 2.3.0+ now supports O_DIRECT, closing the last performance gap
- PostgreSQL is actively implementing this exact architecture (posix_aio backend)
- The security attack surface is dramatically smaller than io_uring
- Production deployments exist at scale (Netflix, WhatsApp, financial institutions)

---

## Part 1: The Problem with io_uring

### What is io_uring?

io_uring (introduced Linux 5.1, 2019) is a high-performance async I/O interface that uses shared memory ring buffers between userspace and kernel. It's powerful and fast.

### The Security Reality

**Google's 2022 findings:**
> "60% of our kernel exploit bounty submissions targeted io_uring"

**Responses from major platforms:**

| Platform | Action | Date |
|----------|--------|------|
| Android | Disabled io_uring | 2022 |
| ChromeOS | Disabled io_uring | 2022 |
| Google servers | Disabled io_uring | 2022 |
| Docker | Disabled by default | v24.0 (2023) |
| Many enterprise kernels | Disabled or restricted | Ongoing |

**Why is io_uring vulnerable?**

1. **Large attack surface**: ~30+ operation types, constantly growing
2. **Kernel context execution**: Operations run in kernel context, bypassing seccomp
3. **Complex state machine**: Ring buffer management creates race condition opportunities
4. **Rapid development**: New features added faster than security review can keep up

### The Database Dilemma

Modern databases optimized for io_uring face a choice:

```
Option A: Keep io_uring
├── Best performance
├── Security risk accepted
└── Blocked in many enterprise environments

Option B: Disable io_uring
├── Fall back to synchronous I/O
├── Significant performance regression
└── Defeats the purpose of the optimization
```

**There should be an Option C.**

---

## Part 2: The Alternative Architecture

### FreeBSD AIO + kqueue + O_DSYNC

```
┌─────────────────────────────────────────────────────────────┐
│                    Application Layer                         │
│              (TigerBeetle, PostgreSQL, etc.)                │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                      POSIX AIO API                          │
│         aio_read() / aio_write() / aio_fsync()             │
│                                                             │
│  • Submit I/O operation → returns immediately               │
│  • No thread blocked waiting                                │
│  • Kernel handles completion                                │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                    kqueue (Event Loop)                      │
│                      EVFILT_AIO                             │
│                                                             │
│  • Unified event notification (disk + network)              │
│  • Single syscall waits for ANY completion                  │
│  • Scales to thousands of concurrent operations             │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                         ZFS 2.3+                            │
│           O_DIRECT (bypass ARC) + O_DSYNC (durable)        │
│                                                             │
│  • Direct I/O support (new in 2.3.0)                       │
│  • BIO_FLUSH on sync (guaranteed durability)               │
│  • Checksums, compression, snapshots                        │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                    NVMe / Storage                           │
│                   DMA + Interrupt                           │
│                                                             │
│  • Hardware does the work                                   │
│  • CPU is free during I/O                                   │
│  • Interrupt signals completion                             │
└─────────────────────────────────────────────────────────────┘
```

### Why This Works

**True Async I/O (Not Thread Pool Simulation)**

Some "async" implementations just hide blocking I/O in a thread pool. FreeBSD AIO is different:

| Implementation | How It Works | Truly Async? |
|----------------|--------------|--------------|
| glibc POSIX AIO (Linux) | Userspace thread pool | ❌ No |
| Linux libaio | Kernel AIO, O_DIRECT only | ⚠️ Limited |
| Linux io_uring | Kernel ring buffers | ✅ Yes |
| **FreeBSD AIO** | Kernel AIO + kqueue | ✅ Yes |
| Windows IOCP | Kernel completion ports | ✅ Yes |

FreeBSD AIO with SIGEV_KEVENT delivers completions through kqueue — the kernel notifies you when I/O is done. No thread sits waiting.

**Completion Model vs Readiness Model**

This is a crucial distinction:

```
READINESS MODEL (epoll, kqueue for sockets):
  "The socket is ready for you to read"
  → You must still call read() 
  → For disk: files are always "ready" but I/O still blocks

COMPLETION MODEL (AIO, io_uring, IOCP):
  "The read is DONE, here's your data"
  → No second syscall needed
  → True async for disk I/O
```

For database workloads (disk-heavy), you need the **completion model**. FreeBSD provides this through AIO.

---

## Part 3: Security Comparison

### Attack Surface Analysis

| Aspect | io_uring | FreeBSD AIO |
|--------|----------|-------------|
| Age | ~5 years (2019) | ~25 years (1998) |
| Operation types | 30+ and growing | 5 (read, write, fsync, etc.) |
| Code complexity | High (ring buffers, polling modes) | Low (simple syscalls) |
| Kernel context bypass | Yes (seccomp concern) | No |
| CVEs (2020-2024) | Dozens | Minimal |
| Disabled by major vendors | Yes (Google, Docker, etc.) | No |

### The Seccomp Problem

io_uring operations execute in kernel worker threads, not in the context of the original syscall. This means:

- Seccomp filters don't see the actual operations
- Container sandboxing is bypassed
- Security policies can't restrict what io_uring does

FreeBSD AIO operations are traditional syscalls — standard security mechanisms apply.

### Maturity Matters

```
FreeBSD AIO timeline:
├── 1998: Initial implementation (FreeBSD 3.0)
├── 2000s: Battle-tested in production
├── 2010s: PostgreSQL evaluation begins
├── 2020s: PostgreSQL implements posix_aio backend
└── 25+ years of security hardening

io_uring timeline:
├── 2019: Initial release (Linux 5.1)
├── 2020: Rapid feature additions
├── 2021: First major CVEs
├── 2022: Google disables it (60% of exploit bounties)
├── 2023: Docker disables by default
└── Ongoing: New CVEs regularly discovered
```

---

## Part 4: The ZFS Advantage

### Why ZFS Matters for Databases

**Traditional filesystem (UFS, ext4, XFS):**
```
Application writes data
    ↓
Filesystem buffers it
    ↓
Eventually writes to disk
    ↓
fsync() flushes buffers
    ↓
Hope the disk cache flushed too (often doesn't!)
```

**ZFS:**
```
Application writes data with O_DSYNC
    ↓
ZFS checksums the data
    ↓
ZFS issues BIO_FLUSH
    ↓
Data is on physical media (guaranteed)
    ↓
Corruption detected on read (checksums)
```

### The UFS Durability Problem

**Critical finding**: FreeBSD UFS does NOT flush disk write cache on fsync/O_DSYNC.

From Thomas Munro (PostgreSQL + FreeBSD kernel contributor):

> "UFS specifically does not issue a volatile drive cache flush as part of fsync()... There is no workaround to get powersafe durability, other than using ZFS."

| Filesystem | fsync/O_DSYNC Behavior | Power-Safe |
|------------|------------------------|------------|
| FreeBSD ZFS | Issues BIO_FLUSH | ✅ Yes |
| FreeBSD UFS | Buffer cache only | ❌ No |
| Linux ext4/XFS | Issues FLUSH/FUA | ✅ Yes |

**For any serious database workload on FreeBSD, ZFS is mandatory.**

### ZFS 2.3.0: The O_DIRECT Gap Is Closed

Previously, ZFS ignored O_DIRECT and routed everything through the ARC (Adaptive Replacement Cache). This caused:
- Double caching (database buffer pool + ARC)
- Extra memory copies
- ARC thrashing under pressure

**OpenZFS 2.3.0 (January 2025) adds true O_DIRECT support:**

```bash
# Enable Direct I/O for database dataset
zfs set direct=standard poolname/database
```

| Property Value | Behavior |
|----------------|----------|
| `disabled` | Ignores O_DIRECT (old behavior) |
| `standard` | Honors O_DIRECT with alignment requirements |
| `always` | Treats all I/O as direct |

**Now ZFS + O_DIRECT + O_DSYNC provides:**
- Bypass ARC (no double caching)
- Guaranteed durability (BIO_FLUSH)
- Checksums (data integrity)
- Compression (storage efficiency)
- Snapshots (instant backups)

---

## Part 5: PostgreSQL Validates This Architecture

### The PostgreSQL AIO Project

PostgreSQL is implementing async I/O with multiple backends:

```c
io_method = {
    worker,      // Thread pool fallback (all platforms)
    io_uring,    // Linux 5.1+
    posix_aio,   // FreeBSD ← Same architecture we're discussing
    windows_iocp // Windows
}
```

**Key contributors:**
- Andres Freund (Microsoft, started the project)
- Thomas Munro (Microsoft, FreeBSD kernel committer, posix_aio backend author)

### Status (PostgreSQL 18, Beta 2025)

| Feature | Status |
|---------|--------|
| Async reads | ✅ Implemented |
| Async writes | 🔄 Future work |
| FreeBSD posix_aio | ✅ Implemented |
| Direct I/O option | ✅ Implemented |

### Thomas Munro's FreeBSD Work

Munro has extensively documented FreeBSD AIO characteristics:
- https://wiki.postgresql.org/wiki/FreeBSD/AIO
- BSDCan 2022: "AIO & DIO for PostgreSQL on FreeBSD"

His findings align with our analysis:
- ZFS required for durability
- O_DSYNC works correctly on ZFS
- AIO provides true async (not thread pool)
- kqueue integration works well

**PostgreSQL's investment in this architecture validates its viability.**

---

## Part 6: Production Deployments

### Who Uses FreeBSD in Production?

**Netflix (Content Delivery):**
- Serves ~30% of North American internet traffic
- Custom FreeBSD on Open Connect Appliances
- Contributes extensively to FreeBSD kernel

> "We are one of the biggest sources of traffic on the internet – sending terabits per second, powered by thousands of servers, all running FreeBSD."
> — Gleb Smirnoff, Netflix

**WhatsApp (Messaging):**
- 2 million concurrent TCP connections per server
- FreeBSD + Erlang architecture
- Jan Koum donated $1.5M to FreeBSD Foundation

**Sony PlayStation:**
- PS3, PS4, PS5 all run FreeBSD-derived OS
- Stability and licensing advantages

**Juniper Networks:**
- JunOS (routers, switches) is FreeBSD-based
- Network equipment demands reliability

**Financial Institutions:**
- Often not publicized (competitive advantage)
- Stability and security prioritized over features

### PostgreSQL on FreeBSD + ZFS

This combination exists in production:
- Financial services (stability requirements)
- Organizations with ZFS investments
- Security-conscious deployments

---

## Part 7: Practical Implementation

### For Database Developers

**Porting from io_uring to FreeBSD AIO:**

```
io_uring concept        →  FreeBSD equivalent
─────────────────────────────────────────────────
io_uring_queue_init()   →  kqueue()
io_uring_prep_read()    →  aio_read() with SIGEV_KEVENT
io_uring_prep_write()   →  aio_write() with SIGEV_KEVENT
io_uring_submit()       →  (implicit on aio_read/write)
io_uring_wait_cqe()     →  kevent()
cqe->res                →  aio_return()
```

**Key differences:**
- io_uring can batch submissions; AIO submits individually
- io_uring has ~0 syscalls (SQPOLL); AIO has 2-3 per I/O
- io_uring is Linux-only; AIO is POSIX (portable)

### For System Architects

**Recommended configuration:**

```bash
# ZFS pool for database
zpool create dbpool mirror /dev/nvd0 /dev/nvd1

# Dataset with optimal settings
zfs create dbpool/data
zfs set direct=standard dbpool/data    # Enable O_DIRECT (ZFS 2.3+)
zfs set compression=lz4 dbpool/data    # Efficient compression
zfs set atime=off dbpool/data          # Disable access time updates
zfs set recordsize=64k dbpool/data     # Match database block size

# Kernel tuning
sysctl kern.ipc.shm_use_phys=1         # Wire shared memory
sysctl kern.aio_max=2048               # Increase AIO limits
sysctl kern.aio_max_ops_per_proc=256
```

**Application opens files with:**
```c
open(path, O_RDWR | O_DIRECT | O_DSYNC);
```

### For Security Teams

**Comparison checklist:**

| Concern | io_uring | FreeBSD AIO |
|---------|----------|-------------|
| Seccomp bypass | ⚠️ Yes | ✅ No |
| Kernel attack surface | ⚠️ Large | ✅ Small |
| CVE history | ⚠️ Frequent | ✅ Rare |
| Disabled in containers | ⚠️ Often | ✅ No |
| Audit trail | ⚠️ Complex | ✅ Standard syscalls |

---

## Part 8: Trade-offs and Limitations

### Where io_uring Still Wins

| Aspect | io_uring | FreeBSD AIO |
|--------|----------|-------------|
| Syscall overhead | Lower (batching, SQPOLL) | Higher (~2-3 per I/O) |
| Network + disk unified | Yes | Separate (kqueue + AIO) |
| Feature breadth | 30+ operations | 5 operations |
| Raw throughput (best case) | Higher | Slightly lower |

**For pure performance benchmarks, io_uring wins.** But benchmarks don't capture:
- Security incident response costs
- Compliance requirements
- Long-term maintenance burden

### Known Limitations of FreeBSD AIO

1. **UFS is not suitable** — ZFS mandatory for durability
2. **Higher syscall count** — ~2-3 syscalls per I/O vs ~0 for io_uring SQPOLL
3. **No scatter/gather for O_DIRECT** — single buffer per operation
4. **Smaller ecosystem** — fewer examples, less documentation

### When to Choose Which

**Choose io_uring if:**
- Maximum performance is the only priority
- Security team accepts the risk
- Container/seccomp restrictions don't apply
- Linux-only deployment is acceptable

**Choose FreeBSD AIO if:**
- Security is a primary concern
- Running in restricted environments (containers, etc.)
- ZFS features are valuable (checksums, snapshots)
- Long-term stability preferred over cutting-edge features
- Compliance or audit requirements exist

---

## Part 9: The Bigger Picture

### Why This Matters Beyond Databases

Any system using io_uring faces the same security trade-off:
- Web servers (nginx has io_uring support)
- Message queues
- Storage systems
- Any high-performance I/O application

**The FreeBSD AIO architecture applies broadly** — it's not database-specific.

### The Path Forward

1. **Awareness** — Developers should know alternatives exist
2. **Abstraction** — Build I/O layers that support multiple backends
3. **Testing** — Validate FreeBSD AIO performance for your workload
4. **Deployment options** — Give users choice, don't lock into io_uring

### Contributing

If this architecture interests you:

- **PostgreSQL** is actively working on posix_aio — contributions welcome
- **FreeBSD** kernel improvements benefit everyone
- **Your project** could add a FreeBSD backend

---

## Conclusion

io_uring is a remarkable piece of engineering, but its security track record gives pause. For organizations that can't accept that risk — or have it blocked by security policy — **FreeBSD AIO + kqueue + ZFS provides a mature, secure alternative**.

The architecture is:
- **Sound** — Completion-based async I/O, same model as io_uring
- **Proven** — 25+ years of AIO, production use at Netflix/WhatsApp scale
- **Validated** — PostgreSQL is implementing the same approach
- **Complete** — ZFS 2.3 closes the O_DIRECT gap

The question isn't "Linux vs BSD" — it's "what are your actual requirements?"

For security-conscious deployments, financial systems, healthcare, government, or anywhere io_uring is blocked: **there is an alternative, and it works.**

---

## References

### Primary Sources
- [PostgreSQL AIO Wiki](https://wiki.postgresql.org/wiki/AIO)
- [Thomas Munro's FreeBSD/AIO Notes](https://wiki.postgresql.org/wiki/FreeBSD/AIO)
- [OpenZFS 2.3.0 Release Notes](https://github.com/openzfs/zfs/releases/tag/zfs-2.3.0)
- [OpenZFS Direct I/O PR #10018](https://github.com/openzfs/zfs/pull/10018)

### Security References
- [Google's io_uring Security Concerns](https://security.googleblog.com/)
- [Docker io_uring Restrictions](https://docs.docker.com/engine/security/)
- [FreeBSD Phabricator D36371 (UFS fsync)](https://reviews.freebsd.org/D36371)

### Conference Talks
- BSDCan 2022: "AIO & DIO for PostgreSQL on FreeBSD" — Thomas Munro
- FOSDEM 2019: "Asynchronous IO for PostgreSQL" — Andres Freund
- FreeBSD Vendor Summit 2023: "Netflix and FreeBSD" — Gleb Smirnoff

### Production Case Studies
- [Netflix FreeBSD Case Study](https://freebsdfoundation.org/netflix-case-study/)
- [FreeBSD Foundation End User Stories](https://freebsdfoundation.org/end-user-stories/)

---

## About This Document

This analysis emerged from a deep-dive into porting TigerBeetle (a financial transactions database) from Linux io_uring to FreeBSD. The findings apply broadly to any system requiring high-performance async I/O.

**Feedback welcome** — this is intended to start a conversation, not end one.

---

*Document version: 1.0*
*Last updated: January 2025*
