# Slot resets racing hot-add under pci_rescan_remove_lock contention: hot-add
# NICs on rp1..rpN at once while reset_subordinate loops on rp2 for 4 s.
# The reset loop runs in the background so that a reset stuck in D state
# (v7.4-rc1: pci_slot_mutex vs reset_lock AB-BA) still yields a RESULT.
N=${n:-8}
RP=0000:00:11.0
act addall $N
(end=$(( $(date +%s) + 4 )); c=0
 while [ $(date +%s) -lt $end ]; do
	echo 1 2>/dev/null > /sys/bus/pci/devices/$RP/reset_subordinate; c=$((c + 1)); sleep 0.05
 done
 echo $c > /tmp/storm.count) &
RL=$!
stuck=0
wait_exit $RL 40 || { stuck=1; log "reset loop stuck"; }
c=$(cat /tmp/storm.count 2>/dev/null || echo "?")
log "reset_subordinate issued $c times"
if wait_count $NIC_V $NIC_D $N 40 && [ $stuck = 0 ]; then r="PASS"; else r="FAIL"; fi
retries=$(dmesg | grep -c "Reset during hot-add")
dstacks "end"
result "$r devices=$(devs $NIC_V $NIC_D | wc -l)/$N resets=$c retries=$retries hung=$(nhung) stuck=$stuck"
lockdep_check
