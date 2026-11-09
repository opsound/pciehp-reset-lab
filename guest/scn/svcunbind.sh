# a= seconds (default in harness/run.py).
# pciehp service unbind/bind vs. slot reset (run on a KASAN kernel).  A NIC sits in
# rp2's slot.  A "reset_subordinate" loop resets rp2's slot (pci_reset_bridge() ->
# pci_try_reset_slot(), slot lock = rp2's and the NIC's device locks, ~0.1 s each)
# while rp2's pciehp service device is unbound and rebound through sysfs in a loop.
# pciehp_remove() then runs with only the service device locked.
# var=svc (default): unbind/rebind the pciehp service.
# var=port: unbind/rebind rp2's pcieport driver instead (pciehp_remove() with the
# port locked).
# var=fn: reset the NIC through its sysfs "reset" with reset_method=bus instead
# (pci_reset_function() -> pci_dev_reset_slot_function(), NIC locked only).
# var=hot: bind the NIC to vfio-pci and reset it with VFIO_DEVICE_PCI_HOT_RESET
# in a loop instead (vtool hotresetloop: pci_reset_bus() -> pci_try_reset_slot(),
# which uses rp2's struct pci_slot and its controller without a reference).
RP=0000:00:11.0 SECS=${a:-20}
act add nic2 rp2
wait_count $NIC_V $NIC_D 1 30 || { result "FAIL setup"; return; }
D=$(devs $NIC_V $NIC_D)
wait_bound_dev $D 10
SVC=
for s in /sys/bus/pci_express/devices/$RP:pcie*; do
	[ "$(basename "$(readlink $s/driver 2>/dev/null)")" = pciehp ] && SVC=$(basename $s)
done
log "pciehp service device: $SVC"
[ -n "$SVC" ] || { result "FAIL no pciehp service"; return; }
rm -f /tmp/stop
[ "$var" = fn ] && echo bus > /sys/bus/pci/devices/$D/reset_method
F=/sys/bus/pci/devices/$RP/reset_subordinate
[ "$var" = fn ] && F=/sys/bus/pci/devices/$D/reset
if [ "$var" = hot ]; then
	need /bin/vtool || return
	bind_vfio $D
	vtool hotresetloop 1000000 $D > /tmp/hr.out 2>&1 &
	SP=$!
else
	( c=0; while [ ! -e /tmp/stop ]; do echo 1 > $F 2>/dev/null; c=$((c + 1)); done; echo "resets=$c" ) &
	SP=$!
fi
end=$(( $(date +%s) + SECS )) u=0
UB=/sys/bus/pci_express/drivers/pciehp X=$SVC
[ "$var" = port ] && UB=/sys/bus/pci/drivers/pcieport X=$RP
while [ $(date +%s) -lt $end ]; do
	echo $X > $UB/unbind 2>/dev/null
	sleep 0.0$((RANDOM % 9))
	echo $X > $UB/bind 2>/dev/null
	sleep 0.0$((RANDOM % 9))
	u=$((u + 1))
	dmesg | grep -q "BUG: KASAN" && break
done
touch /tmp/stop
[ "$var" = hot ] && { kill $SP 2>/dev/null; sleep 1; tail -3 /tmp/hr.out; }
wait_exit $SP 30 || { dstacks "storm stuck"; }
log "unbind/bind cycles=$u"
k=$(dmesg | grep -c "BUG: KASAN")
h=$(dmesg | grep -c "blocked for more than")
[ $k -eq 0 ] && [ $h -eq 0 ] && result "PASS cycles=$u" || result "FAIL kasan=$k hung=$h cycles=$u"
lockdep_check
