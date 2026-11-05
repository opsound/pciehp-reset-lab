# Reset during enumeration: pciehp sleeps (test knob) with reset_lock held right
# before (var=pre) or after (var=post) pci_scan_slot.  Hot-add a NIC on rp2 and
# reset rp2's secondary bus through sysfs while pciehp sleeps.
need $KNOBS/test_pre_scan_ms $KNOBS/test_post_scan_ms || return
F="pciehp_configure_device pci_scan_slot pci_bus_add_devices pciehp_reset_slot pci_bridge_secondary_bus_reset pci_save_state pci_restore_state pci_dev_trylock pci_dev_unlock pci_dev_lock e1000_probe pci_dev_assign_slot"
trace_on $F
RP=0000:00:11.0
P=/sys/module/pciehp/parameters
if [ "$var" = post ]; then echo 3000 > $P/test_post_scan_ms; else echo 3000 > $P/test_pre_scan_ms; fi
act add nic2 rp2
i=0
while ! dmesg | grep -q "test: sleeping" && [ $i -lt 1000 ]; do sleep 0.01; i=$((i + 1)); done
sleep 0.5
log "pciehp sleeps with reset_lock held ($var scan); resetting $RP"
(r=$(echo 1 2>&1 > /sys/bus/pci/devices/$RP/reset_subordinate); log "reset_subordinate done: ${r:-ok}") &
RS=$!
wait_exit $RS 40 || { log "reset still blocked"; dstacks "reset blocked"; }
sleep 5
trace_dump > /tmp/tr
cat /tmp/tr
n=$(devs $NIC_V $NIC_D | wc -l)
drv=none
for b in $(devs $NIC_V $NIC_D); do
	[ -e /sys/bus/pci/devices/$b/driver ] && drv=$(basename "$(readlink /sys/bus/pci/devices/$b/driver)")
done
if dmesg | grep -q "blocked for more than"; then o=HUNG; elif alive $RS; then o=RESET-STUCK; else o=COMPLETED; fi
# A completed run passes only if the hot-added NIC is bound with BAR0 intact.
v=FAIL
if [ $o = COMPLETED ] && [ $n -ge 1 ] && [ $drv = e1000e ]; then
	v=PASS
	for b in $(devs $NIC_V $NIC_D); do bar_ok $b || { v=FAIL; o="$o BAR-LOST"; }; done
fi
result "$v $o devices=$n driver=$drv var=$var"
dmesg | grep -iE "e1000e|0000:02:00" | tail -8
lockdep_check
