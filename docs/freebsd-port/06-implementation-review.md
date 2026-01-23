# FreeBSD Port Implementation Review

## Context

This document is a handoff for AI review of the TigerBeetle FreeBSD port implementation.

**Repository**: TigerBeetle database (high-performance financial ledger)
**Branch**: `zfs-sync-storage-compatibility`
**Goal**: Port TigerBeetle to FreeBSD with TRUE async disk I/O using native AIO

### Why FreeBSD?

1. **Linux io_uring issues**:
   - ZFS + io_uring has documented hangs and potential data corruption (OpenZFS #16133)
   - Security concerns (60% of 2022 kernel exploits targeted io_uring)
   - Disabled by default in Docker/container environments

2. **macOS limitation**:
   - darwin.zig uses **blocking** pread/pwrite for disk I/O
   - kqueue only used for network operations

3. **FreeBSD advantage**:
   - Native POSIX AIO (aio_read/aio_write) with kqueue integration (EVFILT_AIO)
   - TRUE async disk I/O without io_uring's issues
   - ZFS is native and well-tested

## Implementation Summary

### Core File: `src/io/freebsd.zig`

Implements async I/O using:
- **Network**: kqueue (same as darwin.zig)
- **Disk**: FreeBSD native AIO with SIGEV_KEVENT notification

### Key Components

1. **AIO C Bindings** (lines 23-88):
   - `sigevent` struct for kqueue notification
   - `aiocb` struct (AIO Control Block)
   - External function declarations: `aio_read`, `aio_write`, `aio_error`, `aio_return`

2. **EVFILT_AIO Integration** (lines 183-227):
   - Event loop checks for `filter == EVFILT_AIO`
   - Routes completions to `handle_aio_completion()`

3. **Async read()** (lines 641-738):
   - Uses `aio_read()` instead of blocking `pread()`
   - SIGEV_KEVENT delivers completion to kqueue

4. **Async write()** (lines 870-965):
   - Uses `aio_write()` instead of blocking `pwrite()`
   - Includes synchronous fsync after write (noted for future improvement)

## Struct Verification

Verified against FreeBSD 16.0-CURRENT source (`/Users/nicolaremarasoiu/open/os/freebsd-src`).

### aiocb (from sys/sys/aio.h lines 106-117)

| Field | FreeBSD C | Our Zig | Match |
|-------|-----------|---------|-------|
| aio_fildes | `int` | `c_int` | YES |
| aio_offset | `off_t` | `i64` | YES |
| aio_buf | `volatile void*` | `?*anyopaque` | YES |
| aio_nbytes | `size_t` | `usize` | YES |
| __spare__ | `int[2]` | `[2]c_int` | YES |
| __spare2__ | `void*` | `?*anyopaque` | YES |
| aio_lio_opcode | `int` | `c_int` | YES |
| aio_reqprio | `int` | `c_int` | YES |
| _aiocb_private | struct{long,long,void*} | extern struct | YES |
| aio_sigevent | `struct sigevent` | `sigevent` | YES |

### sigevent (from sys/sys/signal.h lines 173-186)

| Field | FreeBSD C | Our Zig | Match |
|-------|-----------|---------|-------|
| sigev_notify | `int` | `c_int` | YES |
| sigev_signo | `int` | `c_int` (named sigev_notify_kqueue) | YES |
| sigev_value | `union sigval` | extern union{sival_int,sival_ptr} | YES |
| _sigev_un._threadid | `__lwpid_t` (int32_t) | `i32` | YES (fixed) |
| _sigev_un._kevent_flags | `unsigned short` | `c_ushort` | YES |
| _sigev_un.__spare__ | `long[8]` | `[8]c_long` | YES |

### Constants Verified

- `SIGEV_KEVENT = 3` (from signal.h line 200)
- `EVFILT_AIO = -3` (standard kqueue filter)

## Bugs Found and Fixed

### 1. AIO Submit Failure Handling
**Problem**: When `submit_aio()` failed, completion was pushed to queue but callback would call `aio_error()` on unsubmitted aiocb (undefined behavior).

**Fix**: Added `submit_failed` flag to aio_read/aio_write operation structs. Callback checks flag before calling AIO functions.

### 2. handle_aio_completion EINPROGRESS Case
**Problem**: If `aio_error()` returned EINPROGRESS after EVFILT_AIO fired, code returned early after removing from `aio_pending` but never pushed to `completed` - completion lost.

**Fix**: Changed to `@panic()` since this condition should never occur (EVFILT_AIO only fires on completion). If it happens, something is fundamentally broken.

### 3. sigevent._threadid Type
**Problem**: Was `c_long` (64-bit on amd64), should be `i32` (`__lwpid_t` is `int32_t` on FreeBSD).

**Fix**: Changed to `i32`.

## Files Modified

| File | Changes |
|------|---------|
| `src/io/freebsd.zig` | NEW - Full AIO implementation (~1400 lines with tests) |
| `src/io.zig` | Added FreeBSD backend selection |
| `build.zig` | Added FreeBSD targets (x86_64, aarch64) |
| `src/tigerbeetle.zig` | Added FreeBSD to platform check |
| `src/time.zig` | Added FreeBSD monotonic clock |
| `src/stdx/mlock.zig` | Added FreeBSD mlockall |
| `src/multiversion.zig` | Added FreeBSD support |
| `src/repl/terminal.zig` | Added FreeBSD terminal handling |
| `src/clients/java/src/jni_thread_cleaner.zig` | Added FreeBSD to pthread TLS |

## Tests Added

In `src/io/freebsd.zig` (bottom of file):

1. **Struct size tests** - Verify sigevent/aiocb have non-zero size
2. **SIGEV constants test** - Verify SIGEV_NONE/SIGNAL/THREAD/KEVENT values
3. **EVFILT_AIO test** - Verify filter value is -3
4. **IO init/deinit test** - Works on macOS too (kqueue)
5. **Timeout test** - Works on macOS too
6. **Operation union test** - Compile-time verification
7. **AIO read/write test** - FreeBSD only, tests actual file I/O

## What Remains

1. **Build and test on actual FreeBSD**
   - Requires Zig 0.14.1 (TigerBeetle's required version)
   - Run: `zig build test` to run unit tests
   - Run full test suite

2. **Verify struct sizes match at runtime**
   - Add `@sizeOf` checks against expected values
   - May need adjustment for 32-bit FreeBSD (if supported)

3. **Performance testing**
   - Compare AIO vs blocking I/O throughput
   - Test under load with concurrent operations

4. **Chaos testing (Vortex)**
   - Vortex is Linux-only (uses namespaces)
   - See `docs/freebsd-port/05-vortex-kvm.md` for KVM-based approach

## Build Requirements

- **Zig**: 0.14.1 (exact version required by TigerBeetle)
- **FreeBSD**: 13.x or 14.x recommended (AIO structs stable since 5.x)
- **Target triples**: `x86_64-freebsd`, `aarch64-freebsd`

## How to Test

```bash
# On FreeBSD with Zig 0.14.1:
cd /path/to/tigerbeetle
zig build test

# Or cross-compile from Linux/macOS:
zig build -Dtarget=x86_64-freebsd
```

## Architecture Diagram

```
TigerBeetle on FreeBSD

┌─────────────────────────────────────────────────┐
│  Storage Layer (storage.zig)                    │
│  - Uses IO.read() / IO.write()                  │
└─────────────────┬───────────────────────────────┘
                  │
┌─────────────────▼───────────────────────────────┐
│  IO Layer (io/freebsd.zig)                      │
│                                                 │
│  Network I/O          │  Disk I/O               │
│  ─────────────        │  ────────               │
│  kqueue              │  aio_read/aio_write     │
│  EVFILT_READ/WRITE    │  EVFILT_AIO             │
│  (non-blocking)       │  (TRUE async!)          │
│                                                 │
│  ┌───────────────────────────────────────────┐  │
│  │  kqueue event loop (flush())              │  │
│  │  - Handles both network and AIO events    │  │
│  │  - SIGEV_KEVENT delivers AIO completions  │  │
│  └───────────────────────────────────────────┘  │
└─────────────────────────────────────────────────┘
```

## Questions for Reviewer

1. Should we add more specific errno mapping (like darwin.zig) instead of generic AioError?
2. Is the synchronous fsync in write callback acceptable, or should we implement aio_fsync?
3. Any concerns about the SIGEV_KEVENT approach vs explicit kevent registration?

## References

- FreeBSD aio(4) man page
- FreeBSD kqueue(2) man page
- FreeBSD source: `sys/sys/aio.h`, `sys/sys/signal.h`
- OpenZFS issue #16133 (io_uring compatibility)
