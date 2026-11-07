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
fix_trees_conf="${root}/configs/fix-trees.conf"
local_trees_conf="${out}/local-trees.conf"

# shellcheck source=../configs/versions.env
. "${root}/configs/versions.env"
busybox_src="${out}/src/busybox-${BUSYBOX_VERSION}"

# The bug suite's kernels: v7.4-rc1 as is, and with the TEST ONLY hooks patch.
BUG_KERNELS="mainline mainline-kasan mainline-hooks mainline-hooks-kasan mainline-hooks-hc"
# Every fix tree is built as <tree>-hooks, <tree>-hooks-kasan, <tree>-hooks-hc.
FLAVORS="hooks hooks-kasan hooks-hc"
# Static guest helpers, tools/<name>.c
GUEST_TOOLS="vtool wloop cf1 aerinj"

# Serial git phase: submodules, pins and the generated mainline-hooks tree.
# Runs before any compile so parallel steps never contend on git metadata.
fetch_all()
{
	if [ ! -e "${linux_src}/.git" ] || [ ! -e "${qemu_src}/.git" ]; then
		git -C "${root}" submodule update --init --depth 1 \
			--single-branch linux qemu
	fi
	if [ "$(git -C "${linux_src}" rev-parse HEAD)" != "${LINUX_MAINLINE_COMMIT}" ]; then
		echo "linux/ is not pinned to LINUX_MAINLINE_COMMIT; update submodules" >&2
		exit 1
	fi
	if [ "$(git -C "${qemu_src}" rev-parse HEAD)" != "${QEMU_COMMIT}" ]; then
		echo "qemu/ is not pinned to QEMU_COMMIT; update submodules" >&2
		exit 1
	fi
	mkdir -p "${out}/src"
	patched_worktree mainline-hooks "${linux_src}" "${LINUX_MAINLINE_COMMIT}" \
		"${root}/patches/test-hooks.patch"
	fetch_busybox
}

# fix_tree NAME: "url ref commit patch" of a fix tree from configs/fix-trees.conf
# or from a local tree registered by "build.sh add-tree" (url = local path).
fix_tree()
{
	local f n rest
	for f in "${fix_trees_conf}" "${local_trees_conf}"; do
		[ -f "${f}" ] || continue
		while read -r n rest; do
			case "${n}" in ''|'#'*) continue ;; esac
			if [ "${n}" = "$1" ]; then
				echo "${rest}"
				return 0
			fi
		done < "${f}"
	done
	return 1
}

list_trees()
{
	local n rest
	[ -f "${fix_trees_conf}" ] || return 0
	while read -r n rest; do
		case "${n}" in ''|'#'*) continue ;; esac
		echo "${n}"
	done < "${fix_trees_conf}"
}

# fetch_trees NAME...: the source of each fix tree, as out/src/NAME-hooks with
# its hooks patch applied.
fetch_trees()
{
	local name url ref commit patch rounds def
	for name in "$@"; do
		def="$(fix_tree "${name}")" || { echo "unknown fix tree: ${name}" >&2; exit 2; }
		read -r url ref commit patch <<< "${def}"
		case "${patch}" in /*) ;; *) patch="${root}/${patch}" ;; esac
		if [ "${ref}" = local ]; then
			local_worktree "${name}" "${url}" "${commit}" "${patch}"
			continue
		fi
		rounds=0
		if ! git -C "${linux_src}" cat-file -e "${commit}^{commit}" 2>/dev/null; then
			echo "==> Fetching fix tree ${name} (${url} ${ref})"
			git -C "${linux_src}" fetch --no-tags --depth=1 "${url}" "${ref}"
		fi
		# The pinned commit may sit below the branch tip; deepen in bounded
		# steps until it is available.
		while ! git -C "${linux_src}" cat-file -e "${commit}^{commit}" 2>/dev/null; do
			rounds=$((rounds + 1))
			if [ "${rounds}" -gt 10 ]; then
				echo "fix tree ${name}: commit ${commit} is unavailable from ${url}" >&2
				exit 1
			fi
			git -C "${linux_src}" fetch --no-tags --deepen=10 "${url}" "${ref}"
		done
		patched_worktree "${name}-hooks" "${linux_src}" "${commit}" "${patch}"
	done
}

# stamp_ok DIR COMMIT PATCH: DIR is at COMMIT with PATCH applied by us
stamp_ok()
{
	[ -f "$1.stamp" ] && [ "$(cat "$1.stamp")" = "$2 $(sha256sum < "$3" | cut -d' ' -f1)" ]
}

apply_patch() # dir patch commit
{
	local dir="$1" patch="$2"
	if git -C "${dir}" apply --check "${patch}" 2>/dev/null; then
		git -C "${dir}" apply "${patch}"
	elif git -C "${dir}" apply --check -C1 "${patch}" 2>/dev/null; then
		echo "==> ${patch##*/}: applying with reduced context to ${dir##*/}"
		git -C "${dir}" apply -C1 "${patch}"
	else
		git -C "${dir}" apply --check -C1 "${patch}" || true
		echo "${patch} does not apply to ${dir} ($3)" >&2
		exit 1
	fi
	echo "$3 $(sha256sum < "${patch}" | cut -d' ' -f1)" > "${dir}.stamp"
}

# patched_worktree NAME REPO COMMIT PATCH: out/src/NAME, a detached worktree of
# REPO at COMMIT with PATCH applied.
patched_worktree()
{
	local name="$1" repo="$2" commit="$3" patch="$4" dir="${out}/src/$1"

	[ -f "${patch}" ] || { echo "missing patch ${patch}" >&2; exit 1; }
	if [ -e "${dir}/.git" ]; then
		stamp_ok "${dir}" "${commit}" "${patch}" && return 0
		echo "==> Resetting ${name} to ${commit:0:12}"
		git -C "${dir}" checkout -q -f --detach "${commit}"
		git -C "${dir}" clean -q -fd
	else
		echo "==> Creating ${name} at ${commit:0:12}"
		git -C "${repo}" worktree prune
		git -C "${repo}" worktree add -q --detach "${dir}" "${commit}"
	fi
	apply_patch "${dir}" "${patch}" "${commit}"
}

# local_worktree NAME PATH COMMIT PATCH: out/src/NAME-hooks, a clone of the local
# tree PATH sharing its objects (PATH itself is not modified), at COMMIT.
local_worktree()
{
	local name="$1" path="$2" commit="$3" patch="$4" dir="${out}/src/$1-hooks"

	if [ -e "${dir}/.git" ]; then
		stamp_ok "${dir}" "${commit}" "${patch}" && return 0
		# The clone borrows PATH's objects (--shared), so COMMIT is there.
		git -C "${dir}" checkout -q -f --detach "${commit}"
		git -C "${dir}" clean -q -fd
	else
		echo "==> Cloning ${path} (${commit:0:12}) as ${name}-hooks"
		git clone -q --shared --no-checkout "${path}" "${dir}"
		git -C "${dir}" checkout -q --detach "${commit}"
	fi
	apply_patch "${dir}" "${patch}" "${commit}"
}

# add_tree NAME PATH [REV [PATCH]]: register a local tree for fix tracking.
# Without PATCH, the first patches/test-hooks*.patch that applies is used,
# preferring one that applies with full context.
add_tree()
{
	local name="$1" path="$2" rev="${3:-HEAD}" patch="${4:-}" commit p tmp ctx
	case "${name}" in *[!a-zA-Z0-9_.-]*|mainline*) echo "bad tree name: ${name}" >&2; exit 2 ;; esac
	path="$(cd "${path}" && pwd)"
	commit="$(git -C "${path}" rev-parse --verify "${rev}^{commit}")"
	if [ -n "$(git -C "${path}" status --porcelain --untracked-files=no 2>/dev/null)" ] &&
	   [ "${rev}" = HEAD ]; then
		echo "note: ${path} has uncommitted changes; testing its HEAD ${commit:0:12}" >&2
	fi
	if [ -z "${patch}" ]; then
		# Pick the patch in a throwaway index: git apply --cached against
		# the commit's tree, without touching any work tree.  The patches
		# differ only in context, so with reduced context the wrong one
		# may apply too.
		tmp="$(mktemp)"
		GIT_INDEX_FILE="${tmp}" git -C "${path}" read-tree "${commit}"
		for ctx in "" -C1; do
			for p in "${root}"/patches/test-hooks*.patch; do
				if GIT_INDEX_FILE="${tmp}" git -C "${path}" apply --cached --check ${ctx} "${p}" 2>/dev/null; then
					patch="${p}"
					break 2
				fi
			done
		done
		rm -f "${tmp}"
		[ -n "${patch}" ] || { echo "no patches/test-hooks*.patch applies to ${path} ${commit:0:12}; use --patch" >&2; exit 1; }
	fi
	case "${patch}" in /*) ;; *) patch="$(cd "$(dirname "${patch}")" && pwd)/${patch##*/}" ;; esac
	mkdir -p "${out}/src"
	touch "${local_trees_conf}"
	grep -v "^${name} " "${local_trees_conf}" > "${local_trees_conf}.tmp" || true
	echo "${name} ${path} local ${commit} ${patch}" >> "${local_trees_conf}.tmp"
	mv "${local_trees_conf}.tmp" "${local_trees_conf}"
	echo "==> Tree ${name}: ${path} ${commit:0:12}, ${patch##*/}"
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
	mainline|mainline-kasan) echo "${linux_src}" ;;
	*-hooks|*-hooks-kasan|*-hooks-hc) echo "${out}/src/${1%-hooks*}-hooks" ;;
	*) echo "unknown kernel: $1" >&2; exit 2 ;;
	esac
}

build_one_kernel() # name
{
	local name="$1" source build="${out}/linux-$1" frag=

	source="$(kernel_source "${name}")"
	[ -e "${source}/Makefile" ] || { echo "no source for ${name}: ${source} (run fetch first)" >&2; exit 1; }
	echo "==> Building Linux ${name} ($(git -C "${source}" rev-parse --short HEAD))"
	mkdir -p "${build}"
	install -m 0644 "${root}/configs/linux-x86_64.config" "${build}/.config"
	case "${name}" in
	*-kasan) frag="${root}/configs/kasan.config" ;;
	*-hc) frag="${root}/configs/hc.config" ;;
	esac
	if [ -n "${frag}" ]; then
		"${source}/scripts/kconfig/merge_config.sh" -m -O "${build}" \
			"${build}/.config" "${frag}"
	fi
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
	local t
	echo "==> Building static guest tools"
	mkdir -p "${tools_build}"
	for t in ${GUEST_TOOLS}; do
		"${cc}" -O2 -g -Wall -Wextra -static -o "${tools_build}/${t}" \
			"${root}/tools/${t}.c"
	done
}

build_initramfs()
{
	local applet t

	echo "==> Building initramfs"
	rm -rf -- "${rootfs}"
	mkdir -p "${rootfs}/bin" "${rootfs}/dev" "${rootfs}/proc" \
		"${rootfs}/sys" "${rootfs}/tmp" "${rootfs}/scn"
	install -m 0755 "${out}/busybox/busybox" "${rootfs}/bin/busybox"
	for applet in $("${out}/busybox/busybox" --list); do
		[ -e "${rootfs}/bin/${applet}" ] || ln -s busybox "${rootfs}/bin/${applet}"
	done
	for t in ${GUEST_TOOLS}; do
		install -m 0755 "${tools_build}/${t}" "${rootfs}/bin/"
	done
	install -m 0755 "${root}/guest/init" "${rootfs}/init"
	install -m 0644 "${root}/guest/lib.sh" "${root}/guest/scn/"*.sh "${rootfs}/scn/"
	(
		cd "${rootfs}"
		find . -print0 | LC_ALL=C sort -z | cpio --null -o --format=newc --quiet
	) | gzip -n > "${out}/initramfs.cpio.gz"
}

usage()
{
	echo "usage: $0 [all|fetch|fetch-trees TREE...|add-tree NAME PATH [REV [PATCH]]|list-trees|" >&2
	echo "          kernel NAME|qemu|busybox|tools|initramfs]" >&2
	echo "  bug suite kernels: ${BUG_KERNELS}" >&2
	echo "  fix tree kernels: TREE-{${FLAVORS// /,}} for TREE in: $(list_trees | tr '\n' ' ')" >&2
	exit 2
}

step="${1:-all}"
case "${step}" in
fetch) fetch_all ;;
fetch-trees) shift; fetch_trees "$@" ;;
add-tree)
	[ $# -ge 3 ] || usage
	add_tree "${@:2}"
	;;
list-trees) list_trees ;;
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
	for k in ${BUG_KERNELS}; do
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
