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
| `04-cluster-ops.yml` | Start/stop/status/restart operations |

## Cluster Operations

```bash
# Check status (shows nice table like bash script)
ansible-playbook playbooks/04-cluster-ops.yml -e operation=status

# Start cluster
ansible-playbook playbooks/04-cluster-ops.yml -e operation=start

# Stop cluster
ansible-playbook playbooks/04-cluster-ops.yml -e operation=stop

# Restart cluster
ansible-playbook playbooks/04-cluster-ops.yml -e operation=restart
```

## Tags for Selective Execution

Each playbook has tags for running specific parts:

### 01-setup-host.yml
```bash
# Run only package installation
ansible-playbook playbooks/01-setup-host.yml --tags packages --ask-become-pass

# Run only VM creation
ansible-playbook playbooks/01-setup-host.yml --tags vms --ask-become-pass

# Run only image download
ansible-playbook playbooks/01-setup-host.yml --tags download --ask-become-pass
```

Available tags: `preflight`, `packages`, `setup`, `libvirt`, `network`, `image`, `download`, `vms`, `create`, `wait`

### 02-configure-freebsd.yml
```bash
# Run only verification
ansible-playbook playbooks/02-configure-freebsd.yml --tags verify

# Run only Zig installation
ansible-playbook playbooks/02-configure-freebsd.yml --tags zig
```

Available tags: `verify`, `setup`, `zfs`, `aio`, `network`, `zig`, `install`

### 03-deploy-tigerbeetle.yml
```bash
# Run only build
ansible-playbook playbooks/03-deploy-tigerbeetle.yml --tags build

# Run only distribution
ansible-playbook playbooks/03-deploy-tigerbeetle.yml --tags distribute

# Run only format
ansible-playbook playbooks/03-deploy-tigerbeetle.yml --tags format
```

Available tags: `clone`, `build`, `verify`, `distribute`, `format`

### 04-cluster-ops.yml
```bash
# Tags match operation names
ansible-playbook playbooks/04-cluster-ops.yml --tags status
ansible-playbook playbooks/04-cluster-ops.yml --tags start
ansible-playbook playbooks/04-cluster-ops.yml --tags stop
ansible-playbook playbooks/04-cluster-ops.yml --tags restart
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

## Dry Run

Test what would change without making changes:

```bash
ansible-playbook playbooks/01-setup-host.yml --check --ask-become-pass
ansible-playbook playbooks/02-configure-freebsd.yml --check
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
| Selective execution | Not possible | `--tags` flag |
