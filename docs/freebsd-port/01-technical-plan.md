# Technical Plan: FreeBSD Port

## Architecture

```
TigerBeetle I/O Layer
├── src/io/linux.zig    → io_uring (2078 lines)
├── src/io/darwin.zig   → kqueue   (1073 lines)  ← BASE FOR PORT
├── src/io/windows.zig  → IOCP     (1578 lines)
├── src/io/freebsd.zig  → kqueue   (~1100 lines) ← NEW
└── src/io/common.zig   → shared POSIX code
```

## Files to Create/Modify

### 1. `src/io/freebsd.zig` (NEW)

Copy from `darwin.zig` with these changes:

| Feature | macOS (darwin.zig) | FreeBSD | Change |
|---------|-------------------|---------|--------|
| Direct I/O | `F_NOCACHE` fcntl | `O_DIRECT` flag | Use flag in open() |
| fsync | `F_FULLFSYNC` (fsync lies on macOS) | `fsync()` works correctly | Simpler code |
| Preallocation | `F_PREALLOCATE` fcntl | `posix_fallocate()` | Replace ~40 lines |
| SIGPIPE | `SO_NOSIGPIPE` | `SO_NOSIGPIPE` | No change |
| CLOEXEC | fcntl workaround | `SOCK_CLOEXEC` works | Can simplify |

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

### 1. Direct I/O (O_DIRECT instead of F_NOCACHE)

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

## Estimated Lines of Code

| File | Lines Changed |
|------|---------------|
| freebsd.zig (new) | ~1100 (mostly copy) |
| Actual diff from darwin.zig | ~100 lines |
| build.zig | ~20 lines |
| Platform detection | ~10 lines |
| **Total new/changed** | ~130 lines of actual work |
