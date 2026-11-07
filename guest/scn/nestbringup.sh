# (N10) A child hotplug port brings its slot up while the removal of its
# parent begins.  Nested topology (harness/run.py): rps (00:1e.0) - up1 - dp1
# (empty), dp2 (nicd2).
#   H  pcitest/hold_rescan_ms holds pci_rescan_remove_lock for 8 s.
#   R  the remover of up1 queues on the lock: var=sysfs: sysfs "remove" of
#      up1; var=locked: pcitest/remove_locked (unbinds under the lock, like
#      acpiphp or host bridge removal).
#   P  a NIC is hot-added on dp1: dp1's IRQ thread waits for the lock to
#      enumerate it.
# When H releases the lock, R unbinds dp1, whose pciehp_remove() waits in
# free_irq() for dp1's IRQ thread, which waits for the lock that R holds.
need $DBG/hold_rescan_ms || return
[ "$var" = locked ] && { need $DBG/remove_locked || return; }
wait_count $NIC_V $NIC_D 1 60 || { result "FAIL setup"; return; }
NICD2=$(devs $NIC_V $NIC_D)
DP2=$(port_of $NICD2)
UP1=$(port_of $DP2)
DP1=
for d in /sys/bus/pci/devices/$UP1/0*; do
	b=$(basename $d)
	[ -d /sys/bus/pci/devices/$b ] && [ "$b" != "$DP2" ] && [ -e /sys/bus/pci/devices/$b/subordinate_bus_number ] && DP1=$b
done
[ -n "$DP1" ] || { result "FAIL setup: no dp1"; return; }
log "up1=$UP1 dp1=$DP1 (empty) dp2=$DP2 nicd2=$NICD2 var=$var"
trace_on pciehp_configure_device pcie_shutdown_notification pci_stop_and_remove_bus_device
(echo 8000 > $DBG/hold_rescan_ms; log "H: released") &
sleep 0.3
if [ "$var" = locked ]; then
	( echo "$UP1 0" > $DBG/remove_locked; log "R: remove_locked returned" ) &
else
	( echo 1 > /sys/bus/pci/devices/$UP1/remove; log "R: sysfs remove returned" ) &
fi
R=$!
sleep 0.3
act add nicx dp1
# dp1's IRQ thread enumerates once the link is up; it must be waiting before H ends
sleep 5
dstacks "before H releases the lock"
if wait_exit $R 60; then
	o=PASS
else
	o=HANG
	dstacks "remover stuck after 60 s"
fi
sleep 2
n=$(devs $NIC_V $NIC_D | wc -l)
trace_dump | grep -v "^$" | tail -30
if [ $(nhung) -gt 0 ]; then
	result "FAIL hung tasks, $o devices=$n"
elif [ $o = PASS ] && [ $n -eq 0 ]; then
	result "PASS devices=0"
else
	result "FAIL $o devices=$n"
fi
lockdep_check
