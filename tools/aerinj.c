// SPDX-License-Identifier: GPL-2.0-only
/*
 * aerinj: inject AER errors through /dev/aer_inject (CONFIG_PCIEAER_INJECT).
 * The kernel fakes the AER status registers of the device and its Root Port
 * and injects the Root Port's AER interrupt, so aer_irq()/aer_isr() handle
 * the error exactly as a real one, including pcie_do_recovery().
 *
 * Usage: aerinj DDDD:BB:DD.F UNCOR COR [COUNT [INTERVAL_US]]
 *   UNCOR/COR: status bits (e.g. 0x10 = Data Link Protocol, fatal by default)
 *   COUNT: number of injections, 0 = until killed (default 1)
 *   INTERVAL_US: pause between injections (default 0)
 * Prints "AERINJ start ..." and, per distinct errno, "AERINJ err N: ...".
 * AERINJ_WAIT=PATTERN: first wait for a new kernel log record containing
 * PATTERN (read from /dev/kmsg, from its end), e.g. "sysrq: Power Off".
 */
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

struct aer_error_inj {		/* drivers/pci/pcie/aer_inject.c */
	uint8_t bus;
	uint8_t dev;
	uint8_t fn;
	uint32_t uncor_status;
	uint32_t cor_status;
	uint32_t header_log0;
	uint32_t header_log1;
	uint32_t header_log2;
	uint32_t header_log3;
	uint32_t domain;
};

int main(int argc, char **argv)
{
	struct aer_error_inj e;
	unsigned int dom, bus, dev, fn;
	unsigned long count = 1, interval = 0, n, ok = 0;
	int fd, seen[256] = { 0 };

	if (argc < 4 || sscanf(argv[1], "%x:%x:%x.%x", &dom, &bus, &dev, &fn) != 4) {
		fprintf(stderr, "usage: aerinj DDDD:BB:DD.F UNCOR COR [COUNT [INTERVAL_US]]\n");
		return 2;
	}
	memset(&e, 0, sizeof(e));
	e.domain = dom;
	e.bus = bus;
	e.dev = dev;
	e.fn = fn;
	e.uncor_status = strtoul(argv[2], NULL, 0);
	e.cor_status = strtoul(argv[3], NULL, 0);
	if (argc > 4)
		count = strtoul(argv[4], NULL, 0);
	if (argc > 5)
		interval = strtoul(argv[5], NULL, 0);

	fd = open("/dev/aer_inject", O_WRONLY);
	if (fd < 0) {
		printf("AERINJ open: %s\n", strerror(errno));
		return 1;
	}
	if (getenv("AERINJ_WAIT")) {
		const char *pat = getenv("AERINJ_WAIT");
		char rec[8192];
		ssize_t r;
		int k = open("/dev/kmsg", O_RDONLY);

		if (k < 0 || lseek(k, 0, SEEK_END) < 0) {
			printf("AERINJ kmsg: %s\n", strerror(errno));
			return 1;
		}
		for (;;) {
			r = read(k, rec, sizeof(rec) - 1);
			if (r < 0 && errno == EPIPE)
				continue;	/* overwritten records */
			if (r < 0) {
				printf("AERINJ kmsg read: %s\n", strerror(errno));
				return 1;
			}
			rec[r] = 0;
			if (strstr(rec, pat))
				break;
		}
		close(k);
	}
	printf("AERINJ start %s uncor=%#x cor=%#x count=%lu interval_us=%lu\n",
	       argv[1], e.uncor_status, e.cor_status, count, interval);
	fflush(stdout);
	for (n = 0; !count || n < count; n++) {
		if (write(fd, &e, sizeof(e)) == sizeof(e)) {
			ok++;
		} else if (errno < 256 && !seen[errno]++) {
			printf("AERINJ err %lu: %s\n", n, strerror(errno));
			fflush(stdout);
		}
		if (interval)
			usleep(interval);
	}
	printf("AERINJ done n=%lu ok=%lu\n", n, ok);
	return ok ? 0 : 1;
}
