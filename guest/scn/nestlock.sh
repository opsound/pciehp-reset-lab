# Lockdep with nested hotplug ports: re-enumerate a switch through sysfs rescan
# (child ports' pciehp probe runs under pci_rescan_remove_lock), then hot-remove
# and hot-add a NIC on a child port (child IST takes the locks itself).
wait_count $NIC_V $NIC_D 2 60 || { result "FAIL setup"; return; }
set -- $(devs $NIC_V $NIC_D)
DP=$(port_of $1); UP=$(port_of $DP)
log "nic $1 dp $DP up $UP"
echo 1 > /sys/bus/pci/devices/$UP/remove
wait_count $NIC_V $NIC_D 0 30 || log "switch removal incomplete"
echo 1 > /sys/bus/pci/rescan
wait_count $NIC_V $NIC_D 2 60 || { result "FAIL rescan"; return; }
sleep 2
act del nicd1
wait_count $NIC_V $NIC_D 1 30 || { result "FAIL child removal"; return; }
sleep 3
act add nicd3 dp1
wait_count $NIC_V $NIC_D 2 60 || { result "FAIL child hot-add"; return; }
sleep 2
c=$(dmesg | grep -cE "possible circular|possible recursive")
[ $c -eq 0 ] && result "PASS no lockdep report" || result "LOCKDEP $c report(s)"
dmesg | grep -A12 "possible circular" | head -40
lockdep_check
