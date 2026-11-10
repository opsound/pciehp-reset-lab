#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only

set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
logs="${root}/out/logs"

usage()
{
	cat >&2 <<EOF
usage: $0 [--suite bugs|fixes|checks] [--tree TREE]... [--jobs N] [--runs N] [--all-runs] [--dry-run] [SELECTION]
  --suite bugs   (default) every test on v7.4-rc1, expecting its bug's symptom
  --suite fixes  every test plus the fix tracking tests on each --tree (default:
                 the trees of configs/fix-trees.conf), expecting "clean"
  --suite checks the series checks: on v7.4-rc1, expecting each check's
                 v7.4-rc1 result; with --tree, on those trees, expecting "pass"
                 ("clean" for the checks that are clean on v7.4-rc1)
  --runs N       runs per entry (default: the test's runs or fixruns)
  --all-runs     bug suite: do every run instead of stopping at the first one
                 that shows the symptom, to measure its rate
  SELECTION      all (default), a test, an issue ID (e.g. N11), a kernel, or
                 KERNEL:TEST
  tests: ${TEST_NAMES}
EOF
	exit 2
}

# Tests: "name issues flavor scenario var rounds expectation runs fixruns".
#   flavor   kernel build: plain (v7.4-rc1 as is), kasan, hooks (with
#            patches/test-hooks.patch), hooks-kasan, hooks-hc (hooks plus
#            configs/hc.config: pci-host-common built in), hooks-jh (hooks
#            plus configs/jh.config: Jailhouse guest support)
#   scenario guest/scn/<scenario>.sh; var and rounds ("-": the default of
#            harness/run.py) are passed to it as var= and a=
#   expectation  the symptom the test shows on v7.4-rc1: hang, lockdep,
#            kasan, warn or fail (harness/check.py)
#   runs     bug suite: attempts until the symptom shows up
#   fixruns  fix tracking: runs that all have to be clean
TESTS=(
	# P0: the production deadlock and its variants
	"vfio-exit-deadlock P0 plain deadlock exit - hang 1 1"
	"vfio-reset-deadlock P0 plain deadlock ioctl - hang 1 1"
	"vfio-exit-surprise P0 plain deadlock sexit - hang 1 1"
	"vfio-reset-surprise P0 plain deadlock sioctl - hang 1 1"
	"sysfs-remove-deadlock P0 plain sysfsrm del - hang 1 1"
	"sriov-disable-deadlock P0 plain sriovdl - - hang 1 1"
	"hotadd-lockdep N1 plain plain - - lockdep 1 1"
	"nested-lockdep N1 plain nestlock - - lockdep 1 1"
	"host-reset-deadlock N2 hooks hostreset - - hang 1 1"
	"spurious-link-lookup-deadlock N3 hooks spurlink reset - hang 2 2"
	"reset-removal-uaf N4 hooks-kasan teardown err 20 kasan 16 2"
	"bus-reset-removal-uaf N4 hooks-kasan busuaf plain 20 lockdep 2 4"
	"reset-adding-device N5 hooks addwin win - hang 1 1"
	"pciehp-unbind-uaf N6 kasan svcunbind fn 20 kasan 1 1"
	"pciehp-unbind-hot-reset-uaf N6 kasan svcunbind hot 20 kasan 2 2"
	"reset-pciehp-unbind N6,N8 hooks lifetime - - hang 1 1"
	"reset-before-bind N7 hooks window2 hold - fail 1 1"
	"reset-after-scan N7 hooks scanwin post - fail 8 2"
	"reset-storm N8 plain storm - - hang 1 1"
	"reset-during-bind N8 plain bindreset - - hang 1 1"
	"slot-mutex-lockdep N8 plain slotmx - - lockdep 1 1"
	"aer-hotadd-race N8,N12 hooks single aer 5 hang 1 1"
	"sysfs-remove-uaf N9 kasan sysremove e1000e 10 kasan 2 1"
	"nested-removal N10 plain nested - - hang 12 3"
	"nested-surprise-removal N10 hooks nestsurprise prelock - hang 2 3"
	"nested-bringup-deadlock N10 hooks nestbringup sysfs - hang 2 2"
	"port-unbind-deadlock N10 hooks portunbind lockedadd - hang 2 2"
	"port-unbind-host-reset N10 hooks portunbind hostlock - hang 2 2"
	"sriov-recovery-walk-deadlock N11 hooks sriovreset walk 60 hang 2 3"
	"recovery-walk-deadlock N11 hooks portunbind nolock - hang 2 2"
	"recovery-hotadd-msix N12 hooks aermsix - - warn 2 3"
	"sriov-remove-abba N13 hooks sriovabba sysfs - hang 1 2"
	"sriov-pciehp-abba N13 hooks sriovabba pciehp - hang 2 6"
	"dead-link-reset-wait N14 plain deadreset sysfs - fail 1 1"
	"reset-holds-removing N15 hooks resetremove - - hang 2 3"
	"reset-holds-probing N16 hooks resetprobe rescan 10 hang 2 3"
	"reset-subordinate-uaf N17 kasan subuaf 4 20 kasan 2 3"
	"pciehp-rpm-recursion N18 hooks rpmrec remove+pin - hang 2 3"
	"rescan-remove-deadlock N19 plain rescanrm race-dev 10 hang 2 3"
	"sriov-host-reset-deadlock N20 hooks sriovreset hostreset - hang 1 2"
	"sriov-linkdown-deadlock N20 hooks-hc sriovreset linkdown 60 hang 2 3"
	"pf-unbind-unlocked-vf-removal N21 plain pfunbind unbind - warn 1 2"
	"removal-stall N22 plain vfstall pciehp - fail 1 2"
	"bind-during-removal N23 plain bindremove sysfs - fail 1 2"
	"shutdown-aer-deadlock N24 plain shutaer slot 10 hang 1 2"
	"reset-prepare-order N25 plain resetorder io 3 hang 1 2"
	"isolated-fn-aspm-oops N26 hooks-jh isolfn vanish-aspm - oops 1 2"
	"isolated-fn-resume-removal N27 hooks-jh isolfn resume - fail 1 2"
	"hotadd-fn0-vanish N27 hooks-jh isolfn vanish - oops 1 2"
)
# Fix tracking only: regressions that fix attempts introduced, not bugs of
# v7.4-rc1.  "name - flavor scenario var rounds - - fixruns"
FIXTESTS=(
	"pciehp-rpm-safe-removal - hooks rpmsafe rpm - - - 3"
	"linkdown-hotadd-bars - hooks-hc linkdownadd - - - - 3"
	"pf-probe-sriov-removal - hooks pfprobe - - - - 2"
)
# Series checks: tests written for posted series, of problems outside the
# catalog (what a series claims to fix) or of regressions a series introduced.
# Not bugs of the catalog, so neither in the bug suite nor in fix tracking.
# Fields as for TESTS; the expectation is the result on v7.4-rc1, "pass" for
# the regression checks (harness/check.py: the scenario's check passes; lockdep
# reports and warnings, such as N1's, don't count).  On a --tree every run has
# to pass; checks that are clean on v7.4-rc1 (no hot-add, so lockdep stays on)
# have to stay clean, lockdep reports included.
CHECKS=(
	"pf-reset-vf-wipe - plain sriovguard sysfs - fail 1 2"
	"pf-reset-vf-wipe-vfio - plain sriovguard vfio - fail 1 2"
	"vfio-recovery-restore - plain vfiorec ep - fail 1 2"
	"vfio-recovery-restore-switch - plain vfiorec sw - fail 1 2"
	"aer-unbound - plain aerunb new - fail 1 2"
	"aer-unbound-mf - plain aerunb mf - fail 1 2"
	"aer-unbound-vfs - plain aerunb vfs - fail 1 2"
	"aer-no-handler - plain aerunb nohandler - pass 2 2"
	"dpcwait-slow - hooks dpcwait slow - fail 1 2"
	"dpcwait-dead - hooks dpcwait dead - pass 2 2"
	"vfio-pm-sriov-race - plain pmsriov - 10 warn 1 3"
	"numa-pf-probe-hotadd - plain numaprobe pciehp - pass 2 2"
	"numa-pf-probe-rescan - plain numaprobe rescan - pass 2 2"
	"vfio-recovery-pm-deadlock - plain w6pm dl+sync+inject 60 clean 2 3"
	"vfio-recovery-pm-lockdep - hooks w6pm lockdep-pm - clean 2 2"
	"vfio-recovery-d3-lockdep - hooks w6pm lockdep-d3 - clean 2 2"
	"vfio-recovery-close-lockdep - hooks w6pm lockdep-pm+norec - clean 2 2"
)
TEST_NAMES="$(for t in "${TESTS[@]}" "${FIXTESTS[@]}" "${CHECKS[@]}"; do echo -n "${t%% *} "; done)"

suite=bugs jobs=1 runs_override="" dry_run=0 all_runs=0 trees=()
while [ $# -gt 0 ]; do
	case "$1" in
	--suite) [ $# -ge 2 ] || usage; suite="$2"; shift 2 ;;
	--tree) [ $# -ge 2 ] || usage; trees+=("$2"); shift 2 ;;
	--jobs|-j) [ $# -ge 2 ] || usage; jobs="$2"; shift 2 ;;
	--jobs=*) jobs="${1#--jobs=}"; shift ;;
	--runs) [ $# -ge 2 ] || usage; runs_override="$2"; shift 2 ;;
	--dry-run) dry_run=1; shift ;;
	--all-runs) all_runs=1; shift ;;
	-h|--help) usage ;;
	-*) usage ;;
	*) break ;;
	esac
done
[ $# -le 1 ] || usage
selection="${1:-all}"
case "${suite}" in bugs|fixes|checks) ;; *) usage ;; esac
if [ "${suite}" = fixes ] && [ ${#trees[@]} -eq 0 ]; then
	mapfile -t trees < <("${root}/scripts/build.sh" list-trees)
fi

# kernel_for SUITE TREE FLAVOR
kernel_for()
{
	if [ "$1" = bugs ]; then
		case "$3" in
		plain) echo mainline ;;
		kasan) echo mainline-kasan ;;
		*) echo "mainline-$3" ;;
		esac
	else
		case "$3" in
		plain) echo "$2-hooks" ;;
		kasan) echo "$2-hooks-kasan" ;;
		*) echo "$2-$3" ;;
		esac
	fi
}

selected() # kernel test issues
{
	case "${selection}" in
	all) return 0 ;;
	"$1:$2"|"$1"|"$2") return 0 ;;
	esac
	case ",$3," in *",${selection},"*) return 0 ;; esac
	return 1
}

# Entries: "kernel test scenario var rounds expectation runs"
entries=()
add_entries() # suite tree defs...
{
	local s="$1" tr="$2" t name issue flavor scn var rounds expect runs fixruns kernel
	shift 2
	for t in "$@"; do
		read -r name issue flavor scn var rounds expect runs fixruns <<< "${t}"
		kernel="$(kernel_for "${s}" "${tr}" "${flavor}")"
		if [ "${s}" = fixes ]; then
			if [ "${suite}" != checks ]; then
				expect=clean
			elif [ "${expect}" != clean ]; then
				expect=pass
			fi
			runs="${fixruns}"
		fi
		if selected "${kernel}" "${name}" "${issue}"; then
			entries+=("${kernel} ${name} ${scn} ${var} ${rounds} ${expect} ${runs_override:-${runs}}")
		fi
	done
}
if [ "${suite}" = bugs ]; then
	add_entries bugs - "${TESTS[@]}"
elif [ "${suite}" = checks ] && [ ${#trees[@]} -eq 0 ]; then
	add_entries bugs - "${CHECKS[@]}"
elif [ "${suite}" = checks ]; then
	for tr in "${trees[@]}"; do
		add_entries fixes "${tr}" "${CHECKS[@]}"
	done
else
	for tr in "${trees[@]}"; do
		add_entries fixes "${tr}" "${TESTS[@]}" "${FIXTESTS[@]}"
	done
fi
if [ ${#entries[@]} -eq 0 ]; then
	echo "no test matches '${selection}'" >&2
	usage
fi

if [ "${dry_run}" -eq 1 ]; then
	for e in "${entries[@]}"; do
		read -r kernel test scn var rounds expect runs <<< "${e}"
		echo "${kernel} ${test} ${expect} ${runs}"
	done
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

run_entry() # kernel test scenario var rounds expect runs
{
	local kernel="$1" test="$2" scn="$3" var="$4" rounds="$5" expect="$6" runs="$7"
	local image="${root}/out/linux-${kernel}/arch/x86/boot/bzImage"
	local dir i n=0 met=0 bad=0 hits=0 line args=() every=0

	[ "${var}" = - ] || args+=(--var "${var}")
	[ "${rounds}" = - ] || args+=(--a "${rounds}")
	case "${kernel}" in *-kasan) args+=(--kasan) ;; esac
	if [ ! -e "${image}" ]; then
		echo "FAIL: ${kernel}:${test}; missing ${image}"
		return 1
	fi
	case "${expect}" in clean|pass) every=1 ;; esac
	echo "==> Running ${kernel}:${test} (expect ${expect})"
	for i in $(seq 1 "${runs}"); do
		dir="${logs}/${kernel}/${test}/${i}"
		rm -rf -- "${dir}"
		mkdir -p "${dir%/*}"
		python3 "${root}/harness/run.py" "${image}" "${scn}" "${dir}" "${args[@]}" \
			--label "${test}" > "${dir}.out" 2>&1 || true
		n=$((n + 1))
		if line="$(python3 "${root}/harness/check.py" "${dir}/result.json" "${expect}" 2>&1)"; then
			met=1 hits=$((hits + 1))
		else
			bad=1
		fi
		echo "    run ${i}: ${line}; log: ${dir}/serial.log"
		# A symptom shows up once: stop, unless measuring its rate.  A
		# clean or pass expectation runs them all.
		if [ "${every}" = 0 ] && [ "${met}" = 1 ] && [ "${all_runs}" = 0 ]; then
			break
		fi
	done
	if { [ "${every}" = 1 ] && [ "${bad}" = 0 ]; } ||
	   { [ "${every}" = 0 ] && [ "${met}" = 1 ]; }; then
		echo "PASS: ${kernel}:${test} (expected ${expect}; met in ${hits}/${n} runs)"
		return 0
	fi
	echo "FAIL: ${kernel}:${test} (expected ${expect}; met in ${hits}/${n} runs)"
	return 1
}

results="${logs}/results-${suite}.txt"
: > "${results}"
running=0
for e in "${entries[@]}"; do
	read -r kernel test scn var rounds expect runs <<< "${e}"
	(run_entry "${kernel}" "${test}" "${scn}" "${var}" "${rounds}" "${expect}" "${runs}" \
		> "${logs}/${kernel}-${test}.txt" 2>&1 || true
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
