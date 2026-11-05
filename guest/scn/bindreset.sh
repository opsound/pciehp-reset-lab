# var=dS: wait S s after the link check before the reset (default 0).
# Reset during hot-add with pci_rescan_remove_lock uncontended: hot-add a NIC on
# rp2 and, as soon as its IST is in pciehp_check_link_status (reset_lock held for
# reading), reset rp2's secondary bus through sysfs.  The reset locks the still
# empty slot and waits for reset_lock, which pciehp drops after the scan to bind
# drivers.  Report the order and whether the NIC's config space survived.
F="pciehp_check_link_status pciehp_configure_device pci_scan_slot pci_bus_add_devices pci_bus_add_device e1000_probe pciehp_reset_slot pci_reset_secondary_bus pci_try_reset_slot pci_bridge_wait_for_secondary_bus"
trace_on $F
RP=0000:00:11.0
DELAY=${var#d}
[ "$DELAY" = "$var" ] && DELAY=0
act add nic2 rp2
i=0
while ! grep -q pciehp_check_link_status $T/trace && [ $i -lt 2000 ]; do sleep 0.005; i=$((i + 1)); done
[ "$DELAY" != 0 ] && sleep $DELAY
log "link check seen; resetting $RP"
(r=$(echo 1 2>&1 > /sys/bus/pci/devices/$RP/reset_subordinate); log "reset_subordinate done: ${r:-ok}") &
RS=$!
wait_exit $RS 30 || { log "reset still blocked"; dstacks blocked; }
sleep 3
trace_dump > /tmp/tr
cat /tmp/tr
B=$(devs $NIC_V $NIC_D | head -1)
drv=none
[ -n "$B" ] && [ -e /sys/bus/pci/devices/$B/driver ] && drv=$(basename "$(readlink /sys/bus/pci/devices/$B/driver)")
cmdreg=$(cfg $B COMMAND 2>/dev/null); bar0=$(cfg $B BASE_ADDRESS_0 2>/dev/null)
res0=$(head -1 /sys/bus/pci/devices/$B/resource 2>/dev/null)
log "nic=$B driver=$drv COMMAND=$cmdreg BAR0=$bar0 resource0=$res0"
ls /sys/class/net 2>/dev/null
dmesg | grep -iE "e1000e|pciehp|reset|0000:01:00|0000:02:00" | tail -40
scan=$(grep -n pci_scan_slot /tmp/tr | head -1 | cut -d: -f1)
add=$(grep -n "pci_bus_add_devices" /tmp/tr | head -1 | cut -d: -f1)
probe=$(grep -n "e1000_probe" /tmp/tr | head -1 | cut -d: -f1)
sbr=$(grep -n pci_reset_secondary_bus /tmp/tr | head -1 | cut -d: -f1)
log "lines: scan=$scan add=$add probe=$probe sbr=$sbr"
o="ORDER"
[ -n "$sbr" ] && [ -n "$scan" ] && [ "$sbr" -gt "$scan" ] && o="SBR-AFTER-SCAN"
[ -n "$sbr" ] && [ -n "$scan" ] && [ "$sbr" -lt "$scan" ] && o="SBR-BEFORE-SCAN"
case "$bar0" in 00000000|"") ok=BAR0-LOST;; *) ok=BAR0-OK;; esac
case "$cmdreg" in 0000|"") ok="$ok CMD-LOST";; *) ok="$ok CMD-$cmdreg";; esac
# The hot-added NIC must survive with its config space and driver.
v=PASS
case "$ok" in *LOST*) v=FAIL;; esac
[ "$drv" = e1000e ] || v=FAIL
alive $RS && { v=FAIL; ok="$ok RESET-STUCK"; }
result "$v $o $ok driver=$drv"
lockdep_check
