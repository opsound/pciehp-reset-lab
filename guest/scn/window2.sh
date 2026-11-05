# Slot reset during hot-add, through ->reset_slot() only (no pci_slot_mutex).
#   var=hold	pci_rescan_remove_lock held by another task for 6 s (contended)
#   var=nohold	uncontended
# Report whether the reset ran before or after the scan, how many link checks
# pciehp did, and whether the device was enumerated.
F="pciehp_check_link_status pciehp_configure_device pci_scan_slot pci_bus_add_devices pciehp_reset_slot pci_bridge_secondary_bus_reset pci_lock_rescan_remove"
trace_on $F
RP=0000:00:11.0
if [ "$var" = hold ]; then
	(echo 6000 > $DBG/hold_rescan_ms; log "hold done") &
	HP=$!
	sleep 0.5
fi
act add nic2 rp2
i=0
while ! grep -q pciehp_check_link_status $T/trace && [ $i -lt 300 ]; do sleep 0.01; i=$((i + 1)); done
log "link check seen; resetting slot of $RP"
(echo $RP > $DBG/slot_reset; log "slot_reset done") &
RS=$!
[ -n "$HP" ] && wait $HP
wait_exit $RS 30 || log "reset still blocked"
sleep 5
trace_dump > /tmp/tr
cat /tmp/tr
scan=$(grep -n pci_scan_slot /tmp/tr | head -1 | cut -d: -f1)
rst=$(grep -n pciehp_reset_slot /tmp/tr | head -1 | cut -d: -f1)
nchk=$(grep -c pciehp_check_link_status /tmp/tr)
n=$(devs $NIC_V $NIC_D | wc -l)
if [ -z "$rst" ]; then o="NO-RESET"
elif [ -z "$scan" ]; then o="NO-SCAN"
elif [ "$rst" -lt "$scan" ]; then o="RESET-BEFORE-SCAN"
else o="RESET-AFTER-SCAN"; fi
result "$o linkchecks=$nchk devices=$n"
dmesg | grep -E "pcitest|pciehp" | tail -20
lockdep_check
