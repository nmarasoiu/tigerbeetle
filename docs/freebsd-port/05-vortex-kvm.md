# Running Vortex with KVM-hosted FreeBSD TigerBeetle

## Overview

This document describes how to run Vortex's chaos testing on a Linux host while
the TigerBeetle replicas run inside KVM virtual machines (e.g., FreeBSD VMs).

## Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│ Linux Host                                                          │
│                                                                     │
│  ┌─────────────────┐                                                │
│  │ Vortex          │                                                │
│  │ Supervisor      │                                                │
│  │                 │    ┌──────────────────────────────────────┐    │
│  │  ┌───────────┐  │    │ virbr0 (192.168.122.0/24)            │    │
│  │  │ Network   │──┼────┤                                      │    │
│  │  │ Proxy 0   │  │    │  ┌─────────┐ ┌─────────┐ ┌─────────┐ │    │
│  │  ├───────────┤  │    │  │ VM 0    │ │ VM 1    │ │ VM 2    │ │    │
│  │  │ Network   │──┼────┤  │ FreeBSD │ │ FreeBSD │ │ FreeBSD │ │    │
│  │  │ Proxy 1   │  │    │  │ .10     │ │ .11     │ │ .12     │ │    │
│  │  ├───────────┤  │    │  │         │ │         │ │         │ │    │
│  │  │ Network   │──┼────┤  │ TB :3001│ │ TB :3001│ │ TB :3001│ │    │
│  │  │ Proxy 2   │  │    │  └─────────┘ └─────────┘ └─────────┘ │    │
│  │  └───────────┘  │    └──────────────────────────────────────┘    │
│  │                 │                                                │
│  │  ┌───────────┐  │                                                │
│  │  │ Workload  │  │  VM Control via libvirt:                       │
│  │  │ (client)  │  │  - virsh start/destroy (start/kill)            │
│  │  └───────────┘  │  - virsh suspend/resume (pause/unpause)        │
│  └─────────────────┘                                                │
└─────────────────────────────────────────────────────────────────────┘
```

## Implementation Options

### Option 1: KVMReplica Module (Recommended)

Create a new `kvm_replica.zig` that implements the same interface as `Replica`
but uses libvirt/virsh commands instead of process signals.

```zig
// Pseudocode for kvm_replica.zig
const KVMReplica = struct {
    vm_name: []const u8,
    vm_ip: []const u8,

    pub fn start(self: *KVMReplica) !void {
        // virsh start <vm_name>
        try std.process.Child.run(.{
            .argv = &.{ "virsh", "start", self.vm_name },
        });
        // Wait for TigerBeetle to be ready (poll TCP port)
        try self.waitForReady();
    }

    pub fn terminate(self: *KVMReplica) !void {
        // virsh destroy <vm_name> (forceful shutdown like SIGKILL)
        try std.process.Child.run(.{
            .argv = &.{ "virsh", "destroy", self.vm_name },
        });
    }

    pub fn pause(self: *KVMReplica) !void {
        // virsh suspend <vm_name> (pauses all vCPUs)
        try std.process.Child.run(.{
            .argv = &.{ "virsh", "suspend", self.vm_name },
        });
    }

    pub fn unpause(self: *KVMReplica) !void {
        // virsh resume <vm_name>
        try std.process.Child.run(.{
            .argv = &.{ "virsh", "resume", self.vm_name },
        });
    }
};
```

### Option 2: External Orchestrator Script

Run Vortex in `--disable-faults` mode and inject faults externally:

```bash
#!/bin/bash
# vortex-kvm-chaos.sh

VMS=("tb-freebsd-0" "tb-freebsd-1" "tb-freebsd-2")

# Run Vortex workload without fault injection
zig build vortex -- supervisor \
    --disable-faults \
    --replica-count=3 \
    --addresses=192.168.122.10:3001,192.168.122.11:3001,192.168.122.12:3001 &
VORTEX_PID=$!

# Inject faults externally
while kill -0 $VORTEX_PID 2>/dev/null; do
    sleep $((RANDOM % 10 + 5))

    # Random fault
    case $((RANDOM % 4)) in
        0) # Kill random VM
            VM=${VMS[$((RANDOM % 3))]}
            echo "Destroying $VM"
            virsh destroy $VM
            sleep 5
            virsh start $VM
            ;;
        1) # Suspend random VM
            VM=${VMS[$((RANDOM % 3))]}
            echo "Suspending $VM"
            virsh suspend $VM
            sleep 10
            virsh resume $VM
            ;;
        2) # Network fault via tc on virbr0
            echo "Adding network delay"
            tc qdisc add dev virbr0 root netem delay 100ms 50ms
            sleep 10
            tc qdisc del dev virbr0 root
            ;;
        3) # Packet loss
            echo "Adding packet loss"
            tc qdisc add dev virbr0 root netem loss 5%
            sleep 10
            tc qdisc del dev virbr0 root
            ;;
    esac
done
```

### Option 3: Modify Network Proxy Only

Keep fault injection at network level only (Vortex already supports this):

1. Start TigerBeetle manually in VMs
2. Configure Vortex network proxies to connect to VM IPs
3. Use Vortex's built-in network fault injection
4. Handle replica crashes/restarts manually or via separate script

## VM Setup

### 1. Create FreeBSD VM Template

```bash
# Create VM with virt-install
virt-install \
    --name tb-freebsd-template \
    --ram 4096 \
    --vcpus 2 \
    --disk path=/var/lib/libvirt/images/tb-freebsd-template.qcow2,size=20 \
    --cdrom /path/to/FreeBSD-14.1-RELEASE-amd64-disc1.iso \
    --network bridge=virbr0 \
    --graphics vnc

# Inside VM: install TigerBeetle, configure auto-start
```

### 2. Clone VMs for Each Replica

```bash
for i in 0 1 2; do
    virt-clone \
        --original tb-freebsd-template \
        --name tb-freebsd-$i \
        --file /var/lib/libvirt/images/tb-freebsd-$i.qcow2
done
```

### 3. Configure Static IPs

In each VM's `/etc/rc.conf`:
```bash
# VM 0
ifconfig_vtnet0="inet 192.168.122.10 netmask 255.255.255.0"

# VM 1
ifconfig_vtnet0="inet 192.168.122.11 netmask 255.255.255.0"

# VM 2
ifconfig_vtnet0="inet 192.168.122.12 netmask 255.255.255.0"
```

### 4. Auto-start TigerBeetle

In each VM's `/etc/rc.local`:
```bash
#!/bin/sh
# Format data file if not exists
if [ ! -f /data/0_${REPLICA_INDEX}.tigerbeetle ]; then
    /usr/local/bin/tigerbeetle format \
        --cluster=0 \
        --replica=${REPLICA_INDEX} \
        --replica-count=3 \
        /data/0_${REPLICA_INDEX}.tigerbeetle
fi

# Start TigerBeetle
/usr/local/bin/tigerbeetle start \
    --addresses=192.168.122.10:3001,192.168.122.11:3001,192.168.122.12:3001 \
    /data/0_${REPLICA_INDEX}.tigerbeetle &
```

## Network Proxy Modification

The key change needed in Vortex is to make the network proxy connect to
arbitrary addresses instead of localhost. In `faulty_network.zig`:

```zig
// Current: connects to localhost:replica_port
// Needed: connects to vm_ip:3001

pub const ProxyConfig = struct {
    listen_port: u16,
    target_address: std.net.Address,  // NEW: configurable target
};
```

## virsh Command Reference

| Action | Command | Equivalent |
|--------|---------|------------|
| Start | `virsh start vm-name` | Process spawn |
| Force stop | `virsh destroy vm-name` | SIGKILL |
| Graceful stop | `virsh shutdown vm-name` | SIGTERM |
| Pause | `virsh suspend vm-name` | SIGSTOP |
| Resume | `virsh resume vm-name` | SIGCONT |
| Status | `virsh domstate vm-name` | Process state |

## Limitations

1. **Slower fault injection**: VM operations take seconds vs milliseconds for signals
2. **No namespace isolation**: VMs use real network, potential port conflicts
3. **Resource overhead**: Each VM needs RAM/CPU allocation
4. **Startup time**: VMs take longer to boot than processes

## Advantages

1. **Real FreeBSD testing**: Test actual FreeBSD port, not just Linux
2. **More realistic**: VM boundaries more like production deployments
3. **Storage isolation**: Each VM has its own filesystem
4. **Full OS faults**: Can test kernel panics, filesystem corruption, etc.
