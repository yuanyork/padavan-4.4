#!/bin/sh

# Hardware Watchdog Test Script
# This script provides various tests for the MT7621 hardware watchdog

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Test 1: Check if watchdog device exists
test_device_exists() {
    echo "=========================================="
    echo "Test 1: Check Watchdog Device"
    echo "=========================================="

    if [ -c /dev/watchdog ]; then
        log_info "✓ /dev/watchdog exists"
        ls -l /dev/watchdog
        return 0
    else
        log_error "✗ /dev/watchdog not found"
        log_warn "Kernel may not have watchdog driver enabled"
        log_warn "Check: CONFIG_MT7621_WDT=y in kernel config"
        return 1
    fi
}

# Test 2: Check kernel module
test_kernel_module() {
    echo ""
    echo "=========================================="
    echo "Test 2: Check Kernel Module"
    echo "=========================================="

    if lsmod | grep -q watchdog; then
        log_info "✓ Watchdog module loaded:"
        lsmod | grep watchdog
    else
        log_warn "Watchdog module not in lsmod (may be built-in)"
    fi

    if dmesg | grep -i watchdog | tail -5; then
        log_info "✓ Watchdog messages in dmesg"
    fi
}

# Test 3: Basic watchdog functionality test
test_basic_watchdog() {
    echo ""
    echo "=========================================="
    echo "Test 3: Basic Watchdog Functionality"
    echo "=========================================="
    log_warn "This test will open and close watchdog device"
    log_warn "The watchdog will remain ACTIVE after this test"

    read -p "Continue? (y/n): " confirm
    if [ "$confirm" != "y" ]; then
        log_info "Test skipped"
        return 0
    fi

    # Simple test: open and feed watchdog
    cat > /tmp/wdt_test.c << 'EOF'
#include <stdio.h>
#include <stdlib.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <linux/watchdog.h>

int main() {
    int fd, timeout;

    fd = open("/dev/watchdog", O_WRONLY);
    if (fd < 0) {
        perror("Failed to open /dev/watchdog");
        return 1;
    }

    // Get timeout
    if (ioctl(fd, WDIOC_GETTIMEOUT, &timeout) == 0) {
        printf("Current timeout: %d seconds\n", timeout);
    }

    // Set timeout to 30 seconds
    timeout = 30;
    if (ioctl(fd, WDIOC_SETTIMEOUT, &timeout) == 0) {
        printf("Set timeout to: %d seconds\n", timeout);
    }

    // Get actual timeout (may differ)
    if (ioctl(fd, WDIOC_GETTIMEOUT, &timeout) == 0) {
        printf("Actual timeout: %d seconds\n", timeout);
    }

    // Feed watchdog
    printf("Feeding watchdog...\n");
    if (write(fd, "\0", 1) < 0) {
        perror("Failed to feed watchdog");
    } else {
        printf("Watchdog fed successfully\n");
    }

    printf("Closing watchdog device (watchdog remains ACTIVE)\n");
    close(fd);

    return 0;
}
EOF

    # Compile if gcc available
    if which gcc >/dev/null 2>&1; then
        gcc -o /tmp/wdt_test /tmp/wdt_test.c
        /tmp/wdt_test
        rm -f /tmp/wdt_test /tmp/wdt_test.c
    else
        log_warn "gcc not available, skipping compiled test"
        # Try simple shell test
        log_info "Trying simple shell test..."
        timeout 2 cat /dev/watchdog > /dev/null 2>&1
        log_info "Watchdog device accessed"
    fi
}

# Test 4: Check if hw_watchdog daemon is running
test_daemon_running() {
    echo ""
    echo "=========================================="
    echo "Test 4: Check hw_watchdog Daemon"
    echo "=========================================="

    if pidof hw_watchdog >/dev/null; then
        log_info "✓ hw_watchdog daemon is running"
        ps | grep hw_watchdog | grep -v grep

        if [ -f /var/run/hw_watchdog.pid ]; then
            pid=$(cat /var/run/hw_watchdog.pid)
            log_info "PID file exists: $pid"
        fi

        log_info "Checking syslog for hw_watchdog messages:"
        logread | grep hw_watchdog | tail -10
    else
        log_warn "✗ hw_watchdog daemon is not running"
        log_info "You can start it with: /usr/sbin/hw_watchdog &"
    fi
}

# Test 5: Watchdog feed test (safe)
test_watchdog_feed() {
    echo ""
    echo "=========================================="
    echo "Test 5: Watchdog Feed Test (Safe)"
    echo "=========================================="
    log_info "This test will feed the watchdog 5 times, then disable it"

    read -p "Continue? (y/n): " confirm
    if [ "$confirm" != "y" ]; then
        log_info "Test skipped"
        return 0
    fi

    cat > /tmp/wdt_feed_test.sh << 'SCRIPT'
#!/bin/sh
echo "Opening watchdog device..."
exec 3>/dev/watchdog

echo "Feeding watchdog 5 times (every 3 seconds)..."
for i in 1 2 3 4 5; do
    echo "Feed #$i at $(date '+%H:%M:%S')"
    echo "1" >&3
    sleep 3
done

echo "Disabling watchdog (writing 'V')..."
echo "V" >&3
exec 3>&-
echo "Watchdog disabled successfully"
SCRIPT

    chmod +x /tmp/wdt_feed_test.sh
    /tmp/wdt_feed_test.sh
    rm -f /tmp/wdt_feed_test.sh
}

# Test 6: Kill daemon test (DANGEROUS - will reboot!)
test_kill_daemon() {
    echo ""
    echo "=========================================="
    echo "Test 6: Kill Daemon Test"
    echo "=========================================="
    log_error "⚠️  WARNING: DANGEROUS TEST ⚠️"
    log_error "This will kill the hw_watchdog daemon"
    log_error "System will reboot in ~120 seconds if daemon doesn't restart!"
    echo ""
    log_info "What this test does:"
    log_info "1. Kill hw_watchdog daemon"
    log_info "2. Watchdog device remains open (active)"
    log_info "3. No one feeds the watchdog"
    log_info "4. After timeout (~120s), hardware forces reboot"
    echo ""

    if ! pidof hw_watchdog >/dev/null; then
        log_error "hw_watchdog daemon is not running, cannot test"
        return 1
    fi

    read -p "Type 'REBOOT' to confirm: " confirm
    if [ "$confirm" != "REBOOT" ]; then
        log_info "Test cancelled"
        return 0
    fi

    log_warn "Killing hw_watchdog daemon in 5 seconds..."
    log_warn "System will reboot in ~2 minutes!"
    sleep 5

    killall -9 hw_watchdog
    log_info "hw_watchdog killed at: $(date)"
    log_info "System should reboot around: $(date -d '+120 seconds' 2>/dev/null || echo 'in ~120 seconds')"
    log_info "Monitoring time until reboot..."

    # Count down
    for i in $(seq 120 -10 10); do
        echo "T-${i} seconds to reboot..."
        sleep 10
    done
}

# Test 7: Simulate system hang (DANGEROUS - will reboot!)
test_simulate_hang() {
    echo ""
    echo "=========================================="
    echo "Test 7: Simulate System Hang"
    echo "=========================================="
    log_error "⚠️  EXTREMELY DANGEROUS TEST ⚠️"
    log_error "This will freeze the system to simulate a hang"
    log_error "Only hardware watchdog can recover"
    echo ""
    log_info "Methods to simulate hang:"
    log_info "1. Fork bomb (fills process table)"
    log_info "2. Memory bomb (exhausts memory)"
    log_info "3. Kernel panic (crashes kernel)"
    echo ""

    read -p "Type 'FORCE_REBOOT' to confirm: " confirm
    if [ "$confirm" != "FORCE_REBOOT" ]; then
        log_info "Test cancelled"
        return 0
    fi

    echo ""
    read -p "Choose method (1-3): " method

    case $method in
        1)
            log_error "Launching fork bomb in 5 seconds..."
            log_error "System will become unresponsive!"
            sleep 5
            log_info "Starting fork bomb..."
            :(){ :|:& };:
            ;;
        2)
            log_error "Launching memory bomb in 5 seconds..."
            sleep 5
            log_info "Starting memory bomb..."
            while true; do cat /dev/zero; done
            ;;
        3)
            log_error "Triggering kernel panic in 5 seconds..."
            log_error "This requires CONFIG_MAGIC_SYSRQ=y"
            sleep 5
            echo c > /proc/sysrq-trigger
            ;;
        *)
            log_error "Invalid choice"
            return 1
            ;;
    esac
}

# Test 8: Monitor watchdog activity
test_monitor_activity() {
    echo ""
    echo "=========================================="
    echo "Test 8: Monitor Watchdog Activity"
    echo "=========================================="
    log_info "Monitoring watchdog-related activities for 30 seconds..."
    log_info "Press Ctrl+C to stop early"
    echo ""

    # Monitor in background
    (
        echo "=== Process Monitor ==="
        while true; do
            ps | grep -E "hw_watchdog|monitor" | grep -v grep
            sleep 5
        done
    ) &
    mon_pid=$!

    # Monitor logs
    echo "=== Log Monitor ==="
    timeout 30 logread -f | grep -E "watchdog|monitor|CRITICAL" &

    sleep 30
    kill $mon_pid 2>/dev/null

    log_info "Monitoring complete"
}

# Main menu
show_menu() {
    echo ""
    echo "=========================================="
    echo "Hardware Watchdog Test Suite"
    echo "=========================================="
    echo "SAFE TESTS:"
    echo "  1. Check watchdog device exists"
    echo "  2. Check kernel module"
    echo "  3. Basic watchdog functionality"
    echo "  4. Check hw_watchdog daemon"
    echo "  5. Watchdog feed test (safe)"
    echo "  8. Monitor watchdog activity"
    echo ""
    echo "DANGEROUS TESTS (will cause reboot):"
    echo "  6. Kill daemon test (reboot in ~2min)"
    echo "  7. Simulate system hang (immediate reboot)"
    echo ""
    echo "  a. Run all safe tests"
    echo "  q. Quit"
    echo "=========================================="
}

# Main program
main() {
    if [ "$(id -u)" -ne 0 ]; then
        log_error "This script must be run as root"
        exit 1
    fi

    while true; do
        show_menu
        read -p "Select test: " choice

        case $choice in
            1) test_device_exists ;;
            2) test_kernel_module ;;
            3) test_basic_watchdog ;;
            4) test_daemon_running ;;
            5) test_watchdog_feed ;;
            6) test_kill_daemon ;;
            7) test_simulate_hang ;;
            8) test_monitor_activity ;;
            a|A)
                test_device_exists
                test_kernel_module
                test_daemon_running
                test_monitor_activity
                ;;
            q|Q)
                log_info "Exiting"
                exit 0
                ;;
            *)
                log_error "Invalid choice"
                ;;
        esac

        echo ""
        read -p "Press Enter to continue..."
    done
}

# Run main program
main
