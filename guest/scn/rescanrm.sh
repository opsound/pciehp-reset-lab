# (N19) "rescan" attributes vs removal.  Nested topology (harness/run.py):
#   rps (00:1e.0) -> up1 (03:00.0) -> dp1 (04:00.0) -> nicd1 (05:00.0)
#                                  -> dp2 (04:01.0) -> nicd2 (06:00.0)
# dev_rescan_store() and bus_rescan_store() wait for pci_rescan_remove_lock
# with the kernfs active reference of their "rescan" file held.  A remover
# that holds the lock and reaches device_del() of nicd1 (dev) or
# device_unregister() of bus 05 (bus) drains that reference: ABBA, both tasks
# hang.
# var=<mode>-<tgt>
#   tgt  dev   writer: echo 1 > /sys/bus/pci/devices/0000:05:00.0/rescan
#        bus   writer: echo 1 > /sys/class/pci_bus/0000:05/rescan
#   mode race  a writer loop vs sysfs remove of up1, a= rounds (up1 comes back
#              with a global rescan between rounds); no hooks
#        hold  pcitest/hold_rescan_ms holds the lock 4 s; sysfs remove of up1
#              queues on it first, one write second
NO_ADDED_CHECK=1	# the scenario removes the switch on purpose
UP1=0000:03:00.0 NICA=0000:05:00.0 BUSA=0000:05
mode=${var%-*} tgt=${var#*-}
case $tgt in
dev) RF=/sys/bus/pci/devices/$NICA/rescan ;;
bus) RF=/sys/class/pci_bus/$BUSA/rescan ;;
*) result "FAIL bad var $var"; return ;;
esac
wait_count $NIC_V $NIC_D 2 60 || { result "FAIL setup: NICs not found"; return; }
need $RF || return
[ $mode = hold ] && { need $DBG/hold_rescan_ms || return; }

remover_sysfs() {
	( echo 1 > /sys/bus/pci/devices/$UP1/remove; log "sysfs remove of $UP1 returned" ) &
	RM=$!
	log "remover $RM: echo 1 > /sys/bus/pci/devices/$UP1/remove"
}
# verdict: both tasks must be gone and no hung-task report
finish() {
	local stuck=
	[ -n "$W" ] && ! wait_exit $W 1 && stuck="$stuck writer"
	[ -n "$RM" ] && ! wait_exit $RM 1 && stuck="$stuck remover"
	dstacks "final"
	if [ -n "$stuck" ] || [ $(nhung) -gt 0 ]; then
		result "HANG stuck:${stuck:- none} hung_reports=$(nhung) $1"
	else
		result "PASS $1"
	fi
}
W= RM=
case $mode in
hold)
	echo 4000 > $DBG/hold_rescan_ms &
	HOLD=$!
	sleep 0.5
	remover_sysfs		# blocks on the lock after device_remove_file_self()
	sleep 0.5
	( echo 1 > $RF; log "rescan write returned rc=$?" ) &
	W=$!
	sleep 0.5
	dstacks "lock held by hook"
	wait_exit $HOLD 10
	log "hook released the lock"
	sleep 45
	finish
	;;
race)
	rounds=${a:-10} r=0 hung=0
	while [ $r -lt $rounds ]; do
		r=$((r + 1))
		wait_count $NIC_V $NIC_D 2 30 || { log "round $r: NICs not back"; break; }
		rm -f /tmp/stop
		( while [ ! -e /tmp/stop ]; do echo 1 > $RF; done 2>/dev/null ) &
		W=$!
		sleep 0.$((RANDOM % 5))
		remover_sysfs
		if ! wait_exit $RM 30; then hung=1; log "round $r: remover stuck"; break; fi
		touch /tmp/stop
		if ! wait_exit $W 30; then hung=1; log "round $r: writer stuck"; break; fi
		log "round $r: ok"
		W= RM=
		echo 1 > /sys/bus/pci/rescan
	done
	touch /tmp/stop
	[ $hung = 1 ] && sleep 30	# let the hung-task detector report
	finish "rounds=$r/$rounds"
	;;
*) result "FAIL bad var $var" ;;
esac
lockdep_check
