.PHONY: all build test clean fetch kernels qemu busybox tools initramfs

KERNELS := mainline fixed mainline-kasan fixed-kasan mainline-hooks fixed-hooks \
	mainline-hooks-kasan fixed-hooks-kasan
# Ninja cannot join make's jobserver, so QEMU takes a fixed slice on top
# of the shared pool.  Overridable: make build QEMU_JOBS=16.
QEMU_JOBS ?= 8
export QEMU_JOBS
# Test guests in parallel: make test TEST_JOBS=8.
TEST_JOBS ?= 4

all: test

# fetch (serial git) runs first; the kernels, QEMU and busybox then build in
# parallel sharing one jobserver pool, followed by the initramfs.
build: kernels qemu initramfs
	@echo "Build complete: $(CURDIR)/out"

fetch:
	./scripts/build.sh fetch

kernels: $(addprefix kernel-,$(KERNELS))

$(addprefix kernel-,$(KERNELS)): fetch

# '+' lets the kernel builds behind the script join the jobserver.
kernel-%:
	+./scripts/build.sh kernel $*

qemu: fetch
	./scripts/build.sh qemu

busybox: fetch
	+./scripts/build.sh busybox

tools:
	./scripts/build.sh tools

initramfs: busybox tools
	./scripts/build.sh initramfs

test: build
	./scripts/run-tests.sh --jobs $(TEST_JOBS) all

clean:
	rm -rf -- $(addprefix "$(CURDIR)/out/linux-",$(KERNELS)) \
		"$(CURDIR)/out/qemu" "$(CURDIR)/out/busybox" "$(CURDIR)/out/tools" \
		"$(CURDIR)/out/rootfs" "$(CURDIR)/out/logs" "$(CURDIR)/out/initramfs.cpio.gz"
