# Nested hotplug ports: a switch with two hotplug downstream ports (NICs on both)
# below a root port.  Remove a NIC on a child port and the whole switch at nearly
# the same time, so the child port's IST may wait for pci_rescan_remove_lock while
# the parent removal unbinds the child port and waits for that IST in free_irq().
wait_count $NIC_V $NIC_D 2 60 || { result "FAIL setup"; return; }
act del nicd1
act del up1
sleep 45
n=$(devs $NIC_V $NIC_D | wc -l); dstacks "after 45 s"
if dmesg | grep -q "blocked for more than"; then
	result "FAIL hung tasks, devices=$n"
	dstacks "hung"
else
	result "PASS devices=$n"
fi
lockdep_check
