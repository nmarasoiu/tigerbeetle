# Execution Checklist

## Phase 1: Code Port (Day 1)

### Repository Setup
- [ ] Ensure fork is synced with upstream main
- [ ] Create branch: `git checkout -b freebsd-port`
- [ ] Create docs/freebsd-port/ directory (done)

### Create freebsd.zig
- [ ] Copy darwin.zig to freebsd.zig
- [ ] Replace `F_NOCACHE` with `O_DIRECT` flag
- [ ] Replace `F_FULLFSYNC` with simple `fsync()`
- [ ] Replace `F_PREALLOCATE` with `posix_fallocate()`
- [ ] Simplify CLOEXEC (use SOCK_CLOEXEC directly)
- [ ] Update any darwin-specific comments

### Update build.zig
- [ ] Add `.freebsd` to supported OS list
- [ ] Add FreeBSD cross-compilation targets
- [ ] Test: `zig build --help` shows FreeBSD targets

### Update platform detection
- [ ] Find all `builtin.os.tag` checks
- [ ] Add `.freebsd => ...` cases
- [ ] Search for any hardcoded `.macos` or `.linux` that should include FreeBSD

### Local Build Test
- [ ] `zig build` completes without errors (cross-compile)
- [ ] Check for any compilation warnings

### Commit
- [ ] Commit with clear message
- [ ] Push to fork

## Phase 2: FreeBSD Testing (Week 1)

### Local FreeBSD VM (optional, before GCP)
- [ ] Install FreeBSD 14 in VirtualBox/VMware
- [ ] Build TigerBeetle natively
- [ ] Run unit tests: `zig build test`
- [ ] Fix any test failures

### GCP Environment
- [ ] Create GCP project (or use existing)
- [ ] Run VPC setup script
- [ ] Create 3x FreeBSD VMs
- [ ] Create 1x driver VM
- [ ] SSH access working

### ZFS Setup
- [ ] Create zpool on each node
- [ ] Create tigerbeetle dataset
- [ ] Verify ZFS settings

### TigerBeetle Build on FreeBSD
- [ ] Clone fork on each node
- [ ] Checkout freebsd-port branch
- [ ] Build succeeds
- [ ] Binary runs

### Cluster Setup
- [ ] Format replicas
- [ ] Start cluster
- [ ] Verify all nodes connected
- [ ] Basic operations work

## Phase 3: Failure Injection (Week 2-4)

### Network Tests
- [ ] Setup: dummynet loaded
- [ ] Test: 100ms latency - cluster survives
- [ ] Test: 500ms latency - timeout behavior
- [ ] Test: 1% packet loss - retries work
- [ ] Test: 10% packet loss - no data loss
- [ ] Test: Network partition (1 node isolated)
- [ ] Test: Network partition (2 nodes isolated)
- [ ] Document results

### Process Tests
- [ ] Test: Single node kill -9
- [ ] Test: Single node restart
- [ ] Test: Rolling restarts
- [ ] Test: All nodes killed, all restarted
- [ ] Document results

### Disk/ZFS Tests
- [ ] Test: zpool offline (simulate disk failure)
- [ ] Test: zpool online (disk recovery)
- [ ] Test: ZFS scrub detects no corruption after tests
- [ ] Test: Full disk scenario
- [ ] Document results

### Combined Chaos
- [ ] Test: Kill during partition
- [ ] Test: Slow disk + network latency
- [ ] Test: Power loss simulation
- [ ] Document results

## Phase 4: Benchmarks (Week 5)

### Performance Tests
- [ ] Measure throughput (transfers/second)
- [ ] Measure latency (P50, P95, P99)
- [ ] Compare to Linux/io_uring baseline (if available)
- [ ] Test under various ZFS configurations

### Document Results
- [ ] Create benchmark report
- [ ] Include methodology
- [ ] Include hardware specs
- [ ] Include ZFS configuration

## Phase 5: Documentation & Release (Week 6)

### Documentation
- [ ] Update README with FreeBSD instructions
- [ ] Document ZFS recommendations
- [ ] Document known limitations
- [ ] Create troubleshooting guide

### Publish
- [ ] Clean up commit history (if needed)
- [ ] Write release notes
- [ ] Open issue on upstream tigerbeetle/tigerbeetle
- [ ] Link to fork with benchmarks
- [ ] Share on relevant forums (FreeBSD, ZFS communities)

## Quick Commands Reference

```bash
# Git
git checkout -b freebsd-port
git add -A && git commit -m "Add FreeBSD support"
git push origin freebsd-port

# Build
zig build
zig build test

# GCP
gcloud compute instances list
gcloud compute ssh tb-node-1 --zone=us-central1-a

# FreeBSD chaos
sudo ipfw add pipe 1 ip from any to any dst-port 3001
sudo ipfw pipe 1 config delay 100ms
sudo ipfw delete 1

# ZFS
zpool status tbdata
zfs list
```
