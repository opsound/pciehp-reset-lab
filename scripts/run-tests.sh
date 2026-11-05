#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only

set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
logs="${root}/out/logs"

usage()
{
	echo "usage: $0 [--jobs N] [--runs N] [--dry-run] [all|<kernel>|<test>|<kernel>:<test>]" >&2
	echo "  kernels: mainline fixed mainline-kasan fixed-kasan mainline-hooks fixed-hooks" >&2
	echo "           mainline-hooks-kasan fixed-hooks-kasan" >&2
	echo "  tests: ${TEST_NAMES}" >&2
	exit 2
}

# Tests: "name scenario var rounds".  "-" leaves the scenario's default.
TESTS=(
	"vfio-exit-deadlock deadlock exit -"
	"vfio-reset-deadlock deadlock ioctl -"
	"sysfs-remove-deadlock sysfsrm del -"
	"sriov-disable-deadlock sriovdl - -"
	"hotadd-lockdep plain - -"
	"reset-storm storm - -"
	"slot-mutex-lockdep slotmx - -"
	"reset-during-bind bindreset - -"
	"nested-lockdep nestlock - -"
	"nested-removal nested - -"
	"sysfs-remove-uaf sysremove e1000e 10"
	"pciehp-unbind-uaf svcunbind fn 20"
	"host-reset-deadlock hostreset - -"
	"reset-removal-uaf teardown err 20"
	"reset-adding-device addwin win -"
	"reset-pciehp-unbind lifetime - -"
	"reset-before-bind window2 hold -"
	"reset-after-scan scanwin post -"
	"aer-hotadd-race single aer 5"
	"sriov-remove-abba sriovabba sysfs -"
)
TEST_NAMES="$(for t in "${TESTS[@]}"; do echo -n "${t%% *} "; done)"

# Matrix: "kernel test expectation runs".  An expectation other than "clean"
# is met if any of the runs shows it; "clean" needs every run to be clean.
MATRIX=(
	# Tier 1: exact mainline and fix series, no test code in the kernel.
	"mainline vfio-exit-deadlock hang 1"		"fixed vfio-exit-deadlock clean 1"
	"mainline vfio-reset-deadlock hang 1"		"fixed vfio-reset-deadlock clean 1"
	"mainline sysfs-remove-deadlock hang 1"		"fixed sysfs-remove-deadlock clean 1"
	"mainline sriov-disable-deadlock hang 1"	"fixed sriov-disable-deadlock clean 1"
	"mainline hotadd-lockdep lockdep 1"		"fixed hotadd-lockdep clean 1"
	"mainline reset-storm hang 1"			"fixed reset-storm clean 1"
	"mainline slot-mutex-lockdep lockdep 1"		"fixed slot-mutex-lockdep clean 1"
	"mainline reset-during-bind hang 1"		"fixed reset-during-bind clean 1"
	"mainline nested-lockdep lockdep 1"		"fixed nested-lockdep clean 1"
	"mainline nested-removal hang 4"		"fixed nested-removal clean 2"
	"mainline-kasan sysfs-remove-uaf kasan 1"	"fixed-kasan sysfs-remove-uaf clean 1"
	"mainline-kasan pciehp-unbind-uaf kasan 1"	"fixed-kasan pciehp-unbind-uaf clean 1"
	# Tier 2: the same trees plus the TEST ONLY hooks and delay knobs.
	"mainline-hooks host-reset-deadlock hang 1"	"fixed-hooks host-reset-deadlock clean 1"
	"mainline-hooks-kasan reset-removal-uaf kasan 6" "fixed-hooks-kasan reset-removal-uaf clean 2"
	"mainline-hooks reset-adding-device hang 1"	"fixed-hooks reset-adding-device clean 1"
	"mainline-hooks reset-pciehp-unbind hang 1"	"fixed-hooks reset-pciehp-unbind clean 1"
	"mainline-hooks reset-before-bind fail 1"	"fixed-hooks reset-before-bind clean 1"
	"mainline-hooks reset-after-scan fail 4"	"fixed-hooks reset-after-scan clean 1"
	# Known issues that the fix series doesn't address.
	"mainline-hooks aer-hotadd-race hang 1"		"fixed-hooks aer-hotadd-race fail 1"
	"mainline-hooks sriov-remove-abba hang 1"	"fixed-hooks sriov-remove-abba hang 1"
)

jobs=1 runs_override="" dry_run=0
while [ $# -gt 0 ]; do
	case "$1" in
	--jobs|-j) [ $# -ge 2 ] || usage; jobs="$2"; shift 2 ;;
	--jobs=*) jobs="${1#--jobs=}"; shift ;;
	--runs) [ $# -ge 2 ] || usage; runs_override="$2"; shift 2 ;;
	--dry-run) dry_run=1; shift ;;
	-h|--help) usage ;;
	-*) usage ;;
	*) break ;;
	esac
done
[ $# -le 1 ] || usage
selection="${1:-all}"

test_def() # name -> "scenario var rounds"
{
	local t
	for t in "${TESTS[@]}"; do
		if [ "${t%% *}" = "$1" ]; then
			echo "${t#* }"
			return 0
		fi
	done
	return 1
}

selected() # kernel test
{
	case "${selection}" in
	all) return 0 ;;
	"$1:$2"|"$1"|"$2") return 0 ;;
	esac
	return 1
}

entries=()
for e in "${MATRIX[@]}"; do
	read -r kernel test expect runs <<< "${e}"
	if selected "${kernel}" "${test}"; then
		entries+=("${kernel} ${test} ${expect} ${runs_override:-${runs}}")
	fi
done
if [ ${#entries[@]} -eq 0 ]; then
	echo "no matrix entry matches '${selection}'" >&2
	usage
fi

if [ "${dry_run}" -eq 1 ]; then
	printf '%s\n' "${entries[@]}"
	exit 0
fi

if [ ! -r /dev/kvm ] || [ ! -w /dev/kvm ]; then
	echo "/dev/kvm is not accessible" >&2
	exit 1
fi
for path in "${root}/out/initramfs.cpio.gz"; do
	[ -e "${path}" ] || { echo "missing ${path}; run ./run build first" >&2; exit 1; }
done
mkdir -p "${logs}"

run_entry() # kernel test expect runs
{
	local kernel="$1" test="$2" expect="$3" runs="$4"
	local image="${root}/out/linux-${kernel}/arch/x86/boot/bzImage"
	local scn var rounds dir i met=0 bad=0 line args=()

	read -r scn var rounds <<< "$(test_def "${test}")"
	[ "${var}" = - ] || args+=(--var "${var}")
	[ "${rounds}" = - ] || args+=(--a "${rounds}")
	case "${kernel}" in *-kasan) args+=(--kasan) ;; esac
	if [ ! -e "${image}" ]; then
		echo "FAIL: ${kernel}:${test}; missing ${image}"
		return 1
	fi
	echo "==> Running ${kernel}:${test} (expect ${expect})"
	for i in $(seq 1 "${runs}"); do
		dir="${logs}/${kernel}/${test}/${i}"
		rm -rf -- "${dir}"
		mkdir -p "${dir%/*}"
		python3 "${root}/harness/run.py" "${image}" "${scn}" "${dir}" "${args[@]}" \
			--label "${test}" > "${dir}.out" 2>&1 || true
		if line="$(python3 "${root}/harness/check.py" "${dir}/result.json" "${expect}" 2>&1)"; then
			met=1
		else
			bad=1
		fi
		echo "    run ${i}: ${line}; log: ${dir}/serial.log"
		# A symptom shows up once: stop.  A clean expectation runs them all.
		if [ "${expect}" != clean ] && [ "${met}" = 1 ]; then
			break
		fi
	done
	if { [ "${expect}" = clean ] && [ "${bad}" = 0 ]; } ||
	   { [ "${expect}" != clean ] && [ "${met}" = 1 ]; }; then
		echo "PASS: ${kernel}:${test} (expected ${expect})"
		return 0
	fi
	echo "FAIL: ${kernel}:${test} (expected ${expect})"
	return 1
}

results="${logs}/results.txt"
: > "${results}"
running=0
for e in "${entries[@]}"; do
	read -r kernel test expect runs <<< "${e}"
	(run_entry "${kernel}" "${test}" "${expect}" "${runs}" > "${logs}/${kernel}-${test}.txt" 2>&1 || true
	 cat "${logs}/${kernel}-${test}.txt"; grep -E '^(PASS|FAIL):' "${logs}/${kernel}-${test}.txt" >> "${results}") &
	running=$((running + 1))
	if [ "${running}" -ge "${jobs}" ]; then
		wait -n || true
		running=$((running - 1))
	fi
done
wait || true

pass=$(grep -c '^PASS:' "${results}" || true)
fail=$(grep -c '^FAIL:' "${results}" || true)
echo "==> ${pass} passed, ${fail} failed (${results})"
[ "${fail}" -eq 0 ]
