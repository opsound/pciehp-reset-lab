# (fix tracking) A PF driver that enables SR-IOV in ->probe() (igb.max_vfs=2,
# harness/run.py) adds its VFs under the PF's device_lock.  A fix for N13 or
# N21 that takes pci_rescan_remove_lock when adding VFs must not deadlock a
# sysfs bind of the PF with a remover that holds that lock and waits for the
# PF's device_lock (pcitest/remove_locked).  pcitest/probe_delay_ms keeps the
# probe (device_lock held) busy for 3 s.
PF_D=0x10c9 VF_D=0x10ca
need $DBG/probe_delay_ms $DBG/remove_locked || return
act add pf1 rp1 igb
wait_count $NIC_V $PF_D 1 60 || { result "FAIL setup: no PF"; return; }
PF=$(devs $NIC_V $PF_D)
wait_bound_dev $PF 10
wait_count $NIC_V $VF_D 2 20 || { result "FAIL setup: no VFs at probe (igb.max_vfs?)"; return; }
log "PF=$PF driver=$(drv_of $PF) VFs: $(devs $NIC_V $VF_D | tr '\n' ' ')"
echo $PF > /sys/bus/pci/devices/$PF/driver/unbind
wait_count $NIC_V $VF_D 0 20 || { result "FAIL setup: VFs left after unbind"; return; }
sleep 0.5
echo 3000 > $DBG/probe_delay_ms
log "B: bind $PF to igb (probe sleeps 3 s with device_lock held)"
( echo $PF > /sys/bus/pci/drivers/igb/bind; log "B: bind returned" ) &
B=$!
sleep 1
log "R: remove_locked $PF (holds pci_rescan_remove_lock, waits for device_lock(PF))"
( echo "$PF 0" > $DBG/remove_locked; log "R: remove_locked returned" ) &
R=$!
if wait_exit $B 40 && wait_exit $R 20; then o=PASS; else o=HANG; dstacks "stuck"; fi
sleep 1
result "$o pf=$(devs $NIC_V $PF_D | wc -l) vfs=$(devs $NIC_V $VF_D | wc -l) hung=$(nhung)"
lockdep_check
