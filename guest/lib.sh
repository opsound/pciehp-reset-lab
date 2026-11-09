# SPDX-License-Identifier: GPL-2.0-only
# Guest-side helpers for the scenarios.  Sourced by /init (which sets scn,
# var, n and ACTCH and opens fd 9 on the host channel ttyS1 when ACTCH=tty).
# Scenario output lines starting with RESULT:, PERF, STATS, BENCH, OK, ERRS,
# VLAT are collected for the host at the end (see init); print metrics that way.
T=/sys/kernel/tracing
DBG=/sys/kernel/debug/pcitest
DBG2=/sys/kernel/debug/pcitest2
KNOBS=/sys/module/pciehp/parameters
NIC_V=0x8086 NIC_D=0x10d3

up() { read -r u _ < /proc/uptime; echo "$u"; }
log() { echo "[g $(up)] $*"; }
# act ACTION ARGS...: ask the host to perform a QMP action (run.py):
#   add ID BUS [DRIVER]   device_add (default e1000e); retried while ID is still taken
#   del ID                device_del
#   addall N [DRIVER]     device_add nic1..nicN on rp1..rpN
#   delall N              device_del nic1..nicN
act() {
	echo "@@ACT $*"
	[ "$ACTCH" = tty ] && echo "@@ACT $*" >&9
	return 0
}
result() { echo "RESULT: $*"; }
# need PATH...: report SKIP and fail if a hook/knob/file is missing, e.g.
#   need $DBG/host_reset_nolock || return
need() {
	local f
	for f in "$@"; do
		[ -e "$f" ] || { result "SKIP missing $f"; return 1; }
	done
}

# devs VENDOR DEVICE: matching BDFs, sorted
devs() {
	local d
	for d in /sys/bus/pci/devices/*; do
		[ "$(cat $d/vendor 2>/dev/null)" = "$1" ] && [ "$(cat $d/device 2>/dev/null)" = "$2" ] && basename $d
	done | sort
}
# wait_count VENDOR DEVICE N TIMEOUT_S: wait until exactly N matching devices exist
wait_count() {
	local end=$(( ${4%.*} * 100 )) i=0
	while [ $i -lt $end ]; do
		[ "$(devs $1 $2 | wc -l)" -eq "$3" ] && return 0
		sleep 0.01; i=$((i + 1))
	done
	return 1
}
port_of() { basename "$(dirname "$(readlink -f /sys/bus/pci/devices/$1)")"; }
# bind_vfio BDF [RESET_METHOD]
bind_vfio() {
	local b=$1
	hotadd_check $b > /dev/null	# the device's hot-add result, before vfio-pci replaces its driver
	echo vfio-pci > /sys/bus/pci/devices/$b/driver_override
	[ -e /sys/bus/pci/devices/$b/driver ] && echo $b > /sys/bus/pci/devices/$b/driver/unbind
	echo $b > /sys/bus/pci/drivers_probe
	[ -n "$2" ] && echo "$2" > /sys/bus/pci/devices/$b/reset_method
	log "bound $b to $(basename "$(readlink /sys/bus/pci/devices/$b/driver)") reset_method=$(cat /sys/bus/pci/devices/$b/reset_method)"
}
# dstacks LABEL: kernel stacks of all D-state tasks
dstacks() {
	local p s
	echo "=== D-state tasks: $1"
	for p in /proc/[0-9]*; do
		s=$(awk '{print $3}' $p/stat 2>/dev/null)
		[ "$s" = D ] || continue
		echo "-- $(basename $p) $(cat $p/comm 2>/dev/null)"
		cat $p/stack 2>/dev/null | head -14
	done
}
lockdep_check() {
	dmesg | grep -E "possible circular|possible recursive|WARNING:|BUG:|blocked for more than|DEADLOCK|general protection|corruption" | head -20
	echo "LOCKDEP-LINES: $(dmesg | grep -cE 'possible circular|possible recursive|DEADLOCK')"
	echo "KASAN-LINES: $(dmesg | grep -c 'BUG: KASAN')"
}
# lockdep_sigs: one line per lockdep circular or recursive locking report so
# far, "KIND LOCK", LOCK being the lock the task was trying to acquire, e.g.
# "recursive &ctrl->reset_lock"
lockdep_sigs() {
	dmesg | awk '
		/WARNING: possible recursive locking detected/ { k = "recursive"; next }
		/WARNING: possible circular locking dependency detected/ { k = "circular"; next }
		k != "" && /is trying to acquire lock:/ { w = 1; next }
		w { if (match($0, /\([^(){}]*\)\{/)) print k, substr($0, RSTART + 1, RLENGTH - 3); else print k, "?"; w = 0; k = "" }
	'
}
# trace_on FUNC...: function tracer on the given functions; functions the
# kernel doesn't have (renamed/inlined in a candidate) are skipped.
trace_on() {
	local f
	echo 0 > $T/tracing_on
	echo > $T/trace
	echo > $T/set_ftrace_filter
	for f in $*; do echo $f >> $T/set_ftrace_filter 2>/dev/null; done
	echo function > $T/current_tracer
	echo 1 > $T/tracing_on
}
trace_dump() { echo 0 > $T/tracing_on; grep -v '^#' $T/trace; }
# graph_on FUNC...: function_graph tracer on those of the functions that exist;
# stays off if none does (an empty filter would trace everything).
graph_on() {
	local f
	echo 0 > $T/tracing_on
	echo > $T/trace
	echo > $T/set_ftrace_filter
	for f in $*; do echo $f >> $T/set_ftrace_filter 2>/dev/null; done
	grep -q . $T/set_ftrace_filter || { log "graph_on: none of $* exists"; return 1; }
	echo function_graph > $T/current_tracer
	echo 1 > $T/tracing_on
}
# alive PID
alive() { [ -d /proc/$1 ] && [ "$(awk '{print $3}' /proc/$1/stat)" != Z ]; }
# wait_exit PID TIMEOUT_S
wait_exit() {
	local i=0
	while [ $i -lt $(( $2 * 10 )) ]; do
		alive $1 || return 0
		sleep 0.1; i=$((i + 1))
	done
	return 1
}
# nhung: count of hung-task reports so far
nhung() { dmesg | grep -c "blocked for more than"; }
drv_of() { [ -e /sys/bus/pci/devices/$1/driver ] && basename "$(readlink /sys/bus/pci/devices/$1/driver)" || echo none; }
# bar_ok BDF: BAR0 register matches the kernel's resource 0 and memory decode is on
# pcicfg BDF OFFSET BYTES: a config register in hex without 0x, like setpci
pcicfg() { od -An -tx$3 -j$(($2)) -N$3 /sys/bus/pci/devices/$1/config 2>/dev/null | tr -d ' \n'; }
# pciwr BDF OFFSET BYTES VALUE: write a config register (VALUE in hex) in one
# access through the sysfs config file
pciwr() {
	local v=$((0x$4)) i=0 b=
	while [ $i -lt $3 ]; do b="$b\\x$(printf %02x $(( (v >> (8 * i)) & 0xff )))"; i=$((i + 1)); done
	printf "$b" | dd of=/sys/bus/pci/devices/$1/config bs=$3 seek=$(( $2 / $3 )) count=1 conv=notrunc 2>/dev/null
}
# expcap BDF: config offset of the PCI Express capability (0 if none)
expcap() {
	local p id
	p=$((0x$(pcicfg $1 0x34 1)))
	while [ $p -ne 0 ]; do
		id=$((0x$(pcicfg $1 $p 1)))
		[ $id -eq 16 ] && { echo $p; return; }
		p=$((0x$(pcicfg $1 $((p + 1)) 1)))
	done
	echo 0
}
# cfg BDF COMMAND|BASE_ADDRESS_0: config read bounded to 3 s ("blocked" if it
# does not return: config accesses sleep while a reset holds the device).
cfg() {
	local off=0x04 len=2
	[ "$2" = BASE_ADDRESS_0 ] && off=0x10 len=4
	rm -f /tmp/cfg.out
	( pcicfg $1 $off $len > /tmp/cfg.out ) &
	if wait_exit $! 3; then cat /tmp/cfg.out; else echo blocked; fi
}
bar_ok() {
	local b=$1 reg cmd res
	# Config reads can sleep for long behind a reset: bounded read.
	rm -f /tmp/bar.out
	( echo "$(pcicfg $b 0x10 4) $(pcicfg $b 0x04 2)" > /tmp/bar.out ) 2>/dev/null &
	if wait_exit $! 3 && [ -s /tmp/bar.out ]; then read -r reg cmd < /tmp/bar.out; else BAR_INFO="cfg-blocked"; return 1; fi
	[ -n "$cmd" ] || { BAR_INFO="cfg-read-failed"; return 1; }
	res=$(head -1 /sys/bus/pci/devices/$b/resource | awk '{print $1}')
	BAR_INFO="bar0=0x$reg res0=$res cmd=0x$cmd"
	[ $(( 0x$reg & ~0xf )) -eq $(( res & 0xffffffff )) ] && [ $(( 0x$cmd & 2 )) -ne 0 ]
}
slot_power() { echo $2 > /sys/bus/pci/slots/$1/power 2>/dev/null; }
wait_bound_dev() {	# BDF TIMEOUT_S
	local i=0
	while [ "$(drv_of $1)" = none ] && [ $i -lt $(( $2 * 20 )) ]; do sleep 0.05; i=$((i + 1)); done
	[ "$(drv_of $1)" != none ]
}
# unplug_slot SLOT VENDOR DEVICE N: power the slot off (QEMU unplugs on power-off),
# retrying while pciehp is still busy, until N matching devices remain
unplug_slot() {
	local i=0
	while [ $i -lt 60 ]; do
		slot_power $1 0
		wait_count $2 $3 $4 1 && return 0
		i=$((i + 1))
	done
	return 1
}

# hotadd_check BDF: the per-device form of added_check, for devices that the
# scenario rebinds or removes before the end (bind_vfio calls it; scenarios
# call it after a hot-add).  Bad: BAR0 register != resource 0 (config read not
# blocked), or no driver within 5 s for a device with a native driver here
# (e1000e 10d3, igb 10c9).  VFs are skipped (not hot-added; scenarios may set
# sriov_drivers_autoprobe=0).  Bad devices are appended to /tmp/added_mid,
# which added_check reports and counts ("mid:STATE").
hotadd_check() {
	local b=$1 d=/sys/bus/pci/devices/$1 id st= reg= cmd= res=0
	[ -e $d ] && [ ! -e $d/physfn ] || return 0
	id=$(cat $d/vendor 2>/dev/null):$(cat $d/device 2>/dev/null)
	case $id in 0x8086:0x10d3|0x8086:0x10c9) wait_bound_dev $b 5 || st=+UNBOUND;; esac
	rm -f /tmp/hc.out
	( echo "$(pcicfg $b 0x10 4) $(pcicfg $b 0x04 2)" > /tmp/hc.out ) 2>/dev/null &
	if wait_exit $! 3 && [ -s /tmp/hc.out ]; then
		read -r reg cmd < /tmp/hc.out
		res=$(head -1 $d/resource 2>/dev/null | awk '{print $1}'); res=${res:-0}
		[ -n "$cmd" ] && [ $(( res )) -ne 0 ] &&
			[ $(( 0x$reg & ~0xf )) -ne $(( res & 0xffffffff )) ] && st=$st+BAR-LOST
	fi
	st=${st#+}
	[ -z "$st" ] && return 0
	echo "ADDED-CHECK $b $id driver=$(drv_of $b) bar0=0x$reg res0=$res cmd=0x$cmd mid:$st" | tee -a /tmp/added_mid
	return 1
}
# added_check: run by /init after every scenario.  Every non-bridge device
# below a root port (bus != 00, i.e. hot-added or below the switch) must have a
# driver bound and its BAR0 register must match its resource (VFs are skipped:
# not hot-added, BARs read 0, may be unbound on purpose); devices bound to a driver other than
# vfio-pci must also have memory decode on.  Waits up to 5 s for drivers to
# bind; config reads are bounded, as they block behind a stuck reset.  Prints
# one ADDED-CHECK line per device (states ok or UNBOUND/CFG-BLOCKED/BAR-LOST/
# DECODE-OFF joined by "+") and ADDED-CHECK-SUMMARY devices=N bad=M, which
# harness/qxparse.py turns into a FAIL.  A scenario that leaves a device unbound
# on purpose sets NO_ADDED_CHECK=1.
added_check() {
	local d b cls drv reg cmd res st bad=0 tot=0 i=0 un
	while [ $i -lt 50 ]; do
		un=0
		for d in /sys/bus/pci/devices/0000:0[1-9a-f]:* /sys/bus/pci/devices/0000:[1-9a-f]?:*; do
			[ -e $d ] || continue
			case $(cat $d/class 2>/dev/null) in 0x0604*) continue;; esac
			[ -e $d/driver ] || [ -e $d/physfn ] || un=1
		done
		[ $un = 0 ] && break
		sleep 0.1; i=$((i + 1))
	done
	for d in /sys/bus/pci/devices/0000:0[1-9a-f]:* /sys/bus/pci/devices/0000:[1-9a-f]?:*; do
		[ -e $d ] || continue
		b=${d##*/}
		cls=$(cat $d/class 2>/dev/null)
		case $cls in 0x0604*|"") continue;; esac
		[ -e $d/physfn ] && continue	# VFs: not hot-added, may be left unbound on purpose
		tot=$((tot + 1))
		drv=$(basename "$(readlink $d/driver 2>/dev/null)" 2>/dev/null); drv=${drv:-none}
		rm -f /tmp/ac.out
		( echo "$(pcicfg $b 0x10 4) $(pcicfg $b 0x04 2)" > /tmp/ac.out ) 2>/dev/null &
		if wait_exit $! 3 && [ -s /tmp/ac.out ]; then read -r reg cmd < /tmp/ac.out; else reg=blocked cmd=blocked; fi
		res=$(head -1 $d/resource 2>/dev/null | awk '{print $1}'); res=${res:-0}
		st=
		[ $drv = none ] && st=+UNBOUND
		if [ "$reg" = blocked ] || [ -z "$cmd" ]; then st=$st+CFG-BLOCKED
		else
			[ $(( res )) -ne 0 ] && [ $(( 0x$reg & ~0xf )) -ne $(( res & 0xffffffff )) ] && st=$st+BAR-LOST
			[ $drv != none ] && [ $drv != vfio-pci ] && [ $(( 0x$cmd & 2 )) -eq 0 ] && st=$st+DECODE-OFF
		fi
		st=${st#+}; st=${st:-ok}
		[ $st = ok ] || bad=$((bad + 1))
		echo "ADDED-CHECK $b $(cat $d/vendor 2>/dev/null):$(cat $d/device 2>/dev/null) driver=$drv bar0=0x$reg res0=$res cmd=0x$cmd $st"
	done
	if [ -s /tmp/added_mid ]; then
		cat /tmp/added_mid
		bad=$((bad + $(wc -l < /tmp/added_mid)))
	fi
	echo "ADDED-CHECK-SUMMARY devices=$tot bad=$bad"
}
