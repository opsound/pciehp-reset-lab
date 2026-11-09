# Three-party deadlock with SR-IOV disable as the pci_rescan_remove_lock holder: an igb
# PF on rp1 with 2 VFs, VF 0 bound to vfio-pci, and a vfio-pci NIC (dev B) on rp2, both
# held by one process.  sriov_numvfs=0 waits for the VF to be released, dev B is safely
# removed through slot "power", then the holder is SIGKILLed (exit releases dev B first).
PF_D=0x10c9 VF_D=0x10ca
act add pf1 rp1 igb
act add nic2 rp2
wait_count $NIC_V $PF_D 1 60 || { result "FAIL setup: PF not found"; return; }
wait_count $NIC_V $NIC_D 1 60 || { result "FAIL setup: NIC not found"; return; }
PF=$(devs $NIC_V $PF_D) B=$(devs $NIC_V $NIC_D)
# sriov_numvfs needs a bound PF driver ("no driver bound to device")
wait_bound_dev $PF 30 || { result "FAIL setup: igb not bound to $PF"; return; }
echo 2 > /sys/bus/pci/devices/$PF/sriov_numvfs
wait_count $NIC_V $VF_D 2 30 || { result "FAIL setup: VFs not found"; return; }
VF=$(devs $NIC_V $VF_D | head -1)
bind_vfio $VF
bind_vfio $B bus
/bin/vtool hold $VF $B > /tmp/h.out 2>&1 &
H=$!
sleep 1; cat /tmp/h.out
(echo 0 > /sys/bus/pci/devices/$PF/sriov_numvfs; log "sriov_numvfs=0 returned") &
sleep 1
(echo 0 > /sys/bus/pci/slots/2/power; log "power off slot 2 returned") &
sleep 3
dstacks "before kill"
kill -9 $H
if wait_exit $H 40; then
	# The removals finish once the holder is gone; 30 s covers a heavily
	# loaded host.
	left() { echo $(( $(devs $NIC_V $VF_D | wc -l) + $(devs $NIC_V $NIC_D | wc -l) )); }
	t0=$(up)
	while [ $(left) -gt 0 ] && awk "BEGIN{exit !($(up) - $t0 < 30)}"; do sleep 0.2; done
	log "$(left) devices left $(awk "BEGIN{printf \"%.1f\", $(up) - $t0}") s after the holder exited"
	[ $(left) -eq 0 ] && result "PASS holder exited, VFs and dev B removed" || result "FAIL holder exited, $(left) devices left after 30 s"
else
	result "FAIL holder stuck"
	dstacks "after kill"
fi
lockdep_check
