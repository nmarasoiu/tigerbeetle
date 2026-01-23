# Testing Plan: Failure Injection on FreeBSD + ZFS

## Testing Environment

### Cloud: Google Cloud Platform (GCP)

FreeBSD on GCP options:
1. **Marketplace image**: `freebsd-cloud/freebsd-14` (official)
2. **Custom image**: Upload FreeBSD 14.1 ISO if needed

### VM Configuration

```
3x VMs for TigerBeetle cluster (replication factor 3)
- Machine type: n2-standard-4 (4 vCPU, 16 GB RAM)
- Boot disk: 20 GB (FreeBSD 14)
- Data disk: 100 GB SSD (for ZFS pool)
- Network: VPC with internal IPs

1x VM for test driver / chaos injection
- Machine type: n2-standard-2
- Can be Linux (easier tooling)
```

### ZFS Setup on Each Node

```bash
# Create ZFS pool on data disk
zpool create tbdata /dev/da1

# Create dataset for TigerBeetle
zfs create tbdata/tigerbeetle
zfs set compression=lz4 tbdata/tigerbeetle
zfs set atime=off tbdata/tigerbeetle
zfs set recordsize=64k tbdata/tigerbeetle

# TigerBeetle data directory
mkdir /tbdata/tigerbeetle/data
```

## Failure Injection Tools

### 1. Network Failures: dummynet (FreeBSD native)

FreeBSD has **dummynet** (ipfw) built-in - equivalent to Linux tc.

```bash
# Enable ipfw
kldload dummynet

# Add latency (100ms) to traffic on port 3001 (TigerBeetle)
ipfw add pipe 1 ip from any to any dst-port 3001
ipfw pipe 1 config delay 100ms

# Add packet loss (5%)
ipfw pipe 1 config plr 0.05

# Add bandwidth limit (1 Mbit/s)
ipfw pipe 1 config bw 1Mbit/s

# Remove rules
ipfw delete 1
ipfw pipe 1 delete
```

### 2. Network Partitions

```bash
# Block traffic between node1 and node2
ipfw add 100 deny ip from 10.0.0.2 to 10.0.0.1
ipfw add 100 deny ip from 10.0.0.1 to 10.0.0.2

# Restore
ipfw delete 100
```

### 3. Process Crashes

```bash
# Find TigerBeetle process
pgrep tigerbeetle

# Kill with SIGKILL (simulate crash)
kill -9 $(pgrep tigerbeetle)

# Kill with SIGTERM (graceful)
kill -15 $(pgrep tigerbeetle)
```

### 4. Disk/ZFS Failures

```bash
# Simulate slow disk (dummynet on block device - limited)
# Better: Use ZFS features

# Take disk offline (simulates disk failure)
zpool offline tbdata /dev/da1

# Bring back online
zpool online tbdata /dev/da1

# Simulate corruption (DANGEROUS - test only)
# Write garbage to a specific offset
dd if=/dev/random of=/dev/da1 bs=4k count=1 seek=1000 conv=notrunc

# ZFS should detect and report corruption
zpool scrub tbdata
zpool status tbdata
```

### 5. Power Loss Simulation

```bash
# Hard VM shutdown (from GCP console or gcloud)
gcloud compute instances stop node1 --zone=us-central1-a

# Or from inside VM (instant power off)
shutdown -p now
```

### 6. Clock Skew

```bash
# Adjust system time (requires disabling NTP first)
service ntpd stop
date -n +300  # Jump 5 minutes forward
date -n -300  # Jump 5 minutes back
```

## Test Scenarios

### Phase 1: Basic Functionality (Week 1-2)

| Test | Command | Expected |
|------|---------|----------|
| Cluster starts | `tigerbeetle start ...` | All 3 nodes healthy |
| Basic transfers | benchmark tool | Transfers succeed |
| Node restart | `kill -9` + restart | Cluster recovers |
| Unit tests | `zig build test` | All pass |

### Phase 2: Network Failures (Week 2-3)

| Test | Injection | Expected |
|------|-----------|----------|
| Latency 100ms | dummynet delay | Throughput drops, no errors |
| Latency 500ms | dummynet delay | Possible timeouts, recovery |
| Packet loss 1% | dummynet plr | Minor retry overhead |
| Packet loss 10% | dummynet plr | Significant retries, no data loss |
| Network partition (1 node) | ipfw deny | Cluster continues (2/3 quorum) |
| Network partition (2 nodes) | ipfw deny | Cluster halts, recovers when healed |

### Phase 3: Disk/ZFS Failures (Week 3-4)

| Test | Injection | Expected |
|------|-----------|----------|
| Disk offline | `zpool offline` | Node fails, cluster continues |
| Disk online | `zpool online` | Node recovers, syncs |
| Simulated corruption | dd + scrub | ZFS detects, reports |
| Full disk | Fill ZFS pool | Graceful error handling |

### Phase 4: Process Failures (Week 3-4)

| Test | Injection | Expected |
|------|-----------|----------|
| Single node crash | `kill -9` | Cluster continues |
| Single node crash + restart | kill + start | Node recovers, syncs |
| Rolling crashes | kill nodes sequentially | Cluster survives |
| All nodes crash | kill all | Cluster recovers after restart |

### Phase 5: Combined Chaos (Week 4)

| Test | Injection | Expected |
|------|-----------|----------|
| Crash during partition | kill + ipfw | Quorum maintains consistency |
| Slow disk + latency | dummynet both | Performance degrades, no errors |
| Power loss during write | `shutdown -p now` | Data integrity on recovery |

## Automation Script Structure

```
tests/
├── chaos/
│   ├── setup_cluster.sh      # GCP VM creation + TigerBeetle setup
│   ├── teardown_cluster.sh   # Cleanup
│   ├── network_chaos.sh      # dummynet injection
│   ├── process_chaos.sh      # kill/restart
│   ├── disk_chaos.sh         # ZFS failures
│   └── run_all_tests.sh      # Full test suite
├── workloads/
│   ├── steady_load.sh        # Constant transfer rate
│   ├── burst_load.sh         # Spiky traffic
│   └── verify_consistency.sh # Check account balances
└── results/
    └── (test run outputs)
```

## Success Metrics

| Metric | Target |
|--------|--------|
| Data loss | **Zero** |
| Undetected corruption | **Zero** |
| Recovery time (single node) | < 30 seconds |
| Recovery time (cluster) | < 60 seconds |
| Throughput on ZFS | > 50k TPS |
| P99 latency | < 50ms (under normal conditions) |

## Monitoring During Tests

```bash
# TigerBeetle logs
tail -f /var/log/tigerbeetle/tigerbeetle.log

# ZFS pool status
watch -n 1 'zpool status tbdata'

# System resources
top -P  # FreeBSD top with per-CPU

# Network
netstat -i 1

# dummynet stats
ipfw show
```

## GCP Cost Estimate

```
3x n2-standard-4 + 1x n2-standard-2
= 3*($0.19/hr) + 1*($0.10/hr)
= $0.67/hr
= ~$16/day
= ~$480/month (if running 24/7)

Tip: Use preemptible VMs for ~70% discount during testing
     Stop VMs when not actively testing
```
