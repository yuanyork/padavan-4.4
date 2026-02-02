#!/bin/sh

# System Health Monitor - Detect system hang/freeze
# Monitors critical services and system responsiveness
# Usage:
#   monitor_system_health.sh daemon  - Run as daemon (recommended)
#   monitor_system_health.sh check   - Single check (for cron)
#   monitor_system_health.sh status  - Show status

# Configuration
WATCHDOG_FILE="/tmp/system_health.watchdog"
HEARTBEAT_FILE="/tmp/system_health.heartbeat"
PID_FILE="/var/run/system_health.pid"
MAX_FAIL_COUNT=3
REBOOT_THRESHOLD=3  # Reboot after 3 consecutive failures (3 minutes)
CHECK_INTERVAL=60   # Check every 60 seconds in daemon mode
SELF_CHECK_TIMEOUT=120  # Self-watchdog: reboot if no successful check in 120s

# Log directory
if [ -d "/media/storage_emmc" ]; then
    LOG_DIR="/media/storage_emmc/logs"
    [ ! -d "$LOG_DIR" ] && mkdir -p "$LOG_DIR"
    LOG_FILE="$LOG_DIR/system_health.log"
else
    LOG_FILE="/tmp/system_health.log"
fi

log_msg() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE"
}

check_critical_services() {
    failed_services=""

    # Check HTTP server (httpd or lighttpd)
    if ! pidof httpd >/dev/null && ! pidof lighttpd >/dev/null; then
        failed_services="${failed_services}httpd "
    fi

    # Check SSH server (dropbear)
    if ! pidof dropbear >/dev/null; then
        failed_services="${failed_services}dropbear "
    fi

    # Check dnsmasq
    if ! pidof dnsmasq >/dev/null; then
        failed_services="${failed_services}dnsmasq "
    fi

    echo "$failed_services"
}

check_system_load() {
    # Get 1-minute load average
    load=$(awk '{print $1}' /proc/loadavg)
    # Compare with number of CPUs (MT7621 has 2 cores, so load > 10 is critical)
    high_load=$(echo "$load > 10" | bc 2>/dev/null || echo "0")
    echo "$high_load"
}

check_memory() {
    # Check if free memory is critically low (< 1MB)
    mem_free=$(awk '/MemFree/ {print $2}' /proc/meminfo)
    if [ "$mem_free" -lt 1024 ]; then
        echo "1"
    else
        echo "0"
    fi
}

restart_critical_service() {
    service=$1
    log_msg "CRITICAL: Restarting $service"

    case "$service" in
        httpd)
            /sbin/restart_httpd
            ;;
        dropbear)
            killall dropbear 2>/dev/null
            /usr/sbin/dropbear -p 22
            ;;
        dnsmasq)
            killall dnsmasq 2>/dev/null
            /usr/sbin/dnsmasq
            ;;
    esac
}

# Main check
check_system() {
    # Initialize fail counter
    if [ ! -f "$WATCHDOG_FILE" ]; then
        echo "0" > "$WATCHDOG_FILE"
    fi

    fail_count=$(cat "$WATCHDOG_FILE")
    current_issues=""

    # Check critical services
    failed_svcs=$(check_critical_services)
    if [ -n "$failed_svcs" ]; then
        current_issues="${current_issues}Services_Down:$failed_svcs; "

        # Try to restart services first
        for svc in $failed_svcs; do
            restart_critical_service "$svc"
        done

        fail_count=$((fail_count + 1))
    fi

    # Check system load
    if [ "$(check_system_load)" = "1" ]; then
        current_issues="${current_issues}High_Load; "
        fail_count=$((fail_count + 1))
    fi

    # Check memory
    if [ "$(check_memory)" = "1" ]; then
        current_issues="${current_issues}Low_Memory; "
        fail_count=$((fail_count + 1))
    fi

    # Log if issues found
    if [ -n "$current_issues" ]; then
        log_msg "ISSUE: $current_issues (Fail count: $fail_count/$REBOOT_THRESHOLD)"

        # Trigger crash dump for diagnosis
        if [ -x /usr/bin/monitor_crash.sh ]; then
            /usr/bin/monitor_crash.sh &
        fi

        # Update fail counter
        echo "$fail_count" > "$WATCHDOG_FILE"

        # Reboot if threshold exceeded
        if [ "$fail_count" -ge "$REBOOT_THRESHOLD" ]; then
            log_msg "CRITICAL: System unresponsive for $fail_count checks. Initiating reboot."
            sync
            sleep 2
            reboot -f
        fi
    else
        # System healthy - reset counter
        if [ "$fail_count" -gt 0 ]; then
            log_msg "RECOVERY: System health restored"
        fi
        echo "0" > "$WATCHDOG_FILE"
    fi
}

show_status() {
    echo "System Health Status:"
    echo "--------------------"
    failed_svcs=$(check_critical_services)
    if [ -z "$failed_svcs" ]; then
        echo "✓ All critical services running"
    else
        echo "✗ Failed services: $failed_svcs"
    fi

    load=$(awk '{print $1}' /proc/loadavg)
    echo "Load average: $load"

    mem_free=$(awk '/MemFree/ {print $2}' /proc/meminfo)
    echo "Free memory: ${mem_free}kB"

    if [ -f "$WATCHDOG_FILE" ]; then
        echo "Fail counter: $(cat $WATCHDOG_FILE)/$REBOOT_THRESHOLD"
    fi

    if [ -f "$LOG_FILE" ]; then
        echo ""
        echo "Recent issues:"
        tail -n 10 "$LOG_FILE"
    fi
}

update_heartbeat() {
    date +%s > "$HEARTBEAT_FILE"
}

check_self_watchdog() {
    # Self-protection: if heartbeat is too old, something is wrong with monitoring itself
    if [ -f "$HEARTBEAT_FILE" ]; then
        last_beat=$(cat "$HEARTBEAT_FILE" 2>/dev/null || echo "0")
        now=$(date +%s)
        age=$((now - last_beat))

        if [ "$age" -gt "$SELF_CHECK_TIMEOUT" ]; then
            log_msg "CRITICAL: Self-watchdog triggered! No successful check in ${age}s. Rebooting."
            sync
            sleep 2
            reboot -f
        fi
    fi
}

daemon_mode() {
    # Check if already running
    if [ -f "$PID_FILE" ]; then
        old_pid=$(cat "$PID_FILE")
        if kill -0 "$old_pid" 2>/dev/null; then
            echo "System health monitor already running (PID: $old_pid)"
            exit 1
        fi
    fi

    # Daemonize
    echo $$ > "$PID_FILE"
    log_msg "System health monitor daemon started (PID: $$, interval: ${CHECK_INTERVAL}s)"

    # Initialize heartbeat
    update_heartbeat

    # Main loop
    while true; do
        # Self-watchdog check (in case check_system hangs)
        check_self_watchdog

        # Perform actual system check
        check_system

        # Update heartbeat on successful completion
        update_heartbeat

        # Sleep until next check
        sleep "$CHECK_INTERVAL"
    done
}

stop_daemon() {
    if [ -f "$PID_FILE" ]; then
        pid=$(cat "$PID_FILE")
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid"
            log_msg "System health monitor stopped (PID: $pid)"
            rm -f "$PID_FILE"
            echo "System health monitor stopped"
        else
            echo "No running process found"
            rm -f "$PID_FILE"
        fi
    else
        echo "System health monitor is not running"
    fi
}

case "$1" in
    daemon)
        daemon_mode
        ;;
    check)
        check_system
        ;;
    status)
        show_status
        ;;
    stop)
        stop_daemon
        ;;
    *)
        echo "Usage: $0 {daemon|check|status|stop}"
        echo ""
        echo "  daemon - Run as background daemon (recommended)"
        echo "  check  - Perform single check"
        echo "  status - Show current status"
        echo "  stop   - Stop daemon"
        exit 1
        ;;
esac
