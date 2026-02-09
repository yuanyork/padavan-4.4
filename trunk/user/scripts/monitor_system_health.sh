#!/bin/sh

# System Health Monitor - Enhanced Version
# Detects system hang/freeze AND service unresponsiveness
# Usage:
#   monitor_system_health.sh daemon  - Run as daemon (recommended)
#   monitor_system_health.sh check   - Single check (for cron)
#   monitor_system_health.sh status  - Show status
#   monitor_system_health.sh diag    - Full diagnostic report

# Configuration
WATCHDOG_FILE="/tmp/system_health.watchdog"
HEARTBEAT_FILE="/tmp/system_health.heartbeat"
PID_FILE="/var/run/system_health.pid"
REBOOT_THRESHOLD=3       # Reboot after 3 consecutive failures (3 minutes)
CHECK_INTERVAL=60        # Check every 60 seconds in daemon mode
SELF_CHECK_TIMEOUT=120   # Self-watchdog: reboot if no successful check in 120s
SERVICE_TIMEOUT=5        # Timeout for service responsiveness check

# Log directory
if [ -d "/media/storage_emmc" ]; then
    LOG_DIR="/media/storage_emmc/logs"
    [ ! -d "$LOG_DIR" ] && mkdir -p "$LOG_DIR"
    LOG_FILE="$LOG_DIR/system_health.log"
    DIAG_DIR="$LOG_DIR/diagnostics"
else
    LOG_FILE="/tmp/system_health.log"
    DIAG_DIR="/tmp/diagnostics"
fi
[ ! -d "$DIAG_DIR" ] && mkdir -p "$DIAG_DIR"

log_msg() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE"
    logger -t "health_monitor" "$1"
}

# ============================================================
# ENHANCED: Check if service is RESPONDING, not just running
# ============================================================

check_httpd_responsive() {
    # Check if httpd process exists
    if ! pidof httpd >/dev/null && ! pidof lighttpd >/dev/null; then
        echo "DEAD"
        return
    fi

    # Check if httpd is RESPONDING (this catches hung processes)
    http_port=$(nvram get http_lanport 2>/dev/null || echo "80")
    if timeout $SERVICE_TIMEOUT wget -q -O /dev/null "http://127.0.0.1:${http_port}/" 2>/dev/null; then
        echo "OK"
    else
        # Process exists but not responding
        echo "HUNG"
    fi
}

check_dropbear_responsive() {
    # Check if dropbear process exists
    if ! pidof dropbear >/dev/null; then
        echo "DEAD"
        return
    fi

    # Check if dropbear is RESPONDING (can accept connections)
    ssh_port=$(nvram get sshd_port 2>/dev/null || echo "22")
    if timeout $SERVICE_TIMEOUT sh -c "echo '' | nc 127.0.0.1 $ssh_port" 2>/dev/null | grep -q "SSH"; then
        echo "OK"
    else
        # Try alternative check: can we connect at all?
        if timeout $SERVICE_TIMEOUT sh -c "echo 'quit' | nc -w 2 127.0.0.1 $ssh_port" >/dev/null 2>&1; then
            echo "OK"
        else
            echo "HUNG"
        fi
    fi
}

check_dnsmasq_responsive() {
    # Check if dnsmasq process exists
    if ! pidof dnsmasq >/dev/null; then
        echo "DEAD"
        return
    fi

    # Check if dnsmasq responds to DNS queries
    if timeout $SERVICE_TIMEOUT nslookup localhost 127.0.0.1 >/dev/null 2>&1; then
        echo "OK"
    else
        echo "HUNG"
    fi
}

# ============================================================
# Resource checks
# ============================================================

check_system_load() {
    load=$(awk '{print $1}' /proc/loadavg)
    # MT7621 has 2 cores, load > 10 is critical
    load_int=$(echo "$load" | cut -d. -f1)
    if [ "$load_int" -gt 10 ]; then
        echo "CRITICAL:$load"
    elif [ "$load_int" -gt 5 ]; then
        echo "HIGH:$load"
    else
        echo "OK:$load"
    fi
}

check_memory() {
    mem_free=$(awk '/MemFree/ {print $2}' /proc/meminfo)
    mem_available=$(awk '/MemAvailable/ {print $2}' /proc/meminfo 2>/dev/null || echo "$mem_free")

    if [ "$mem_available" -lt 2048 ]; then
        echo "CRITICAL:${mem_available}kB"
    elif [ "$mem_available" -lt 8192 ]; then
        echo "LOW:${mem_available}kB"
    else
        echo "OK:${mem_available}kB"
    fi
}

check_conntrack() {
    # Check connection tracking table usage
    if [ -f /proc/sys/net/nf_conntrack_max ]; then
        max=$(cat /proc/sys/net/nf_conntrack_max)
        current=$(cat /proc/sys/net/nf_conntrack_count 2>/dev/null || echo "0")

        if [ "$max" -gt 0 ]; then
            usage=$((current * 100 / max))
            if [ "$usage" -gt 90 ]; then
                echo "CRITICAL:${current}/${max}(${usage}%)"
            elif [ "$usage" -gt 70 ]; then
                echo "HIGH:${current}/${max}(${usage}%)"
            else
                echo "OK:${current}/${max}(${usage}%)"
            fi
        else
            echo "OK:N/A"
        fi
    else
        echo "OK:N/A"
    fi
}

check_file_descriptors() {
    # Check system-wide file descriptor usage
    if [ -f /proc/sys/fs/file-nr ]; then
        read allocated free max < /proc/sys/fs/file-nr
        usage=$((allocated * 100 / max))
        if [ "$usage" -gt 90 ]; then
            echo "CRITICAL:${allocated}/${max}(${usage}%)"
        elif [ "$usage" -gt 70 ]; then
            echo "HIGH:${allocated}/${max}(${usage}%)"
        else
            echo "OK:${allocated}/${max}(${usage}%)"
        fi
    else
        echo "OK:N/A"
    fi
}

# ============================================================
# Service recovery
# ============================================================

restart_service() {
    service=$1
    reason=$2
    log_msg "RESTART: $service ($reason)"

    case "$service" in
        httpd)
            killall -9 httpd 2>/dev/null
            sleep 1
            /sbin/restart_httpd 2>/dev/null || start_httpd
            ;;
        dropbear)
            killall -9 dropbear 2>/dev/null
            sleep 1
            ssh_port=$(nvram get sshd_port 2>/dev/null || echo "22")
            /usr/sbin/dropbear -p "$ssh_port"
            ;;
        dnsmasq)
            killall -9 dnsmasq 2>/dev/null
            sleep 1
            /sbin/restart_dhcpd 2>/dev/null || /usr/sbin/dnsmasq
            ;;
    esac
}

# ============================================================
# Full diagnostic report
# ============================================================

collect_diagnostics() {
    timestamp=$(date "+%Y%m%d_%H%M%S")
    diag_file="$DIAG_DIR/diag_${timestamp}.log"

    {
        echo "=== System Diagnostic Report ==="
        echo "Timestamp: $(date)"
        echo "Uptime: $(uptime)"
        echo ""

        echo "=== Service Status ==="
        echo "httpd: $(check_httpd_responsive)"
        echo "dropbear: $(check_dropbear_responsive)"
        echo "dnsmasq: $(check_dnsmasq_responsive)"
        echo ""

        echo "=== Resource Status ==="
        echo "Load: $(check_system_load)"
        echo "Memory: $(check_memory)"
        echo "Conntrack: $(check_conntrack)"
        echo "File Descriptors: $(check_file_descriptors)"
        echo ""

        echo "=== Memory Details ==="
        cat /proc/meminfo | head -20
        echo ""

        echo "=== Top Processes (by CPU) ==="
        top -b -n 1 | head -20
        echo ""

        echo "=== Process List (httpd/dropbear) ==="
        ps aux 2>/dev/null | grep -E "httpd|dropbear|dnsmasq" | grep -v grep
        ps w 2>/dev/null | grep -E "httpd|dropbear|dnsmasq" | grep -v grep
        echo ""

        echo "=== Network Connections ==="
        netstat -tlnp 2>/dev/null | head -20
        echo ""

        echo "=== Conntrack Table (sample) ==="
        cat /proc/net/nf_conntrack 2>/dev/null | head -30
        echo ""

        echo "=== File Descriptor Usage ==="
        cat /proc/sys/fs/file-nr
        echo ""

        echo "=== Recent Kernel Messages ==="
        dmesg | tail -50
        echo ""

        echo "=== Recent Syslog ==="
        logread | tail -50

    } > "$diag_file"

    echo "$diag_file"
}

# ============================================================
# Main system check
# ============================================================

check_system() {
    # Initialize fail counter
    if [ ! -f "$WATCHDOG_FILE" ]; then
        echo "0" > "$WATCHDOG_FILE"
    fi

    fail_count=$(cat "$WATCHDOG_FILE")
    issues=""
    need_diag=0

    # Check services (ENHANCED: check responsiveness, not just existence)
    httpd_status=$(check_httpd_responsive)
    dropbear_status=$(check_dropbear_responsive)
    dnsmasq_status=$(check_dnsmasq_responsive)

    # Handle httpd
    case "$httpd_status" in
        DEAD)
            issues="${issues}httpd:DEAD "
            restart_service httpd "process dead"
            need_diag=1
            ;;
        HUNG)
            issues="${issues}httpd:HUNG "
            restart_service httpd "not responding"
            need_diag=1
            ;;
    esac

    # Handle dropbear
    case "$dropbear_status" in
        DEAD)
            issues="${issues}dropbear:DEAD "
            restart_service dropbear "process dead"
            need_diag=1
            ;;
        HUNG)
            issues="${issues}dropbear:HUNG "
            restart_service dropbear "not responding"
            need_diag=1
            ;;
    esac

    # Handle dnsmasq
    case "$dnsmasq_status" in
        DEAD)
            issues="${issues}dnsmasq:DEAD "
            restart_service dnsmasq "process dead"
            need_diag=1
            ;;
        HUNG)
            issues="${issues}dnsmasq:HUNG "
            restart_service dnsmasq "not responding"
            need_diag=1
            ;;
    esac

    # Check resources
    load_status=$(check_system_load)
    mem_status=$(check_memory)
    conn_status=$(check_conntrack)
    fd_status=$(check_file_descriptors)

    case "$load_status" in
        CRITICAL:*)
            issues="${issues}Load:${load_status#*:} "
            need_diag=1
            ;;
    esac

    case "$mem_status" in
        CRITICAL:*)
            issues="${issues}Mem:${mem_status#*:} "
            need_diag=1
            # Try to free some memory
            sync
            echo 3 > /proc/sys/vm/drop_caches 2>/dev/null
            ;;
    esac

    case "$conn_status" in
        CRITICAL:*)
            issues="${issues}Conntrack:${conn_status#*:} "
            need_diag=1
            ;;
    esac

    case "$fd_status" in
        CRITICAL:*)
            issues="${issues}FD:${fd_status#*:} "
            need_diag=1
            ;;
    esac

    # Process results
    if [ -n "$issues" ]; then
        fail_count=$((fail_count + 1))
        log_msg "ISSUE: $issues (Count: $fail_count/$REBOOT_THRESHOLD)"

        # Collect diagnostics on first failure
        if [ "$need_diag" = "1" ]; then
            diag_file=$(collect_diagnostics)
            log_msg "DIAG: Saved to $diag_file"

            # Also trigger crash monitor
            if [ -x /usr/bin/monitor_crash.sh ]; then
                /usr/bin/monitor_crash.sh &
            fi
        fi

        # Update fail counter
        echo "$fail_count" > "$WATCHDOG_FILE"

        # Reboot if threshold exceeded
        if [ "$fail_count" -ge "$REBOOT_THRESHOLD" ]; then
            log_msg "CRITICAL: System issues persist after $fail_count checks. Rebooting."
            collect_diagnostics  # Final diagnostic before reboot
            sync
            sleep 2
            reboot -f
        fi
    else
        # System healthy - reset counter
        if [ "$fail_count" -gt 0 ]; then
            log_msg "RECOVERY: All services responding normally"
        fi
        echo "0" > "$WATCHDOG_FILE"
    fi
}

# ============================================================
# Status display
# ============================================================

show_status() {
    echo "========================================"
    echo "System Health Status"
    echo "========================================"
    echo ""

    echo "--- Service Status ---"
    printf "%-12s : %s\n" "httpd" "$(check_httpd_responsive)"
    printf "%-12s : %s\n" "dropbear" "$(check_dropbear_responsive)"
    printf "%-12s : %s\n" "dnsmasq" "$(check_dnsmasq_responsive)"
    echo ""

    echo "--- Resource Status ---"
    printf "%-12s : %s\n" "Load" "$(check_system_load)"
    printf "%-12s : %s\n" "Memory" "$(check_memory)"
    printf "%-12s : %s\n" "Conntrack" "$(check_conntrack)"
    printf "%-12s : %s\n" "File Desc" "$(check_file_descriptors)"
    echo ""

    if [ -f "$WATCHDOG_FILE" ]; then
        echo "--- Fail Counter ---"
        echo "Current: $(cat $WATCHDOG_FILE)/$REBOOT_THRESHOLD"
    fi

    echo ""
    echo "--- Recent Issues ---"
    if [ -f "$LOG_FILE" ]; then
        tail -n 10 "$LOG_FILE"
    else
        echo "(no log file)"
    fi

    echo ""
    echo "--- Diagnostic Files ---"
    if [ -d "$DIAG_DIR" ]; then
        ls -lht "$DIAG_DIR" 2>/dev/null | head -5
    fi
}

show_diag() {
    echo "Collecting full diagnostic report..."
    diag_file=$(collect_diagnostics)
    echo "Report saved to: $diag_file"
    echo ""
    echo "=== Summary ==="
    head -30 "$diag_file"
    echo ""
    echo "Full report: $diag_file"
}

# ============================================================
# Daemon mode
# ============================================================

update_heartbeat() {
    date +%s > "$HEARTBEAT_FILE"
}

check_self_watchdog() {
    if [ -f "$HEARTBEAT_FILE" ]; then
        last_beat=$(cat "$HEARTBEAT_FILE" 2>/dev/null || echo "0")
        now=$(date +%s)
        age=$((now - last_beat))

        if [ "$age" -gt "$SELF_CHECK_TIMEOUT" ]; then
            log_msg "CRITICAL: Self-watchdog triggered! No check in ${age}s. Rebooting."
            collect_diagnostics
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
            echo "Already running (PID: $old_pid)"
            exit 1
        fi
    fi

    # Daemonize
    echo $$ > "$PID_FILE"
    log_msg "Daemon started (PID: $$, interval: ${CHECK_INTERVAL}s)"

    # Initialize heartbeat
    update_heartbeat

    # Main loop
    while true; do
        check_self_watchdog
        check_system
        update_heartbeat
        sleep "$CHECK_INTERVAL"
    done
}

stop_daemon() {
    if [ -f "$PID_FILE" ]; then
        pid=$(cat "$PID_FILE")
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid"
            log_msg "Daemon stopped (PID: $pid)"
            rm -f "$PID_FILE"
            echo "Stopped"
        else
            rm -f "$PID_FILE"
            echo "Not running"
        fi
    else
        echo "Not running"
    fi
}

# ============================================================
# Main
# ============================================================

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
    diag)
        show_diag
        ;;
    stop)
        stop_daemon
        ;;
    *)
        echo "Usage: $0 {daemon|check|status|diag|stop}"
        echo ""
        echo "  daemon - Run as background daemon"
        echo "  check  - Perform single check"
        echo "  status - Show current status"
        echo "  diag   - Collect full diagnostic report"
        echo "  stop   - Stop daemon"
        exit 1
        ;;
esac
