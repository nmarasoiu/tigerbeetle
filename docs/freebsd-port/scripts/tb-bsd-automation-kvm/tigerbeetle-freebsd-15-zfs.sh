#!/bin/bash
#
# TigerBeetle FreeBSD 15.0 + ZFS - Minimal Automated KVM Setup
#
# FOCUSED: FreeBSD 15.0-RELEASE + ZFS only. No conditionals, no variations.
#
# Author: Nicolae Marasoiu
# Purpose: Zero-touch deployment of TB/FreeBSD cluster for AIO vs io_uring comparison
#

set -e

#############################################
# HARDCODED CONFIGURATION (no variations)
#############################################

FREEBSD_VERSION="15.0-RELEASE"
IMAGE_FILENAME="FreeBSD-15.0-RELEASE-amd64-zfs.qcow2.xz"
BASE_IMAGE="FreeBSD-15.0-RELEASE-amd64-zfs.qcow2"
FREEBSD_IMAGE_URL="https://download.freebsd.org/ftp/releases/VM-IMAGES/15.0-RELEASE/amd64/Latest/${IMAGE_FILENAME}"

LIBVIRT_IMAGES="/var/lib/libvirt/images"
WORK_DIR="$HOME/tigerbeetle-freebsd"

VM_RAM_MB=4096
VM_VCPUS=2
VM_DISK_SIZE="20G"
VM_DATA_DISK_SIZE="50G"

VM_IPS=("192.168.122.10" "192.168.122.11" "192.168.122.12")
VM_NAMES=("tb-freebsd-0" "tb-freebsd-1" "tb-freebsd-2")
GATEWAY="192.168.122.1"
NETMASK="255.255.255.0"

TB_FORK_URL="https://github.com/nmarasoiu/tigerbeetle.git"
TB_BRANCH="freebsd-port"

#############################################
# COLORS
#############################################

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

ok()   { echo -e "${GREEN}[OK]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
err()  { echo -e "${RED}[ERR]${NC} $1"; }

#############################################
# 1. PREFLIGHT CHECKS
#############################################

echo ""
echo "========================================"
echo "  TigerBeetle FreeBSD 15.0 + ZFS Setup"
echo "========================================"
echo ""

if [[ $EUID -ne 0 ]]; then
   err "Run as root (sudo)."
   exit 1
fi

if grep -qE '(vmx|svm)' /proc/cpuinfo; then
    ok "KVM supported"
else
    err "No CPU virtualization"
    exit 1
fi

#############################################
# 2. INSTALL DEPENDENCIES
#############################################

echo ""
echo "=== Installing Dependencies ==="

apt-get update -qq
for pkg in qemu-kvm libvirt-daemon-system libvirt-clients virtinst bridge-utils wget xz-utils libguestfs-tools; do
    if dpkg -l | grep -q "^ii  $pkg"; then
        ok "$pkg"
    else
        apt-get install -y -qq $pkg
        ok "$pkg installed"
    fi
done

systemctl enable --now libvirtd
virsh net-define /usr/share/libvirt/networks/default.xml 2>/dev/null || true
virsh net-start default 2>/dev/null || true
virsh net-autostart default 2>/dev/null || true
ok "libvirt ready"

#############################################
# 3. DOWNLOAD FREEBSD IMAGE
#############################################

echo ""
echo "=== FreeBSD Image ==="

mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

if [[ -f "$BASE_IMAGE" ]]; then
    ok "Image exists: $BASE_IMAGE"
else
    if [[ ! -f "$IMAGE_FILENAME" ]]; then
        echo "Downloading FreeBSD 15.0 ZFS image..."
        wget -q --show-progress -c "$FREEBSD_IMAGE_URL" -O "$IMAGE_FILENAME"
    fi
    echo "Decompressing..."
    xz -dkv "$IMAGE_FILENAME"
    ok "Image ready"
fi

#############################################
# 4. GENERATE VM SETUP SCRIPTS
#############################################

echo ""
echo "=== Generating VM Scripts ==="

for i in 0 1 2; do
    VM_NAME="${VM_NAMES[$i]}"
    VM_IP="${VM_IPS[$i]}"

    cat > "$WORK_DIR/setup-${VM_NAME}.sh" << VMEOF
#!/bin/sh
# ${VM_NAME} setup - FreeBSD 15.0 + ZFS

set -e

if [ -f "/root/.setup_complete" ]; then
    echo "Setup already done" > /dev/console
    exit 0
fi

echo "Configuring ${VM_NAME}..." > /dev/console

# Network
sysrc hostname="${VM_NAME}"
sysrc ifconfig_vtnet0="inet ${VM_IP} netmask ${NETMASK}"
sysrc defaultrouter="${GATEWAY}"
sysrc sshd_enable="YES"

sed -i '' 's/#PermitRootLogin no/PermitRootLogin yes/' /etc/ssh/sshd_config
sed -i '' 's/#PermitRootLogin prohibit-password/PermitRootLogin yes/' /etc/ssh/sshd_config
echo "PermitRootLogin yes" >> /etc/ssh/sshd_config

cat > /etc/resolv.conf << DNS
nameserver 8.8.8.8
nameserver 8.8.4.4
DNS

hostname ${VM_NAME}

# ZFS pool on data disk
if ! zpool list tbpool >/dev/null 2>&1; then
    echo "Creating ZFS pool..." > /dev/console

    if [ ! -e "/dev/vtbd1p1" ]; then
        gpart create -s GPT vtbd1
        gpart add -t freebsd-zfs -l tbdata vtbd1
    fi

    zpool create -o ashift=12 -O compression=lz4 -O atime=off tbpool /dev/vtbd1p1
    zfs create tbpool/tigerbeetle
    zfs create tbpool/tigerbeetle/data
    zfs set mountpoint=/tbdata tbpool
fi

sysrc zfs_enable="YES"
mkdir -p /tbdata/tigerbeetle/data

# AIO module
echo 'aio_load="YES"' >> /boot/loader.conf
kldload aio 2>/dev/null || true

# Dummynet for chaos testing
echo 'dummynet_load="YES"' >> /boot/loader.conf
kldload dummynet 2>/dev/null || true
sysrc firewall_enable="YES"
sysrc firewall_type="open"

# Packages
env ASSUME_ALWAYS_YES=YES pkg bootstrap
pkg update -q
pkg install -y git curl wget nano htop

# Done
touch /root/.setup_complete
echo "# Setup complete" > /etc/rc.local

echo "${VM_NAME} configured: ${VM_IP}" > /dev/console
echo "Rebooting..." > /dev/console
sleep 3
reboot
VMEOF

    chmod +x "$WORK_DIR/setup-${VM_NAME}.sh"
    ok "setup-${VM_NAME}.sh"
done

#############################################
# 5. CREATE VMs
#############################################

echo ""
echo "=== Creating VMs ==="

export LIBGUESTFS_BACKEND=direct

for i in 0 1 2; do
    VM_NAME="${VM_NAMES[$i]}"
    VM_IP="${VM_IPS[$i]}"
    BOOT_DISK="${LIBVIRT_IMAGES}/${VM_NAME}.qcow2"
    DATA_DISK="${LIBVIRT_IMAGES}/${VM_NAME}-data.qcow2"
    SETUP_SCRIPT="$WORK_DIR/setup-${VM_NAME}.sh"

    if virsh dominfo "$VM_NAME" &>/dev/null; then
        ok "${VM_NAME} exists"
        continue
    fi

    echo "Creating ${VM_NAME}..."

    cp "$WORK_DIR/$BASE_IMAGE" "$BOOT_DISK"
    qemu-img resize "$BOOT_DISK" "$VM_DISK_SIZE" >/dev/null

    if [[ ! -f "$DATA_DISK" ]]; then
        qemu-img create -f qcow2 "$DATA_DISK" "$VM_DATA_DISK_SIZE" >/dev/null
    fi

    virt-customize -a "$BOOT_DISK" \
        --run-command 'echo "console=\"comconsole\"" >> /boot/loader.conf' \
        --run-command 'echo "autoboot_delay=\"0\"" >> /boot/loader.conf' \
        --upload "${SETUP_SCRIPT}:/root/setup.sh" \
        --run-command 'chmod +x /root/setup.sh' \
        --run-command 'echo "/root/setup.sh >> /var/log/setup.log 2>&1" >> /etc/rc.local' \
        --run-command 'chmod +x /etc/rc.local' \
        --root-password password:root \
        >/dev/null 2>&1

    virt-install \
        --name "$VM_NAME" \
        --ram "$VM_RAM_MB" \
        --vcpus "$VM_VCPUS" \
        --disk path="$BOOT_DISK",format=qcow2,bus=virtio \
        --disk path="$DATA_DISK",format=qcow2,bus=virtio \
        --network network=default,model=virtio \
        --os-variant freebsd15.0 \
        --import \
        --graphics none \
        --noautoconsole >/dev/null

    ok "${VM_NAME} created"
done

#############################################
# 6. WAIT FOR SSH
#############################################

echo ""
echo "=== Waiting for VMs (will reboot once) ==="

for i in 0 1 2; do
    VM_NAME="${VM_NAMES[$i]}"
    IP="${VM_IPS[$i]}"
    echo -n "Waiting for ${VM_NAME}..."

    ssh-keygen -f "$HOME/.ssh/known_hosts" -R "$IP" >/dev/null 2>&1 || true

    while ! ping -c 1 -W 1 $IP >/dev/null 2>&1; do
        echo -n "."
        sleep 3
    done

    while ! ssh -o StrictHostKeyChecking=no -o ConnectTimeout=2 root@$IP "echo ok" >/dev/null 2>&1; do
        echo -n "."
        sleep 3
    done

    echo " OK"
done

ok "All VMs online"

#############################################
# 7. BUILD SCRIPT
#############################################

echo ""
echo "=== Generating Helper Scripts ==="

cat > "$WORK_DIR/build-tigerbeetle.sh" << 'BUILDEOF'
#!/bin/sh
# Build TigerBeetle on FreeBSD 15.0

set -e

ZIG_VERSION="0.14.1"

if command -v zig >/dev/null 2>&1; then
    echo "Zig installed: $(zig version)"
else
    echo "Installing Zig..."
    cd /tmp
    [ ! -f "zig-freebsd-x86_64-${ZIG_VERSION}.tar.xz" ] && \
        fetch "https://ziglang.org/download/${ZIG_VERSION}/zig-freebsd-x86_64-${ZIG_VERSION}.tar.xz"
    tar -xf zig-freebsd-x86_64-${ZIG_VERSION}.tar.xz
    rm -rf /usr/local/zig
    mv zig-freebsd-x86_64-${ZIG_VERSION} /usr/local/zig
    ln -sf /usr/local/zig/zig /usr/local/bin/zig
fi

cd /root
if [ -d "tigerbeetle" ]; then
    cd tigerbeetle && git fetch && git checkout freebsd-port && git pull
else
    git clone https://github.com/nmarasoiu/tigerbeetle.git
    cd tigerbeetle && git checkout freebsd-port
fi

echo "Building..."
zig build -Doptimize=ReleaseSafe

./zig-out/bin/tigerbeetle version
echo "Done: /root/tigerbeetle/zig-out/bin/tigerbeetle"
BUILDEOF

chmod +x "$WORK_DIR/build-tigerbeetle.sh"
ok "build-tigerbeetle.sh"

#############################################
# 8. CLUSTER SCRIPTS
#############################################

cat > "$WORK_DIR/format-cluster.sh" << 'EOF'
#!/bin/bash
set -e
IPS=("192.168.122.10" "192.168.122.11" "192.168.122.12")
TB="/root/tigerbeetle/zig-out/bin/tigerbeetle"

echo "Formatting cluster..."
for i in 0 1 2; do
    ssh -o StrictHostKeyChecking=no root@${IPS[$i]} \
        "$TB format --cluster=0 --replica=$i --replica-count=3 /tbdata/tigerbeetle/data/0_${i}.tigerbeetle"
    echo "Replica $i formatted"
done
echo "Done"
EOF
chmod +x "$WORK_DIR/format-cluster.sh"
ok "format-cluster.sh"

cat > "$WORK_DIR/start-cluster.sh" << 'EOF'
#!/bin/bash
IPS=("192.168.122.10" "192.168.122.11" "192.168.122.12")
ADDRS="192.168.122.10:3001,192.168.122.11:3001,192.168.122.12:3001"
TB="/root/tigerbeetle/zig-out/bin/tigerbeetle"

echo "Starting cluster..."
for i in 0 1 2; do
    ssh -o StrictHostKeyChecking=no root@${IPS[$i]} \
        "nohup $TB start --addresses=$ADDRS /tbdata/tigerbeetle/data/0_${i}.tigerbeetle > /var/log/tigerbeetle.log 2>&1 &"
    echo "Replica $i started"
done
echo "Addresses: $ADDRS"
EOF
chmod +x "$WORK_DIR/start-cluster.sh"
ok "start-cluster.sh"

cat > "$WORK_DIR/stop-cluster.sh" << 'EOF'
#!/bin/bash
IPS=("192.168.122.10" "192.168.122.11" "192.168.122.12")
for i in 0 1 2; do
    ssh -o StrictHostKeyChecking=no root@${IPS[$i]} "pkill tigerbeetle" 2>/dev/null || true
done
echo "Stopped"
EOF
chmod +x "$WORK_DIR/stop-cluster.sh"
ok "stop-cluster.sh"

cat > "$WORK_DIR/status.sh" << 'EOF'
#!/bin/bash
IPS=("192.168.122.10" "192.168.122.11" "192.168.122.12")
VMS=("tb-freebsd-0" "tb-freebsd-1" "tb-freebsd-2")

echo ""
echo "VM               State        IP              TB"
echo "-------------    ----------   -------------   --------"
for i in 0 1 2; do
    STATE=$(virsh domstate ${VMS[$i]} 2>/dev/null || echo "not found")
    if [[ "$STATE" == "running" ]]; then
        TB=$(ssh -o StrictHostKeyChecking=no -o ConnectTimeout=2 root@${IPS[$i]} \
            "pgrep tigerbeetle >/dev/null && echo running || echo stopped" 2>/dev/null || echo "?")
    else
        TB="-"
    fi
    printf "%-16s %-12s %-15s %s\n" "${VMS[$i]}" "$STATE" "${IPS[$i]}" "$TB"
done
echo ""
EOF
chmod +x "$WORK_DIR/status.sh"
ok "status.sh"

#############################################
# 9. DEPLOY BUILD SCRIPT
#############################################

echo ""
echo "=== Deploying to VMs ==="

for i in 0 1 2; do
    scp -o StrictHostKeyChecking=no "$WORK_DIR/build-tigerbeetle.sh" root@${VM_IPS[$i]}:/root/ >/dev/null
    ok "Deployed to ${VM_NAMES[$i]}"
done

#############################################
# 10. DONE
#############################################

echo ""
echo "========================================"
echo "  SETUP COMPLETE"
echo "========================================"
echo ""
echo "VMs:"
echo "  tb-freebsd-0: 192.168.122.10"
echo "  tb-freebsd-1: 192.168.122.11"
echo "  tb-freebsd-2: 192.168.122.12"
echo ""
echo "Root password: root"
echo "Work dir: $WORK_DIR"
echo ""
echo "NEXT:"
echo ""
echo "  1. Build TigerBeetle:"
echo "     ssh root@192.168.122.10 './build-tigerbeetle.sh'"
echo ""
echo "  2. Copy binary to other nodes:"
echo "     for ip in 192.168.122.11 192.168.122.12; do"
echo "       ssh root@192.168.122.10 \"scp /root/tigerbeetle/zig-out/bin/tigerbeetle root@\$ip:/root/tigerbeetle/zig-out/bin/\""
echo "     done"
echo ""
echo "  3. Format and start:"
echo "     $WORK_DIR/format-cluster.sh"
echo "     $WORK_DIR/start-cluster.sh"
echo "     $WORK_DIR/status.sh"
echo ""