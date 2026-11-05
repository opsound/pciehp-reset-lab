# Three-party deadlock with a non-pciehp holder of pci_rescan_remove_lock: two
# vfio-pci NICs below two root ports, held by one process.  Dev A is removed
# through sysfs "remove" (which waits for the holder under the lock), then slot
# B is safely removed, then the holder is SIGKILLed (exit releases dev B first,
# whose reset needs B's reset_lock, held by irq/B waiting for the lock).
#   var=del	slot B removed with device_del (Attention Button, 5 s delay)
#   var=power	slot B removed with sysfs slot power=0 (immediate)
act add nic1 rp1
act add nic2 rp2
wait_count $NIC_V $NIC_D 2 60 || { result "FAIL setup: NICs not found"; return; }
set -- $(devs $NIC_V $NIC_D)
A=$1 B=$2
bind_vfio $A bus
bind_vfio $B bus
/bin/vtool hold $A $B > /tmp/h.out 2>&1 &
H=$!
sleep 1; cat /tmp/h.out
(echo 1 > /sys/bus/pci/devices/$A/remove; log "sysfs remove of $A returned") &
RM=$!
sleep 1
if [ "$var" = power ]; then
	(echo 0 > /sys/bus/pci/slots/2/power; log "power off slot 2 returned") &
	sleep 3
else
	act del nic2
	sleep 12
fi
dstacks "before kill"
kill -9 $H
if wait_exit $H 40 && wait_exit $RM 20; then
	sleep 3
	left=$(devs $NIC_V $NIC_D | wc -l)
	[ $left -eq 0 ] && result "PASS holder exited, devices removed" || result "FAIL holder exited, $left devices left"
else
	result "FAIL holder stuck"
	dstacks "after kill"
fi
cat /tmp/h.out
lockdep_check
