# TigerBeetle FreeBSD KVM Automation Script

## Background

TigerBeetle uses `io_uring` on Linux for high-performance async I/O. The FreeBSD port replaces this with **POSIX AIO + kqueue**, which is the native async I/O mechanism on BSD systems.

To validate the port works correctly, we need an isolated test environment that:
- Runs real FreeBSD (not emulated syscalls)
- Supports a 3-node cluster for consensus testing
- Enables chaos/fault injection (network partitions, node crashes)
- Allows quick iteration: change code → rebuild → test

This script automates the entire KVM-based FreeBSD cluster setup.

## Purpose

**One command to go from nothing to a running 3-node FreeBSD cluster ready for TigerBeetle.**

The script:
1. Downloads FreeBSD VM image
2. Creates 3 VMs with proper networking
3. Auto-configures each VM (no manual console login needed)
4. Sets up UFS storage with POSIX AIO support
5. Generates helper scripts for cluster management and chaos testing

## Requirements

| Requirement | Details |
|-------------|---------|
| **Host OS** | Debian/Ubuntu Linux with KVM support |
| **CPU** | Must support virtualization (vmx/svm) |
| **RAM** | 12GB+ free (3 VMs × 4GB each) |
| **Disk** | ~10GB for base image + 70GB per VM (OS + data disk) |
| **Packages** | Auto-installed: `qemu-kvm`, `libvirt`, `libguestfs-tools` |

## What Gets Created

```
$HOME/tigerbeetle-freebsd/
├── FreeBSD-14.3-RELEASE-amd64.qcow2    # Base image (downloaded)
├── setup-tb-freebsd-{0,1,2}.sh         # Per-VM config scripts
├── build-tigerbeetle.sh                # Zig + TB build script
├── format-cluster.sh                   # Initialize TB data files
├── start-cluster.sh                    # Launch TB on all nodes
├── stop-cluster.sh                     # Graceful shutdown
├── cluster-status.sh                   # Check VM/process state
├── chaos.sh                            # Fault injection toolkit
└── benchmark.sh                        # Performance testing

/var/lib/libvirt/images/
├── tb-freebsd-{0,1,2}.qcow2           # VM boot disks
└── tb-freebsd-{0,1,2}-data.qcow2      # UFS data disks
```

**VMs Created:**

| VM | IP | Role |
|----|-----|------|
| tb-freebsd-0 | 192.168.122.10 | Replica 0 |
| tb-freebsd-1 | 192.168.122.11 | Replica 1 |
| tb-freebsd-2 | 192.168.122.12 | Replica 2 |

## Features (Merged from Two Scripts)

### From Gemini Auto Script
- **Zero-touch VM setup** via `virt-customize` (no console login needed)
- **SSH root login** pre-configured for orchestration
- **Sentinel file** (`/root/.setup_complete`) prevents re-running setup on reboot
- **Fast boot** with `autoboot_delay="0"`
- **Connectivity wait loop** - script waits until all VMs respond to SSH
- **Auto-removes old SSH host keys** to prevent verification errors

### From Original Script
- **FreeBSD 14.3-RELEASE** (latest stable)
- **Zig 0.14.1** (latest)
- **ReleaseSafe build** (better error messages for testing)
- **Complete helper scripts** - chaos, benchmark, cluster management
- **Explicit AIO verification** - fails fast if AIO module won't load

### New in Merged Version
- Auto-deploys `build-tigerbeetle.sh` to all VMs
- Instructions for binary distribution (build once, copy to all)
- Root password (`root`) displayed in summary

## Usage

### Initial Setup (Run Once)

```bash
sudo ./tigerbeetle-freebsd-complete-merged.sh
```

This takes ~10-15 minutes (mostly downloading FreeBSD image).

### Build TigerBeetle

```bash
# Build on node 0
ssh root@192.168.122.10 './build-tigerbeetle.sh'

# Copy binary to other nodes (faster than building 3x)
ssh root@192.168.122.10 'scp /root/tigerbeetle/zig-out/bin/tigerbeetle root@192.168.122.11:/root/tigerbeetle/zig-out/bin/'
ssh root@192.168.122.10 'scp /root/tigerbeetle/zig-out/bin/tigerbeetle root@192.168.122.12:/root/tigerbeetle/zig-out/bin/'
```

### Start Cluster

```bash
cd ~/tigerbeetle-freebsd
./format-cluster.sh    # One-time: creates data files
./start-cluster.sh     # Starts TB on all nodes
./cluster-status.sh    # Verify everything is running
```

### Development Workflow (Iterate on Fixes)

```bash
# 1. Make changes to FreeBSD port code locally
# 2. Push to your fork
git push origin freebsd-port

# 3. Rebuild on VM (pulls latest, rebuilds)
ssh root@192.168.122.10 'cd /root/tigerbeetle && git pull && zig build -Doptimize=ReleaseSafe'

# 4. Restart cluster
./stop-cluster.sh
./start-cluster.sh

# 5. Run tests
./benchmark.sh
# or run vortex/other tests
```

### Chaos Testing

```bash
./chaos.sh status              # Show cluster state

# VM-level faults
./chaos.sh kill 0              # Hard crash node 0
./chaos.sh start 0             # Bring it back
./chaos.sh suspend 1           # Freeze node 1 (simulates hang)
./chaos.sh resume 1            # Unfreeze

# Network faults (host-side, affects all traffic)
./chaos.sh partition 2         # Isolate node 2 from cluster
./chaos.sh heal                # Restore connectivity
./chaos.sh latency 100         # Add 100ms to all VM traffic
./chaos.sh loss 5              # 5% packet loss
./chaos.sh reset-network       # Remove all network chaos

# Network faults (in-VM via dummynet)
./chaos.sh vm-latency 0 50     # 50ms latency inside node 0 only
./chaos.sh vm-loss 1 10        # 10% loss inside node 1 only
./chaos.sh vm-reset 0          # Clear node 0's network config
```

## Configuration

Edit these variables at the top of the script:

```bash
FREEBSD_VERSION="14.3-RELEASE"     # FreeBSD version
VM_RAM_MB=4096                      # RAM per VM
VM_VCPUS=2                          # CPUs per VM
VM_DISK_SIZE="20G"                  # OS disk
VM_DATA_DISK_SIZE="50G"             # TigerBeetle data disk

TB_FORK_URL="https://github.com/nmarasoiu/tigerbeetle.git"
TB_BRANCH="freebsd-port"
```

## Troubleshooting

### VM won't start
```bash
virsh list --all                    # Check VM state
virsh start tb-freebsd-0            # Manual start
virsh console tb-freebsd-0          # Attach console (Ctrl+] to exit)
```

### SSH connection refused
```bash
# VMs take ~2 min to fully boot on first run
# Check if setup is complete:
ssh root@192.168.122.10 'cat /root/.setup_complete'
```

### AIO module not loaded
```bash
ssh root@192.168.122.10 'kldstat | grep aio'
# If missing:
ssh root@192.168.122.10 'kldload aio'
```

### TigerBeetle won't start
```bash
# Check logs
ssh root@192.168.122.10 'cat /var/log/tigerbeetle.log'

# Verify data file exists
ssh root@192.168.122.10 'ls -la /tbdata/tigerbeetle/data/'
```

### Clean slate (destroy everything)
```bash
for vm in tb-freebsd-0 tb-freebsd-1 tb-freebsd-2; do
    virsh destroy $vm 2>/dev/null
    virsh undefine $vm 2>/dev/null
done
rm -rf /var/lib/libvirt/images/tb-freebsd-*
rm -rf ~/tigerbeetle-freebsd
```

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                     Linux Host (Debian/Ubuntu)              │
│                                                             │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐         │
│  │ tb-freebsd-0│  │ tb-freebsd-1│  │ tb-freebsd-2│         │
│  │ .122.10     │  │ .122.11     │  │ .122.12     │         │
│  │             │  │             │  │             │         │
│  │ FreeBSD 14.3│  │ FreeBSD 14.3│  │ FreeBSD 14.3│         │
│  │ UFS + AIO   │  │ UFS + AIO   │  │ UFS + AIO   │         │
│  │ TigerBeetle │  │ TigerBeetle │  │ TigerBeetle │         │
│  │ (replica 0) │  │ (replica 1) │  │ (replica 2) │         │
│  └──────┬──────┘  └──────┬──────┘  └──────┬──────┘         │
│         │                │                │                 │
│         └────────────────┼────────────────┘                 │
│                          │                                  │
│                    virbr0 (NAT)                             │
│                   192.168.122.0/24                          │
└─────────────────────────────────────────────────────────────┘
```

## Why UFS (not ZFS)?

- **Simpler**: No pool/vdev complexity
- **Lower overhead**: Less RAM, faster for small VMs
- **Better AIO integration**: ZFS has its own async layer that can interfere
- **Sufficient**: TigerBeetle manages its own data integrity

The script uses UFS with:
- **Soft Updates** (`-U`): Async metadata for performance
- **Journaling** (`-j`): Fast fsck after crashes
- **noatime**: Reduces unnecessary writes
