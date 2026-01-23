#!/bin/bash

# setup_scheduling.sh
# 
# This script applies I/O priority and scheduling settings for ZFS on SMR drives.
#
# Actions:
# 1. Creates /etc/modprobe.d/zfs-io-priority.conf (separate file, won't duplicate)
# 2. Creates /etc/udev/rules.d/70-io-scheduler.rules for BFQ on sd[c-g]
# 3. Applies all settings immediately without requiring a reboot
#
# Target drives: sd[c-g] (Seagate Expansion HDD - SMR drives)
# Excluded: sda (Samsung SSD 850), sdb (Samsung HD103UJ), nvme*
#
# Run with: sudo ./setup_scheduling.sh

set -e
set -u
set -x

# Ensure the script is run as root
if [ "$(id -u)" -ne 0 ]; then
  echo "This script must be run as root. Please use sudo." >&2
  exit 1
fi

echo "=============================================="
echo "  ZFS + BFQ I/O Priority Configuration"
echo "=============================================="
echo

# --- Step 1: Show current state ---
echo "=== Current State (Before Changes) ==="
echo
echo "Existing /etc/modprobe.d/zfs.conf:"
cat /etc/modprobe.d/zfs.conf 2>/dev/null || echo "  (not found)"
echo
echo "Current ZFS lane settings:"
for p in zfs_vdev_sync_read_max_active zfs_vdev_async_read_max_active \
         zfs_vdev_async_write_min_active zfs_vdev_async_write_max_active; do
  echo "  $p = $(cat /sys/module/zfs/parameters/$p)"
done
echo
echo "Current scheduler on SMR drives:"
for d in sd{c,d,e,f,g}; do
  [ -e /sys/block/$d ] && echo "  $d: $(cat /sys/block/$d/queue/scheduler)"
done
echo

# --- Step 2: Create ZFS I/O priority config (separate file) ---
echo "=== Creating ZFS I/O Priority Configuration ==="

cat > /etc/modprobe.d/zfs-io-priority.conf <<'EOF'
# ZFS I/O Priority Tuning
# Created by setup_scheduling.sh
# 
# Goal: Guarantee write throughput for stability, serialize reads to reduce
#       head thrashing on SMR drives, and prevent read-heavy workloads
#       from starving critical ZFS writes (txg commits).
#
# These settings apply per leaf vdev (physical disk).

# Limit sync operations to 1 lane each (serialized)
options zfs zfs_vdev_sync_read_min_active=1
options zfs zfs_vdev_sync_read_max_active=1
options zfs zfs_vdev_sync_write_min_active=1
options zfs zfs_vdev_sync_write_max_active=1

# Limit async reads to 1 lane (Storj + Torrent share this)
options zfs zfs_vdev_async_read_min_active=1
options zfs zfs_vdev_async_read_max_active=1

# Guarantee 4 lanes for async writes (txg commits)
options zfs zfs_vdev_async_write_min_active=4
options zfs zfs_vdev_async_write_max_active=10

# Scrub stays low priority
options zfs zfs_vdev_scrub_min_active=1
options zfs zfs_vdev_scrub_max_active=2
EOF

echo "  Created /etc/modprobe.d/zfs-io-priority.conf"

# --- Step 3: Apply ZFS settings live ---
echo
echo "=== Applying ZFS Settings Live ==="

echo 1 > /sys/module/zfs/parameters/zfs_vdev_sync_read_min_active
echo 1 > /sys/module/zfs/parameters/zfs_vdev_sync_read_max_active
echo 1 > /sys/module/zfs/parameters/zfs_vdev_sync_write_min_active
echo 1 > /sys/module/zfs/parameters/zfs_vdev_sync_write_max_active
echo 1 > /sys/module/zfs/parameters/zfs_vdev_async_read_min_active
echo 1 > /sys/module/zfs/parameters/zfs_vdev_async_read_max_active
echo 4 > /sys/module/zfs/parameters/zfs_vdev_async_write_min_active
echo 10 > /sys/module/zfs/parameters/zfs_vdev_async_write_max_active
echo 1 > /sys/module/zfs/parameters/zfs_vdev_scrub_min_active
echo 2 > /sys/module/zfs/parameters/zfs_vdev_scrub_max_active

echo "  Live ZFS settings applied."

# --- Step 4: Verify ZFS settings ---
echo
echo "=== Verifying ZFS Configuration ==="
for p in zfs_vdev_sync_read_max_active zfs_vdev_sync_write_max_active \
         zfs_vdev_async_read_max_active zfs_vdev_async_write_min_active \
         zfs_vdev_async_write_max_active zfs_vdev_scrub_max_active; do
  value=$(cat "/sys/module/zfs/parameters/$p")
  echo "  $p = $value"
done

# --- Step 5: Create BFQ udev rules ---
echo
echo "=== Creating BFQ Block Scheduler Configuration ==="

cat > /etc/udev/rules.d/70-io-scheduler.rules <<'EOF'
# BFQ Scheduler for SMR HDDs (sd[c-g])
# Created by setup_scheduling.sh
#
# Provides deadlines and batching at block layer.
# Note: ionice is ineffective with ZFS (kernel threads don't inherit priority).
# Real priority control happens at ZFS layer (zfs-io-priority.conf).

# Scheduler selection
ACTION=="add|change", SUBSYSTEM=="block", KERNEL=="sd[c-g]", ATTR{queue/scheduler}="bfq"

# Priority enforcement
ACTION=="add|change", SUBSYSTEM=="block", KERNEL=="sd[c-g]", ATTR{queue/iosched/low_latency}="1"
ACTION=="add|change", SUBSYSTEM=="block", KERNEL=="sd[c-g]", ATTR{queue/iosched/strict_guarantees}="1"

# Deadlines: 200ms for reads, 2000ms for writes
ACTION=="add|change", SUBSYSTEM=="block", KERNEL=="sd[c-g]", ATTR{queue/iosched/timeout_sync}="200"
ACTION=="add|change", SUBSYSTEM=="block", KERNEL=="sd[c-g]", ATTR{queue/iosched/fifo_expire_sync}="200"
ACTION=="add|change", SUBSYSTEM=="block", KERNEL=="sd[c-g]", ATTR{queue/iosched/fifo_expire_async}="2000"

# Read-ahead: moderate (ZFS does its own prefetch)
ACTION=="add|change", SUBSYSTEM=="block", KERNEL=="sd[c-g]", ATTR{queue/read_ahead_kb}="512"
EOF

echo "  Created /etc/udev/rules.d/70-io-scheduler.rules"

# --- Step 6: Apply udev rules ---
echo
echo "=== Applying udev Rules ==="
udevadm control --reload-rules
udevadm trigger --subsystem-match=block
echo "  Udev rules reloaded and triggered."

# --- Step 7: Verify BFQ settings ---
echo
echo "=== Verifying BFQ Configuration ==="
for d in sd{c,d,e,f,g}; do
  if [ -e /sys/block/$d ]; then
    sched=$(cat /sys/block/$d/queue/scheduler)
    strict=$(cat /sys/block/$d/queue/iosched/strict_guarantees 2>/dev/null || echo "N/A")
    expire=$(cat /sys/block/$d/queue/iosched/fifo_expire_async 2>/dev/null || echo "N/A")
    echo "  $d: scheduler=$sched, strict_guarantees=$strict, fifo_expire_async=$expire"
  fi
done

# --- Done ---
echo
echo "=============================================="
echo "  Configuration Complete"
echo "=============================================="
echo
echo "Files created:"
echo "  /etc/modprobe.d/zfs-io-priority.conf"
echo "  /etc/udev/rules.d/70-io-scheduler.rules"
echo
echo "Settings applied live and will persist after reboot."
echo
echo "Summary of what was configured:"
echo "  - ZFS: 1 read lane, 4 guaranteed write lanes (per disk)"
echo "  - BFQ: 200ms read deadline, 2000ms write deadline"
echo "  - Targets: sd[c-g] (your SMR Expansion HDDs)"
echo
