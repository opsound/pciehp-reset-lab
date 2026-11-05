#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only

set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
linux_src="${root}/linux"
qemu_src="${root}/qemu"
out="${root}/out"
qemu_build="${out}/qemu"
tools_build="${out}/tools"
rootfs="${out}/rootfs"
jobs="${JOBS:-16}"
cc="${CC:-cc}"

# shellcheck source=../configs/versions.env
. "${root}/configs/versions.env"
busybox_src="${out}/src/busybox-${BUSYBOX_VERSION}"

KERNELS="mainline fixed mainline-kasan fixed-kasan mainline-hooks fixed-hooks
	mainline-hooks-kasan fixed-hooks-kasan"

# Serial git phase: submodules, pins, and generated worktrees.  Runs before
# any compile so parallel steps never contend on git metadata.
fetch_all()
{
	if [ ! -e "${linux_src}/.git" ] || [ ! -e "${qemu_src}/.git" ]; then
		git -C "${root}" submodule update --init --depth 1 \
			--single-branch linux qemu
	fi
	if [ "$(git -C "${linux_src}" rev-parse HEAD)" != "${LINUX_FIXED_COMMIT}" ]; then
		echo "linux/ is not pinned to LINUX_FIXED_COMMIT; update submodules" >&2
		exit 1
	fi
	if [ "$(git -C "${qemu_src}" rev-parse HEAD)" != "${QEMU_COMMIT}" ]; then
		echo "qemu/ is not pinned to QEMU_COMMIT; update submodules" >&2
		exit 1
	fi

	mkdir -p "${out}/src"
	ensure_kernel_source mainline "${out}/src/linux-mainline" \
		"${LINUX_MAINLINE_COMMIT}" "${LINUX_FIXED_REF}"
	ensure_kernel_source mainline-hooks "${out}/src/linux-mainline-hooks" \
		"${LINUX_MAINLINE_HOOKS_COMMIT}" "${LINUX_MAINLINE_HOOKS_REF}"
	ensure_kernel_source fixed-hooks "${out}/src/linux-fixed-hooks" \
		"${LINUX_FIXED_HOOKS_COMMIT}" "${LINUX_FIXED_HOOKS_REF}"
	fetch_busybox
}

ensure_kernel_source() # label worktree commit ref
{
	local label="$1" source="$2" commit="$3" ref="$4" rounds=0

	if ! git -C "${linux_src}" cat-file -e "${commit}^{commit}" 2>/dev/null; then
		echo "==> Fetching the Linux ${label} revision"
		git -C "${linux_src}" fetch --no-tags --depth=1 origin "${ref}"
	fi
	# The pinned commit may sit below the branch tip (mainline is the base
	# of the fix series); deepen in bounded steps until it is available.
	while ! git -C "${linux_src}" cat-file -e "${commit}^{commit}" 2>/dev/null; do
		rounds=$((rounds + 1))
		if [ "${rounds}" -gt 10 ]; then
			echo "Linux ${label} commit ${commit} is unavailable from origin" >&2
			exit 1
		fi
		git -C "${linux_src}" fetch --no-tags --deepen=10 origin "${ref}"
	done

	if [ -e "${source}/.git" ]; then
		if [ -n "$(git -C "${source}" status --porcelain)" ]; then
			echo "generated ${label} worktree is dirty: ${source}" >&2
			exit 1
		fi
		if [ "$(git -C "${source}" rev-parse HEAD)" != "${commit}" ]; then
			git -C "${source}" switch --detach "${commit}"
		fi
	else
		git -C "${linux_src}" worktree prune
		git -C "${linux_src}" worktree add --detach "${source}" "${commit}"
	fi
}

fetch_busybox()
{
	local tarball="${out}/dl/busybox-${BUSYBOX_VERSION}.tar.bz2"

	if [ -f "${busybox_src}/Makefile" ]; then
		return
	fi
	mkdir -p "${out}/dl"
	if [ ! -f "${tarball}" ]; then
		echo "==> Downloading busybox ${BUSYBOX_VERSION}"
		curl -fsSL -o "${tarball}.tmp" "${BUSYBOX_URL}"
		mv "${tarball}.tmp" "${tarball}"
	fi
	echo "${BUSYBOX_SHA256}  ${tarball}" | sha256sum -c --quiet
	mkdir -p "${busybox_src}"
	tar -xjf "${tarball}" -C "${busybox_src}" --strip-components=1
}

kernel_source() # name
{
	case "$1" in
	mainline|mainline-kasan) echo "${out}/src/linux-mainline" ;;
	fixed|fixed-kasan) echo "${linux_src}" ;;
	mainline-hooks|mainline-hooks-kasan) echo "${out}/src/linux-mainline-hooks" ;;
	fixed-hooks|fixed-hooks-kasan) echo "${out}/src/linux-fixed-hooks" ;;
	*) echo "unknown kernel: $1" >&2; exit 2 ;;
	esac
}

build_one_kernel() # name
{
	local name="$1" source build="${out}/linux-$1"

	source="$(kernel_source "${name}")"
	echo "==> Building Linux ${name} ($(git -C "${source}" rev-parse --short HEAD))"
	mkdir -p "${build}"
	install -m 0644 "${root}/configs/linux-x86_64.config" "${build}/.config"
	case "${name}" in
	*-kasan)
		"${source}/scripts/kconfig/merge_config.sh" -m -O "${build}" \
			"${build}/.config" "${root}/configs/kasan.config"
		;;
	esac
	make -C "${source}" O="${build}" olddefconfig
	case "${MAKEFLAGS:-}" in
	*jobserver*)
		# Under a parallel make, join its jobserver pool instead of
		# taking a fixed slice, so all kernels share one budget.
		make -C "${source}" O="${build}" bzImage
		;;
	*)
		make -C "${source}" O="${build}" -j"${jobs}" bzImage
		;;
	esac
}

build_qemu()
{
	echo "==> Building QEMU ($(git -C "${qemu_src}" rev-parse --short HEAD))"
	mkdir -p "${qemu_build}"
	if [ ! -f "${qemu_build}/build.ninja" ]; then
		(
			cd "${qemu_build}"
			"${qemu_src}/configure" \
				--target-list=x86_64-softmmu \
				--enable-kvm \
				--disable-tcg \
				--disable-fdt \
				--disable-docs \
				--disable-werror
		)
	fi
	# Ninja cannot join make's jobserver, so it takes a fixed slice.
	ninja -C "${qemu_build}" -j "${QEMU_JOBS:-${jobs}}" qemu-system-x86_64
}

build_busybox()
{
	local build="${out}/busybox"

	echo "==> Building busybox ${BUSYBOX_VERSION} (static)"
	mkdir -p "${build}"
	if [ ! -f "${build}/.config" ]; then
		make -C "${busybox_src}" O="${build}" defconfig > /dev/null
		# Static, and without tc, which doesn't build against recent
		# kernel headers.
		sed -i -e 's/^# CONFIG_STATIC is not set/CONFIG_STATIC=y/' \
			-e 's/^CONFIG_TC=y/# CONFIG_TC is not set/' "${build}/.config"
		(yes "" || true) | make -C "${build}" oldconfig > /dev/null
	fi
	make -C "${build}" -j"${jobs}" busybox
}

build_tools()
{
	echo "==> Building static guest tools"
	mkdir -p "${tools_build}"
	"${cc}" -O2 -g -Wall -Wextra -static -o "${tools_build}/vtool" \
		"${root}/tools/vtool.c"
}

build_initramfs()
{
	local applet

	echo "==> Building initramfs"
	rm -rf -- "${rootfs}"
	mkdir -p "${rootfs}/bin" "${rootfs}/dev" "${rootfs}/proc" \
		"${rootfs}/sys" "${rootfs}/tmp" "${rootfs}/scn"
	install -m 0755 "${out}/busybox/busybox" "${rootfs}/bin/busybox"
	for applet in $("${out}/busybox/busybox" --list); do
		[ -e "${rootfs}/bin/${applet}" ] || ln -s busybox "${rootfs}/bin/${applet}"
	done
	install -m 0755 "${tools_build}/vtool" "${rootfs}/bin/vtool"
	install -m 0755 "${root}/guest/init" "${rootfs}/init"
	install -m 0644 "${root}/guest/lib.sh" "${root}/guest/scn/"*.sh "${rootfs}/scn/"
	(
		cd "${rootfs}"
		find . -print0 | LC_ALL=C sort -z | cpio --null -o --format=newc --quiet
	) | gzip -n > "${out}/initramfs.cpio.gz"
}

usage()
{
	echo "usage: $0 [all|fetch|kernel <name>|qemu|busybox|tools|initramfs]" >&2
	echo "  kernels: ${KERNELS}" >&2
	exit 2
}

step="${1:-all}"
case "${step}" in
fetch) fetch_all ;;
kernel)
	[ $# -ge 2 ] || usage
	build_one_kernel "$2"
	;;
qemu) build_qemu ;;
busybox) build_busybox ;;
tools) build_tools ;;
initramfs) build_initramfs ;;
all)
	fetch_all
	for k in ${KERNELS}; do
		build_one_kernel "${k}"
	done
	build_qemu
	build_busybox
	build_tools
	build_initramfs
	echo "Build complete: ${out}"
	;;
*) usage ;;
esac
