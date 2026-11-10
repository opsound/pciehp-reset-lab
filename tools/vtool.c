// SPDX-License-Identifier: GPL-2.0-only
// vfio test tool for the pciehp/vfio/PCI reset reproducers (group API).
//   vtool hold [--respond] [--reset-on-req] BDF...
//	Open devices (fds opened last, in argv order, so exit closes the last first),
//	arm a request eventfd on each, then wait.  --respond closes a device when vfio
//	relays a removal request for it.  --reset-on-req first issues VFIO_DEVICE_RESET
//	on every other open device, like a live user resetting dev B while dev A is
//	being removed.  SIGUSR1 closes all devices, last first; SIGUSR2 closes
//	the first device only; SIGHUP prints a "VTPROBE" line per device
//	(COMMAND read through vfio's config region, BAR0 + 8 through its BAR0
//	region).  VT_CMD_OR=HEX sets those COMMAND bits through vfio after the
//	open, as a user driver would; VT_REC, VT_IRQ, VT_MMAP, VT_D3,
//	VT_D3CYCLE, VT_PMLOOP and VT_REARM (below) add more.  Devices in one
//	IOMMU group (functions of one multifunction device) share the group fd.
//   vtool loop N BDF	   open and close the device fd N times (close resets)
//   vtool resetloop N BDF  open once, VFIO_DEVICE_RESET N times
//   vtool hotresetloop N BDF  open once, VFIO_DEVICE_PCI_HOT_RESET N times
//   vtool hammer SECS BDF  VFIO_DEVICE_RESET loop, close VT_LINGER_MS after the
//			   removal request
//   hold --respond waits VT_RESP_DELAY_MS before closing
//   vtool openwait MS BDF  retry opening the device for up to MS ms (until the
//			   group exists), report the result of the first real open
// Errors are counted per errno ("ERRS" line) and the loops continue; reset
// errors are also printed per iteration as "reset N: <strerror>".
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <pthread.h>
#include <setjmp.h>
#include <stdint.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/eventfd.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>
#include <linux/vfio.h>

#define MAXDEV 32
static int ndev, container, grp[MAXDEV], devfd[MAXDEV], efd[MAXDEV];
static const char *bdf[MAXDEV];
static volatile sig_atomic_t do_close;

static void on_usr1(int sig) { (void)sig; do_close = 1; }
static volatile sig_atomic_t do_close1;
static void on_usr2(int sig) { (void)sig; do_close1 = 1; }
static volatile sig_atomic_t do_probe;
static void on_hup(int sig) { (void)sig; do_probe = 1; }

/*
 * PCI error recovery reporting of Shameer Kolothum's "[RFC PATCH v2 00/16]
 * vfio/pci: Handle PCI error recovery and report state to userspace"
 * (uapi copied from 15/16; kernels without it return ENOTTY).
 *   VT_REC=1      enable it on each held device with an eventfd; a thread
 *                 prints "VTREVT BDF n=N flags=0x.. seq=N" per notification
 *   VT_IRQ=msix|intx  arm one interrupt of that type with an eventfd
 *   VT_MMAP=1     mmap BAR0; SIGHUP probes also read BAR0 + 8 through it
 *   VT_D3=1       put each device into D3hot through vfio's PMCSR
 *   VT_D3CYCLE=1  first write D3hot and then D0 to it (before VT_D3)
 *   VT_PMLOOP=FILE  a thread writes D3hot and D0 to the first device's PMCSR
 *                 back to back, as a guest's runtime PM would, and keeps
 *                 "n=N eio=N other=N" in FILE
 *   VT_REARM=1    in a SIGHUP probe, re-arm VT_IRQ after a reported reset
 */
static double now(void);
#ifndef VFIO_DEVICE_FEATURE_PCI_ERROR_RECOVERY
#define VFIO_DEVICE_FEATURE_PCI_ERROR_RECOVERY 14
#endif
struct vt_rec {
	uint32_t flags;
	int32_t eventfd;
	uint64_t sequence __attribute__((aligned(8)));
};
static int recfd[MAXDEV] = { [0 ... MAXDEV - 1] = -1 };
static int irqfd[MAXDEV] = { [0 ... MAXDEV - 1] = -1 };
static volatile unsigned char *bar0map[MAXDEV];
static int pmcsr_off[MAXDEV];
static sigjmp_buf bus_jmp;
static volatile sig_atomic_t in_mmap_read;
static void on_bus(int sig) { (void)sig; if (in_mmap_read) siglongjmp(bus_jmp, 1); _exit(99); }

static const char *ename(int e)
{
	return strerrorname_np(e) ? strerrorname_np(e) : "?";
}

/* GET the recovery state: 0 and *st filled, or -errno */
static int rec_get(int i, struct vt_rec *st)
{
	char buf[sizeof(struct vfio_device_feature) + sizeof(struct vt_rec)];
	struct vfio_device_feature *f = (void *)buf;

	memset(buf, 0, sizeof(buf));
	f->argsz = sizeof(buf);
	f->flags = VFIO_DEVICE_FEATURE_GET | VFIO_DEVICE_FEATURE_PCI_ERROR_RECOVERY;
	if (ioctl(devfd[i], VFIO_DEVICE_FEATURE, f))
		return -errno;
	memcpy(st, f->data, sizeof(*st));
	return 0;
}

static int rec_set(int i, int fd)
{
	char buf[sizeof(struct vfio_device_feature) + sizeof(struct vt_rec)];
	struct vfio_device_feature *f = (void *)buf;
	struct vt_rec r = { .eventfd = fd };

	memset(buf, 0, sizeof(buf));
	f->argsz = sizeof(buf);
	f->flags = VFIO_DEVICE_FEATURE_SET | VFIO_DEVICE_FEATURE_PCI_ERROR_RECOVERY;
	memcpy(f->data, &r, sizeof(r));
	return ioctl(devfd[i], VFIO_DEVICE_FEATURE, f) ? -errno : 0;
}

static void rec_str(int i, char *out, size_t len)
{
	struct vt_rec st;
	int r = rec_get(i, &st);

	if (r)
		snprintf(out, len, "rec=%s", ename(-r));
	else
		snprintf(out, len, "rec=0x%x seq=%llu", st.flags, (unsigned long long)st.sequence);
}

static void *rec_thread(void *arg)
{
	(void)arg;
	for (;;) {
		struct pollfd pfd[MAXDEV];
		int i;

		for (i = 0; i < ndev; i++) {
			pfd[i].fd = recfd[i];
			pfd[i].events = POLLIN;
		}
		if (poll(pfd, ndev, -1) < 0)
			continue;
		for (i = 0; i < ndev; i++) {
			unsigned long long v;
			char st[64];

			if (!(pfd[i].revents & POLLIN) || read(recfd[i], &v, sizeof(v)) != sizeof(v))
				continue;
			rec_str(i, st, sizeof(st));
			printf("VTREVT %s n=%llu %s\n", bdf[i], v, st);
			fflush(stdout);
		}
	}
	return NULL;
}

static int arm_irq(int i, const char *type)
{
	char buf[sizeof(struct vfio_irq_set) + sizeof(int)];
	struct vfio_irq_set *s = (void *)buf;

	if (irqfd[i] < 0)
		irqfd[i] = eventfd(0, EFD_CLOEXEC | EFD_NONBLOCK);
	s->argsz = sizeof(buf);
	s->flags = VFIO_IRQ_SET_DATA_EVENTFD | VFIO_IRQ_SET_ACTION_TRIGGER;
	s->index = !strcmp(type, "intx") ? VFIO_PCI_INTX_IRQ_INDEX : VFIO_PCI_MSIX_IRQ_INDEX;
	s->start = 0;
	s->count = 1;
	memcpy(s->data, &irqfd[i], sizeof(int));
	return ioctl(devfd[i], VFIO_DEVICE_SET_IRQS, s) ? -errno : 0;
}

static off_t cfg_off(int i)
{
	struct vfio_region_info r = { .argsz = sizeof(r), .index = VFIO_PCI_CONFIG_REGION_INDEX };

	return ioctl(devfd[i], VFIO_DEVICE_GET_REGION_INFO, &r) ? -1 : (off_t)r.offset;
}

/* PMCSR offset in config space, through vfio's virtualized capability list */
static int find_pmcsr(int i)
{
	off_t base = cfg_off(i);
	unsigned char p = 0, id = 0;
	int n = 0;

	if (base < 0 || pread(devfd[i], &p, 1, base + 0x34) != 1)
		return 0;
	while (p && n++ < 48) {
		if (pread(devfd[i], &id, 1, base + p) != 1)
			return 0;
		if (id == 1)
			return p + 4;
		if (pread(devfd[i], &p, 1, base + p + 1) != 1)
			return 0;
	}
	return 0;
}

/* write power state STATE (0 or 3) to PMCSR: 0 or -errno */
static int set_pm(int i, int state)
{
	off_t base = cfg_off(i);
	unsigned short v = 0;

	if (base < 0 || !pmcsr_off[i])
		return -ENODEV;
	if (pread(devfd[i], &v, 2, base + pmcsr_off[i]) != 2)
		return -errno;
	v = (v & ~3) | state;
	if (pwrite(devfd[i], &v, 2, base + pmcsr_off[i]) != 2)
		return -errno;
	return 0;
}

static void *pm_thread(void *arg)
{
	const char *file = arg;
	long n = 0, eio = 0, other = 0;
	double tlast = 0;

	for (;;) {
		int r1 = set_pm(0, 3), r2 = set_pm(0, 0);

		n++;
		if (r1 == -EIO || r2 == -EIO)
			usleep(200);	/* access blocked by recovery */
		eio += (r1 == -EIO) + (r2 == -EIO);
		other += (r1 && r1 != -EIO) + (r2 && r2 != -EIO);
		if (now() - tlast > 0.2) {
			FILE *f = fopen(file, "w");

			if (f) {
				fprintf(f, "n=%ld eio=%ld other=%ld\n", n, eio, other);
				fclose(f);
			}
			tlast = now();
		}
	}
	return NULL;
}

static void vt_setup(int i)
{
	if (getenv("VT_REC")) {
		int r;

		recfd[i] = eventfd(0, EFD_CLOEXEC | EFD_NONBLOCK);
		r = rec_set(i, recfd[i]);
		printf("VTREC %s enable: %s\n", bdf[i], r ? ename(-r) : "ok");
	}
	if (getenv("VT_IRQ")) {
		int r = arm_irq(i, getenv("VT_IRQ"));

		printf("VTIRQ %s %s: %s\n", bdf[i], getenv("VT_IRQ"), r ? ename(-r) : "ok");
	}
	if (getenv("VT_MMAP")) {
		struct vfio_region_info rb = { .argsz = sizeof(rb), .index = VFIO_PCI_BAR0_REGION_INDEX };
		void *m = MAP_FAILED;

		if (!ioctl(devfd[i], VFIO_DEVICE_GET_REGION_INFO, &rb) && (rb.flags & VFIO_REGION_INFO_FLAG_MMAP))
			m = mmap(NULL, 4096, PROT_READ | PROT_WRITE, MAP_SHARED, devfd[i], rb.offset);
		bar0map[i] = m == MAP_FAILED ? NULL : m;
		printf("VTMMAP %s: %s\n", bdf[i], bar0map[i] ? "ok" : strerror(errno));
	}
	pmcsr_off[i] = find_pmcsr(i);
	if (getenv("VT_D3CYCLE")) {
		int r1 = set_pm(i, 3), r2 = set_pm(i, 0);

		printf("VTPM %s pmcsr=0x%x D3hot: %s D0: %s\n", bdf[i], pmcsr_off[i],
		       r1 ? ename(-r1) : "ok", r2 ? ename(-r2) : "ok");
	}
	if (getenv("VT_D3")) {
		int r = set_pm(i, 3);

		printf("VTPM %s pmcsr=0x%x D3hot: %s\n", bdf[i], pmcsr_off[i], r ? ename(-r) : "ok");
	}
	fflush(stdout);
}

static void vt_start_threads(void)
{
	pthread_t t;

	if (getenv("VT_REC"))
		pthread_create(&t, NULL, rec_thread, NULL);
	if (getenv("VT_PMLOOP") && pmcsr_off[0])
		pthread_create(&t, NULL, pm_thread, getenv("VT_PMLOOP"));
	signal(SIGBUS, on_bus);
}

/* SIGHUP in hold: read COMMAND through the config region and the 32-bit
 * register at BAR0 + 8 (e1000e STATUS) through the BAR0 region, as a user would;
 * also through the mmap (VT_MMAP) and the recovery state (VT_REC). */
static void mmap_read(int i, char *mm, size_t len)
{
	if (!sigsetjmp(bus_jmp, 1)) {
		unsigned int mv;

		in_mmap_read = 1;
		mv = *(volatile unsigned int *)(bar0map[i] + 8);
		in_mmap_read = 0;
		snprintf(mm, len, " mmap_reg8=0x%x", mv);
	} else {
		in_mmap_read = 0;
		snprintf(mm, len, " mmap_reg8=SIGBUS");
	}
}

static unsigned int last_seq[MAXDEV];
static void probe(int i)
{
	struct vfio_region_info rc = { .argsz = sizeof(rc), .index = VFIO_PCI_CONFIG_REGION_INDEX };
	struct vfio_region_info rb = { .argsz = sizeof(rb), .index = VFIO_PCI_BAR0_REGION_INDEX };
	unsigned short c = 0;
	unsigned int v = 0;
	ssize_t n1 = -1, n2 = -1;
	int e1 = 0, e2 = 0;
	char mm[48] = "", rs[64] = "", ra[48] = "";

	if (!ioctl(devfd[i], VFIO_DEVICE_GET_REGION_INFO, &rc)) {
		n1 = pread(devfd[i], &c, 2, rc.offset + 4);
		e1 = errno;
	}
	if (!ioctl(devfd[i], VFIO_DEVICE_GET_REGION_INFO, &rb)) {
		n2 = pread(devfd[i], &v, 4, rb.offset + 8);
		e2 = errno;
	}
	if (bar0map[i])
		mmap_read(i, mm, sizeof(mm));
	if (getenv("VT_REC")) {
		struct vt_rec st;

		rs[0] = ' ';
		rec_str(i, rs + 1, sizeof(rs) - 1);
		if (getenv("VT_REARM") && getenv("VT_IRQ") && !rec_get(i, &st) &&
		    (st.flags & 4) && st.sequence != last_seq[i]) {
			int r = arm_irq(i, getenv("VT_IRQ"));

			last_seq[i] = st.sequence;
			snprintf(ra, sizeof(ra), " rearm_%s=%s", getenv("VT_IRQ"), r ? ename(-r) : "ok");
		}
	}
	printf("VTPROBE %s vfio_cmd=%s%s0x%x bar0_reg8=%s%s0x%x%s%s%s\n", bdf[i],
	       n1 == 2 ? "" : "ERR:", n1 == 2 ? "" : ename(e1), c,
	       n2 == 4 ? "" : "ERR:", n2 == 4 ? "" : ename(e2), v, mm, rs, ra);
	fflush(stdout);
}

static double now(void)
{
	struct timespec t;

	clock_gettime(CLOCK_MONOTONIC, &t);
	return t.tv_sec + t.tv_nsec / 1e9;
}

static int group_of(const char *b)
{
	char p[PATH_MAX], l[PATH_MAX];
	ssize_t n;

	snprintf(p, sizeof(p), "/sys/bus/pci/devices/%s/iommu_group", b);
	n = readlink(p, l, sizeof(l) - 1);
	if (n < 0) { perror(p); exit(1); }
	l[n] = 0;
	return atoi(strrchr(l, '/') + 1);
}

static void setup_groups(void)
{
	char p[64];
	int i;

	container = open("/dev/vfio/vfio", O_RDWR);
	if (container < 0) { perror("/dev/vfio/vfio"); exit(1); }
	for (i = 0; i < ndev; i++) {
		struct vfio_group_status st = { .argsz = sizeof(st) };
		int j;

		for (j = 0; j < i && group_of(bdf[j]) != group_of(bdf[i]); j++)
			;
		if (j < i) {	/* same group as an earlier device: one open per group */
			grp[i] = grp[j];
			continue;
		}
		snprintf(p, sizeof(p), "/dev/vfio/%d", group_of(bdf[i]));
		grp[i] = open(p, O_RDWR);
		if (grp[i] < 0) { perror(p); exit(1); }
		if (ioctl(grp[i], VFIO_GROUP_GET_STATUS, &st) || !(st.flags & VFIO_GROUP_FLAGS_VIABLE)) {
			fprintf(stderr, "%s: group not viable\n", bdf[i]); exit(1);
		}
		if (ioctl(grp[i], VFIO_GROUP_SET_CONTAINER, &container)) { perror("SET_CONTAINER"); exit(1); }
		if (i == 0 && ioctl(container, VFIO_SET_IOMMU, VFIO_TYPE1v2_IOMMU)) { perror("SET_IOMMU"); exit(1); }
	}
}

static int open_dev(int i)
{
	int fd = ioctl(grp[i], VFIO_GROUP_GET_DEVICE_FD, bdf[i]);

	if (fd < 0)
		fprintf(stderr, "%s: GET_DEVICE_FD: %s\n", bdf[i], strerror(errno));
	return fd;
}

static void stats(const char *what, double *t, int n)
{
	double sum = 0, mx = 0, mn = 1e9;
	int i;

	for (i = 0; i < n; i++) {
		sum += t[i];
		if (t[i] > mx) mx = t[i];
		if (t[i] < mn) mn = t[i];
	}
	printf("STATS %s n=%d avg_ms=%.3f min_ms=%.3f max_ms=%.3f\n", what, n,
	       1e3 * sum / n, 1e3 * mn, 1e3 * mx);
}

static int nerr[256];

static void count_err(int e)
{
	nerr[e & 255]++;
}

static void print_errs(const char *what)
{
	int e, any = 0;

	printf("ERRS %s", what);
	for (e = 1; e < 256; e++)
		if (nerr[e]) {
			printf(" %s=%d", strerrorname_np(e) ? strerrorname_np(e) : "?", nerr[e]);
			any = 1;
		}
	printf("%s\n", any ? "" : " none");
}

static int hot_reset(int fd, int gfd)
{
	char buf[sizeof(struct vfio_pci_hot_reset) + sizeof(int)];
	struct vfio_pci_hot_reset *r = (void *)buf;

	r->argsz = sizeof(buf);
	r->flags = 0;
	r->count = 1;
	r->group_fds[0] = gfd;
	return ioctl(fd, VFIO_DEVICE_PCI_HOT_RESET, r);
}

static int cmd_loop(int n, int mode)
{
	static const char *names[] = { "open+close", "VFIO_DEVICE_RESET", "VFIO_DEVICE_PCI_HOT_RESET" };
	double *t = calloc(n, sizeof(*t)), t0;
	int i, fd = -1, ok = 0;

	if (mode && (fd = open_dev(0)) < 0)
		return 1;
	for (i = 0; i < n; i++) {
		int r;

		t0 = now();
		if (mode == 1) {
			r = ioctl(fd, VFIO_DEVICE_RESET);
		} else if (mode == 2) {
			r = hot_reset(fd, grp[0]);
		} else {
			r = fd = open_dev(0);
			if (fd >= 0)
				close(fd);
		}
		t[i] = now() - t0;
		if (r < 0) {
			int e = errno;

			count_err(e);
			/* per-iteration errors, as parsed by churn/liveuser ("reset N: ...") */
			if (mode)
				printf("reset %d: %s\n", i, strerror(e));
		} else {
			ok++;
		}
	}
	stats(names[mode], t, n);
	printf("OK %s %d/%d\n", names[mode], ok, n);
	print_errs(names[mode]);
	return 0;
}

/* hammer SECS BDF: VFIO_DEVICE_RESET in a loop; close the device
 * VT_LINGER_MS (default 300) after vfio's removal request, or after SECS. */
static int cmd_hammer(int secs)
{
	char buf[sizeof(struct vfio_irq_set) + sizeof(int)];
	struct vfio_irq_set *s = (void *)buf;
	double t0 = now(), treq = 0;
	long n = 0, nerr = 0;
	int fd, ev, linger = getenv("VT_LINGER_MS") ? atoi(getenv("VT_LINGER_MS")) : 300;

	fd = open_dev(0);
	if (fd < 0)
		return 1;
	ev = eventfd(0, EFD_CLOEXEC | EFD_NONBLOCK);
	s->argsz = sizeof(buf);
	s->flags = VFIO_IRQ_SET_DATA_EVENTFD | VFIO_IRQ_SET_ACTION_TRIGGER;
	s->index = VFIO_PCI_REQ_IRQ_INDEX;
	s->start = 0;
	s->count = 1;
	memcpy(s->data, &ev, sizeof(int));
	ioctl(fd, VFIO_DEVICE_SET_IRQS, s);
	printf("HAMMER %s start\n", bdf[0]);
	fflush(stdout);
	while (now() - t0 < secs) {
		unsigned long long v;

		if (!treq && read(ev, &v, sizeof(v)) == sizeof(v)) {
			treq = now();
			printf("HAMMER %s request after %ld resets\n", bdf[0], n);
			fflush(stdout);
		}
		if (treq && now() - treq > linger / 1e3)
			break;
		if (ioctl(fd, VFIO_DEVICE_RESET))
			nerr++;
		n++;
	}
	close(fd);
	printf("HAMMER %s closed resets=%ld errors=%ld req=%d after %.2f s\n", bdf[0], n, nerr,
	       treq != 0, now() - t0);
	return 0;
}

static int cmd_openwait(int ms)
{
	double t0 = now();
	int fd;

	for (;;) {
		char p[PATH_MAX], l[PATH_MAX];

		snprintf(p, sizeof(p), "/sys/bus/pci/devices/%s/driver", bdf[0]);
		if (readlink(p, l, sizeof(l)) > 0 && strstr(l, "vfio-pci"))
			break;
		if (now() - t0 > ms / 1e3) {
			printf("OPENWAIT timeout\n");
			return 1;
		}
		usleep(50);
	}
	for (;;) {
		char p[64];

		snprintf(p, sizeof(p), "/dev/vfio/%d", group_of(bdf[0]));
		if (!access(p, F_OK))
			break;
		usleep(50);
	}
	setup_groups();
	fd = open_dev(0);
	printf("OPENWAIT %s after %.3f ms: %s\n", bdf[0], 1e3 * (now() - t0),
	       fd < 0 ? strerror(errno) : "ok");
	if (fd >= 0)
		close(fd);
	return fd < 0;
}

static int cmd_hold(int respond, int reset_on_req)
{
	int i, j;

	for (i = 0; i < ndev; i++)
		efd[i] = eventfd(0, EFD_CLOEXEC);
	for (i = 0; i < ndev; i++) {
		char buf[sizeof(struct vfio_irq_set) + sizeof(int)];
		struct vfio_irq_set *s = (void *)buf;

		devfd[i] = open_dev(i);
		if (devfd[i] < 0)
			return 1;
		s->argsz = sizeof(buf);
		s->flags = VFIO_IRQ_SET_DATA_EVENTFD | VFIO_IRQ_SET_ACTION_TRIGGER;
		s->index = VFIO_PCI_REQ_IRQ_INDEX;
		s->start = 0;
		s->count = 1;
		memcpy(s->data, &efd[i], sizeof(int));
		if (ioctl(devfd[i], VFIO_DEVICE_SET_IRQS, s))
			fprintf(stderr, "%s: REQ irq: %s (continuing)\n", bdf[i], strerror(errno));
		/* VT_CMD_OR=HEX: set PCI_COMMAND bits through vfio's config region, as a user would */
		if (getenv("VT_CMD_OR")) {
			struct vfio_region_info ri = { .argsz = sizeof(ri), .index = VFIO_PCI_CONFIG_REGION_INDEX };
			unsigned short c = 0, c2 = 0;

			if (ioctl(devfd[i], VFIO_DEVICE_GET_REGION_INFO, &ri) ||
			    pread(devfd[i], &c, 2, ri.offset + 4) != 2) {
				fprintf(stderr, "%s: config region: %s\n", bdf[i], strerror(errno));
			} else {
				c |= strtoul(getenv("VT_CMD_OR"), NULL, 16);
				if (pwrite(devfd[i], &c, 2, ri.offset + 4) != 2)
					fprintf(stderr, "%s: COMMAND write: %s\n", bdf[i], strerror(errno));
				pread(devfd[i], &c2, 2, ri.offset + 4);
				printf("VTCMD %s wrote=0x%x reads=0x%x\n", bdf[i], c, c2);
			}
		}
	}
	for (i = 0; i < ndev; i++)
		vt_setup(i);
	vt_start_threads();
	signal(SIGUSR1, on_usr1);
	signal(SIGUSR2, on_usr2);
	signal(SIGHUP, on_hup);
	printf("READY pid=%d\n", getpid());
	fflush(stdout);
	while ((respond || reset_on_req) && !do_close) {
		struct pollfd pfd[MAXDEV];
		int open = 0;

		for (i = 0; i < ndev; i++) {
			pfd[i].fd = devfd[i] >= 0 ? efd[i] : -1;
			pfd[i].events = POLLIN;
			open += devfd[i] >= 0;
		}
		if (!open)
			return 0;
		if (poll(pfd, ndev, -1) < 0)
			continue;
		for (i = 0; i < ndev; i++) {
			if (!(pfd[i].revents & POLLIN))
				continue;
			printf("request for %s\n", bdf[i]);
			fflush(stdout);
			if (respond && getenv("VT_RESP_DELAY_MS"))
				usleep(1000 * atoi(getenv("VT_RESP_DELAY_MS")));
			if (reset_on_req && getenv("VT_REQ_DELAY_MS"))
				usleep(1000 * atoi(getenv("VT_REQ_DELAY_MS")));
			for (j = 0; reset_on_req && j < ndev; j++) {
				double t0 = now();
				int r;

				if (j == i || devfd[j] < 0)
					continue;
				printf("VFIO_DEVICE_RESET %s ...\n", bdf[j]);
				fflush(stdout);
				r = ioctl(devfd[j], VFIO_DEVICE_RESET);
				printf("VFIO_DEVICE_RESET %s -> %s after %.3f s\n", bdf[j],
				       r ? strerror(errno) : "ok", now() - t0);
				fflush(stdout);
			}
			close(devfd[i]);
			devfd[i] = -1;
			printf("closed %s\n", bdf[i]);
			fflush(stdout);
		}
	}
	while (!do_close) {
		pause();
		if (do_probe) {
			do_probe = 0;
			for (i = 0; i < ndev; i++)
				if (devfd[i] >= 0)
					probe(i);
		}
		if (do_close1 && devfd[0] >= 0) {
			close(devfd[0]);
			devfd[0] = -1;
			printf("closed %s\n", bdf[0]);
			fflush(stdout);
		}
	}
	for (i = ndev - 1; i >= 0; i--) {
		if (devfd[i] < 0)
			continue;
		close(devfd[i]);
		printf("closed %s\n", bdf[i]);
		fflush(stdout);
	}
	return 0;
}

int main(int argc, char **argv)
{
	int respond = 0, reset_on_req = 0, n = 0;
	const char *cmd;

	if (argc < 3) {
		fprintf(stderr, "usage: vtool hold [--respond] [--reset-on-req] BDF... | loop|resetloop|hotresetloop N BDF | openwait MS BDF | hammer SECS BDF\n");
		return 2;
	}
	cmd = argv[1];
	argv += 2;
	argc -= 2;
	if (!strcmp(cmd, "loop") || !strcmp(cmd, "resetloop") ||
	    !strcmp(cmd, "hotresetloop") || !strcmp(cmd, "openwait") || !strcmp(cmd, "hammer")) {
		n = atoi(argv[0]);
		argv++;
		argc--;
	}
	while (argc && !strncmp(argv[0], "--", 2)) {
		if (!strcmp(argv[0], "--respond"))
			respond = 1;
		else if (!strcmp(argv[0], "--reset-on-req"))
			reset_on_req = 1;
		argv++;
		argc--;
	}
	ndev = argc;
	if (ndev < 1 || ndev > MAXDEV)
		return 2;
	memcpy(bdf, argv, ndev * sizeof(*argv));
	if (!strcmp(cmd, "openwait"))
		return cmd_openwait(n);
	if (!strcmp(cmd, "hammer"))
		return cmd_hammer(n);
	setup_groups();
	if (!strcmp(cmd, "hold"))
		return cmd_hold(respond, reset_on_req);
	return cmd_loop(n, !strcmp(cmd, "resetloop") ? 1 : !strcmp(cmd, "hotresetloop") ? 2 : 0);
}
