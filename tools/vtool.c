// SPDX-License-Identifier: GPL-2.0-only
// vfio test tool for the pciehp/vfio/PCI reset reproducers (group API).
//   vtool hold [--respond] [--reset-on-req] BDF...
//	Open devices (fds opened last, in argv order, so exit closes the last first),
//	arm a request eventfd on each, then wait.  --respond closes a device when vfio
//	relays a removal request for it.  --reset-on-req first issues VFIO_DEVICE_RESET
//	on every other open device, like a live user resetting dev B while dev A is
//	being removed.  SIGUSR1 closes all devices, last first.
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
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/eventfd.h>
#include <sys/ioctl.h>
#include <time.h>
#include <unistd.h>
#include <linux/vfio.h>

#define MAXDEV 32
static int ndev, container, grp[MAXDEV], devfd[MAXDEV], efd[MAXDEV];
static const char *bdf[MAXDEV];
static volatile sig_atomic_t do_close;

static void on_usr1(int sig) { (void)sig; do_close = 1; }

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
	}
	signal(SIGUSR1, on_usr1);
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
	while (!do_close)
		pause();
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
