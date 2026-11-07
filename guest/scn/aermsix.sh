# (N12) AER-style recovery of rp2 (pcitest/aer_reset: pcie_do_recovery()
# with pci_bus_error_reset(), no lock) while pciehp hot-adds a NIC on rp2.
# pcitest/aer_link_delay_ms makes the recovery sleep 5 s between its
# error_detected walk (rp2's bus is still empty) and the reset; pciehp adds
# and binds the NIC meanwhile.  The reset then resets the bound NIC, and the
# resume walk calls e1000e's ->resume() without ->error_detected():
# e1000e_pm_thaw() enables MSI-X again, which is still enabled (WARNING in
# __pci_enable_msix_range()), and the NIC loses the configuration the reset
# cleared.
# RESULT: FAIL WARN if a WARNING other than lockdep's was logged meanwhile.
RP=0000:00:11.0
need $DBG/aer_reset $DBG/aer_link_delay_ms || return
wait_msg() {	# PATTERN TIMEOUT_S
	local i=0
	while ! dmesg | grep -q "$1"; do
		[ $i -ge $(( $2 * 20 )) ] && return 1
		sleep 0.05; i=$((i + 1))
	done
}
# WARNINGs other than lockdep's (the first hot-add reports N1)
nwarn() { dmesg | grep "WARNING:" | grep -vcE "locking dependency|recursive locking"; }
W0=$(nwarn)
echo 5000 > $DBG/aer_link_delay_ms
(echo "$RP" > $DBG/aer_reset; log "R: aer_reset returned rc=$?") &
R=$!
wait_msg "aer_reset $RP: link delay" 10 || { result "FAIL no link delay"; return; }
log "R: error_detected walk done on the empty bus; hot-adding nic2"
act add nic2 rp2
wait_count $NIC_V $NIC_D 1 4 || log "NIC not enumerated before the reset"
D=$(devs $NIC_V $NIC_D)
[ -n "$D" ] && wait_bound_dev $D 3
log "before the reset: nic=$D driver=$( [ -n "$D" ] && drv_of $D)"
wait_exit $R 40 || { result "FAIL HANG recovery stuck"; dstacks "stuck"; echo 0 > $DBG/aer_link_delay_ms; return; }
echo 0 > $DBG/aer_link_delay_ms
sleep 2
dmesg | grep -E "WARNING:|pcitest|recovery" | tail -10
w=$(( $(nwarn) - W0 ))
msix=$(dmesg | grep "WARNING:" | grep -c "msi")
if [ $w -gt 0 ]; then
	result "FAIL WARN warnings=$w msix=$msix"
else
	result "PASS warnings=0"
fi
lockdep_check
