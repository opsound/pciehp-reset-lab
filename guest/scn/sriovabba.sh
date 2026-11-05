# ABBA between removal of a PF with VFs and sriov_numvfs_store(0).
#   var=sysfs: remover is sysfs "remove" of the PF;  var=pciehp: remover is pciehp (device_del)
PF_V=0x8086 PF_D=0x10c9 VF_D=0x10ca
act add pf1 rp1 igb
wait_count $PF_V $PF_D 1 60 || { result "FAIL setup: no PF"; return; }
PF=$(devs $PF_V $PF_D)
sleep 2
echo 2 > /sys/bus/pci/devices/$PF/sriov_numvfs
sleep 2
log "PF=$PF driver=$(basename "$(readlink /sys/bus/pci/devices/$PF/driver)") VFs: $(devs $PF_V $VF_D | tr '\n' ' ')"
for v in $(devs $PF_V $VF_D); do log "VF $v driver=$(basename "$(readlink /sys/bus/pci/devices/$v/driver)")"; done
if [ "$var" = pciehp ]; then
	log "W: device_del pf1 (attention button, 5 s)"
	act del pf1
	sleep 4.2
	log "H: hold pci_rescan_remove_lock 4 s"
	echo 4000 > $DBG/hold_rescan_ms &
	sleep 1.8
else
	log "H: hold pci_rescan_remove_lock 4 s"
	echo 4000 > $DBG/hold_rescan_ms &
	sleep 0.5
	log "W: sysfs remove $PF"
	( echo 1 > /sys/bus/pci/devices/$PF/remove; log "W: remove returned" ) &
	sleep 0.5
fi
log "X: sriov_numvfs=0"
( echo 0 > /sys/bus/pci/devices/$PF/sriov_numvfs; log "X: sriov_numvfs returned" ) &
sleep 40
dstacks "final"
if dmesg | grep -q "blocked for more than"; then
	result "FAIL hung tasks"
else
	result "PASS PFs=$(devs $PF_V $PF_D | wc -l) VFs=$(devs $PF_V $VF_D | wc -l)"
fi
lockdep_check
