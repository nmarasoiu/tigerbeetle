# GCP Setup: FreeBSD + ZFS Test Environment

## Prerequisites

1. GCP account with billing enabled
2. `gcloud` CLI installed and authenticated
3. A GCP project (create one if needed)

```bash
# Authenticate
gcloud auth login

# Set project
gcloud config set project YOUR_PROJECT_ID

# Enable Compute Engine API
gcloud services enable compute.googleapis.com
```

## Step 1: Create VPC Network

```bash
# Create VPC
gcloud compute networks create tigerbeetle-net \
    --subnet-mode=custom

# Create subnet
gcloud compute networks subnets create tigerbeetle-subnet \
    --network=tigerbeetle-net \
    --region=us-central1 \
    --range=10.0.0.0/24

# Firewall: allow internal traffic
gcloud compute firewall-rules create tigerbeetle-internal \
    --network=tigerbeetle-net \
    --allow=tcp,udp,icmp \
    --source-ranges=10.0.0.0/24

# Firewall: allow SSH from your IP
gcloud compute firewall-rules create tigerbeetle-ssh \
    --network=tigerbeetle-net \
    --allow=tcp:22 \
    --source-ranges=YOUR_IP/32
```

## Step 2: Create FreeBSD VMs

```bash
# List available FreeBSD images
gcloud compute images list --filter="family:freebsd"

# Create 3 TigerBeetle nodes
for i in 1 2 3; do
  gcloud compute instances create tb-node-$i \
    --zone=us-central1-a \
    --machine-type=n2-standard-4 \
    --image-family=freebsd-14-1 \
    --image-project=freebsd-org-cloud-dev \
    --boot-disk-size=20GB \
    --boot-disk-type=pd-ssd \
    --network=tigerbeetle-net \
    --subnet=tigerbeetle-subnet \
    --private-network-ip=10.0.0.$((10+i)) \
    --create-disk=name=tb-data-$i,size=100GB,type=pd-ssd,auto-delete=yes
done

# Create test driver VM (can be Linux for easier tooling)
gcloud compute instances create tb-driver \
    --zone=us-central1-a \
    --machine-type=n2-standard-2 \
    --image-family=debian-12 \
    --image-project=debian-cloud \
    --boot-disk-size=20GB \
    --network=tigerbeetle-net \
    --subnet=tigerbeetle-subnet \
    --private-network-ip=10.0.0.100
```

## Step 3: FreeBSD Initial Setup (on each tb-node)

SSH into each node:
```bash
gcloud compute ssh tb-node-1 --zone=us-central1-a
```

Run setup:
```bash
# Update packages
sudo pkg update && sudo pkg upgrade -y

# Install required tools
sudo pkg install -y git zig curl

# Find the data disk
camcontrol devlist
# Usually /dev/da1 or /dev/nvd1 for NVMe

# Create ZFS pool
sudo zpool create tbdata /dev/da1

# Create dataset
sudo zfs create tbdata/tigerbeetle
sudo zfs set compression=lz4 tbdata/tigerbeetle
sudo zfs set atime=off tbdata/tigerbeetle
sudo zfs set recordsize=64k tbdata/tigerbeetle

# Create data directory
sudo mkdir -p /tbdata/tigerbeetle/data
sudo chown $USER /tbdata/tigerbeetle/data

# Enable ipfw for chaos testing (add to /etc/rc.conf)
sudo sysrc firewall_enable="YES"
sudo sysrc firewall_type="open"

# Load dummynet
sudo kldload dummynet
# Make persistent
echo 'dummynet_load="YES"' | sudo tee -a /boot/loader.conf
```

## Step 4: Build TigerBeetle on FreeBSD

```bash
# Clone your fork
git clone https://github.com/YOUR_USERNAME/tigerbeetle.git
cd tigerbeetle
git checkout freebsd-port

# Build
zig build

# Verify
./zig-out/bin/tigerbeetle version
```

## Step 5: Initialize TigerBeetle Cluster

On **tb-node-1**:
```bash
cd ~/tigerbeetle

# Format replica 0
./zig-out/bin/tigerbeetle format \
    --cluster=0 \
    --replica=0 \
    --replica-count=3 \
    /tbdata/tigerbeetle/data/0_0.tigerbeetle
```

On **tb-node-2**:
```bash
./zig-out/bin/tigerbeetle format \
    --cluster=0 \
    --replica=1 \
    --replica-count=3 \
    /tbdata/tigerbeetle/data/0_1.tigerbeetle
```

On **tb-node-3**:
```bash
./zig-out/bin/tigerbeetle format \
    --cluster=0 \
    --replica=2 \
    --replica-count=3 \
    /tbdata/tigerbeetle/data/0_2.tigerbeetle
```

## Step 6: Start Cluster

On each node (replace replica number):
```bash
# Node 1
./zig-out/bin/tigerbeetle start \
    --addresses=10.0.0.11:3001,10.0.0.12:3001,10.0.0.13:3001 \
    /tbdata/tigerbeetle/data/0_0.tigerbeetle

# Node 2
./zig-out/bin/tigerbeetle start \
    --addresses=10.0.0.11:3001,10.0.0.12:3001,10.0.0.13:3001 \
    /tbdata/tigerbeetle/data/0_1.tigerbeetle

# Node 3
./zig-out/bin/tigerbeetle start \
    --addresses=10.0.0.11:3001,10.0.0.12:3001,10.0.0.13:3001 \
    /tbdata/tigerbeetle/data/0_2.tigerbeetle
```

Use `tmux` or `screen` to keep processes running, or create rc.d service scripts.

## Step 7: Verify Cluster Health

From tb-driver:
```bash
# Install TigerBeetle client (or use the benchmark tool)
# Connect and run basic operations
```

## Cost Management

```bash
# Stop VMs when not testing
gcloud compute instances stop tb-node-1 tb-node-2 tb-node-3 tb-driver \
    --zone=us-central1-a

# Start VMs when ready to test
gcloud compute instances start tb-node-1 tb-node-2 tb-node-3 tb-driver \
    --zone=us-central1-a

# Delete everything when done
gcloud compute instances delete tb-node-1 tb-node-2 tb-node-3 tb-driver \
    --zone=us-central1-a --quiet
gcloud compute firewall-rules delete tigerbeetle-internal tigerbeetle-ssh --quiet
gcloud compute networks subnets delete tigerbeetle-subnet --region=us-central1 --quiet
gcloud compute networks delete tigerbeetle-net --quiet
```

## Using Preemptible VMs (70% cheaper)

For testing where occasional VM preemption is acceptable:
```bash
gcloud compute instances create tb-node-$i \
    --preemptible \
    ... (other flags)
```

Note: Preemptible VMs can be terminated with 30s notice. Good for development, not for final validation.

## Snapshot for Quick Recovery

```bash
# Create snapshot of configured node
gcloud compute disks snapshot tb-node-1 \
    --zone=us-central1-a \
    --snapshot-names=tb-freebsd-configured

# Restore from snapshot for new nodes
gcloud compute instances create tb-node-new \
    --source-snapshot=tb-freebsd-configured \
    ... (other flags)
```
