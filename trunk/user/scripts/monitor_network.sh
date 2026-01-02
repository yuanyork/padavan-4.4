#!/bin/sh

# Network Monitor Script - Enhanced
# Usage: 
#   monitor_network.sh check  - Perform a single check (for cron)
#   monitor_network.sh stats  - Show daily statistics
#   monitor_network.sh daemon - Run in loop (if cron not available)

# Configuration
IP_TARGETS="223.5.5.5 114.114.114.114 8.8.8.8"
DNS_TARGETS="www.aliyun.com www.baidu.com www.google.com"
TIMEOUT=2
PING_COUNT=1

# Log file location
if [ -d "/media/storage_emmc" ]; then
    LOG_DIR="/media/storage_emmc/logs"
    [ ! -d "$LOG_DIR" ] && mkdir -p "$LOG_DIR"
    LOG_FILE="$LOG_DIR/network_monitor.log"
elif [ -d "/etc/storage/inet_log" ]; then
    LOG_FILE="/etc/storage/inet_log/network_monitor.log"
else
    LOG_FILE="/tmp/network_monitor.log"
fi

get_wifi_stats() {
    # Extract RSSI for main interfaces and apcli if present
    # Padavan usually uses ra0 (2.4G) and rai0 (5G)
    stats=""
    for iface in ra0 rai0 apcli0 apclii0; do
        if [ -d "/sys/class/net/$iface" ]; then
            # Try to get RSSI from iwpriv. This is driver dependent.
            # For MTK drivers in Padavan, 'get_mac_table' or 'show conn' might work.
            # Here we just try to see if the interface is up and log a placeholder or SSID
            rssi=$(iwpriv $iface get_mac_table 2>/dev/null | awk '/[0-9A-F:]{17}/ {print $2}' | xargs | sed 's/ /,/g')
            if [ -z "$rssi" ]; then
                # Fallback to /proc/net/wireless if available
                rssi=$(awk -v iface="$iface" '$1 ~ iface {print $4}' /proc/net/wireless | sed 's/\.//')
            fi
            [ ! -z "$rssi" ] && stats="$stats$iface:$rssi "
        fi
    done
    echo "${stats:-N/A}"
}

check_connectivity() {
    # Returns: 0=OK, 1=IP_FAIL, 2=DNS_FAIL
    
    # 1. Check IP Connectivity
    ip_ok=0
    for ip in $IP_TARGETS; do
        if ping -c $PING_COUNT -W $TIMEOUT -q $ip >/dev/null 2>&1; then
            ip_ok=1
            break
        fi
    done
    
    if [ $ip_ok -eq 0 ]; then
        return 1 # IP Connectivity Failed
    fi
    
    # 2. Check DNS/Domain Connectivity
    dns_ok=0
    for domain in $DNS_TARGETS; do
        if ping -c $PING_COUNT -W $TIMEOUT -q $domain >/dev/null 2>&1; then
            dns_ok=1
            break
        fi
    done
    
    if [ $dns_ok -eq 0 ]; then
        return 2 # DNS/Name Resolution Failed
    fi
    
    return 0 # All OK
}


perform_diagnostics() {
    fail_type=$1
    diag_msg=""
    
    # 1. Gateway Check (LAN Issue?)
    gateway=$(ip route show default | awk '/default/ {print $3}')
    if [ ! -z "$gateway" ]; then
        if ! ping -c 1 -W 1 -q "$gateway" >/dev/null 2>&1; then
            diag_msg="LAN_FAIL:Gateway($gateway) unreachable;"
        fi
    else
        diag_msg="CFG_FAIL:No default gateway;"
    fi

    # 2. System Resources (Load/Mem)
    load=$(uptime | awk -F'load average:' '{print $2}' | sed 's/^ //')
    mem_free=$(awk '/MemFree/ {print $2}' /proc/meminfo)
    if [ "$mem_free" -lt 2048 ]; then # Less than 2MB free is critical
        diag_msg="${diag_msg}SYS_CRIT:LowMem(${mem_free}kB);"
    fi
    
    # 3. Process Check
    if ! pidof dnsmasq >/dev/null; then
        diag_msg="${diag_msg}SVC_FAIL:dnsmasq not running;"
    fi
    
    # 4. Kernel Logs (Last line of dmesg, sanitized)
    dmesg_tail=$(dmesg | tail -n 1 | sed 's/[^a-zA-Z0-9 _-]/./g' | cut -c 1-50)
    
    # Formulate Conclusion
    if [ -z "$diag_msg" ]; then
        if [ "$fail_type" = "IP_FAIL" ]; then
            diag_msg="ISP_FAIL:Gateway Reachable, WAN IP likely down;"
        elif [ "$fail_type" = "DNS_FAIL" ]; then
            diag_msg="DNS_FAIL:IPs Reachable, DNS resolution failing;"
        else
            diag_msg="UNKNOWN_FAIL;"
        fi
    fi
    
    echo "$diag_msg Load:$load dmesg:[$dmesg_tail]"
}

log_event() {
    status=$1
    reason=$2
    wifi_info=$3
    diag_info=$4
    timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    echo "$timestamp|$status|$reason|$wifi_info|$diag_info" >> "$LOG_FILE"
}

cmd_check() {
    check_connectivity
    ret=$?
    wifi=$(get_wifi_stats)
    
    if [ $ret -eq 0 ]; then
        if [ -f "/tmp/net_monitor.state" ]; then
            last_state=$(cat /tmp/net_monitor.state)
            if [ "$last_state" != "UP" ]; then
                log_event "UP" "RECOVERY" "$wifi"
            fi
        fi
        echo "UP" > /tmp/net_monitor.state
    else
        case $ret in
            1) fail_type="IP_FAIL" ;;
            2) fail_type="DNS_FAIL" ;;
            *) fail_type="UNKNOWN" ;;
        esac
        
        # Run Deep Diagnostics
        diag_info=$(perform_diagnostics "$fail_type")
        
        log_event "DOWN" "$fail_type" "$wifi" "$diag_info"
        echo "DOWN" > /tmp/net_monitor.state
    fi
}

cmd_stats() {
    if [ ! -f "$LOG_FILE" ]; then
        echo "No log file found at $LOG_FILE"
        return
    fi
    
    echo "Network Stability Statistics ($LOG_FILE)"
    echo "--------------------------------------------------------------------------------"
    printf "%-10s | %-6s | %-8s | %-10s | %s\n" "Date" "Drops" "IP_Fail" "DNS_Fail" "Last Diagnostic Info"
    echo "-----------|--------|----------|------------|-----------------------------------"
    
    awk -F"|" '
    {
        date = substr($1, 1, 10)
        status = $2
        reason = $3
        wifi = $4
        diag = $5
        
        if (status == "DOWN") {
            drops[date]++
            if (reason == "IP_FAIL") ip_fails[date]++
            if (reason == "DNS_FAIL") dns_fails[date]++
            last_diag[date] = diag " (" wifi ")"
        }
        dates[date] = 1
    }
    END {
        for (d in dates) {
            printf "%-10s | %-6d | %-8d | %-10d | %s\n", d, drops[d], ip_fails[d], dns_fails[d], last_diag[d]
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
