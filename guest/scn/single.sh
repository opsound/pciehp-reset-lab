# a= rounds (default in harness/run.py).
# One reset during hot-add: hot-add a NIC on rp2, and as soon as pciehp's IST has
# started the link check (it holds reset_lock from there through enumeration),
# issue ONE reset of rp2's slot: var=sub "reset_subordinate" (with restore),
# var=err AER-style pci_bus_error_reset() (err_reset hook), var=aer/aerhost
# pcie_do_recovery() without/with pci_rescan_remove_lock (aer_reset hooks).  Then check that the
# NIC is bound and its BAR0 register matches its resource.  Rounds: a= (default 5).
RP=0000:00:11.0 R=${a:-5}; [ "$R" = 0 ] && R=5
ok=0 bad=0 hung=0
for r in $(seq 1 $R); do
	trace_on pciehp_check_link_status pci_scan_slot pciehp_reset_slot e1000_probe pci_bridge_wait_for_secondary_bus
	act add nic2 rp2
	# var=aerlate: reset once the driver starts probing (after enumeration)
	w=pciehp_check_link_status; [ "$var" = aerlate ] && w=e1000_probe
	i=0; while ! grep -q $w $T/trace && [ $i -lt 1000 ]; do sleep 0.005; i=$((i + 1)); done
	case $var in
	aerlate) (echo "$RP" > $DBG/aer_reset) 2>/dev/null & ;;
	err) (echo "$RP" > $DBG/err_reset) 2>/dev/null & ;;
	aer) (echo "$RP" > $DBG/aer_reset) 2>/dev/null & ;;
	aerhost) (echo "$RP" > $DBG/aer_host_reset) 2>/dev/null & ;;
	*) (echo 1 > /sys/bus/pci/devices/$RP/reset_subordinate) 2>/dev/null & ;;
	esac
	RS=$!
	wait_count $NIC_V $NIC_D 1 30 || { hung=$((hung + 1)); dstacks "enum"; break; }
	wait_exit $RS 30 || { hung=$((hung + 1)); dstacks "reset stuck"; break; }
	D=$(devs $NIC_V $NIC_D)
	wait_bound_dev $D 5; sleep 2.5
	trace_dump | grep -v "^ *<idle>" | grep -vE "pciehp_reset_slot <-pci_reset_bus_function" | awk '{print $1, $4, $5, $6}' | head -n 14
	if bar_ok $D && [ "$(drv_of $D)" = e1000e ]; then s=OK; ok=$((ok + 1)); else s=BAD; bad=$((bad + 1)); fi
	echo "CHECK: round=$r $s drv=$(drv_of $D) $BAR_INFO"
	unplug_slot 2 $NIC_V $NIC_D 0 || { hung=$((hung + 1)); break; }
	sleep 1.2
done
h=$(dmesg | grep -c "blocked for more than")
[ $bad = 0 ] && [ $hung = 0 ] && [ $h = 0 ] && result "PASS single=$var ok=$ok/$R" || result "FAIL single=$var ok=$ok bad=$bad hung=$hung"
lockdep_check
