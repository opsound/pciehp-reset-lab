// SPDX-License-Identifier: GPL-2.0-only
// cf1: PCI config access through configuration mechanism #1 (I/O ports
// 0xcf8/0xcfc), past the kernel and its config access lock, like
// "setpci -A intel-conf1".  Registers below 0x100 only.  On QEMU's q35 the
// kernel uses ECAM, so these port accesses don't interleave with its own.
//   cf1 BDF OFFSET.{b,w,l}         read, printed in hex like setpci
//   cf1 BDF OFFSET.{b,w,l}=VALUE   write (VALUE in hex)
// BDF is [DDDD:]BB:DD.F with domain 0; OFFSET is hex.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/io.h>

int main(int argc, char **argv)
{
	unsigned int dom = 0, bus, dev, fn, off, val = 0, addr;
	char width, *eq;
	int n, write = 0;

	if (argc != 3)
		goto usage;
	if (sscanf(argv[1], "%x:%x:%x.%x", &dom, &bus, &dev, &fn) != 4) {
		dom = 0;
		if (sscanf(argv[1], "%x:%x.%x", &bus, &dev, &fn) != 3)
			goto usage;
	}
	eq = strchr(argv[2], '=');
	if (eq) {
		write = 1;
		val = strtoul(eq + 1, NULL, 16);
	}
	if (sscanf(argv[2], "%x.%c%n", &off, &width, &n) != 2 || dom || bus > 255 ||
	    dev > 31 || fn > 7 || off > 0xff || !strchr("bwl", width))
		goto usage;
	n = width == 'b' ? 1 : width == 'w' ? 2 : 4;
	if (off & (n - 1))
		goto usage;
	if (iopl(3)) {
		perror("iopl");
		return 1;
	}
	addr = 0x80000000u | bus << 16 | dev << 11 | fn << 8 | (off & 0xfc);
	outl(addr, 0xcf8);
	if (write) {
		if (n == 1)
			outb(val, 0xcfc + (off & 3));
		else if (n == 2)
			outw(val, 0xcfc + (off & 2));
		else
			outl(val, 0xcfc);
		return 0;
	}
	if (n == 1)
		printf("%02x\n", inb(0xcfc + (off & 3)));
	else if (n == 2)
		printf("%04x\n", inw(0xcfc + (off & 2)));
	else
		printf("%08x\n", inl(0xcfc));
	return 0;
usage:
	fprintf(stderr, "usage: cf1 [0000:]BB:DD.F OFFSET.{b,w,l}[=VALUE]\n");
	return 2;
}
