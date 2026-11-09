# A PF driver that enables SR-IOV in ->probe() (igb.max_vfs=2) on a device
# with a NUMA node.  pci_call_probe() then runs the probe in pci_probe_wq on
# that node and waits in flush_work(), while the caller (pciehp hot-add, sysfs
# rescan) holds pci_rescan_remove_lock.  A fix that takes the lock while
# adding VFs (sriov_add_vfs()) must not deadlock here: the worker is not the
# task that holds the lock.  Topology (harness/run.py): two NUMA nodes, a
# pxb-pcie host bridge on node 1 with a hotplug Root Port rpn.
#   var=pciehp  (default) hot-add igb on rpn
#   var=rescan  igb on rpn at boot; sysfs remove of the PF, then bus rescan
# PASS: the PF's two VFs appear within 40 s.
PF_D=0x10c9 VF_D=0x10ca
NO_ADDED_CHECK=1
case $var in
pciehp)
	act add pf1 rpn igb
	wait_count $NIC_V $PF_D 1 60 || { result "FAIL setup: no PF"; return; }
	;;
rescan)
	wait_count $NIC_V $PF_D 1 30 || { result "FAIL setup: no PF"; return; }
	PF=$(devs $NIC_V $PF_D)
	wait_count $NIC_V $VF_D 2 20 || { result "FAIL setup: no VFs at boot probe"; return; }
	log "boot: PF=$PF node=$(cat /sys/bus/pci/devices/$PF/numa_node) VFs: $(devs $NIC_V $VF_D | tr '\n' ' ')"
	echo 1 > /sys/bus/pci/devices/$PF/remove
	wait_count $NIC_V $PF_D 0 20 || { result "FAIL setup: PF not removed"; return; }
	log "R: rescan"
	( echo 1 > /sys/bus/pci/rescan; log "R: rescan returned" ) &
	wait_count $NIC_V $PF_D 1 30 || { result "FAIL no PF after rescan"; return; }
	;;
*) result "FAIL unknown var $var"; return ;;
esac
PF=$(devs $NIC_V $PF_D)
log "PF=$PF numa_node=$(cat /sys/bus/pci/devices/$PF/numa_node)"
if wait_count $NIC_V $VF_D 2 40; then o=PASS; else o=HANG; dstacks "stuck"; fi
sleep 1
result "$o pf=$PF node=$(cat /sys/bus/pci/devices/$PF/numa_node) drv=$(drv_of $PF) vfs=$(devs $NIC_V $VF_D | wc -l) hung=$(nhung)"
lockdep_check
