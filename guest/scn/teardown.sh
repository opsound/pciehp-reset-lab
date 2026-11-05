# a= rounds (default in harness/run.py).
# Resets during teardown.  NICs A (rp1) and B (rp2) bound to vfio-pci, held by one
# process.  rp2's slot is powered off through sysfs, so pciehp's teardown waits in
# vfio-pci's ->remove() for the holder.  Meanwhile rp2 and rp1 are reset in loops
# (var=host: host_reset hook = pci_bus_error_reset() under pci_rescan_remove_lock;
# var=err: AER-style err_reset; var=sub: reset_subordinate), and the holder
# answers B's removal request 2 s later with VFIO_DEVICE_RESET of A, then closes B.
# Then rp1 is powered off as well.  Rounds: a= (default 3).
R=${a:-3}; [ "$R" = 0 ] && R=3
reset_loop() {
	( while [ ! -e /tmp/stop ]; do
		case $var in
		host) echo "$1 0" > $DBG/host_reset ;;
		err) echo "$1" > $DBG/err_reset ;;
		*) echo 1 > /sys/bus/pci/devices/$1/reset_subordinate ;;
		esac 2>/dev/null
		sleep 0.0$((RANDOM % 5))
	done ) &
}
fail=0
for r in $(seq 1 $R); do
	echo "ROUND $r" > /dev/kmsg
	act add nic1 rp1; act add nic2 rp2
	wait_count $NIC_V $NIC_D 2 30 || { fail=1; break; }
	set -- $(devs $NIC_V $NIC_D); A=$1 B=$2
	wait_bound_dev $A 10; wait_bound_dev $B 10
	bind_vfio $A bus > /dev/null; bind_vfio $B bus > /dev/null
	VT_REQ_DELAY_MS=2000 /bin/vtool hold --reset-on-req $A $B > /tmp/h.out 2>&1 & HP=$!
	sleep 0.5
	rm -f /tmp/stop
	( slot_power 2 0 ) & P2=$!
	sleep 0.3
	reset_loop 0000:00:11.0; reset_loop 0000:00:10.0
	wait_exit $P2 40 || { log "round $r: rp2 power off stuck"; fail=1; }
	touch /tmp/stop
	( slot_power 1 0 ) & P1=$!
	wait_exit $P1 40 || { log "round $r: rp1 power off stuck"; fail=1; }
	wait_exit $HP 20 || { log "holder stuck"; fail=1; }
	cat /tmp/h.out | grep -v READY; rm -f /tmp/h.out
	unplug_slot 1 $NIC_V $NIC_D 0 > /dev/null; unplug_slot 2 $NIC_V $NIC_D 0 > /dev/null
	wait_count $NIC_V $NIC_D 0 20 || { log "round $r: left $(devs $NIC_V $NIC_D)"; fail=1; }
	[ $fail = 0 ] || { dstacks "stuck"; break; }
	sleep 1.5
done
h=$(dmesg | grep -c "blocked for more than") k=$(dmesg | grep -c "BUG: KASAN")
[ $fail = 0 ] && [ $h = 0 ] && [ $k = 0 ] && result "PASS teardown=$var rounds=$R" || result "FAIL teardown=$var round=$r hung=$h kasan=$k"
lockdep_check
