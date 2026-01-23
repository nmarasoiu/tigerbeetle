#!/bin/bash
#
# TigerBeetle FreeBSD Port - Complete Automated KVM Environment
# Strategy: UFS + Soft Updates + POSIX AIO + kqueue
#
# MERGED VERSION: Combines manual completeness with automated injection
#
# Author: Nicolae Marasoiu
# Purpose: Zero-touch deployment of TB/FreeBSD cluster for AIO vs io_uring comparison
#
# Features from both scripts:
#   - Automated VM configuration via libguestfs (no manual console login)
#   - Complete helper scripts (chaos, benchmark, cluster management)
#   - Latest FreeBSD 14.3 and Zig 0.14.1
#   - SSH root login pre-configured
#   - Sentinel check prevents re-runs
#

set -e

#############################################
# CONFIGURATION
#############################################

FREEBSD_VERSION="14.3-RELEASE"
FREEBSD_IMAGE_URL="https://download.freebsd.org/ftp/releases/VM-IMAGES/${FREEBSD_VERSION}/amd64/Latest/FreeBSD-${FREEBSD_VERSION}-amd64.qcow2.xz"

LIBVIRT_IMAGES="/var/lib/libvirt/images"
WORK_DIR="$HOME/tigerbeetle-freebsd"

# VM Resources
VM_RAM_MB=4096
VM_VCPUS=2
VM_DISK_SIZE="20G"       # OS disk
VM_DATA_DISK_SIZE="50G"  # UFS data disk for TigerBeetle

# Network (libvirt default NAT: virbr0 = 192.168.122.0/24)
VM_IPS=("192.168.122.10" "192.168.122.11" "192.168.122.12")
VM_NAMES=("tb-freebsd-0" "tb-freebsd-1" "tb-freebsd-2")
GATEWAY="192.168.122.1"
NETMASK="255.255.255.0"

# TigerBeetle
TB_FORK_URL="https://github.com/nmarasoiu/tigerbeetle.git"
TB_BRANCH="freebsd-port"

#############################################
# COLORS
#############################################

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

ok()   { echo -e "${GREEN}✓${NC} $1"; }
warn() { echo -e "${YELLOW}⚠${NC} $1"; }
err()  { echo -e "${RED}✗${NC} $1"; }

#############################################
# 1. PREFLIGHT CHECKS
#############################################

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║  TigerBeetle FreeBSD Port - Automated KVM Setup          ║"
echo "║  Strategy: UFS + POSIX AIO + kqueue (Zero-Touch)         ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""

# Root check
if [[ $EUID -ne 0 ]]; then
   err "This script must be run as root (sudo)."
   exit 1
fi

# KVM support
if grep -qE '(vmx|svm)' /proc/cpuinfo; then
    ok "CPU virtualization supported"
else
    err "CPU does not support virtualization (vmx/svm not found)"
    exit 1
fi

# Install dependencies (includes libguestfs-tools for automation)
echo ""
echo "=== Installing Dependencies ==="
REQUIRED_PKGS="qemu-kvm libvirt-daemon-system libvirt-clients virtinst bridge-utils wget xz-utils iproute2 iptables libguestfs-tools"

apt-get update -qq
for pkg in $REQUIRED_PKGS; do
    if dpkg -l | grep -q "^ii  $pkg"; then
        ok "$pkg already installed"
    else
        apt-get install -y -qq $pkg
        ok "$pkg installed"
    fi
done

# Start libvirt
systemctl enable --now libvirtd
ok "libvirtd running"

# Default network
virsh net-define /usr/share/libvirt/networks/default.xml 2>/dev/null || true
virsh net-start default 2>/dev/null || true
virsh net-autostart default 2>/dev/null || true
ok "libvirt default network active"

#############################################
# 2. DOWNLOAD FREEBSD IMAGE
#############################################

echo ""
echo "=== FreeBSD Image ==="

mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

COMPRESSED_IMAGE="FreeBSD-${FREEBSD_VERSION}-amd64.qcow2.xz"
BASE_IMAGE="FreeBSD-${FREEBSD_VERSION}-amd64.qcow2"

if [[ -f "$BASE_IMAGE" ]]; then
    ok "Base image exists: $BASE_IMAGE"
else
    if [[ ! -f "$COMPRESSED_IMAGE" ]]; then
        echo "Downloading FreeBSD ${FREEBSD_VERSION} (~700MB)..."
        wget -q --show-progress -c "$FREEBSD_IMAGE_URL" -O "$COMPRESSED_IMAGE"
    fi
    echo "Decompressing (takes a few minutes)..."
    xz -dkv "$COMPRESSED_IMAGE"
    ok "Image ready: $BASE_IMAGE"
fi

#############################################
# 3. GENERATE IN-VM SETUP SCRIPTS
#############################################

echo ""
echo "=== Generating Configuration Scripts ==="

for i in 0 1 2; do
    VM_NAME="${VM_NAMES[$i]}"
    VM_IP="${VM_IPS[$i]}"
    REPLICA_ID=$i

    cat > "$WORK_DIR/setup-${VM_NAME}.sh" << VMEOF
#!/bin/sh
#
# ${VM_NAME} Configuration Script
# Auto-injected via virt-customize, runs on first boot
#
# Strategy: UFS + Soft Updates + POSIX AIO
#

set -e

# SENTINEL CHECK: Prevent running on every boot
if [ -f "/root/.setup_complete" ]; then
    echo "Setup already complete, skipping." > /dev/console
    exit 0
fi

echo "" > /dev/console
echo "╔════════════════════════════════════════╗" > /dev/console
echo "║  Configuring ${VM_NAME}                ║" > /dev/console
echo "╚════════════════════════════════════════╝" > /dev/console
echo "" > /dev/console

#-----------------------------------------
# 1. NETWORKING
#-----------------------------------------
echo ">>> Configuring Network..." > /dev/console

sysrc hostname="${VM_NAME}"
sysrc ifconfig_vtnet0="inet ${VM_IP} netmask ${NETMASK}"
sysrc defaultrouter="${GATEWAY}"
sysrc sshd_enable="YES"

# Enable root SSH login for orchestration
sed -i '' 's/#PermitRootLogin no/PermitRootLogin yes/' /etc/ssh/sshd_config
sed -i '' 's/#PermitRootLogin prohibit-password/PermitRootLogin yes/' /etc/ssh/sshd_config
sed -i '' 's/PermitRootLogin no/PermitRootLogin yes/' /etc/ssh/sshd_config
echo "PermitRootLogin yes" >> /etc/ssh/sshd_config

cat > /etc/resolv.conf << DNS
nameserver 8.8.8.8
nameserver 8.8.4.4
DNS

echo "${VM_NAME}" > /etc/hostname
hostname ${VM_NAME}

echo "  Network: ${VM_IP}" > /dev/console

#-----------------------------------------
# 2. STORAGE (UFS + Soft Updates + Journal)
#-----------------------------------------
echo ">>> Configuring Storage (UFS)..." > /dev/console

# Format data disk if not already done
if [ ! -e "/dev/vtbd1p1" ]; then
    echo "  Formatting /dev/vtbd1..." > /dev/console
    gpart create -s GPT vtbd1
    gpart add -t freebsd-ufs -l tbdata vtbd1

    # -U = Soft Updates (async metadata, safe)
    # -j = Journaling (fast fsck)
    newfs -U -j /dev/vtbd1p1
    echo "  UFS filesystem created" > /dev/console
else
    echo "  Partition already exists" > /dev/console
fi

# Mount
mkdir -p /tbdata
if ! mount | grep -q "/tbdata"; then
    if ! grep -q "vtbd1p1" /etc/fstab; then
        echo "/dev/vtbd1p1 /tbdata ufs rw,noatime 2 2" >> /etc/fstab
    fi
    mount /tbdata
fi

# Create TigerBeetle directories
mkdir -p /tbdata/tigerbeetle/data
chown -R root:wheel /tbdata/tigerbeetle

echo "  Storage: /tbdata mounted (UFS+SU+J)" > /dev/console

#-----------------------------------------
# 3. KERNEL MODULES (CRITICAL)
#-----------------------------------------
echo ">>> Loading Kernel Modules..." > /dev/console

# AIO - Required for async disk I/O
if ! grep -q 'aio_load="YES"' /boot/loader.conf 2>/dev/null; then
    echo 'aio_load="YES"' >> /boot/loader.conf
fi
kldload aio 2>/dev/null || true

# Verify AIO loaded
if kldstat | grep -q aio; then
    echo "  AIO module loaded" > /dev/console
else
    echo "  AIO module FAILED - TigerBeetle will not work!" > /dev/console
fi

# Dummynet - For chaos testing
if ! grep -q 'dummynet_load="YES"' /boot/loader.conf 2>/dev/null; then
    echo 'dummynet_load="YES"' >> /boot/loader.conf
fi
kldload dummynet 2>/dev/null || true

if kldstat | grep -q dummynet; then
    echo "  Dummynet module loaded" > /dev/console
fi

# Firewall (for dummynet)
sysrc firewall_enable="YES"
sysrc firewall_type="open"

echo "  Kernel modules configured" > /dev/console

#-----------------------------------------
# 4. PACKAGES
#-----------------------------------------
echo ">>> Installing Packages..." > /dev/console

# Bootstrap pkg if needed
if ! command -v pkg >/dev/null 2>&1; then
    env ASSUME_ALWAYS_YES=YES pkg bootstrap
fi

pkg update -q
pkg install -y git curl wget nano htop

echo "  Packages installed" > /dev/console

#-----------------------------------------
# 5. MARK COMPLETE & REBOOT
#-----------------------------------------
touch /root/.setup_complete

# Clean rc.local to prevent re-runs
echo "# Setup complete" > /etc/rc.local

echo "" > /dev/console
echo "╔════════════════════════════════════════╗" > /dev/console
echo "║  ${VM_NAME} CONFIGURED                 ║" > /dev/console
echo "╠════════════════════════════════════════╣" > /dev/console
echo "║  IP:        ${VM_IP}                   ║" > /dev/console
echo "║  Hostname:  ${VM_NAME}                 ║" > /dev/console
echo "║  Storage:   /tbdata (UFS+SU+J)         ║" > /dev/console
echo "║  AIO:       Loaded                     ║" > /dev/console
echo "║  Replica:   ${REPLICA_ID}              ║" > /dev/console
echo "╚════════════════════════════════════════╝" > /dev/console
echo "" > /dev/console
echo ">>> Rebooting in 5 seconds..." > /dev/console
sleep 5
reboot
VMEOF

    chmod +x "$WORK_DIR/setup-${VM_NAME}.sh"
    ok "setup-${VM_NAME}.sh generated"
done

#############################################
# 4. CREATE AND CONFIGURE VMs (AUTOMATED)
#############################################

echo ""
echo "=== Creating and Configuring Virtual Machines ==="

export LIBGUESTFS_BACKEND=direct

for i in 0 1 2; do
    VM_NAME="${VM_NAMES[$i]}"
    VM_IP="${VM_IPS[$i]}"
    BOOT_DISK="${LIBVIRT_IMAGES}/${VM_NAME}.qcow2"
    DATA_DISK="${LIBVIRT_IMAGES}/${VM_NAME}-data.qcow2"
    SETUP_SCRIPT="$WORK_DIR/setup-${VM_NAME}.sh"

    if virsh dominfo "$VM_NAME" &>/dev/null; then
        ok "${VM_NAME} already exists"
        continue
    fi

    echo "Processing ${VM_NAME} (${VM_IP})..."

    # 1. Clone boot disk from base image
    echo "  Creating boot disk..."
    cp "$WORK_DIR/$BASE_IMAGE" "$BOOT_DISK"
    qemu-img resize "$BOOT_DISK" "$VM_DISK_SIZE" >/dev/null

    # 2. Create data disk (for UFS)
    if [[ ! -f "$DATA_DISK" ]]; then
        qemu-img create -f qcow2 "$DATA_DISK" "$VM_DATA_DISK_SIZE" >/dev/null
        echo "  Data disk created"
    fi

    # 3. INJECT CONFIGURATION via virt-customize (the magic step)
    echo "  Injecting configuration..."
    virt-customize -a "$BOOT_DISK" \
        --run-command 'echo "console=\"comconsole\"" >> /boot/loader.conf' \
        --run-command 'echo "autoboot_delay=\"0\"" >> /boot/loader.conf' \
        --upload "${SETUP_SCRIPT}:/root/setup.sh" \
        --run-command 'chmod +x /root/setup.sh' \
        --run-command 'echo "/root/setup.sh >> /var/log/setup.log 2>&1" >> /etc/rc.local' \
        --run-command 'chmod +x /etc/rc.local' \
        --root-password password:root \
        >/dev/null 2>&1

    # 4. Create and start VM
    echo "  Starting VM..."
    virt-install \
        --name "$VM_NAME" \
        --ram "$VM_RAM_MB" \
        --vcpus "$VM_VCPUS" \
        --disk path="$BOOT_DISK",format=qcow2,bus=virtio \
        --disk path="$DATA_DISK",format=qcow2,bus=virtio \
        --network network=default,model=virtio \
        --os-variant freebsd14.0 \
        --import \
        --graphics none \
        --noautoconsole >/dev/null

    ok "${VM_NAME} created and launched"
done

#############################################
# 5. WAIT FOR CLUSTER CONNECTIVITY
#############################################

echo ""
echo "=== Waiting for Cluster Connectivity ==="
echo "Note: VMs will reboot once during initialization (~2-3 min total)"

for i in 0 1 2; do
    VM_NAME="${VM_NAMES[$i]}"
    IP="${VM_IPS[$i]}"
    echo -n "Waiting for ${VM_NAME} (${IP})..."

    # Remove old SSH host keys to prevent verification errors
    ssh-keygen -f "$HOME/.ssh/known_hosts" -R "$IP" >/dev/null 2>&1 || true

    # Wait for ping
    while ! ping -c 1 -W 1 $IP >/dev/null 2>&1; do
        echo -n "."
        sleep 3
    done

    # Wait for SSH
    while ! ssh -o StrictHostKeyChecking=no -o ConnectTimeout=2 root@$IP "echo ok" >/dev/null 2>&1; do
        echo -n "."
        sleep 3
    done

    echo " Online!"
done
ok "All VMs online and SSH accessible"

#############################################
# 6. GENERATE TIGERBEETLE BUILD SCRIPT
#############################################

echo ""
echo "=== Generating Helper Scripts ==="

cat > "$WORK_DIR/build-tigerbeetle.sh" << 'BUILDEOF'
#!/bin/sh
#
# Build TigerBeetle on FreeBSD
# Run this inside any VM after initial setup
#

set -e

echo ""
echo "╔════════════════════════════════════════╗"
echo "║  Building TigerBeetle                  ║"
echo "╚════════════════════════════════════════╝"
echo ""

#-----------------------------------------
# 1. INSTALL ZIG
#-----------------------------------------
ZIG_VERSION="0.14.1"

if command -v zig >/dev/null 2>&1; then
    echo "✓ Zig already installed: $(zig version)"
else
    echo ">>> Installing Zig ${ZIG_VERSION}..."
    cd /tmp

    if [ ! -f "zig-freebsd-x86_64-${ZIG_VERSION}.tar.xz" ]; then
        fetch "https://ziglang.org/download/${ZIG_VERSION}/zig-freebsd-x86_64-${ZIG_VERSION}.tar.xz"
    fi

    tar -xf zig-freebsd-x86_64-${ZIG_VERSION}.tar.xz
    rm -rf /usr/local/zig
    mv zig-freebsd-x86_64-${ZIG_VERSION} /usr/local/zig
    ln -sf /usr/local/zig/zig /usr/local/bin/zig

    echo "✓ Zig installed: $(zig version)"
fi

#-----------------------------------------
# 2. CLONE TIGERBEETLE
#-----------------------------------------
cd /root

if [ -d "tigerbeetle" ]; then
    echo ">>> Updating existing clone..."
    cd tigerbeetle
    git fetch origin
    git checkout BRANCH_PLACEHOLDER
    git pull origin BRANCH_PLACEHOLDER
else
    echo ">>> Cloning TigerBeetle fork..."
    git clone FORK_URL_PLACEHOLDER
    cd tigerbeetle
    git checkout BRANCH_PLACEHOLDER
fi

echo "✓ Source ready: $(git rev-parse --short HEAD)"

#-----------------------------------------
# 3. BUILD
#-----------------------------------------
echo ">>> Building (ReleaseSafe for testing)..."
zig build -Doptimize=ReleaseSafe

#-----------------------------------------
# 4. VERIFY
#-----------------------------------------
echo ""
./zig-out/bin/tigerbeetle version

echo ""
echo "╔════════════════════════════════════════╗"
echo "║  BUILD COMPLETE                        ║"
echo "╠════════════════════════════════════════╣"
echo "║  Binary: /root/tigerbeetle/zig-out/    ║"
echo "║          bin/tigerbeetle               ║"
echo "╚════════════════════════════════════════╝"
echo ""
BUILDEOF

# Replace placeholders
sed -i "s|FORK_URL_PLACEHOLDER|${TB_FORK_URL}|g" "$WORK_DIR/build-tigerbeetle.sh"
sed -i "s|BRANCH_PLACEHOLDER|${TB_BRANCH}|g" "$WORK_DIR/build-tigerbeetle.sh"

chmod +x "$WORK_DIR/build-tigerbeetle.sh"
ok "build-tigerbeetle.sh generated"

#############################################
# 7. GENERATE CLUSTER MANAGEMENT SCRIPTS
#############################################

# --- Format Cluster ---
cat > "$WORK_DIR/format-cluster.sh" << 'FORMATEOF'
#!/bin/bash
#
# Format TigerBeetle replicas (run ONCE before first start)
# Execute from Linux host - SSHs into each VM
#

set -e

IPS=("192.168.122.10" "192.168.122.11" "192.168.122.12")
TB_BIN="/root/tigerbeetle/zig-out/bin/tigerbeetle"
DATA_DIR="/tbdata/tigerbeetle/data"

echo "=== Formatting TigerBeetle Cluster ==="
echo ""

for i in 0 1 2; do
    IP="${IPS[$i]}"
    DATA_FILE="${DATA_DIR}/0_${i}.tigerbeetle"

    echo "Formatting replica $i on $IP..."

    ssh -o StrictHostKeyChecking=no root@$IP "\
        $TB_BIN format \
            --cluster=0 \
            --replica=$i \
            --replica-count=3 \
            $DATA_FILE"

    echo "✓ Replica $i formatted"
done

echo ""
echo "=== All replicas formatted ==="
FORMATEOF

chmod +x "$WORK_DIR/format-cluster.sh"
ok "format-cluster.sh generated"

# --- Start Cluster ---
cat > "$WORK_DIR/start-cluster.sh" << 'STARTEOF'
#!/bin/bash
#
# Start TigerBeetle cluster
# Execute from Linux host - SSHs into each VM
#

IPS=("192.168.122.10" "192.168.122.11" "192.168.122.12")
ADDRESSES="192.168.122.10:3001,192.168.122.11:3001,192.168.122.12:3001"
TB_BIN="/root/tigerbeetle/zig-out/bin/tigerbeetle"
DATA_DIR="/tbdata/tigerbeetle/data"

echo "=== Starting TigerBeetle Cluster ==="
echo ""

# First, ensure VMs are running
for vm in tb-freebsd-0 tb-freebsd-1 tb-freebsd-2; do
    state=$(virsh domstate $vm 2>/dev/null || echo "not found")
    if [[ "$state" != "running" ]]; then
        echo "Starting $vm..."
        virsh start $vm 2>/dev/null || true
    fi
done

echo "Waiting for VMs to boot (20s)..."
sleep 20

# Start TigerBeetle on each node
for i in 0 1 2; do
    IP="${IPS[$i]}"
    DATA_FILE="${DATA_DIR}/0_${i}.tigerbeetle"

    echo "Starting replica $i on $IP..."

    # Start in background, redirect output to log
    ssh -o StrictHostKeyChecking=no root@$IP "\
        nohup $TB_BIN start \
            --addresses=$ADDRESSES \
            $DATA_FILE \
            > /var/log/tigerbeetle.log 2>&1 &"

    echo "✓ Replica $i started"
done

echo ""
echo "=== Cluster Started ==="
echo ""
echo "Addresses: $ADDRESSES"
echo "Logs: /var/log/tigerbeetle.log (on each VM)"
STARTEOF

chmod +x "$WORK_DIR/start-cluster.sh"
ok "start-cluster.sh generated"

# --- Stop Cluster ---
cat > "$WORK_DIR/stop-cluster.sh" << 'STOPEOF'
#!/bin/bash
#
# Stop TigerBeetle cluster gracefully
#

IPS=("192.168.122.10" "192.168.122.11" "192.168.122.12")

echo "=== Stopping TigerBeetle Cluster ==="

for i in 0 1 2; do
    IP="${IPS[$i]}"
    echo "Stopping replica $i on $IP..."
    ssh -o StrictHostKeyChecking=no root@$IP "pkill tigerbeetle" 2>/dev/null || true
done

echo "✓ Cluster stopped"
STOPEOF

chmod +x "$WORK_DIR/stop-cluster.sh"
ok "stop-cluster.sh generated"

# --- Cluster Status ---
cat > "$WORK_DIR/cluster-status.sh" << 'STATUSEOF'
#!/bin/bash
#
# Check cluster status
#

IPS=("192.168.122.10" "192.168.122.11" "192.168.122.12")
VMS=("tb-freebsd-0" "tb-freebsd-1" "tb-freebsd-2")

echo "╔══════════════════════════════════════════════════════════╗"
echo "║  TigerBeetle Cluster Status                              ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""

printf "%-15s %-12s %-15s %-10s\n" "VM" "VM State" "IP" "TB Process"
printf "%-15s %-12s %-15s %-10s\n" "─────────────" "──────────" "─────────────" "────────"

for i in 0 1 2; do
    VM="${VMS[$i]}"
    IP="${IPS[$i]}"

    # VM state
    VM_STATE=$(virsh domstate $VM 2>/dev/null || echo "not found")

    # TigerBeetle process
    if [[ "$VM_STATE" == "running" ]]; then
        TB_STATE=$(ssh -o StrictHostKeyChecking=no -o ConnectTimeout=3 root@$IP \
            "pgrep tigerbeetle >/dev/null && echo 'running' || echo 'stopped'" 2>/dev/null || echo "unreachable")
    else
        TB_STATE="-"
    fi

    printf "%-15s %-12s %-15s %-10s\n" "$VM" "$VM_STATE" "$IP" "$TB_STATE"
done

echo ""
STATUSEOF

chmod +x "$WORK_DIR/cluster-status.sh"
ok "cluster-status.sh generated"

#############################################
# 8. GENERATE CHAOS TESTING SCRIPT
#############################################

cat > "$WORK_DIR/chaos.sh" << 'CHAOSEOF'
#!/bin/bash
#
# Chaos Testing for TigerBeetle FreeBSD Cluster
#
# Usage: ./chaos.sh <command> [args]
#

VMS=("tb-freebsd-0" "tb-freebsd-1" "tb-freebsd-2")
IPS=("192.168.122.10" "192.168.122.11" "192.168.122.12")

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

usage() {
    echo ""
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║  TigerBeetle Chaos Testing                               ║"
    echo "╚══════════════════════════════════════════════════════════╝"
    echo ""
    echo "Usage: $0 <command> [args]"
    echo ""
    echo "VM Control:"
    echo "  kill <0|1|2>         Force stop VM (simulates crash)"
    echo "  start <0|1|2>        Start VM"
    echo "  suspend <0|1|2>      Pause VM (freeze in place)"
    echo "  resume <0|1|2>       Resume paused VM"
    echo "  reboot <0|1|2>       Graceful reboot"
    echo ""
    echo "Network Chaos (from host):"
    echo "  partition <0|1|2>    Isolate VM from cluster"
    echo "  heal                 Remove all network partitions"
    echo "  latency <ms>         Add latency to all VM traffic"
    echo "  loss <percent>       Add packet loss"
    echo "  reset-network        Remove all network chaos"
    echo ""
    echo "In-VM Network Chaos (via dummynet):"
    echo "  vm-latency <0|1|2> <ms>      Add latency inside VM"
    echo "  vm-loss <0|1|2> <percent>    Add packet loss inside VM"
    echo "  vm-reset <0|1|2>             Reset VM's network"
    echo ""
    echo "Info:"
    echo "  status               Show VM and process states"
    echo ""
    exit 1
}

case "$1" in
    #-----------------------------------------
    # VM CONTROL
    #-----------------------------------------
    kill)
        [[ -z "$2" ]] && usage
        virsh destroy ${VMS[$2]} 2>/dev/null
        echo -e "${RED}✗${NC} ${VMS[$2]} destroyed (crash simulated)"
        ;;
    start)
        [[ -z "$2" ]] && usage
        virsh start ${VMS[$2]} 2>/dev/null
        echo -e "${GREEN}✓${NC} ${VMS[$2]} started"
        ;;
    suspend)
        [[ -z "$2" ]] && usage
        virsh suspend ${VMS[$2]} 2>/dev/null
        echo -e "${YELLOW}⏸${NC} ${VMS[$2]} suspended (frozen)"
        ;;
    resume)
        [[ -z "$2" ]] && usage
        virsh resume ${VMS[$2]} 2>/dev/null
        echo -e "${GREEN}▶${NC} ${VMS[$2]} resumed"
        ;;
    reboot)
        [[ -z "$2" ]] && usage
        virsh reboot ${VMS[$2]} 2>/dev/null
        echo -e "${YELLOW}↻${NC} ${VMS[$2]} rebooting"
        ;;

    #-----------------------------------------
    # HOST-SIDE NETWORK CHAOS (iptables)
    #-----------------------------------------
    partition)
        [[ -z "$2" ]] && usage
        IP=${IPS[$2]}
        iptables -I FORWARD -s $IP -j DROP
        iptables -I FORWARD -d $IP -j DROP
        echo -e "${RED}⊘${NC} ${VMS[$2]} ($IP) partitioned from cluster"
        ;;
    heal)
        for ip in "${IPS[@]}"; do
            iptables -D FORWARD -s $ip -j DROP 2>/dev/null || true
            iptables -D FORWARD -d $ip -j DROP 2>/dev/null || true
        done
        echo -e "${GREEN}✓${NC} All network partitions healed"
        ;;
    latency)
        [[ -z "$2" ]] && usage
        tc qdisc replace dev virbr0 root netem delay ${2}ms
        echo -e "${YELLOW}~${NC} Added ${2}ms latency to virbr0"
        ;;
    loss)
        [[ -z "$2" ]] && usage
        tc qdisc replace dev virbr0 root netem loss ${2}%
        echo -e "${YELLOW}~${NC} Added ${2}% packet loss to virbr0"
        ;;
    reset-network)
        tc qdisc del dev virbr0 root 2>/dev/null || true
        echo -e "${GREEN}✓${NC} Network chaos removed from virbr0"
        ;;

    #-----------------------------------------
    # IN-VM NETWORK CHAOS (dummynet)
    #-----------------------------------------
    vm-latency)
        [[ -z "$2" || -z "$3" ]] && usage
        IP=${IPS[$2]}
        ssh -o StrictHostKeyChecking=no root@$IP "\
            ipfw -q flush; \
            ipfw add pipe 1 ip from any to any; \
            ipfw pipe 1 config delay ${3}ms"
        echo -e "${YELLOW}~${NC} Added ${3}ms latency inside ${VMS[$2]}"
        ;;
    vm-loss)
        [[ -z "$2" || -z "$3" ]] && usage
        IP=${IPS[$2]}
        ssh -o StrictHostKeyChecking=no root@$IP "\
            ipfw -q flush; \
            ipfw add pipe 1 ip from any to any; \
            ipfw pipe 1 config plr 0.${3}"
        echo -e "${YELLOW}~${NC} Added ${3}% packet loss inside ${VMS[$2]}"
        ;;
    vm-reset)
        [[ -z "$2" ]] && usage
        IP=${IPS[$2]}
        ssh -o StrictHostKeyChecking=no root@$IP "ipfw -q flush"
        echo -e "${GREEN}✓${NC} Network reset inside ${VMS[$2]}"
        ;;

    #-----------------------------------------
    # STATUS
    #-----------------------------------------
    status)
        echo ""
        echo "╔══════════════════════════════════════════════════════════╗"
        echo "║  Cluster Status                                          ║"
        echo "╚══════════════════════════════════════════════════════════╝"
        echo ""
        printf "%-15s %-12s %-15s %-12s\n" "VM" "State" "IP" "TigerBeetle"
        printf "%-15s %-12s %-15s %-12s\n" "─────────────" "──────────" "─────────────" "──────────"

        for i in 0 1 2; do
            VM="${VMS[$i]}"
            IP="${IPS[$i]}"
            VM_STATE=$(virsh domstate $VM 2>/dev/null || echo "not found")

            if [[ "$VM_STATE" == "running" ]]; then
                TB=$(ssh -o StrictHostKeyChecking=no -o ConnectTimeout=2 root@$IP \
                    "pgrep tigerbeetle >/dev/null && echo 'running' || echo 'stopped'" 2>/dev/null || echo "unreachable")
            else
                TB="-"
            fi

            printf "%-15s %-12s %-15s %-12s\n" "$VM" "$VM_STATE" "$IP" "$TB"
        done
        echo ""
        ;;

    *)
        usage
        ;;
esac
CHAOSEOF

chmod +x "$WORK_DIR/chaos.sh"
ok "chaos.sh generated"

#############################################
# 9. GENERATE BENCHMARK SCRIPT
#############################################

cat > "$WORK_DIR/benchmark.sh" << 'BENCHEOF'
#!/bin/bash
#
# Simple TigerBeetle Benchmark
# Measures throughput and latency
#

ADDRESSES="192.168.122.10:3001,192.168.122.11:3001,192.168.122.12:3001"

echo "╔══════════════════════════════════════════════════════════╗"
echo "║  TigerBeetle Benchmark                                   ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""

# Run benchmark from first VM
echo "Running benchmark from tb-freebsd-0..."
echo ""

ssh -o StrictHostKeyChecking=no root@192.168.122.10 << 'REMOTE'
cd /root/tigerbeetle

# Use built-in benchmark if available
if ./zig-out/bin/tigerbeetle benchmark --help >/dev/null 2>&1; then
    ./zig-out/bin/tigerbeetle benchmark \
        --addresses=192.168.122.10:3001,192.168.122.11:3001,192.168.122.12:3001 \
        --transfer-count=100000
else
    echo "Benchmark subcommand not available in this build."
    echo "Consider using the REPL for manual testing:"
    echo "  ./zig-out/bin/tigerbeetle repl --addresses=..."
fi
REMOTE

echo ""
echo "Benchmark complete."
BENCHEOF

chmod +x "$WORK_DIR/benchmark.sh"
ok "benchmark.sh generated"

#############################################
# 10. DEPLOY BUILD SCRIPT TO ALL VMS
#############################################

echo ""
echo "=== Deploying Build Script to VMs ==="

for i in 0 1 2; do
    IP="${VM_IPS[$i]}"
    VM_NAME="${VM_NAMES[$i]}"
    scp -o StrictHostKeyChecking=no "$WORK_DIR/build-tigerbeetle.sh" root@$IP:/root/ >/dev/null
    ok "build-tigerbeetle.sh deployed to ${VM_NAME}"
done

#############################################
# 11. SUMMARY
#############################################

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║                    SETUP COMPLETE                        ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""
echo "Work Directory: $WORK_DIR"
echo ""
echo "VMs Created and Running:"
for i in 0 1 2; do
    echo "  ${VM_NAMES[$i]}: ${VM_IPS[$i]} (${VM_RAM_MB}MB RAM, ${VM_VCPUS} vCPUs)"
done
echo ""
echo "Root Password: root"
echo ""
echo "═══════════════════════════════════════════════════════════"
echo "  NEXT STEPS (All Automated!)"
echo "═══════════════════════════════════════════════════════════"
echo ""
echo "1. BUILD TIGERBEETLE (on one VM, then copy binary):"
echo ""
echo "   ssh root@192.168.122.10 './build-tigerbeetle.sh'"
echo ""
echo "   # Copy binary to other nodes:"
echo "   ssh root@192.168.122.10 'scp /root/tigerbeetle/zig-out/bin/tigerbeetle root@192.168.122.11:/root/tigerbeetle/zig-out/bin/'"
echo "   ssh root@192.168.122.10 'scp /root/tigerbeetle/zig-out/bin/tigerbeetle root@192.168.122.12:/root/tigerbeetle/zig-out/bin/'"
echo ""
echo "2. FORMAT & START CLUSTER:"
echo ""
echo "   $WORK_DIR/format-cluster.sh"
echo "   $WORK_DIR/start-cluster.sh"
echo "   $WORK_DIR/cluster-status.sh"
echo ""
echo "3. RUN CHAOS TESTS:"
echo ""
echo "   $WORK_DIR/chaos.sh status"
echo "   $WORK_DIR/chaos.sh kill 0        # Crash node 0"
echo "   $WORK_DIR/chaos.sh partition 1   # Isolate node 1"
echo "   $WORK_DIR/chaos.sh latency 100   # Add 100ms latency"
echo "   $WORK_DIR/chaos.sh heal          # Restore network"
echo ""
echo "4. BENCHMARK:"
echo ""
echo "   $WORK_DIR/benchmark.sh"
echo ""
echo "═══════════════════════════════════════════════════════════"
echo ""
