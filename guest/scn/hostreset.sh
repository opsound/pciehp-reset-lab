# Single-port AB-BA, emulating pci_host_reset_root_port(): a task takes
# pci_rescan_remove_lock, and 3 s later resets rp2's slot via pci_bus_error_reset(),
# while rp2's IST is hot-adding a NIC and waits for pci_rescan_remove_lock.
RP=0000:00:11.0
(echo "$RP 3000" > $DBG/host_reset; log "host_reset returned") &
HR=$!
sleep 0.5
act add nic2 rp2
if wait_exit $HR 30; then
	sleep 3
	n=$(devs $NIC_V $NIC_D | wc -l)
	[ $n -eq 1 ] && result "PASS host reset completed, device present" || result "FAIL host reset completed, devices=$n"
else
	result "FAIL host reset stuck"
	dstacks "stuck"
fi
lockdep_check
