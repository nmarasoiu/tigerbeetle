#!/bin/bash
#
# TigerBeetle FreeBSD Cluster - KVM Setup Script
# For: 32GB Linux host, 3x FreeBSD 14.3 VMs
#
# Author: Nicolae Marasoiu
# Purpose: Test TigerBeetle FreeBSD port with true async AIO on ZFS
#

set -e

#############################################
# CONFIGURATION
#############################################

FREEBSD_VERSION="14.3"
FREEBSD_IMAGE_URL="https://download.freebsd.org/ftp/releases/VM-IMAGES/${FREEBSD_VERSION}-RELEASE/amd64/Latest/FreeBSD-${FREEBSD_VERSION}-RELEASE-amd64.qcow2.xz"
LIBVIRT_IMAGES="/var/lib/libvirt/images"
WORK_DIR="$HOME/tigerbeetle-freebsd"

# VM Resources (3 VMs × 4GB = 12GB, leaves 20GB for host)
VM_RAM_MB=4096
VM_VCPUS=2
VM_DISK_SIZE="20G"  # Base disk
VM_DATA_DISK_SIZE="50G"  # ZFS data disk for TigerBeetle

# Network: using default libvirt network (virbr0 = 192.168.122.0/24)
VM_IPS=("192.168.122.10" "192.168.122.11" "192.168.122.12")
VM_NAMES=("tb-freebsd-0" "tb-freebsd-1" "tb-freebsd-2")
GATEWAY="192.168.122.1"
NETMASK="255.255.255.0"

#############################################
# PREFLIGHT CHECKS
#############################################

echo "=== TigerBeetle FreeBSD KVM Setup ==="
echo ""

# Check if running as root or with sudo
if [[ $EUID -ne 0 ]]; then
   echo "This script needs sudo for libvirt operations."
   echo "Run: sudo $0"
   exit 1
fi

# Check KVM support
if ! grep -qE '(vmx|svm)' /proc/cpuinfo; then
    echo "ERROR: CPU does not support virtualization (vmx/svm not found)"
    exit 1
fi

# Check required packages
REQUIRED_PKGS="qemu-kvm libvirt-daemon-system libvirt-clients virtinst bridge-utils wget xz-utils"
MISSING_PKGS=""

for pkg in $REQUIRED_PKGS; do
    if ! dpkg -l | grep -q "^ii  $pkg"; then
        MISSING_PKGS="$MISSING_PKGS $pkg"
    fi
done

if [[ -n "$MISSING_PKGS" ]]; then
    echo "Installing missing packages:$MISSING_PKGS"
    apt-get update
    apt-get install -y $MISSING_PKGS
fi

# Ensure libvirtd is running
systemctl enable --now libvirtd

# Ensure default network is active
if ! virsh net-info default &>/dev/null; then
    virsh net-define /usr/share/libvirt/networks/default.xml
fi
virsh net-start default 2>/dev/null || true
virsh net-autostart default

echo "✓ Preflight checks passed"
echo ""

#############################################
# DOWNLOAD FREEBSD IMAGE
#############################################

mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

COMPRESSED_IMAGE="FreeBSD-${FREEBSD_VERSION}-RELEASE-amd64.qcow2.xz"
BASE_IMAGE="FreeBSD-${FREEBSD_VERSION}-RELEASE-amd64.qcow2"

if [[ ! -f "$BASE_IMAGE" ]]; then
    if [[ ! -f "$COMPRESSED_IMAGE" ]]; then
        echo "Downloading FreeBSD ${FREEBSD_VERSION} VM image..."
        wget -c "$FREEBSD_IMAGE_URL" -O "$COMPRESSED_IMAGE"
    fi
    
    echo "Decompressing image (this takes a few minutes)..."
    xz -dkv "$COMPRESSED_IMAGE"
fi

echo "✓ FreeBSD base image ready: $BASE_IMAGE"
echo ""

#############################################
# CREATE VM DISKS
#############################################

echo "Creating VM disks..."

for i in 0 1 2; do
    VM_NAME="${VM_NAMES[$i]}"
    BOOT_DISK="${LIBVIRT_IMAGES}/${VM_NAME}.qcow2"
    DATA_DISK="${LIBVIRT_IMAGES}/${VM_NAME}-data.qcow2"
    
    # Boot disk: copy from base image
    if [[ ! -f "$BOOT_DISK" ]]; then
        echo "  Creating boot disk for ${VM_NAME}..."
        cp "$WORK_DIR/$BASE_IMAGE" "$BOOT_DISK"
        qemu-img resize "$BOOT_DISK" "$VM_DISK_SIZE"
    else
        echo "  Boot disk for ${VM_NAME} already exists, skipping"
    fi
    
    # Data disk: create new (for ZFS)
    if [[ ! -f "$DATA_DISK" ]]; then
        echo "  Creating data disk for ${VM_NAME} (${VM_DATA_DISK_SIZE})..."
        qemu-img create -f qcow2 "$DATA_DISK" "$VM_DATA_DISK_SIZE"
    else
        echo "  Data disk for ${VM_NAME} already exists, skipping"
    fi
done

echo "✓ VM disks created"
echo ""

#############################################
# CREATE VMs
#############################################

echo "Creating VMs..."

for i in 0 1 2; do
    VM_NAME="${VM_NAMES[$i]}"
    VM_IP="${VM_IPS[$i]}"
    BOOT_DISK="${LIBVIRT_IMAGES}/${VM_NAME}.qcow2"
    DATA_DISK="${LIBVIRT_IMAGES}/${VM_NAME}-data.qcow2"
    
    # Check if VM already exists
    if virsh dominfo "$VM_NAME" &>/dev/null; then
        echo "  VM ${VM_NAME} already exists, skipping creation"
        continue
    fi
    
    echo "  Creating ${VM_NAME} (IP: ${VM_IP})..."
    
    virt-install \
        --name "$VM_NAME" \
        --ram "$VM_RAM_MB" \
        --vcpus "$VM_VCPUS" \
        --disk path="$BOOT_DISK",format=qcow2,bus=virtio \
        --disk path="$DATA_DISK",format=qcow2,bus=virtio \
        --network network=default,model=virtio \
        --os-variant freebsd13.0 \
        --import \
        --graphics vnc,listen=0.0.0.0 \
        --noautoconsole \
        --boot hd
    
    # Let it boot briefly then shut down for config
    sleep 5
    virsh shutdown "$VM_NAME" 2>/dev/null || true
done

echo "✓ VMs created"
echo ""

#############################################
# GENERATE INSIDE-VM SETUP SCRIPTS
#############################################

echo "Generating inside-VM setup scripts..."

# Create a script to run inside each FreeBSD VM
for i in 0 1 2; do
    VM_NAME="${VM_NAMES[$i]}"
    VM_IP="${VM_IPS[$i]}"
    
    cat > "$WORK_DIR/setup-${VM_NAME}.sh" << VMSCRIPT
#!/bin/sh
#
# Run this inside ${VM_NAME} after first boot
# FreeBSD 14.3 initial configuration
#

echo "=== Configuring ${VM_NAME} ==="

# Set static IP
cat >> /etc/rc.conf << 'EOF'
# Network
ifconfig_vtnet0="inet ${VM_IP} netmask ${NETMASK}"
defaultrouter="${GATEWAY}"

# Services
sshd_enable="YES"
zfs_enable="YES"

# Firewall (for chaos testing later)
firewall_enable="YES"
firewall_type="open"
EOF

# DNS
echo "nameserver 8.8.8.8" > /etc/resolv.conf
echo "nameserver 8.8.4.4" >> /etc/resolv.conf

# Set hostname
hostname ${VM_NAME}
echo '${VM_NAME}' > /etc/rc.conf.d/hostname

# Update packages
pkg update
pkg install -y git curl

# Create ZFS pool on data disk (vtbd1)
echo "Creating ZFS pool on /dev/vtbd1..."
zpool create tbdata /dev/vtbd1

# Create TigerBeetle dataset
zfs create tbdata/tigerbeetle
zfs set compression=lz4 tbdata/tigerbeetle
zfs set atime=off tbdata/tigerbeetle
zfs set recordsize=64k tbdata/tigerbeetle

# Create data directory
mkdir -p /tbdata/tigerbeetle/data
chmod 755 /tbdata/tigerbeetle/data

# Load dummynet for chaos testing
kldload dummynet 2>/dev/null || true
echo 'dummynet_load="YES"' >> /boot/loader.conf

echo ""
echo "=== ${VM_NAME} configured ==="
echo "IP: ${VM_IP}"
echo "ZFS pool: tbdata"
echo "TigerBeetle data dir: /tbdata/tigerbeetle/data"
echo ""
echo "Reboot now: shutdown -r now"
VMSCRIPT

    chmod +x "$WORK_DIR/setup-${VM_NAME}.sh"
done

echo "✓ Setup scripts generated in $WORK_DIR/"
echo ""

#############################################
# GENERATE TIGERBEETLE BUILD SCRIPT
#############################################

cat > "$WORK_DIR/build-tigerbeetle.sh" << 'BUILDSCRIPT'
#!/bin/sh
#
# Build TigerBeetle on FreeBSD
# Run this on each VM after initial setup
#

set -e

echo "=== Building TigerBeetle ==="

# Install Zig (TigerBeetle requires specific version)
ZIG_VERSION="0.14.1"
cd /tmp

# Check if zig is already installed
if command -v zig >/dev/null 2>&1; then
    echo "Zig already installed: $(zig version)"
else
    echo "Downloading Zig ${ZIG_VERSION}..."
    fetch "https://ziglang.org/download/${ZIG_VERSION}/zig-freebsd-x86_64-${ZIG_VERSION}.tar.xz"
    tar xf zig-freebsd-x86_64-${ZIG_VERSION}.tar.xz
    mv zig-freebsd-x86_64-${ZIG_VERSION} /usr/local/zig
    ln -sf /usr/local/zig/zig /usr/local/bin/zig
    echo "Zig installed: $(zig version)"
fi

# Clone TigerBeetle (use your fork with FreeBSD branch)
cd /root
if [ ! -d "tigerbeetle" ]; then
    echo "Cloning TigerBeetle..."
    # CHANGE THIS to your fork URL:
    git clone https://github.com/nmarasoiu/tigerbeetle.git
    cd tigerbeetle
    git checkout freebsd-port  # or your branch name
else
    cd tigerbeetle
    git pull
fi

# Build
echo "Building TigerBeetle..."
zig build -Doptimize=ReleaseSafe

# Verify
echo ""
echo "Build complete!"
./zig-out/bin/tigerbeetle version

echo ""
echo "Binary location: /root/tigerbeetle/zig-out/bin/tigerbeetle"
BUILDSCRIPT

chmod +x "$WORK_DIR/build-tigerbeetle.sh"

#############################################
# GENERATE CLUSTER START SCRIPT
#############################################

cat > "$WORK_DIR/start-cluster.sh" << 'CLUSTERSCRIPT'
#!/bin/bash
#
# Start TigerBeetle cluster (run from Linux host)
#

ADDRESSES="192.168.122.10:3001,192.168.122.11:3001,192.168.122.12:3001"

echo "=== Starting TigerBeetle Cluster ==="

# Start all VMs
for vm in tb-freebsd-0 tb-freebsd-1 tb-freebsd-2; do
    echo "Starting $vm..."
    virsh start $vm 2>/dev/null || echo "$vm already running"
done

echo ""
echo "Waiting for VMs to boot (30 seconds)..."
sleep 30

echo ""
echo "=== Format replicas (run once) ==="
echo ""
echo "On tb-freebsd-0 (192.168.122.10):"
echo "  ./tigerbeetle format --cluster=0 --replica=0 --replica-count=3 /tbdata/tigerbeetle/data/0_0.tigerbeetle"
echo ""
echo "On tb-freebsd-1 (192.168.122.11):"
echo "  ./tigerbeetle format --cluster=0 --replica=1 --replica-count=3 /tbdata/tigerbeetle/data/0_1.tigerbeetle"
echo ""
echo "On tb-freebsd-2 (192.168.122.12):"
echo "  ./tigerbeetle format --cluster=0 --replica=2 --replica-count=3 /tbdata/tigerbeetle/data/0_2.tigerbeetle"
echo ""
echo "=== Start replicas ==="
echo ""
echo "On each node, run:"
echo "  ./tigerbeetle start --addresses=${ADDRESSES} /tbdata/tigerbeetle/data/0_N.tigerbeetle"
echo ""
echo "(Replace N with replica number: 0, 1, or 2)"
CLUSTERSCRIPT

chmod +x "$WORK_DIR/start-cluster.sh"

#############################################
# GENERATE CHAOS TESTING SCRIPT
#############################################

cat > "$WORK_DIR/chaos-test.sh" << 'CHAOSSCRIPT'
#!/bin/bash
#
# Chaos testing from Linux host
# Uses virsh to control VMs, tc/iptables for network chaos
#

VMS=("tb-freebsd-0" "tb-freebsd-1" "tb-freebsd-2")
IPS=("192.168.122.10" "192.168.122.11" "192.168.122.12")

usage() {
    echo "Usage: $0 <command> [args]"
    echo ""
    echo "Commands:"
    echo "  kill <0|1|2>       - Force stop VM (like SIGKILL)"
    echo "  start <0|1|2>      - Start VM"
    echo "  suspend <0|1|2>    - Pause VM (like SIGSTOP)"
    echo "  resume <0|1|2>     - Resume VM (like SIGCONT)"
    echo "  partition <0|1|2>  - Network isolate a VM"
    echo "  heal               - Remove all network partitions"
    echo "  latency <ms>       - Add latency to virbr0"
    echo "  loss <percent>     - Add packet loss to virbr0"
    echo "  reset-network      - Remove all network chaos"
    echo "  status             - Show VM states"
    exit 1
}

case "$1" in
    kill)
        virsh destroy ${VMS[$2]}
        echo "VM ${VMS[$2]} destroyed"
        ;;
    start)
        virsh start ${VMS[$2]}
        echo "VM ${VMS[$2]} started"
        ;;
    suspend)
        virsh suspend ${VMS[$2]}
        echo "VM ${VMS[$2]} suspended"
        ;;
    resume)
        virsh resume ${VMS[$2]}
        echo "VM ${VMS[$2]} resumed"
        ;;
    partition)
        IP=${IPS[$2]}
        iptables -I FORWARD -s $IP -j DROP
        iptables -I FORWARD -d $IP -j DROP
        echo "VM ${VMS[$2]} ($IP) partitioned"
        ;;
    heal)
        for ip in "${IPS[@]}"; do
            iptables -D FORWARD -s $ip -j DROP 2>/dev/null || true
            iptables -D FORWARD -d $ip -j DROP 2>/dev/null || true
        done
        echo "Network partitions healed"
        ;;
    latency)
        tc qdisc replace dev virbr0 root netem delay ${2}ms
        echo "Added ${2}ms latency to virbr0"
        ;;
    loss)
        tc qdisc replace dev virbr0 root netem loss ${2}%
        echo "Added ${2}% packet loss to virbr0"
        ;;
    reset-network)
        tc qdisc del dev virbr0 root 2>/dev/null || true
        echo "Network chaos removed"
        ;;
    status)
        for vm in "${VMS[@]}"; do
            state=$(virsh domstate $vm 2>/dev/null || echo "not found")
            echo "$vm: $state"
        done
        ;;
    *)
        usage
        ;;
esac
CHAOSSCRIPT

chmod +x "$WORK_DIR/chaos-test.sh"

#############################################
# SUMMARY
#############################################

echo ""
echo "============================================"
echo "  SETUP COMPLETE"
echo "============================================"
echo ""
echo "Work directory: $WORK_DIR"
echo ""
echo "VMs created:"
for i in 0 1 2; do
    echo "  ${VM_NAMES[$i]} - ${VM_IPS[$i]} (${VM_RAM_MB}MB RAM, ${VM_VCPUS} vCPUs)"
done
echo ""
echo "=== NEXT STEPS ==="
echo ""
echo "1. Start a VM:"
echo "   virsh start tb-freebsd-0"
echo ""
echo "2. Connect via console (default login: root, no password):"
echo "   virsh console tb-freebsd-0"
echo ""
echo "3. Inside VM, run setup script (copy from $WORK_DIR/setup-tb-freebsd-0.sh):"
echo "   - Set static IP"
echo "   - Create ZFS pool"
echo "   - Install packages"
echo ""
echo "4. Build TigerBeetle (copy from $WORK_DIR/build-tigerbeetle.sh)"
echo ""
echo "5. Start cluster: $WORK_DIR/start-cluster.sh"
echo ""
echo "6. Run chaos tests: $WORK_DIR/chaos-test.sh"
echo ""
echo "=== VM MANAGEMENT ==="
echo "  virsh list --all          # List VMs"
echo "  virsh start <vm>          # Start VM"
echo "  virsh shutdown <vm>       # Graceful shutdown"
echo "  virsh destroy <vm>        # Force stop"
echo "  virsh console <vm>        # Serial console"
echo "  ssh root@192.168.122.10   # SSH (after setup)"
echo ""
