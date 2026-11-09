# vfio-pci: closing a PF that user space left in D3hot races enabling SR-IOV
# on it (the race of "vfio/pci: Fix power state race with SR-IOV enablement",
# 20261029203324.1637772-1-dmatlack@google.com).
#
# vfio_pci_core_disable() calls vfio_pci_set_power_state(PCI_D0) without
# memory_lock; vfio_pci_core_sriov_configure() makes the same D3hot->D0
# transition under it.  The PMCSR write leaves the device RPM_ACTIVE, so
# pm_runtime_resume() in the close path doesn't return it to D0 first.  igb is
# NoSoftRst- (needs_pm_restore): the close-time transition can restore the
# PF's BARs after VFs were enabled ("can't update enabled VF BAR", WARN in
# pci_iov_update_resource()), or both threads free vdev->pm_save.
#
# Setup (run.py): igb PF "pf1" present at boot on rp1, so that no pciehp
# hot-add precedes the test (N1's lockdep report turns lockdep off).  The PF
# is bound to vfio-pci with enable_sriov=Y and sriov_drivers_autoprobe=0.
# Then "pmrace a PF": a rounds of D3hot through the vfio config region, close
# of the device fd, and sriov_numvfs=1 from a second thread 2.0-6.5 ms into
# the close (tools/pmrace.c), then sriov_numvfs=0.
# FAIL: any new WARNING, KASAN report, BUG, a close that left the device
# outside D0, or a failed sriov_numvfs write (-EIO: a VF that enumerated with
# header type 0x7f).
PF_D=0x10c9
ROUNDS=${a:-10}
wait_count $NIC_V $PF_D 1 60 || { result "FAIL setup: PF not found"; return; }
PF=$(devs $NIC_V $PF_D)
echo 0 > /sys/bus/pci/devices/$PF/sriov_drivers_autoprobe
echo Y > /sys/module/vfio_pci/parameters/enable_sriov
bind_vfio $PF
w0=$(cat /sys/kernel/warn_count 2>/dev/null || echo 0)
k0=$(dmesg | grep -c "BUG: KASAN")
/bin/pmrace $ROUNDS $PF > /tmp/pm.out 2>&1 &
P=$!
if ! wait_exit $P $((ROUNDS * 15 + 30)); then
	cat /tmp/pm.out
	dstacks "pmrace stuck"
	result "FAIL pmrace stuck"
	lockdep_check
	return
fi
cat /tmp/pm.out
w1=$(cat /sys/kernel/warn_count 2>/dev/null || echo 0)
k1=$(dmesg | grep -c "BUG: KASAN")
vfbar=$(dmesg | grep -c "can't update enabled VF BAR")
line=$(grep '^PMRACE' /tmp/pm.out)
notd0=$(echo "$line" | sed -n 's/.*not_d0=\([0-9]*\).*/\1/p')
wr=$(echo "$line" | sed -n 's/.*warn_rounds=\([0-9]*\).*/\1/p')
nerr=$(echo "$line" | sed -n 's/.*numvfs_err=\([0-9]*\).*/\1/p')
log "warn_count $w0 -> $w1, vf-bar warnings $vfbar, kasan $((k1 - k0)), $line"
if [ -z "$line" ]; then
	result "FAIL pmrace did not finish"
elif [ $((w1 - w0)) -ne 0 ] || [ $((k1 - k0)) -ne 0 ] || [ "${notd0:-1}" -ne 0 ] || [ "${nerr:-1}" -ne 0 ]; then
	result "FAIL warnings=$((w1 - w0)) in ${wr:-?}/$ROUNDS rounds vf-bar=$vfbar kasan=$((k1 - k0)) not-d0=${notd0:-?} numvfs-err=${nerr:-?}"
else
	result "PASS warnings=0 kasan=0 not-d0=0 numvfs-err=0 rounds=$ROUNDS"
fi
lockdep_check
