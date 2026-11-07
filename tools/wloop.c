// SPDX-License-Identifier: GPL-2.0-only
// Write loop for the reset-subordinate-uaf reproducer.
//   wloop PATH SECS
//	Open PATH (a reset_subordinate attribute) once and write "1" to it back
//	to back until a write fails with ENODEV or ENOENT (the attribute was
//	removed) or SECS seconds pass.  Prints
//	"WLOOP PATH writes=N ok=N eagain=N enotty=N enodev=N other=N last=ERR secs=S".
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

static double now(void)
{
	struct timespec ts;

	clock_gettime(CLOCK_MONOTONIC, &ts);
	return ts.tv_sec + ts.tv_nsec / 1e9;
}

int main(int argc, char **argv)
{
	long writes = 0, ok = 0, eagain = 0, enotty = 0, enodev = 0, other = 0;
	double t0, secs;
	int fd, last = 0;

	if (argc != 3) {
		fprintf(stderr, "usage: wloop PATH SECS\n");
		return 2;
	}
	secs = atof(argv[2]);
	fd = open(argv[1], O_WRONLY);
	if (fd < 0) {
		printf("WLOOP %s open: %s\n", argv[1], strerror(errno));
		return 1;
	}
	t0 = now();
	while (now() - t0 < secs) {
		ssize_t r = write(fd, "1", 1);
		int e = r < 0 ? errno : 0;

		writes++;
		last = e;
		if (!e)
			ok++;
		else if (e == EAGAIN)
			eagain++;
		else if (e == ENOTTY)
			enotty++;
		else if (e == ENODEV || e == ENOENT) {
			enodev++;
			break;
		} else
			other++;
	}
	printf("WLOOP %s writes=%ld ok=%ld eagain=%ld enotty=%ld enodev=%ld other=%ld last=%s secs=%.2f\n",
	       argv[1], writes, ok, eagain, enotty, enodev, other, last ? strerror(last) : "ok", now() - t0);
	return 0;
}
