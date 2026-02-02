/*
 * Hardware Watchdog Daemon for MT7621
 * Feeds the hardware watchdog to prevent system reset
 * Acts as the last line of defense against complete system freeze
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <signal.h>
#include <syslog.h>
#include <sys/ioctl.h>
#include <linux/watchdog.h>

#define WDT_DEVICE "/dev/watchdog"
#define WDT_TIMEOUT 120  /* 120 seconds - hardware timeout */
#define WDT_FEED_INTERVAL 30  /* Feed every 30 seconds */
#define PID_FILE "/var/run/hw_watchdog.pid"

static int wdt_fd = -1;
static volatile int running = 1;

void signal_handler(int sig)
{
	if (sig == SIGTERM || sig == SIGINT) {
		running = 0;
		syslog(LOG_INFO, "Received termination signal, shutting down gracefully");
	}
}

int open_watchdog(void)
{
	int fd;
	int timeout = WDT_TIMEOUT;

	fd = open(WDT_DEVICE, O_WRONLY);
	if (fd < 0) {
		syslog(LOG_ERR, "Failed to open %s: %m", WDT_DEVICE);
		return -1;
	}

	/* Set timeout */
	if (ioctl(fd, WDIOC_SETTIMEOUT, &timeout) < 0) {
		syslog(LOG_WARNING, "Failed to set watchdog timeout, using default");
	} else {
		syslog(LOG_INFO, "Hardware watchdog timeout set to %d seconds", timeout);
	}

	/* Get actual timeout (may differ from requested) */
	if (ioctl(fd, WDIOC_GETTIMEOUT, &timeout) == 0) {
		syslog(LOG_INFO, "Actual hardware watchdog timeout: %d seconds", timeout);
	}

	return fd;
}

void feed_watchdog(int fd)
{
	if (fd >= 0) {
		/* Writing anything to the watchdog device feeds it */
		if (write(fd, "\0", 1) < 0) {
			syslog(LOG_ERR, "Failed to feed watchdog: %m");
		}
	}
}

void disable_watchdog(int fd)
{
	if (fd >= 0) {
		/* Writing 'V' before closing disables the watchdog on some drivers */
		write(fd, "V", 1);
		close(fd);
		syslog(LOG_INFO, "Hardware watchdog disabled");
	}
}

int check_system_health(void)
{
	/*
	 * Basic sanity check: verify we can allocate memory and access filesystem
	 * If this function hangs, the watchdog won't be fed and system will reboot
	 */
	void *ptr = malloc(1024);
	if (!ptr) {
		syslog(LOG_WARNING, "Memory allocation failed during health check");
		return -1;
	}
	free(ptr);

	/* Check if /proc is accessible */
	if (access("/proc/uptime", R_OK) != 0) {
		syslog(LOG_ERR, "Cannot access /proc filesystem");
		return -1;
	}

	return 0;
}

void write_pid_file(void)
{
	FILE *fp = fopen(PID_FILE, "w");
	if (fp) {
		fprintf(fp, "%d\n", getpid());
		fclose(fp);
	}
}

void remove_pid_file(void)
{
	unlink(PID_FILE);
}

int main(int argc, char *argv[])
{
	int disable_on_exit = 0;

	/* Parse arguments */
	if (argc > 1 && strcmp(argv[1], "--disable-on-exit") == 0) {
		disable_on_exit = 1;
	}

	/* Open syslog */
	openlog("hw_watchdog", LOG_PID | LOG_CONS, LOG_DAEMON);

	/* Setup signal handlers */
	signal(SIGTERM, signal_handler);
	signal(SIGINT, signal_handler);
	signal(SIGHUP, SIG_IGN);

	/* Daemonize */
	if (daemon(0, 0) < 0) {
		syslog(LOG_ERR, "Failed to daemonize: %m");
		return 1;
	}

	write_pid_file();

	/* Open watchdog device */
	wdt_fd = open_watchdog();
	if (wdt_fd < 0) {
		syslog(LOG_ERR, "Failed to initialize hardware watchdog");
		remove_pid_file();
		return 1;
	}

	syslog(LOG_INFO, "Hardware watchdog daemon started (feed interval: %ds)", WDT_FEED_INTERVAL);

	/* Main loop */
	while (running) {
		/* Perform health check */
		if (check_system_health() == 0) {
			/* System is healthy, feed the watchdog */
			feed_watchdog(wdt_fd);
		} else {
			/* System health check failed - don't feed watchdog */
			syslog(LOG_CRIT, "System health check failed, watchdog will not be fed");
			/* Let the hardware watchdog trigger reboot */
			sleep(WDT_TIMEOUT + 10);
			break;
		}

		/* Sleep until next feed time */
		sleep(WDT_FEED_INTERVAL);
	}

	/* Cleanup */
	syslog(LOG_INFO, "Hardware watchdog daemon shutting down");

	if (disable_on_exit) {
		disable_watchdog(wdt_fd);
	} else {
		/* Keep watchdog active - system will reboot if it doesn't restart properly */
		close(wdt_fd);
		syslog(LOG_WARNING, "Watchdog remains active after exit");
	}

	remove_pid_file();
	closelog();

	return 0;
}
