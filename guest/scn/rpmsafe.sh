# (fix tracking) Safe removal (slot "power" = 0) of a card on a slot without a
# power controller (harness/run.py: power_controller_present=off,
# pcie_port_pm=force) whose Root Port is runtime suspended.
# pciehp_disable_slot() runtime resumes the port; a fix for N18 that only
# queues a presence check on resume must not let the IRQ thread bring the
# slot up again afterwards (card present, slot off).
# The card (nic2 on rp2) is present at boot: a hot-add would show N1's lockdep
# report on v7.4-rc1-based trees, which turns lockdep off before the removal.
# var=rpm: port suspended (pcitest/rpm_allow); var=awake: control.
RP=0000:00:11.0 SLOT=2
need $DBG/rpm_allow || return
ST=/sys/bus/pci/devices/$RP/power/runtime_status
wait_count $NIC_V $NIC_D 1 10 || { result "FAIL setup: no NIC"; NO_ADDED_CHECK=1; return; }
B=$(devs $NIC_V $NIC_D)
wait_bound_dev $B 10
# Unbind the NIC and allow its runtime PM, so the port can suspend with the slot on
[ -e /sys/bus/pci/devices/$B/driver ] && echo $B > /sys/bus/pci/devices/$B/driver/unbind
echo on > /sys/bus/pci/devices/$B/power/control
echo auto > /sys/bus/pci/devices/$B/power/control
sleep 1
log "nic $B rpm=$(cat /sys/bus/pci/devices/$B/power/runtime_status)"
if [ "$var" = rpm ]; then
	echo $RP > $DBG/rpm_allow
	i=0; while [ "$(cat $ST)" != suspended ] && [ $i -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
fi
pst=$(cat $ST)
log "before: port $pst power $(cat /sys/bus/pci/slots/$SLOT/power) adapter $(cat /sys/bus/pci/slots/$SLOT/adapter)"
echo 0 > /sys/bus/pci/slots/$SLOT/power; rc=$?
log "power=0 rc=$rc"
sleep 5
n=$(devs $NIC_V $NIC_D | wc -l)
log "after: port $(cat $ST) power $(cat /sys/bus/pci/slots/$SLOT/power) adapter $(cat /sys/bus/pci/slots/$SLOT/adapter) devices=$n"
dmesg | grep -E "pciehp|Slot\(|rpm_allow" | tail -20
NO_ADDED_CHECK=1
[ $n -eq 0 ] && result "PASS STAYS-REMOVED port-was=$pst" || result "FAIL REENUMERATED devices=$n power=$(cat /sys/bus/pci/slots/$SLOT/power) port-was=$pst"
lockdep_check
