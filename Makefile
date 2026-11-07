.PHONY: all build test clean fetch fetch-trees kernels fix-kernels fixes-build fixes \
	qemu busybox tools initramfs

# The bug suite: v7.4-rc1, as is and with the TEST ONLY hooks patch.
BUG_KERNELS := mainline mainline-kasan mainline-hooks mainline-hooks-kasan mainline-hooks-hc
# Fix tracking: the trees of configs/fix-trees.conf (or FIX_TREES=...), each
# with the hooks patch.
FIX_TREES ?= $(shell ./scripts/build.sh list-trees)
FIX_KERNELS := $(foreach t,$(FIX_TREES),$(t)-hooks $(t)-hooks-kasan $(t)-hooks-hc)
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

fixes-build: fix-kernels qemu initramfs
	@echo "Build complete: $(CURDIR)/out"

fetch:
	./scripts/build.sh fetch

fetch-trees: fetch
	./scripts/build.sh fetch-trees $(FIX_TREES)

kernels: $(addprefix kernel-,$(BUG_KERNELS))

fix-kernels: $(addprefix kernel-,$(FIX_KERNELS))

$(addprefix kernel-,$(BUG_KERNELS)): fetch

$(addprefix kernel-,$(FIX_KERNELS)): fetch-trees

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

fixes: fixes-build
	./scripts/run-tests.sh --suite fixes $(addprefix --tree ,$(FIX_TREES)) --jobs $(TEST_JOBS) all

clean:
	rm -rf -- "$(CURDIR)"/out/linux-* "$(CURDIR)/out/qemu" "$(CURDIR)/out/busybox" \
		"$(CURDIR)/out/tools" "$(CURDIR)/out/rootfs" "$(CURDIR)/out/logs" \
		"$(CURDIR)/out/initramfs.cpio.gz"
