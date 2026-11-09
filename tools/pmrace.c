// SPDX-License-Identifier: GPL-2.0-only
// pmrace ROUNDS BDF: race the close of a vfio-pci PF left in D3hot against
// enabling SR-IOV on it (group API).
//
// Each round opens the device, writes D3hot to its PMCSR through the vfio
// config region, then closes the device fd while a second thread, released by
// the same barrier, writes 1 to sriov_numvfs after a delay of 2000 + (r % 10) *
// 500 us (the window of the close-time D3hot->D0 transition, 10 ms d3hot
// delay).  sriov_numvfs is then written 0.  The next open checks that the
// close left the device in D0.  Output: one line per round, then
// "PMRACE rounds=N warn_rounds=W not_d0=K numvfs_err=E" (W: rounds that
// raised /sys/kernel/warn_count).
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <time.h>
#include <unistd.h>
#include <linux/pci_regs.h>
#include <linux/vfio.h>

static const char *bdf;
static int container, group;
static off_t cfg_off;
static pthread_barrier_t barrier;
static int delay_us, numvfs_errno;
static double t_numvfs_done;

static double now(void)
{
	struct timespec t;

	clock_gettime(CLOCK_MONOTONIC, &t);
	return t.tv_sec + t.tv_nsec / 1e9;
}

static void die(const char *what)
{
	perror(what);
	exit(1);
}

static void setup(void)
{
	struct vfio_group_status st = { .argsz = sizeof(st) };
	char p[PATH_MAX], l[PATH_MAX];
	ssize_t n;

	snprintf(p, sizeof(p), "/sys/bus/pci/devices/%s/iommu_group", bdf);
	n = readlink(p, l, sizeof(l) - 1);
	if (n < 0)
		die(p);
	l[n] = 0;
	container = open("/dev/vfio/vfio", O_RDWR);
	if (container < 0)
		die("/dev/vfio/vfio");
	snprintf(p, sizeof(p), "/dev/vfio/%s", strrchr(l, '/') + 1);
	group = open(p, O_RDWR);
	if (group < 0)
		die(p);
	if (ioctl(group, VFIO_GROUP_GET_STATUS, &st) || !(st.flags & VFIO_GROUP_FLAGS_VIABLE)) {
		fprintf(stderr, "group not viable\n");
		exit(1);
	}
	if (ioctl(group, VFIO_GROUP_SET_CONTAINER, &container))
		die("SET_CONTAINER");
	if (ioctl(container, VFIO_SET_IOMMU, VFIO_TYPE1v2_IOMMU))
		die("SET_IOMMU");
}

static int open_dev(void)
{
	struct vfio_region_info ri = { .argsz = sizeof(ri), .index = VFIO_PCI_CONFIG_REGION_INDEX };
	int fd = ioctl(group, VFIO_GROUP_GET_DEVICE_FD, bdf);

	if (fd < 0)
		die("GET_DEVICE_FD");
	if (ioctl(fd, VFIO_DEVICE_GET_REGION_INFO, &ri))
		die("GET_REGION_INFO");
	cfg_off = ri.offset;
	return fd;
}

static unsigned int cfg_rd(int fd, int off, int len)
{
	unsigned int v = 0;

	if (pread(fd, &v, len, cfg_off + off) != len)
		die("config read");
	return v;
}

static void cfg_wr(int fd, int off, int len, unsigned int v)
{
	if (pwrite(fd, &v, len, cfg_off + off) != len)
		die("config write");
}

static int pm_cap(int fd)
{
	int pos, ttl = 48;

	if (!(cfg_rd(fd, PCI_STATUS, 2) & PCI_STATUS_CAP_LIST))
		return 0;
	for (pos = cfg_rd(fd, PCI_CAPABILITY_LIST, 1); pos >= 0x40 && ttl--;
	     pos = cfg_rd(fd, pos + PCI_CAP_LIST_NEXT, 1)) {
		pos &= ~3;
		if (cfg_rd(fd, pos + PCI_CAP_LIST_ID, 1) == PCI_CAP_ID_PM)
			return pos;
	}
	return 0;
}

static int pm_state(int fd, int pm)
{
	return cfg_rd(fd, pm + PCI_PM_CTRL, 2) & PCI_PM_CTRL_STATE_MASK;
}

static void pm_set(int fd, int pm, int state)
{
	unsigned int v = cfg_rd(fd, pm + PCI_PM_CTRL, 2);

	cfg_wr(fd, pm + PCI_PM_CTRL, 2, (v & ~PCI_PM_CTRL_STATE_MASK) | state);
}

static int numvfs(const char *val)
{
	char p[PATH_MAX];
	int fd, ret = 0;

	snprintf(p, sizeof(p), "/sys/bus/pci/devices/%s/sriov_numvfs", bdf);
	fd = open(p, O_WRONLY);
	if (fd < 0)
		return errno;
	if (write(fd, val, strlen(val)) < 0)
		ret = errno;
	close(fd);
	return ret;
}

static long warn_count(void)
{
	char buf[32] = "";
	int fd = open("/sys/kernel/warn_count", O_RDONLY);
	ssize_t n;

	if (fd < 0)
		return -1;
	n = read(fd, buf, sizeof(buf) - 1);
	close(fd);
	return n > 0 ? atol(buf) : -1;
}

static void *enabler(void *arg)
{
	(void)arg;
	pthread_barrier_wait(&barrier);
	usleep(delay_us);
	numvfs_errno = numvfs("1");
	t_numvfs_done = now();
	return NULL;
}

int main(int argc, char **argv)
{
	int rounds, r, fd, pm, st, not_d0 = 0, nerr = 0, hit = 0;
	long w0, w1;
	pthread_t th;
	double t0, t_close;

	if (argc != 3) {
		fprintf(stderr, "usage: pmrace ROUNDS BDF\n");
		return 2;
	}
	rounds = atoi(argv[1]);
	bdf = argv[2];
	setup();
	fd = open_dev();
	pm = pm_cap(fd);
	if (!pm) {
		fprintf(stderr, "no PM capability\n");
		return 1;
	}
	printf("pmrace: %s PM cap 0x%x PMCSR 0x%04x\n", bdf, pm, cfg_rd(fd, pm + PCI_PM_CTRL, 2));
	pthread_barrier_init(&barrier, NULL, 2);
	for (r = 0; r < rounds; r++) {
		delay_us = 2000 + (r % 10) * 500;
		w0 = warn_count();
		pm_set(fd, pm, 3);
		st = pm_state(fd, pm);
		if (st != 3)
			printf("round %d: D3hot write read back D%d\n", r, st);
		if (pthread_create(&th, NULL, enabler, NULL))
			die("pthread_create");
		pthread_barrier_wait(&barrier);
		t0 = now();
		close(fd);
		t_close = now();
		pthread_join(th, NULL);
		if (numvfs_errno)
			nerr++;
		w1 = warn_count();
		if (w1 != w0)
			hit++;
		printf("round %d: delay %d us, close %.1f ms, numvfs=1 %s at %.1f ms, warnings +%ld\n", r,
		       delay_us, 1e3 * (t_close - t0), numvfs_errno ? strerror(numvfs_errno) : "ok",
		       1e3 * (t_numvfs_done - t0), w1 - w0);
		st = numvfs("0");
		if (st)
			printf("round %d: numvfs=0: %s\n", r, strerror(st));
		fd = open_dev();
		st = pm_state(fd, pm);
		if (st != 0) {
			not_d0++;
			printf("round %d: device in D%d after close\n", r, st);
			pm_set(fd, pm, 0);
		}
	}
	close(fd);
	printf("PMRACE rounds=%d warn_rounds=%d not_d0=%d numvfs_err=%d\n", rounds, hit, not_d0, nerr);
	fflush(stdout);
	return 0;
}
