# TigerBeetle FreeBSD Cluster - Ansible Automation

Ansible-based automation for deploying a 3-node TigerBeetle cluster on FreeBSD 15.0 + ZFS, running on KVM/libvirt.

## Prerequisites

On your Ubuntu host:

```bash
# Install Ansible
sudo apt update
sudo apt install ansible python3-libvirt python3-lxml

# Install libvirt collection
ansible-galaxy collection install community.libvirt
```

## Quick Start

```bash
cd docs/freebsd-port/ansible

# 1. Create VMs (requires sudo for libvirt)
ansible-playbook playbooks/01-setup-host.yml --ask-become-pass

# 2. Configure FreeBSD + install Zig
ansible-playbook playbooks/02-configure-freebsd.yml

# 3. Build and deploy TigerBeetle
ansible-playbook playbooks/03-deploy-tigerbeetle.yml

# 4. Start cluster
ansible-playbook playbooks/04-cluster-ops.yml -e operation=start
```

## Playbooks

| Playbook | Purpose |
|----------|---------|
| `01-setup-host.yml` | Install KVM/libvirt, download FreeBSD image, create 3 VMs |
| `02-configure-freebsd.yml` | Verify FreeBSD setup, install Zig |
| `03-deploy-tigerbeetle.yml` | Clone, build, format cluster |
| `04-cluster-ops.yml` | Start/stop/status operations |

## Cluster Operations

```bash
# Check status
ansible-playbook playbooks/04-cluster-ops.yml -e operation=status

# Start cluster
ansible-playbook playbooks/04-cluster-ops.yml -e operation=start

# Stop cluster
ansible-playbook playbooks/04-cluster-ops.yml -e operation=stop
```

## Configuration

Edit `group_vars/all.yml` to customize:

- FreeBSD version and image URL
- VM resources (RAM, CPUs, disk sizes)
- Network configuration
- TigerBeetle fork/branch

## VMs

| Name | IP | Replica |
|------|-----|---------|
| tb-freebsd-0 | 192.168.122.10 | 0 |
| tb-freebsd-1 | 192.168.122.11 | 1 |
| tb-freebsd-2 | 192.168.122.12 | 2 |

Root password: `root`

## Ad-hoc Commands

```bash
# SSH to all nodes
ansible freebsd_cluster -m shell -a "uname -a"

# Check ZFS status
ansible freebsd_cluster -m shell -a "zpool status tbpool"

# View TigerBeetle logs
ansible freebsd_cluster -m shell -a "tail -20 /var/log/tigerbeetle.log"

# Reboot all VMs
ansible freebsd_cluster -m reboot
```

## Comparison to Bash Script

| Aspect | Bash | Ansible |
|--------|------|---------|
| Idempotent | Manual checks | Built-in |
| SSH orchestration | `ssh root@...` loops | Native |
| Error handling | `set -e` + hope | Per-task handling |
| Parallel execution | Tricky | `serial: N` or async |
| Configuration | Hardcoded variables | `group_vars/` + inventory |
| Dry run | Not possible | `--check` flag |
