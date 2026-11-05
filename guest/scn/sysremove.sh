# a= rounds (default in harness/run.py).
# sysfs "remove" of a NIC racing pciehp removal (slot power off) of the same NIC.
# Rounds: a= (default 10).  var=e1000e: NIC bound to e1000e.  var=vfio: NIC bound
# to vfio-pci, held by a process that closes it 300 ms after vfio's removal
# request, so both removals wait in vfio-pci's ->remove() together.
R=${a:-10}; [ "$R" = 0 ] && R=10
fail=0
for r in $(seq 1 $R); do
	act add nic2 rp2
	wait_count $NIC_V $NIC_D 1 30 || { log "round $r: not enumerated"; fail=1; break; }
	D=$(devs $NIC_V $NIC_D)
	wait_bound_dev $D 10
	hotadd_check $D > /dev/null	# each round's hot-add must end bound with BAR0 intact
	HP=
	if [ "$var" = vfio ]; then
		bind_vfio $D > /dev/null
		VT_RESP_DELAY_MS=300 /bin/vtool hold --respond $D > /tmp/h.out 2>&1 & HP=$!
		sleep 0.5
	fi
	d1=0.0$((RANDOM % 10)) d2=0.0$((RANDOM % 10))
	( sleep $d1; slot_power 2 0 ) & P1=$!
	( sleep $d2; echo 1 > /sys/bus/pci/devices/$D/remove 2>/dev/null ) & P2=$!
	wait_exit $P1 40 || { log "round $r: slot power off stuck"; fail=1; }
	wait_exit $P2 40 || { log "round $r: sysfs remove stuck"; fail=1; }
	[ -n "$HP" ] && { wait_exit $HP 20 || { log "holder stuck"; fail=1; }; }
	unplug_slot 2 $NIC_V $NIC_D 0 || { log "round $r: not removed"; fail=1; }
	[ $fail = 0 ] || { dstacks "stuck"; break; }
	dmesg | grep -q "BUG: KASAN" && { fail=1; break; }
	sleep 1.2
done
k=$(dmesg | grep -c "BUG: KASAN") h=$(dmesg | grep -c "blocked for more than")
[ $fail = 0 ] && [ $k = 0 ] && [ $h = 0 ] && result "PASS sysremove=$var rounds=$R" || result "FAIL sysremove=$var round=$r kasan=$k hung=$h"
lockdep_check
