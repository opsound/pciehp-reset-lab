# Slot lifetime: while pciehp on rp2 is busy enumerating (test knob, 4 s), unbind
# pcieport from rp2 (pciehp_remove() then waits for the IST in free_irq() with
# rp2 locked) and issue an AER-style pci_bus_error_reset() of rp2, which probes the
# slot and then blocks on rp2's device lock until pciehp_remove() has destroyed
# the slot and freed the controller.
need $KNOBS/test_pre_scan_ms $KNOBS/test_error_reset || return
F="pciehp_configure_device pci_scan_slot pciehp_reset_slot pci_bridge_secondary_bus_reset pciehp_remove pci_hp_destroy pci_destroy_slot"
trace_on $F
RP=0000:00:11.0
P=/sys/module/pciehp/parameters
echo 4000 > $P/test_pre_scan_ms
act add nic2 rp2
i=0
while ! dmesg | grep -q "test: sleeping" && [ $i -lt 1000 ]; do sleep 0.01; i=$((i + 1)); done
sleep 0.3
log "pciehp busy; unbinding pcieport from $RP"
(echo $RP > /sys/bus/pci/drivers/pcieport/unbind; log "unbind done") &
UB=$!
sleep 0.5
log "pci_bus_error_reset($RP)"
(echo $RP > $P/test_error_reset; log "error reset returned") &
ER=$!
ok=1
wait_exit $UB 40 || { log "unbind stuck"; ok=0; }
wait_exit $ER 40 || { log "error reset stuck"; ok=0; }
[ $ok = 1 ] || dstacks "stuck"
sleep 3
trace_dump
dmesg | grep -E "pciehp test|KASAN" | head
n=$(devs $NIC_V $NIC_D | wc -l)
ls /sys/bus/pci/slots/
if dmesg | grep -q "BUG: KASAN"; then o=KASAN; elif dmesg | grep -q "blocked for more than"; then o=HUNG; elif [ $ok = 1 ]; then o=COMPLETED; else o=STUCK; fi
result "$o devices=$n slots=$(ls /sys/bus/pci/slots | tr '\n' ' ')"
lockdep_check
