# (fix tracking) The real pci-host-common link-down recovery
# (pcitest/link_down, kernels built with configs/hc.config) of the Root Ports
# while rp2's IRQ thread hot-adds a NIC: the recovery is issued as soon as
# pciehp starts the link check.  A fix for N2 that takes the reset out of
# pci_rescan_remove_lock must still leave the NIC present, bound and with its
# BARs intact (the added check).
need $DBG/link_down || return
trace_on pciehp_check_link_status pciehp_configure_device pci_scan_slot pci_bus_add_devices pciehp_reset_slot
RP=0000:00:11.0
act add nic2 rp2
i=0
while ! grep -q pciehp_check_link_status $T/trace && [ $i -lt 500 ]; do sleep 0.005; i=$((i + 1)); done
log "link check seen; link-down recovery of the Root Ports"
(echo "$RP 0" > $DBG/link_down; log "link_down returned") &
HR=$!
if wait_exit $HR 30; then
	sleep 3
	n=$(devs $NIC_V $NIC_D | wc -l)
	trace_dump | tail -20
	[ $n -eq 1 ] && result "PASS recovery completed, device present" || result "FAIL recovery completed, devices=$n"
else
	result "FAIL recovery stuck"
	dstacks "stuck"
fi
lockdep_check
