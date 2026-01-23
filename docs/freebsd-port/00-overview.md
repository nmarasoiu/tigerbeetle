# TigerBeetle FreeBSD Port

## Why This Exists

TigerBeetle on Linux requires io_uring. This creates two problems:

1. **io_uring + ZFS = documented issues** (hangs, deadlocks, potential corruption)
   - OpenZFS #16133: io_uring workers stuck, unkillable
   - Users on ZFS are unknowingly at risk

2. **io_uring + security = concerns**
   - 60% of Google's 2022 kernel exploit bounties targeted io_uring
   - Disabled by default in Docker 4.42.0+
   - Disabled in ChromeOS
   - Bypasses seccomp filtering

## Why FreeBSD

- **Native ZFS support** - ZFS originated from Solaris/BSD lineage
- **kqueue** - Same async I/O as macOS, which TigerBeetle already supports
- **Battle-tested** - Netflix runs FreeBSD + ZFS in production
- **Clean port** - Not a hack, just another async backend

## Scope

| Component | Status |
|-----------|--------|
| `src/io/freebsd.zig` | To create (based on darwin.zig) |
| `build.zig` | Add FreeBSD targets |
| Test suite | Run existing tests on FreeBSD |
| Failure injection | 1 month testing |

## Success Criteria

1. All existing TigerBeetle tests pass on FreeBSD
2. Runs on ZFS without io_uring issues
3. Performance within 10% of Linux/io_uring (acceptable tradeoff)
4. Survives failure injection testing

## Timeline

- **Day 1**: Code port (freebsd.zig + build.zig)
- **Week 1**: Get tests passing locally
- **Week 2-4**: GCloud FreeBSD environment + failure injection
- **Week 5**: Documentation + benchmarks
- **Week 6**: Publish results, open issue on upstream

## Repository

- Upstream: https://github.com/tigerbeetle/tigerbeetle
- Fork: (your fork)
- Branch: `freebsd-port`
