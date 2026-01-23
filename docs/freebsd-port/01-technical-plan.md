# Technical Plan: FreeBSD Port

## Architecture

```
TigerBeetle I/O Layer
├── src/io/linux.zig    → io_uring (2078 lines) - async but ZFS/security issues
├── src/io/darwin.zig   → kqueue   (1073 lines) - blocking disk I/O
├── src/io/windows.zig  → IOCP     (1578 lines)
├── src/io/freebsd.zig  → kqueue + AIO (~1200 lines) ← NEW - TRUE async!
└── src/io/common.zig   → shared POSIX code
```

## FreeBSD Native AIO: The Best of Both Worlds

Unlike darwin.zig (which uses blocking pread/pwrite for disk I/O) and linux.zig
(which uses io_uring with known ZFS/security issues), FreeBSD's port uses
native POSIX AIO:

| Platform | Disk I/O | Network I/O | ZFS Safe | Truly Async |
|----------|----------|-------------|----------|-------------|
| Linux (io_uring) | io_uring | io_uring | ❌ | ✅ |
| Linux (sync mode) | pread/pwrite | io_uring | ✅ | ❌ |
| macOS | pread/pwrite | kqueue | N/A | ❌ |
| **FreeBSD** | **aio_read/write** | **kqueue** | **✅** | **✅** |

### How FreeBSD AIO Works

```zig
// 1. Submit async read - returns immediately
aio_read(&aiocb);

// 2. Register for kqueue notification
kevent(kq, &[_]Kevent{.{
    .ident = @intFromPtr(&aiocb),
    .filter = EVFILT_AIO,  // AIO completion filter
    .flags = EV_ADD | EV_ONESHOT,
}}, ...);

// 3. kqueue wakes us when I/O completes
// 4. Get result with aio_return(&aiocb)
```

Key advantage: The event loop never blocks on disk I/O. Network and disk
operations are truly concurrent.

## Files to Create/Modify

### 1. `src/io/freebsd.zig` (NEW) - IMPLEMENTED

Based on `darwin.zig` architecture but with TRUE async disk I/O via AIO:

| Feature | macOS (darwin.zig) | FreeBSD | Change |
|---------|-------------------|---------|--------|
| **Disk Read** | `pread()` - BLOCKING | `aio_read()` + EVFILT_AIO | TRUE async! |
| **Disk Write** | `pwrite()` - BLOCKING | `aio_write()` + EVFILT_AIO | TRUE async! |
| Direct I/O | `F_NOCACHE` fcntl | `O_DIRECT` flag | Use flag in open() |
| fsync | `F_FULLFSYNC` (fsync lies on macOS) | `fsync()` works correctly | Simpler code |
| Preallocation | `F_PREALLOCATE` fcntl | `posix_fallocate()` | Replace ~40 lines |
| SIGPIPE | `SO_NOSIGPIPE` | `SO_NOSIGPIPE` | No change |
| CLOEXEC | fcntl workaround | `SOCK_CLOEXEC` works | Can simplify |

#### AIO C Bindings Added

```zig
const c = struct {
    const aiocb = extern struct {
        aio_fildes: c_int,
        aio_offset: i64,
        aio_buf: ?*anyopaque,
        aio_nbytes: usize,
        aio_sigevent: sigevent,
        // ... other fields
    };

    extern "c" fn aio_read(aiocb: *aiocb) c_int;
    extern "c" fn aio_write(aiocb: *aiocb) c_int;
    extern "c" fn aio_error(aiocb: *const aiocb) c_int;
    extern "c" fn aio_return(aiocb: *aiocb) isize;
};

const EVFILT_AIO: i16 = -3;  // kqueue filter for AIO completion
```

### 2. `build.zig`

Add targets:
```zig
.x86_64_freebsd,
.aarch64_freebsd,
```

### 3. `src/io.zig` (if exists, or equivalent dispatcher)

Add FreeBSD to platform detection:
```zig
const builtin = @import("builtin");

pub const IO = switch (builtin.os.tag) {
    .linux => @import("io/linux.zig").IO,
    .macos => @import("io/darwin.zig").IO,
    .windows => @import("io/windows.zig").IO,
    .freebsd => @import("io/freebsd.zig").IO,  // NEW
    else => @compileError("unsupported OS"),
};
```

## Key Code Changes in freebsd.zig

### 1. Async Disk I/O via AIO (MAJOR CHANGE)

**darwin.zig**: Disk operations block the event loop
```zig
// In do_operation callback - runs synchronously in event loop!
fn do_operation(op: anytype) ReadError!usize {
    return posix.pread(op.fd, op.buf[0..op.len], op.offset);
}
```

**freebsd.zig**: TRUE async with AIO + EVFILT_AIO
```zig
pub fn read(self: *IO, ...) void {
    // Set up AIO control block
    aiocb_ptr.aio_sigevent.sigev_notify = c.SIGEV_KEVENT;  // Notify via kqueue

    // Submit async read - returns immediately
    _ = c.aio_read(aiocb_ptr);

    // Register with kqueue for completion
    kevent(kq, &[_]Kevent{.{
        .ident = @intFromPtr(aiocb_ptr),
        .filter = EVFILT_AIO,
        .udata = @intFromPtr(completion),
    }}, ...);

    self.aio_pending.push(completion);
    self.io_inflight += 1;
}

fn handle_aio_completion(self: *IO, completion: *Completion) void {
    const bytes_read = c.aio_return(aiocb_ptr);
    // ... invoke callback with result
}
```

### 2. Direct I/O (O_DIRECT instead of F_NOCACHE)

**darwin.zig** (lines 944-948):
```zig
// On darwin assume that Direct I/O is always supported.
// Use F_NOCACHE to disable the page cache as O_DIRECT doesn't exist.
if (direct_io != .direct_io_disabled) {
    _ = try posix.fcntl(fd, posix.F.NOCACHE, 1);
}
```

**freebsd.zig** (replacement):
```zig
// FreeBSD supports O_DIRECT natively
// Set in open flags instead of fcntl
```

And in `open_data_file`, add to flags:
```zig
if (direct_io != .direct_io_disabled) {
    flags.DIRECT = true;  // FreeBSD has O_DIRECT
}
```

### 2. fsync (simpler on FreeBSD)

**darwin.zig** (lines 989-996):
```zig
/// Darwin's fsync() syscall does not flush past the disk cache. We must use F_FULLFSYNC
fn fs_sync(fd: fd_t) !void {
    _ = posix.fcntl(fd, posix.F.FULLFSYNC, 1) catch return posix.fsync(fd);
}
```

**freebsd.zig** (replacement):
```zig
/// FreeBSD's fsync() properly flushes disk caches
fn fs_sync(fd: fd_t) !void {
    return posix.fsync(fd);
}
```

### 3. File Preallocation

**darwin.zig** (lines 999-1058): Uses `F_PREALLOCATE` with `fstore_t` struct

**freebsd.zig** (replacement):
```zig
fn fs_allocate(fd: fd_t, size: u64) !void {
    log.info("allocating {}...", .{std.fmt.fmtIntSizeBin(size)});

    // FreeBSD supports posix_fallocate
    const result = std.c.posix_fallocate(fd, 0, @intCast(size));
    if (result != 0) {
        // Fallback: write to last sector
        return fallback_allocate(fd, size);
    }
}

fn fallback_allocate(fd: fd_t, size: u64) !void {
    // Write a single byte at the last position to extend the file
    const last_sector = size - constants.sector_size;
    var buf: [constants.sector_size]u8 = undefined;
    _ = try posix.pwrite(fd, &buf, last_sector);
    try posix.ftruncate(fd, size);
}
```

### 4. Socket Creation (can use SOCK_CLOEXEC)

**darwin.zig** (lines 844-845):
```zig
// Darwin doesn't support SOCK_CLOEXEC.
_ = try posix.fcntl(fd, posix.F.SETFD, posix.FD_CLOEXEC);
```

**freebsd.zig**: Can remove this and use `SOCK.CLOEXEC` in socket() call directly.

## Build System Changes

### build.zig additions

Find the target list and add:
```zig
const freebsd_targets = [_]std.Target.Query{
    .{ .cpu_arch = .x86_64, .os_tag = .freebsd },
    .{ .cpu_arch = .aarch64, .os_tag = .freebsd },
};
```

## Platform Detection

Find where `builtin.os.tag` is checked and add `.freebsd` cases.

Search patterns:
```
builtin.os.tag == .linux
builtin.os.tag == .macos
builtin.target.os.tag
```

## Testing Strategy

1. **Unit tests**: Run `zig build test` on FreeBSD
2. **Integration tests**: Run TigerBeetle cluster on FreeBSD
3. **Cross-platform**: Ensure Linux/macOS still work after changes

## Lines of Code (Actual)

| File | Lines | Notes |
|------|-------|-------|
| freebsd.zig (new) | ~1200 | Full AIO implementation |
| Diff from darwin.zig | ~300 lines | AIO bindings, submit_aio, async read/write |
| build.zig | ~10 lines | Added FreeBSD targets |
| Platform detection files | ~15 lines | tigerbeetle.zig, time.zig, mlock.zig, etc. |
| **Total new/changed** | ~325 lines of actual work |

## Implementation Status

- [x] AIO C bindings (aiocb, aio_read, aio_write, aio_error, aio_return)
- [x] EVFILT_AIO kqueue integration
- [x] Async read() using aio_read
- [x] Async write() using aio_write
- [x] io_inflight tracking for AIO operations
- [x] build.zig FreeBSD targets
- [x] Platform detection in all relevant files
- [ ] Test on actual FreeBSD system
- [ ] Validate AIO struct layout matches FreeBSD headers
