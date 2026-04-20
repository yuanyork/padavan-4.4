#!/bin/sh

# Shared helpers for layered network checks.

netmon_run_timeout() {
    duration="$1"
    shift

    if command -v timeout >/dev/null 2>&1; then
        timeout "$duration" "$@"
    else
        "$@"
    fi
}

netmon_route_if() {
    ip route show default 2>/dev/null | awk '/default/ {print $5; exit}'
}

netmon_gateway() {
    ip route show default 2>/dev/null | awk '/default/ {print $3; exit}'
}

netmon_ping_any() {
    for target in "$@"; do
        [ -n "$target" ] || continue
        if netmon_run_timeout 3 ping -c "${PING_COUNT:-1}" -W "${TIMEOUT:-2}" -q "$target" >/dev/null 2>&1; then
            return 0
        fi
    done

    return 1
}

netmon_ping_retry() {
    target="$1"
    attempts="${2:-2}"
    try=1

    while [ "$try" -le "$attempts" ]; do
        if netmon_ping_any "$target"; then
            return 0
        fi

        try=$((try + 1))
        [ "$try" -le "$attempts" ] && sleep 1
    done

    return 1
}

netmon_dns_any() {
    for domain in "$@"; do
        [ -n "$domain" ] || continue

        if command -v nslookup >/dev/null 2>&1; then
            if netmon_run_timeout 4 nslookup "$domain" >/dev/null 2>&1; then
                return 0
            fi
        elif netmon_run_timeout 3 ping -c 1 -W "${TIMEOUT:-2}" -q "$domain" >/dev/null 2>&1; then
            return 0
        fi
    done

    return 1
}
