#!/bin/sh

# Crash Monitor - System State Snapshot
# Save detailed diagnostics to help debug router crashes/instability

# Configuration
LOG_BASE_DIR="/media/storage_emmc/logs"
CRASH_DIR="${LOG_BASE_DIR}/crash_dumps"
MAX_LOG_FILES=10

[ ! -d "$CRASH_DIR" ] && mkdir -p "$CRASH_DIR"

timestamp=$(date "+%Y%m%d_%H%M%S")
log_file="$CRASH_DIR/crash_${timestamp}.log"

echo "=== System Snapshot at $timestamp ===" > "$log_file"

# 1. System Load
echo "--- Uptime & Load ---" >> "$log_file"
uptime >> "$log_file"

# 2. Memory Usage (Detailed)
echo -e "\n--- Memory Info ---" >> "$log_file"
cat /proc/meminfo >> "$log_file"
echo -e "\n--- Slab Info (top 20) ---" >> "$log_file"
cat /proc/slabinfo | head -22 >> "$log_file" # Header + top lines (usually mostly static but good to check)

# 3. Process List (Top CPU/Mem)
echo -e "\n--- Top Processes ---" >> "$log_file"
top -b -n 1 | head -n 30 >> "$log_file"

# 4. Connection Tracking
echo -e "\n--- NF Conntrack Count ---" >> "$log_file"
if [ -f /proc/net/nf_conntrack_count ]; then
    cat /proc/net/nf_conntrack_count >> "$log_file"
else
    echo "N/A" >> "$log_file"
fi

# 5. Interrupts (Check for storms)
echo -e "\n--- Interrupts ---" >> "$log_file"
cat /proc/interrupts >> "$log_file"

# 6. Network Interfaces
echo -e "\n--- Network Interfaces ---" >> "$log_file"
ifconfig >> "$log_file"

# 7. WiFi Driver Info (Proprietary MTK)
# CRITICAL FIX: Add timeout to prevent hang when driver freezes
echo -e "\n--- WiFi State (rai0) ---" >> "$log_file"
timeout 3 iwpriv rai0 show stat 2>/dev/null >> "$log_file" || echo "  (show stat timed out)" >> "$log_file"
timeout 3 iwpriv rai0 show conn 2>/dev/null >> "$log_file" || echo "  (show conn timed out)" >> "$log_file"
timeout 3 iwpriv rai0 get_mac_table 2>/dev/null >> "$log_file" || echo "  (get_mac_table timed out)" >> "$log_file"

echo -e "\n--- WiFi State (ra0) ---" >> "$log_file"
timeout 3 iwpriv ra0 show stat 2>/dev/null >> "$log_file" || echo "  (show stat timed out)" >> "$log_file"

# 8. Full Kernel Log
echo -e "\n--- DMESG (Tail 500) ---" >> "$log_file"
dmesg | tail -n 500 >> "$log_file"

# Cleanup old logs
count=$(ls -1 "$CRASH_DIR"/crash_*.log 2>/dev/null | wc -l)
if [ "$count" -gt "$MAX_LOG_FILES" ]; then
    ls -1t "$CRASH_DIR"/crash_*.log | tail -n +$(($MAX_LOG_FILES + 1)) | xargs rm -f
fi

echo "Snapshot saved to $log_file"
