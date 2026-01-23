#!/bin/bash
# IO Percentile Monitor - tracks pread64 latency AND queue depth percentiles
# For devices sdd-sdg

DEVICES="sdd sde sdf sdg"
SAMPLE_INTERVAL=0.05  # 50ms sampling for queue depth
DISPLAY_INTERVAL=5    # Update display every 5 seconds

# Arrays to store queue samples (we'll keep last N samples per device)
declare -A queue_samples
declare -A sample_count

for dev in $DEVICES; do
    queue_samples[$dev]=""
    sample_count[$dev]=0
done

# Function to calculate percentile from sorted list
calc_percentile() {
    local data="$1"
    local pct="$2"
    local count=$(echo "$data" | wc -w)
    if [ "$count" -eq 0 ]; then
        echo "0"
        return
    fi
    local sorted=$(echo "$data" | tr ' ' '\n' | sort -n)
    local idx=$(echo "($count * $pct / 100)" | bc)
    [ "$idx" -lt 1 ] && idx=1
    echo "$sorted" | sed -n "${idx}p"
}

echo "=============================================="
echo "IO Percentile Monitor"
echo "Devices: $DEVICES"
echo "=============================================="
echo ""
echo "This script monitors two things:"
echo "1. Queue depth percentiles (how full is the queue typically?)"
echo "2. pread64 latency (requires bpftrace in separate terminal)"
echo ""
echo "Starting queue depth sampling..."
echo ""

# For queue monitoring, we sample continuously and compute percentiles
iteration=0
while true; do
    # Collect samples for ~5 seconds
    for i in $(seq 1 100); do  # 100 samples at 50ms = 5 seconds
        for dev in $DEVICES; do
            current=$(cat /sys/block/$dev/inflight 2>/dev/null | awk '{print $1+$2}')
            queue_samples[$dev]="${queue_samples[$dev]} $current"
            # Keep only last 1000 samples (~50 seconds of history)
            sample_count[$dev]=$((${sample_count[$dev]} + 1))
            if [ ${sample_count[$dev]} -gt 1000 ]; then
                queue_samples[$dev]=$(echo "${queue_samples[$dev]}" | cut -d' ' -f2-)
                sample_count[$dev]=1000
            fi
        done
        sleep $SAMPLE_INTERVAL
    done
    
    # Display results
    clear
    echo "=============================================="
    echo "IO Percentile Monitor - $(date)"
    echo "=============================================="
    echo ""
    echo "QUEUE DEPTH PERCENTILES (samples: ${sample_count[sdd]})"
    echo "----------------------------------------------"
    printf "%-6s %8s %8s %8s %8s %8s  %s\n" "Device" "p50" "p75" "p90" "p99" "max" "Visualization (p90)"
    echo "----------------------------------------------"
    
    for dev in $DEVICES; do
        data="${queue_samples[$dev]}"
        p50=$(calc_percentile "$data" 50)
        p75=$(calc_percentile "$data" 75)
        p90=$(calc_percentile "$data" 90)
        p99=$(calc_percentile "$data" 99)
        max=$(echo "$data" | tr ' ' '\n' | sort -n | tail -1)
        
        # Visual bar showing p90 (not max)
        bar=""
        for i in $(seq 1 30); do
            if [ $i -le $p50 ]; then
                bar="${bar}█"
            elif [ $i -le $p90 ]; then
                bar="${bar}▓"
            else
                bar="${bar}-"
            fi
        done
        
        printf "%-6s %8s %8s %8s %8s %8s  [%s]\n" "$dev" "$p50" "$p75" "$p90" "$p99" "$max" "$bar"
    done
    
    echo ""
    echo "Legend: █ = median (p50)  ▓ = up to p90  - = unused"
    echo ""
    echo "----------------------------------------------"
    echo "For pread64 LATENCY percentiles, run in another terminal:"
    echo ""
    echo "  sudo bpftrace -e '"
    echo "    tracepoint:syscalls:sys_exit_pread64"
    echo "    /comm == \"storagenode\"/ {"
    echo "      @usecs = hist((nsecs - @start[tid]) / 1000);"
    echo "    }"
    echo "    tracepoint:syscalls:sys_enter_pread64"
    echo "    /comm == \"storagenode\"/ {"
    echo "      @start[tid] = nsecs;"
    echo "    }'"
    echo ""
    
    ((iteration++))
done
