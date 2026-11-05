# Needs the TEST ONLY hooks (pcitest/add_delay_ms).
# Reset rp2's secondary bus (sysfs reset_subordinate -> pci_reset_bridge) while
# pciehp's IST is between list_add_tail() and device_add() of a hot-added NIC.
# var=win: reset inside the (test-widened) window; var=before: reset after the
# link check but before the scan.
need $DBG/add_delay_ms || return
RP=0000:00:11.0
F="pciehp_check_link_status pciehp_configure_device pci_scan_slot pci_bus_add_devices pciehp_reset_slot pci_bridge_secondary_bus_reset"
trace_on $F
[ "$var" = before0 ] && echo 0 > $DBG/add_delay_ms || echo 3000 > $DBG/add_delay_ms
act add nic2 rp2
i=0
if [ "$var" = win ]; then
	while ! dmesg | grep -q "pcitest: add delay .* ms" && [ $i -lt 1000 ]; do sleep 0.01; i=$((i + 1)); done
	sleep 0.2
	log "IST inside list_add..device_add window; resetting $RP"
else
	while ! grep -q pciehp_check_link_status $T/trace && [ $i -lt 1000 ]; do sleep 0.01; i=$((i + 1)); done
	log "link check seen; resetting $RP"
fi
(r=$(echo 1 2>&1 > /sys/bus/pci/devices/$RP/reset_subordinate); log "reset_subordinate done: ${r:-ok}") &
RS=$!
if ! wait_exit $RS 45; then
	log "reset still blocked after 45 s"
	dstacks "after 45 s"
	o="FAIL HANG"
else
	o=OK
fi
sleep 2
n=$(devs $NIC_V $NIC_D | wc -l)
trace_dump | tail -20
dmesg | grep -E "e1000e 0000:02|probe with driver" | head
ls -l /sys/bus/pci/devices/0000:02:00.0/driver 2>&1 | head -1
[ -e /sys/bus/pci/devices/0000:02:00.0 ] && { bar_ok 0000:02:00.0; log "02:00.0 $BAR_INFO"; }	# bounded: config reads block behind a stuck reset
echo 0 > $DBG/add_delay_ms
result "$o devices=$n"
lockdep_check
