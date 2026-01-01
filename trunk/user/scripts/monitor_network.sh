#!/bin/sh

# Network Monitor Script
# Usage: 
#   monitor_network.sh check  - Perform a single check (for cron)
#   monitor_network.sh stats  - Show daily statistics
#   monitor_network.sh daemon - Run in loop (if cron not available)

# Configuration
TARGETS="223.5.5.5 114.114.114.114 8.8.8.8"
TIMEOUT=2
PING_COUNT=1

# Log file location
# Prefer persistent storage if available (from previous modification)
if [ -d "/media/storage_emmc" ]; then
    LOG_DIR="/media/storage_emmc/logs"
    [ ! -d "$LOG_DIR" ] && mkdir -p "$LOG_DIR"
    LOG_FILE="$LOG_DIR/network_monitor.log"
elif [ -d "/etc/storage/inet_log" ]; then
     # If user manually created this or we want to use MTD/persistent /etc (less preferred due to wear)
     LOG_FILE="/etc/storage/inet_log/network_monitor.log"
else
    # Fallback to RAM
    LOG_FILE="/tmp/network_monitor.log"
fi

check_connectivity() {
    for ip in $TARGETS; do
        ping -c $PING_COUNT -W $TIMEOUT -q $ip >/dev/null 2>&1
        if [ $? -eq 0 ]; then
            return 0 # Connected
        fi
    done
    return 1 # Disconnected
}

log_event() {
    status=$1
    timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    echo "$timestamp|$status" >> "$LOG_FILE"
}

cmd_check() {
    check_connectivity
    if [ $? -eq 0 ]; then
        # Check if last state was down, maybe log recovery? 
        # For now, we only log DOWN events to keep log size small, 
        # OR we can keep a state file to log UP/DOWN transitions.
        
        if [ -f "/tmp/net_monitor.state" ]; then
            last_state=$(cat /tmp/net_monitor.state)
            if [ "$last_state" == "DOWN" ]; then
                log_event "UP"
            fi
        fi
        echo "UP" > /tmp/net_monitor.state
    else
        log_event "DOWN"
        echo "DOWN" > /tmp/net_monitor.state
    fi
}

cmd_stats() {
    if [ ! -f "$LOG_FILE" ]; then
        echo "No log file found at $LOG_FILE"
        return
    fi
    
    echo "Network Stability Statistics ($LOG_FILE)"
    echo "----------------------------------------"
    # Basic analysis using awk
    awk -F"|" '
    BEGIN { 
        print "Date       | Events | Details"
        print "-----------|--------|--------"
    }
    {
        date = substr($1, 1, 10)
        status = $2
        events[date]++
        if (status == "DOWN") {
            drops[date]++
        }
    }
    END {
        for (d in events) {
            printf "%s | Total: %d, Drops: %d\n", d, events[d], drops[d]
        }
    }
    ' "$LOG_FILE" | sort
}

cmd_daemon() {
    echo "Starting Network Monitor Daemon..."
    while true; do
        cmd_check
        sleep 60
    done
}

case "$1" in
    check)
        cmd_check
        ;;
    stats)
        cmd_stats
        ;;
    daemon)
        cmd_daemon
        ;;
    *)
        echo "Usage: $0 {check|stats|daemon}"
        exit 1
        ;;
esac
