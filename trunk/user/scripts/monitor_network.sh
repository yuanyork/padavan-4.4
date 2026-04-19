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

LAYER_HELPER="/usr/bin/monitor_network_layer.sh"
[ -r "$LAYER_HELPER" ] || LAYER_HELPER="$(dirname "$0")/monitor_network_layer.sh"
[ -r "$LAYER_HELPER" ] && . "$LAYER_HELPER"

# Log file location
select_log_path() {
    # Allow external override
    if [ -n "$NET_MONITOR_LOG_DIR" ] && [ -d "$NET_MONITOR_LOG_DIR" ]; then
        LOG_DIR="$NET_MONITOR_LOG_DIR"
        [ ! -d "$LOG_DIR" ] && mkdir -p "$LOG_DIR"
        LOG_FILE="$LOG_DIR/network_monitor.log"
        return
    fi

    if [ -d "/media/storage_emmc" ]; then
        LOG_DIR="/media/storage_emmc/logs"
        [ ! -d "$LOG_DIR" ] && mkdir -p "$LOG_DIR"
        LOG_FILE="$LOG_DIR/network_monitor.log"
    elif [ -d "/etc/storage/inet_log" ]; then
        LOG_DIR="/etc/storage/inet_log"
        [ ! -d "$LOG_DIR" ] && mkdir -p "$LOG_DIR"
        LOG_FILE="$LOG_DIR/network_monitor.log"
    else
        LOG_FILE="/tmp/network_monitor.log"
    fi
}

select_log_path

log_fallback_if_needed() {
    # If storage becomes unavailable, fall back to /tmp
    if ! ( echo "test" >> "$LOG_FILE" 2>/dev/null ); then
        LOG_FILE="/tmp/network_monitor.log"
        echo "$(date '+%Y-%m-%d %H:%M:%S')|WARN|LOG_FALLBACK|N/A|Switched to /tmp" >> "$LOG_FILE"
    else
        # remove the test line if possible
        sed -i '$d' "$LOG_FILE" 2>/dev/null
    fi
}

sanitize_inline() {
    tr '\n' ' ' | sed 's/[[:space:]]\+/ /g; s/^ //; s/ $//'
}

notify_rc_event() {
    event="$1"
    [ -z "$event" ] && return
    mkdir -p /tmp/rc_notification /tmp/rc_action_incomplete
    : > "/tmp/rc_action_incomplete/$event"
    : > "/tmp/rc_notification/$event"
    kill -USR1 1 2>/dev/null
}

read_state_file() {
    file="$1"
    default_value="$2"

    if [ -f "$file" ]; then
        cat "$file" 2>/dev/null
    else
        echo "$default_value"
    fi
}

write_state_file() {
    file="$1"
    value="$2"
    echo "$value" > "$file"
}

reset_recovery_state() {
    rm -f /tmp/net_monitor.fail_count \
        /tmp/net_monitor.recovery_stage \
        /tmp/net_monitor.last_fail_type
}

run_recovery_action() {
    action_key="$1"
    action_desc="$2"
    event_name="$3"
    cooldown="$4"

    now_ts=$(date +%s)
    last_ts=0
    [ -f /tmp/net_monitor.last_recover ] && last_ts=$(cat /tmp/net_monitor.last_recover 2>/dev/null)

    if [ $((now_ts - last_ts)) -lt "$cooldown" ]; then
        return 1
    fi

    echo "$now_ts" > /tmp/net_monitor.last_recover
    log_event "ACTION" "$action_key" "N/A" "$action_desc"

    for event_name in $event_name; do
        notify_rc_event "$event_name"
    done

    return 0
}

advance_recovery() {
    fail_type="$1"
    count="$2"
    stage="$3"

    AUTO_RECOVER_COOLDOWN=300
    REBOOT_AFTER=20

    case "$fail_type" in
        DNS_FAIL)
            if [ "$stage" -lt 1 ] && [ "$count" -ge 2 ]; then
                dns_events="restart_dns"
                [ "$(nvram get sdns_enable 2>/dev/null)" = "1" ] && dns_events="$dns_events restart_smartdns"
                [ "$(nvram get dns_forwarder_enable 2>/dev/null)" = "1" ] && dns_events="$dns_events restart_dns_forwarder"
                [ "$(nvram get adg_enable 2>/dev/null)" = "1" ] && dns_events="$dns_events restart_adguardhome"
                if run_recovery_action "RESTART_DNS_STACK" "Refresh DNS stack after $count DNS failures" "$dns_events" "$AUTO_RECOVER_COOLDOWN"; then
                    write_state_file /tmp/net_monitor.recovery_stage 1
                fi
            elif [ "$stage" -lt 2 ] && [ "$count" -ge 4 ]; then
                if run_recovery_action "RESTART_DHCPD" "Restart dnsmasq/DHCP after $count DNS failures" "restart_dhcpd" "$AUTO_RECOVER_COOLDOWN"; then
                    write_state_file /tmp/net_monitor.recovery_stage 2
                fi
            elif [ "$stage" -lt 3 ] && [ "$count" -ge 6 ]; then
                if run_recovery_action "AUTO_WAN_RECONNECT" "Escalate DNS failures to WAN reconnect after $count checks" "auto_wan_reconnect" "$AUTO_RECOVER_COOLDOWN"; then
                    write_state_file /tmp/net_monitor.recovery_stage 3
                fi
            elif [ "$stage" -lt 4 ] && [ "$count" -ge "$REBOOT_AFTER" ]; then
                log_event "CRITICAL" "REBOOT" "N/A" "DNS failures persisted for $count checks after staged recovery. Rebooting now."
                write_state_file /tmp/net_monitor.recovery_stage 4
                sleep 5
                reboot
            fi
            ;;
        IP_FAIL|GATEWAY_FAIL|ROUTE_FAIL)
            if [ "$stage" -lt 1 ] && [ "$count" -ge 3 ]; then
                if run_recovery_action "AUTO_WAN_RECONNECT" "Trigger auto_wan_reconnect after $count $fail_type events" "auto_wan_reconnect" "$AUTO_RECOVER_COOLDOWN"; then
                    write_state_file /tmp/net_monitor.recovery_stage 1
                fi
            elif [ "$stage" -lt 2 ] && [ "$count" -ge 6 ]; then
                if run_recovery_action "RESTART_WAN" "Escalate to full WAN restart after $count $fail_type events" "restart_wan" "$AUTO_RECOVER_COOLDOWN"; then
                    write_state_file /tmp/net_monitor.recovery_stage 2
                fi
            elif [ "$stage" -lt 3 ] && [ "$count" -ge "$REBOOT_AFTER" ]; then
                log_event "CRITICAL" "REBOOT" "N/A" "WAN failures persisted for $count checks after staged recovery. Rebooting now."
                write_state_file /tmp/net_monitor.recovery_stage 3
                sleep 5
                reboot
            fi
            ;;
    esac
}

safe_nvram_get() {
    key="$1"
    value="$(timeout 2 nvram get "$key" 2>/dev/null)"
    echo "${value:-N/A}"
}

get_interface_state() {
    iface="$1"

    if [ -z "$iface" ]; then
        echo "if=N/A"
        return
    fi

    carrier="N/A"
    operstate="N/A"

    [ -r "/sys/class/net/$iface/carrier" ] && carrier="$(cat "/sys/class/net/$iface/carrier" 2>/dev/null)"
    [ -r "/sys/class/net/$iface/operstate" ] && operstate="$(cat "/sys/class/net/$iface/operstate" 2>/dev/null)"

    echo "if=$iface,carrier=$carrier,state=$operstate"
}

get_wifi_band_snapshot() {
    band="$1"
    iface="$2"
    radio_key="$3"
    ssid_key="$4"
    radio_cfg="$(safe_nvram_get "$radio_key")"
    ssid="$(safe_nvram_get "$ssid_key")"
    exists="0"
    operstate="N/A"
    carrier="N/A"
    iwpriv_rc="N/A"
    state_code="DISABLED"

    if [ "$radio_cfg" = "1" ]; then
        state_code="CONFIG_ENABLED"

        if [ -d "/sys/class/net/$iface" ]; then
            exists="1"
            [ -r "/sys/class/net/$iface/operstate" ] && operstate="$(cat "/sys/class/net/$iface/operstate" 2>/dev/null)"
            [ -r "/sys/class/net/$iface/carrier" ] && carrier="$(cat "/sys/class/net/$iface/carrier" 2>/dev/null)"

            timeout 3 iwpriv "$iface" show stat >/dev/null 2>&1
            iwpriv_rc="$?"

            if [ "$iwpriv_rc" = "124" ]; then
                state_code="DRIVER_TIMEOUT"
            elif [ "$operstate" = "down" ] || [ "$operstate" = "dormant" ] || [ "$operstate" = "lowerlayerdown" ]; then
                state_code="IF_DOWN"
            elif [ "$iwpriv_rc" != "0" ]; then
                state_code="DRIVER_QUERY_FAIL"
            else
                state_code="OK"
            fi
        else
            state_code="IF_MISSING"
        fi
    fi

    summary="wifi_${band}=${state_code}"
    details="band=$band,if=$iface,radio_cfg=$radio_cfg,ssid=$ssid,exists=$exists,operstate=$operstate,carrier=$carrier,iwpriv_rc=$iwpriv_rc"

    echo "$summary|$details"
}

capture_wifi_debug_snapshot() {
    band="$1"
    iface="$2"
    radio_key="$3"
    ssid_key="$4"

    radio_cfg="$(safe_nvram_get "$radio_key")"
    ssid="$(safe_nvram_get "$ssid_key")"
    ifconfig_line="$(ip link show "$iface" 2>/dev/null | head -n 1 | sanitize_inline)"
    iwpriv_stat="$(timeout 3 iwpriv "$iface" show stat 2>/dev/null | head -n 8 | sanitize_inline)"
    iwpriv_conn="$(timeout 3 iwpriv "$iface" show conn 2>/dev/null | head -n 8 | sanitize_inline)"

    [ -n "$ifconfig_line" ] || ifconfig_line="N/A"
    [ -n "$iwpriv_stat" ] || iwpriv_stat="N/A"
    [ -n "$iwpriv_conn" ] || iwpriv_conn="N/A"

    echo "band=$band,if=$iface,radio_cfg=$radio_cfg,ssid=$ssid,link=$ifconfig_line,iwpriv_stat=$iwpriv_stat,iwpriv_conn=$iwpriv_conn"
}

check_wifi_band_event() {
    band="$1"
    iface="$2"
    radio_key="$3"
    ssid_key="$4"
    state_file="/tmp/net_monitor.wifi_${band}.state"

    snapshot="$(get_wifi_band_snapshot "$band" "$iface" "$radio_key" "$ssid_key")"
    summary="${snapshot%%|*}"
    details="${snapshot#*|}"
    current_state="${summary#wifi_${band}=}"
    previous_state="$(read_state_file "$state_file" "")"

    if [ "$current_state" = "DISABLED" ]; then
        rm -f "$state_file"
        return
    fi

    if [ "$current_state" != "$previous_state" ]; then
        write_state_file "$state_file" "$current_state"

        if [ "$current_state" = "OK" ]; then
            log_event "WIFI" "RECOVERY" "cause=WIFI_${band}_RECOVERED" "$details,prev_state=${previous_state:-NONE}"
        else
            log_event "WIFI" "ISSUE" "cause=WIFI_${band}_${current_state}" "$details,prev_state=${previous_state:-NONE}"
            log_event "WIFI_DEBUG" "SNAPSHOT" "cause=WIFI_${band}_${current_state}" "$(capture_wifi_debug_snapshot "$band" "$iface" "$radio_key" "$ssid_key")"
        fi
    fi
}

check_wifi_events() {
    check_wifi_band_event "2g" "ra0" "rt_radio_x" "rt_ssid"
    check_wifi_band_event "5g" "rai0" "wl_radio_x" "wl_ssid"
}

get_resolver_state() {
    nameservers="$(awk '/^nameserver / {print $2}' /etc/resolv.conf 2>/dev/null | xargs 2>/dev/null)"
    dnsmasq_state="down"
    smartdns_state="off"
    dnsforwarder_state="off"
    adguard_state="off"

    pidof dnsmasq >/dev/null 2>&1 && dnsmasq_state="up"
    [ "$(safe_nvram_get sdns_enable)" = "1" ] && smartdns_state="on"
    [ "$(safe_nvram_get dns_forwarder_enable)" = "1" ] && dnsforwarder_state="on"
    [ "$(safe_nvram_get adg_enable)" = "1" ] && adguard_state="on"

    echo "dnsmasq=$dnsmasq_state,smartdns=$smartdns_state,dnsfwd=$dnsforwarder_state,adg=$adguard_state,resolv=${nameservers:-N/A}"
}

classify_root_cause() {
    fail_type="$1"
    route_if="$2"
    gateway="$3"
    wan_ip="$4"
    wan_dns="$5"

    case "$fail_type" in
        ROUTE_FAIL)
            echo "NO_DEFAULT_ROUTE"
            ;;
        GATEWAY_FAIL)
            if [ "$wan_ip" = "0.0.0.0" ] || [ "$wan_ip" = "N/A" ]; then
                echo "WAN_NOT_READY"
            else
                echo "GATEWAY_UNREACHABLE"
            fi
            ;;
        IP_FAIL)
            if [ "$wan_ip" = "0.0.0.0" ] || [ "$wan_ip" = "N/A" ]; then
                echo "WAN_NO_IP"
            elif [ -n "$gateway" ] && [ "$gateway" != "N/A" ]; then
                echo "UPSTREAM_UNREACHABLE"
            else
                echo "PUBLIC_IP_CHECK_FAILED"
            fi
            ;;
        DNS_FAIL)
            if [ -z "$wan_dns" ] || [ "$wan_dns" = "N/A" ]; then
                echo "NO_DNS_SERVER"
            else
                echo "DNS_RESOLUTION_FAILED"
            fi
            ;;
        *)
            echo "UNKNOWN"
            ;;
    esac
}

collect_failure_context() {
    fail_type="$1"
    route_if="$(netmon_route_if)"
    gateway="$(netmon_gateway)"
    wan_proto="$(safe_nvram_get wan_proto)"
    wan_ip="$(safe_nvram_get wan_ipaddr_t)"
    wan_gw="$(safe_nvram_get wan_gateway_t)"
    wan_dns="$(safe_nvram_get wanx_dns)"
    mem_free="$(awk '/MemFree/ {print $2}' /proc/meminfo 2>/dev/null)"
    route_line="$(ip route show default 2>/dev/null | head -n 1 | sed 's/[[:space:]]\\+/ /g')"
    iface_state="$(get_interface_state "$route_if")"
    resolver_state="$(get_resolver_state)"
    root_cause="$(classify_root_cause "$fail_type" "$route_if" "$gateway" "$wan_ip" "$wan_dns")"

    summary="cause=$root_cause"
    context="fail=$fail_type,$iface_state,proto=$wan_proto,wan_ip=$wan_ip,gw=${gateway:-N/A},wan_gw=$wan_gw,wan_dns=${wan_dns:-N/A},$resolver_state,mem_kb=${mem_free:-N/A},route=${route_line:-N/A}"

    echo "$summary|$context"
}

check_connectivity() {
    # Returns: 0=OK, 1=IP_FAIL, 2=DNS_FAIL, 3=GATEWAY_FAIL, 4=ROUTE_FAIL

    route_if="$(netmon_route_if)"
    if [ -z "$route_if" ]; then
        return 4
    fi

    gateway="$(netmon_gateway)"
    if [ -n "$gateway" ] && ! netmon_ping_any "$gateway"; then
        return 3
    fi

    if ! netmon_ping_any $IP_TARGETS; then
        return 1
    fi

    if ! netmon_dns_any $DNS_TARGETS; then
        return 2
    fi

    return 0
}


log_event() {
    log_fallback_if_needed
    status=$1
    reason=$2
    summary=$3
    details=$4
    timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    echo "$timestamp|$status|$reason|$summary|$details" >> "$LOG_FILE"
}

cmd_check() {
    check_wifi_events
    check_connectivity
    ret=$?
    
    if [ $ret -eq 0 ]; then
        # Reset failure counter on success
        reset_recovery_state

        if [ -f "/tmp/net_monitor.state" ]; then
            last_state=$(cat /tmp/net_monitor.state)
            if [ "$last_state" != "UP" ]; then
                log_event "UP" "RECOVERY" "cause=RECOVERED" "network access restored"
            fi
        fi
        echo "UP" > /tmp/net_monitor.state
    else
        case $ret in
            1) fail_type="IP_FAIL" ;;
            2) fail_type="DNS_FAIL" ;;
            3) fail_type="GATEWAY_FAIL" ;;
            4) fail_type="ROUTE_FAIL" ;;
            *) fail_type="UNKNOWN" ;;
        esac
        
        diagnostics="$(collect_failure_context "$fail_type")"
        diag_summary="${diagnostics%%|*}"
        diag_details="${diagnostics#*|}"
        
        # Trigger Crash Monitor Snapshot
        if [ -x "/usr/bin/monitor_crash.sh" ]; then
             /usr/bin/monitor_crash.sh >/dev/null 2>&1 &
        elif [ -x "$(dirname "$0")/monitor_crash.sh" ]; then
             "$(dirname "$0")/monitor_crash.sh" >/dev/null 2>&1 &
        fi
        
        # Auto-Recovery / Reboot Logic
        FAIL_COUNT_FILE="/tmp/net_monitor.fail_count"
        STAGE_FILE="/tmp/net_monitor.recovery_stage"
        FAIL_TYPE_FILE="/tmp/net_monitor.last_fail_type"
        MAX_FAILURES=20
        
        last_fail_type=$(read_state_file "$FAIL_TYPE_FILE" "")
        if [ "$last_fail_type" != "$fail_type" ]; then
            rm -f "$FAIL_COUNT_FILE" "$STAGE_FILE"
            write_state_file "$FAIL_TYPE_FILE" "$fail_type"
            log_event "INFO" "FAIL_TYPE_CHANGE" "cause=FAIL_TYPE_CHANGE" "switch recovery path from ${last_fail_type:-NONE} to $fail_type"
        fi

        count=$(read_state_file "$FAIL_COUNT_FILE" 0)
        count=$((count + 1))
        write_state_file "$FAIL_COUNT_FILE" "$count"
        stage=$(read_state_file "$STAGE_FILE" 0)
        
        log_event "DOWN" "$fail_type" "$diag_summary" "$diag_details,recovery_stage=$stage,count=$count/$MAX_FAILURES"
        echo "DOWN" > /tmp/net_monitor.state

        advance_recovery "$fail_type" "$count" "$stage"
    fi
}

cmd_stats() {
    if [ ! -f "$LOG_FILE" ]; then
        echo "No log file found at $LOG_FILE"
        return
    fi
    
    echo "Network Stability Statistics ($LOG_FILE)"
    echo "--------------------------------------------------------------------------------"
    printf "%-10s | %-6s | %-8s | %-10s | %-10s | %-10s | %-10s | %s\n" "Date" "Drops" "IP_Fail" "DNS_Fail" "GW_Fail" "RouteFail" "WiFiEvt" "Last Cause"
    echo "-----------|--------|----------|------------|------------|------------|------------|-----------------------------------"
    
    awk -F"|" '
    {
        date = substr($1, 1, 10)
        status = $2
        reason = $3
        summary = $4
        details = $5
        
        if (status == "DOWN") {
            drops[date]++
            if (reason == "IP_FAIL") ip_fails[date]++
            if (reason == "DNS_FAIL") dns_fails[date]++
            if (reason == "GATEWAY_FAIL") gw_fails[date]++
            if (reason == "ROUTE_FAIL") route_fails[date]++
            last_diag[date] = summary
        }
        if (status == "WIFI" && reason == "ISSUE")
            wifi_events[date]++
        dates[date] = 1
    }
    END {
        for (d in dates) {
            printf "%-10s | %-6d | %-8d | %-10d | %-10d | %-10d | %-10d | %s\n", d, drops[d], ip_fails[d], dns_fails[d], gw_fails[d], route_fails[d], wifi_events[d], last_diag[d]
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
