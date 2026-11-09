# (N26, N27) Slots without function 0 when hypervisor_isolated_pci_functions()
# is true, as on s390, LoongArch and Jailhouse: pci_scan_slot() then scans
# functions 1-7 although function 0 is absent.  The guest gets Jailhouse's
# CPUID signature (harness/run.py "isolfn"; needs CONFIG_JAILHOUSE_GUEST, the
# -jh kernels).  The NIC's function 1 is 01:00.1, below rp1 (00:10.0).
#   var=resume  (N27; pcie_aspm=off) 01:00.1 alone present at boot, slot
#               without power controller; s2idle with pm_test=platform:
#               pciehp_resume_noirq() asks pciehp_device_replaced(), which
#               looks up 00.0 only.  PASS: the slot is not torn down and
#               01:00.1 stays bound.
#   var=vanish  (N27, hooks; pcie_aspm=off) a NIC with functions 0 and 1 is
#               hot-added (QEMU exposes a hot-added function only once function
#               0 is there); pciehp test_hide_fn0 makes 00.0 vanish after
#               pciehp_check_link_status() found it, right before
#               pci_scan_slot(), so the scan finds 01:00.1 only and
#               pciehp_configure_device() reads the DSN of pci_get_slot(00.0).
#               PASS: no oops, 01:00.1 bound, then safely removed.
#      vanish-aspm  (N26) the same with ASPM on: pci_scan_slot() calls
#               pcie_aspm_init_link_state(rp1), whose link->downstream from
#               pci_function_0() is NULL.
#   var=boot-aspm  (N26) 01:00.1 alone present at boot, ASPM on: the boot scan
#               oopses the same way and kills init, so the guest never gets
#               here (the harness counts that as a boot failure, not a
#               symptom: no test uses it; see serial.log).
# Without the Jailhouse signature, vanish finds no device ("No new device
# found"), and resume skips: 01:00.1 is not enumerated at boot.
B=0000:01:00.1 SLOT=1
NO_ADDED_CHECK=1
log "$(dmesg | grep -m1 'Hypervisor detected')"
bdump() { dmesg | grep -A24 -m1 -E "BUG: kernel NULL|general protection" | head -26; }
oops() { dmesg | grep -qE "BUG:|Oops"; }
case $var in
boot-aspm)
	result "PASS booted with $B $([ -e /sys/bus/pci/devices/$B ] && echo present || echo absent)"
	;;
resume)
	if [ ! -e /sys/bus/pci/devices/$B ]; then
		result "SKIP no $B at boot (functions not isolated)"
		return
	fi
	wait_bound_dev $B 10
	log "before: $B driver=$(drv_of $B)"
	n0=$(dmesg | grep -c "Slot($SLOT): Card not present")
	echo platform > /sys/power/pm_test
	rm -f /tmp/sus
	( echo freeze > /sys/power/state; echo "rc=$?" > /tmp/sus ) &
	pid=$!
	if ! wait_exit $pid 60; then
		dstacks "suspend stuck"
		result "FAIL STUCK suspend did not return in 60 s"
		lockdep_check
		return
	fi
	echo none > /sys/power/pm_test
	log "suspend $(cat /tmp/sus)"
	# pciehp's IRQ thread handles a teardown after resume: let it finish.
	sleep 5
	wait_bound_dev $B 10
	n1=$(dmesg | grep -c "Slot($SLOT): Card not present")
	bdump
	dmesg | grep -E "pciehp|Slot\(" | tail -12
	st="$B $([ -e /sys/bus/pci/devices/$B ] && echo "driver=$(drv_of $B)" || echo missing)"
	if [ $n1 -gt $n0 ]; then
		result "FAIL REMOVED-ON-RESUME $st"
	elif [ "$(drv_of $B)" = e1000e ]; then
		result "PASS kept $st"
	else
		result "FAIL $st"
	fi
	;;
vanish|vanish-aspm)
	need $KNOBS/test_hide_fn0 || return
	echo 1 > $KNOBS/test_hide_fn0
	act qmp device_add '{"driver": "e1000e", "id": "f1", "bus": "rp1", "addr": "0.1"}'
	sleep 1
	act qmp device_add '{"driver": "e1000e", "id": "f0", "bus": "rp1", "addr": "0.0", "multifunction": true}'
	i=0; while [ "$(drv_of $B)" != e1000e ] && ! oops && [ $i -lt 300 ]; do sleep 0.1; i=$((i + 1)); done
	sleep 1
	bdump
	dmesg | grep -E "pciehp|Slot\(|0000:01:00" | tail -14
	if oops; then
		result "FAIL OOPS $(dmesg | grep -m1 -oE 'RIP: [^ ]+')"
	elif [ "$(drv_of $B)" != e1000e ]; then
		result "FAIL $B $([ -e /sys/bus/pci/devices/$B ] && echo "driver=$(drv_of $B)" || echo missing)"
	else
		# Safe removal of the slot, with 00.0 still absent for the kernel
		act del f0
		i=0; while [ -e /sys/bus/pci/devices/$B ] && [ $i -lt 300 ]; do sleep 0.1; i=$((i + 1)); done
		dmesg | grep -E "pciehp|Slot\(" | tail -4
		if [ -e /sys/bus/pci/devices/$B ]; then
			result "FAIL STUCK safe removal of $B did not finish in 30 s"
		else
			result "PASS hot-added $B without 00.0, then removed"
		fi
	fi
	;;
*)
	result "FAIL unknown var $var"
	;;
esac
lockdep_check
