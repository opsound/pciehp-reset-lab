# (W6, series check) Lock order of W6's vfio-pci recovery callbacks against
# power state changes.  pcie_do_recovery() calls the callbacks inside
# pci_walk_bus(), i.e. with pci_bus_sem held for reading.  W6's
# ->error_detected() then takes memory_lock (after synchronize_srcu()), and its
# ->slot_reset() calls pci_set_power_state(D0).  A D0 transition from D3hot
# takes pci_bus_sem for reading in pcie_aspm_pm_state_change(); vfio-pci does
# a user's D0 write (PMCSR) with memory_lock held.
#
# nic1 (e1000e, rp1 at 00:10.0, present at boot) is bound to vfio-pci and held
# by vtool, which opts in to W6's recovery (VT_REC=1) unless var has +norec.
# The recovery is pcitest/aer_reset of rp1 (pcie_do_recovery(), frozen), not
# aer_inject, whose own lockdep report would turn lockdep off first.
#
# var=lockdep-d3  vtool puts nic1 into D3hot; one recovery.  W6's slot_reset()
#                 brings it to D0 inside the walk: pci_bus_sem read-acquired
#                 recursively (lockdep: possible recursive locking)
# var=lockdep-pm  vtool writes D3hot and D0 once (memory_lock -> pci_bus_sem),
#                 nic1 is in D0; one recovery (pci_bus_sem -> device_lock ->
#                 access_lock -> memory_lock): lockdep circular report
# var=dl          the cover letter's deadlock: vtool writes D3hot/D0 to PMCSR
#                 in a loop (VT_PMLOOP), a loop of recoveries of rp1 (0-90 ms
#                 apart), and a pci_bus_sem writer: sysfs remove and rescan
#                 of an unbound NIC on rp2 in a loop (+sriov: sriov_numvfs
#                 2/0 on the igb PF on rpc instead), a= seconds.  +sync: no
#                 separate writer loop; each recovery starts together with the
#                 writer's next step; +inject: the recovery is a fatal error
#                 injected at nic1 through /dev/aer_inject (no hook).  HANG if
#                 the loops stop for 25 s.
# RESULT: PASS/HANG with the loop counters and, on a hang, which tasks wait
# where (cycle=).
PF_D=0x10c9 VF_D=0x10ca RP=0000:00:10.0
mode=${var%%+*}
has() { case "+$var+" in *"+$1+"*) return 0;; esac; return 1; }
if has inject; then need /dev/aer_inject /bin/aerinj /bin/vtool || return; else need $DBG/aer_reset /bin/vtool || return; fi
EP=$(for d in $(devs $NIC_V $NIC_D); do readlink -f /sys/bus/pci/devices/$d | grep -q "/$RP/" && echo $d; done | head -1)
[ -n "$EP" ] || { result "FAIL setup: no NIC below $RP"; return; }
bind_vfio $EP
[ "$(drv_of $EP)" = vfio-pci ] || { result "FAIL setup: $EP not bound to vfio-pci"; return; }
log "aspm: link_state of $RP: $(ls /sys/bus/pci/devices/$RP/link 2>/dev/null | tr '\n' ' ')"
VTENV="VT_CMD_OR=4"
has norec || VTENV="$VTENV VT_REC=1"
case $mode in
lockdep-d3) VTENV="$VTENV VT_D3=1" ;;
lockdep-pm) VTENV="$VTENV VT_D3CYCLE=1" ;;
dl) VTENV="$VTENV VT_PMLOOP=/tmp/pm" ;;
*) result "FAIL unknown var $var"; return ;;
esac
env $VTENV vtool hold $EP > /tmp/vt.out 2>&1 &
VT=$!
i=0; while ! grep -q READY /tmp/vt.out && [ $i -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
grep -q READY /tmp/vt.out || { cat /tmp/vt.out; result "FAIL setup: vtool did not open $EP"; return; }
grep -E "^VT(REC|PM|CMD) " /tmp/vt.out
pmstate() { echo "pmcsr=0x$(pcicfg $EP 0xcc 2) power_state=$(cat /sys/bus/pci/devices/$EP/power_state 2>/dev/null)"; }
log "nic1 $(pmstate)"
# tstacks PATTERN: kernel stacks of all threads whose stack matches
tstacks() {
	local t
	for t in /proc/[0-9]*/task/[0-9]*; do
		grep -qE "$1" $t/stack 2>/dev/null || continue
		echo "-- ${t##*/} $(cat $t/comm 2>/dev/null)"
		head -16 $t/stack
	done
}

o=PASS cyc=- cur=-
case $mode in
lockdep-d3|lockdep-pm)
	( echo "$RP" > $DBG/aer_reset; log "R: aer_reset returned rc=$?" ) &
	R=$!
	if ! wait_exit $R 60; then
		o=HANG
		tstacks "pcitest_aer_common|vtool|rwsem|mutex_lock"
		i=0; while [ "$(nhung)" -eq 0 ] && [ $i -lt 30 ]; do sleep 1; i=$((i + 1)); done
		NO_ADDED_CHECK=1
	fi
	sleep 1
	dmesg | grep -E "AER:|recovery|pcitest|vfio" | tail -8
	log "nic1 after: $(pmstate)"
	;;
dl)
	A=${a:-90}
	mkdir -p /tmp/sr; rm -f /tmp/sr/*
	hr_loop() { local i=0; while [ ! -e /tmp/sr/stop ]; do echo "$RP 0" > $DBG/aer_reset 2>/dev/null; i=$((i + 1)); echo $i > /tmp/sr/hr; sleep 0.0$((RANDOM % 9))$((RANDOM % 10)); done; }
	if has sriov; then
		PF=$(devs $NIC_V $PF_D)
		[ -n "$PF" ] || { result "FAIL setup: no PF"; return; }
		wait_bound_dev $PF 10 || { result "FAIL setup: PF unbound"; return; }
		echo 0 > /sys/bus/pci/devices/$PF/sriov_drivers_autoprobe
		SV=/sys/bus/pci/devices/$PF/sriov_numvfs
		sv_loop() { local i=0; while [ ! -e /tmp/sr/stop ]; do echo 2 > $SV 2>/dev/null; echo 0 > $SV 2>/dev/null; i=$((i + 1)); echo $i > /tmp/sr/sv; done; }
	else
		# the unbound NIC on rp2: sysfs remove and rescan of its bus, each a
		# pci_bus_sem writer (pci_destroy_dev(), pci_device_add())
		WP=0000:00:11.0
		W=$(for d in $(devs $NIC_V $NIC_D); do readlink -f /sys/bus/pci/devices/$d | grep -q "/$WP/" && echo $d; done | head -1)
		[ -n "$W" ] || { result "FAIL setup: no NIC below $WP"; return; }
		WB=$(cat /sys/bus/pci/devices/$WP/subordinate_bus_number 2>/dev/null)
		WB=$(printf "0000:%02x" $((WB)))
		echo nodriver > /sys/bus/pci/devices/$W/driver_override
		[ -e /sys/bus/pci/devices/$W/driver ] && echo $W > /sys/bus/pci/devices/$W/driver/unbind
		[ -e /sys/class/pci_bus/$WB/rescan ] || { result "FAIL setup: no /sys/class/pci_bus/$WB/rescan"; return; }
		sv_loop() { local i=0; while [ ! -e /tmp/sr/stop ]; do echo 1 > /sys/bus/pci/devices/$W/remove 2>/dev/null; echo 1 > /sys/class/pci_bus/$WB/rescan; [ -e /sys/bus/pci/devices/$W ] && echo nodriver > /sys/bus/pci/devices/$W/driver_override; i=$((i + 1)); echo $i > /tmp/sr/sv; done; }
		NO_ADDED_CHECK=1	# the rescanned NIC stays unbound on purpose
	fi
	if has trace; then
		echo 500 > $T/tracing_thresh
		graph_on vfio_pci_core_aer_err_detected vfio_lock_and_set_power_state vfio_pci_set_power_state pcie_aspm_pm_state_change pci_destroy_dev pci_device_add
	fi
	dmesg -n 1	# the hooks log every reset
	if has noreset; then hr_loop() { while [ ! -e /tmp/sr/stop ]; do sleep 1; done; }; fi
	if has sync && ! has sriov; then
		# +sync: each round starts the writer's next step (remove or
		# rescan) and the recovery together, then waits 0-90 ms
		hr_loop() {
			local i=0
			while [ ! -e /tmp/sr/stop ]; do
				if [ $((i % 2)) = 0 ]; then
					( echo 1 > /sys/bus/pci/devices/$W/remove 2>/dev/null ) &
				else
					( echo 1 > /sys/class/pci_bus/$WB/rescan; [ -e /sys/bus/pci/devices/$W ] && echo nodriver > /sys/bus/pci/devices/$W/driver_override ) &
				fi
				if has inject; then
					# a real AER fatal error at nic1: aer_isr() runs the recovery
					n0=$(dmesg | grep -c "device recovery")
					aerinj $EP 0x10 0 1 > /dev/null
					j=0; while [ "$(dmesg | grep -c 'device recovery')" = "$n0" ] && [ $j -lt 400 ]; do sleep 0.01; j=$((j + 1)); done
				else
					echo "$RP 0" > $DBG/aer_reset 2>/dev/null
				fi
				wait $!
				i=$((i + 1)); echo $i > /tmp/sr/hr
				sleep 0.0$((RANDOM % 9))$((RANDOM % 10))
			done
		}
		sv_loop() { while [ ! -e /tmp/sr/stop ]; do sleep 1; done; }
	fi
	hr_loop & P1=$!
	sv_loop & P2=$!
	t=0 last="" still=0
	while [ $t -lt $A ]; do
		sleep 1; t=$((t + 1))
		pm=$(cut -d' ' -f1 /tmp/pm 2>/dev/null)
		cur="$(cat /tmp/sr/hr /tmp/sr/sv 2>/dev/null | tr '\n' '/')$pm"
		if [ "$cur" = "$last" ]; then still=$((still + 1)); else still=0; last=$cur; fi
		[ $still -ge 25 ] && { o=HANG; break; }
	done
	touch /tmp/sr/stop
	dmesg -n 7
	has trace && { echo 0 > $T/tracing_on; grep -v "^#" $T/trace | awk '{print $(NF-1), $NF}' | sort | uniq -c | sort -rn | head -20; grep -v "^#" $T/trace | tail -30; echo 0 > $T/tracing_thresh; echo nop > $T/current_tracer; }
	log "loop: t=${t}s counters resets/sriov/pm: $cur still=${still}s pm: $(cat /tmp/pm 2>/dev/null)"
	if [ $o = PASS ]; then
		kill -USR1 $VT
		wait_exit $P1 30 && wait_exit $P2 30 || o=HANG
	fi
	if [ $o = HANG ]; then
		echo "=== stuck threads"
		tstacks "pcie_do_recovery|sriov_numvfs_store|remove_store|rescan_store|vfio_|pcie_aspm|rwsem_down"
		a1=$(tstacks pcie_do_recovery); a2=$(tstacks pcie_aspm_pm_state_change); a3=$(tstacks "sriov_numvfs_store|remove_store|rescan_store")
		if echo "$a1" | grep -q vfio_pci_core_aer_err_detected && echo "$a2" | grep -qE "vfio_lock_and_set_power_state|vfio_pci_config_rw|vfio_pci_ioctl_reset"; then
			cyc=memory_lock	# walk waits for memory_lock, its holder for pci_bus_sem
		elif echo "$a1" | grep -q "vfio_pci_core_aer_slot_reset" && echo "$a1" | grep -q pcie_aspm_pm_state_change; then
			cyc=slot_reset_d0	# the walk re-acquires pci_bus_sem behind a writer
		else
			cyc=other
		fi
		echo "$a3" | grep -qE "pci_device_add|pci_destroy_dev|pci_stop_bus|pci_remove_bus" && cyc="$cyc+writer"
		i=0; while [ "$(nhung)" -eq 0 ] && [ $i -lt 30 ]; do sleep 1; i=$((i + 1)); done
		NO_ADDED_CHECK=1
	fi
	cur=$(echo "$cur" | tr '/' ' ')
	;;
esac
grep "^VTREVT" /tmp/vt.out | tail -3
nev=$(grep -c "^VTREVT" /tmp/vt.out)
[ $o = PASS ] && [ $mode != dl ] && { kill -USR1 $VT; wait_exit $VT 20 || dstacks "vtool close"; }
result "$o mode=$mode var=$var cycle=$cyc rounds=$(echo $cur | tr ' ' '/') events=$nev hung=$(nhung)"
lockdep_check
