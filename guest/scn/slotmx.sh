# Pre-existing reset_lock <-> pci_slot_mutex inversion (pci_reset_bridge() vs
# pci_scan_slot()): reset_subordinate on empty rp2, then hot-add a NIC on rp2.
RP=0000:00:11.0
r=$(echo 1 2>&1 > /sys/bus/pci/devices/$RP/reset_subordinate); log "reset_subordinate on empty slot: ${r:-ok}"
act add nic2 rp2
if wait_count $NIC_V $NIC_D 1 30; then result "PASS device present"; else result "FAIL no device"; fi
sleep 2
lockdep_check
