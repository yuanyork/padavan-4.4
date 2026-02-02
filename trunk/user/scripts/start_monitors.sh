#!/bin/sh

# Start all monitoring daemons
# This script should be called from autostart.sh or rc.local

LOG_TAG="monitor_init"

log_msg() {
    logger -t "$LOG_TAG" "$1"
    echo "[$(date)] $1"
}

# Wait for system to settle
sleep 10

# Check if hardware watchdog daemon is available and start it
if [ -x /usr/sbin/hw_watchdog ]; then
    if ! pidof hw_watchdog >/dev/null; then
        /usr/sbin/hw_watchdog &
        log_msg "Hardware watchdog daemon started"
    fi
else
    log_msg "WARNING: Hardware watchdog daemon not available"
fi

# Start system health monitor daemon
if [ -x /usr/bin/monitor_system_health.sh ]; then
    if ! pidof monitor_system_health.sh >/dev/null; then
        /usr/bin/monitor_system_health.sh daemon &
        log_msg "System health monitor started"
    fi
else
    log_msg "WARNING: System health monitor not available"
fi

# Start network monitor daemon (optional - can also use cron)
# Uncomment to enable automatic network monitoring
# if [ -x /usr/bin/monitor_network.sh ]; then
#     if ! pidof monitor_network.sh >/dev/null; then
#         /usr/bin/monitor_network.sh daemon &
#         log_msg "Network monitor started"
#     fi
# fi

log_msg "All monitoring daemons initialized"
