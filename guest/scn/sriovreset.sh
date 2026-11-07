# sriov_numvfs_store() vs resets of the Root Port above the PF.
# sriov_numvfs_store() holds the PF's device_lock while it enables or disables
# VFs, which takes pci_rescan_remove_lock and, to add or remove a VF,
# pci_bus_sem for writing.
#   var=walk       (N11) igb PF present at boot on rpc, a Root Port without a
#                  hotplug slot (harness/run.py), so that the reset is a plain
#                  bus reset.  A loop of AER-style recoveries of rpc
#                  (pcitest/aer_reset: pcie_do_recovery(), no lock) vs a
#                  sriov_numvfs 2/0 loop, a= seconds.  The recovery's walks hold
#                  pci_bus_sem for reading and take each device's device_lock.
#   var=hostreset  (N20) PF hot-added on rp1, then pcitest/host_reset of rp1
#                  holds pci_rescan_remove_lock for 3 s before
#                  pci_bus_error_reset(), as pci_host_reset_root_port() does;
#                  sriov_numvfs=2 is written meanwhile.
#   var=linkdown   (N20) PF hot-added on rp1; a loop of the real pci-host-common
#                  link-down recovery (pcitest/link_down, kernels built with
#                  configs/hc.config) vs a sriov_numvfs 2/0 loop, a= seconds.
# RESULT: HANG if the tasks stop making progress for 25 s (loops) or don't
# return (hostreset); cycle= names the dependency the stuck tasks show.
PF_D=0x10c9 VF_D=0x10ca MS=3000
case $var in
walk) need $DBG/aer_reset || return ;;
hostreset) need $DBG/host_reset || return ;;
linkdown) need $DBG/link_down || return ;;
*) result "FAIL unknown var $var"; return ;;
esac
[ $var = walk ] || act add pf1 rp1 igb
wait_count $NIC_V $PF_D 1 60 || { result "FAIL setup: no PF"; return; }
PF=$(devs $NIC_V $PF_D)
RP=$(port_of $PF)
SV=/sys/bus/pci/devices/$PF/sriov_numvfs
wait_bound_dev $PF 10 || { result "FAIL setup: PF unbound"; return; }
sleep 1
log "PF $PF ($(drv_of $PF)) port $RP slots: $(for s in /sys/bus/pci/slots/*; do echo -n "$(basename $s)=$(cat $s/address) "; done)"

# cycle: which dependency the stuck reset (pid $1) and SR-IOV (pid $2) tasks show
cycle() {
	local rs ss
	rs=$(cat /proc/$1/stack 2>/dev/null) ss=$(cat /proc/$2/stack 2>/dev/null)
	if echo "$rs" | grep -q "report_" &&
	   echo "$ss" | grep -qE "pci_device_add|pci_remove_bus_device|pci_destroy_dev|pci_stop_bus_device"; then
		echo walk	# walk holds pci_bus_sem, waits for the PF; S waits for pci_bus_sem
	elif echo "$rs" | grep -qE "pci_bus_lock|pci_slot_reset|pci_slot_lock" &&
	     echo "$ss" | grep -q sriov_numvfs_store && ! echo "$ss" | grep -qE "sriov_(enable|disable)"; then
		echo rescan_lock	# reset holds the lock, waits for the PF; S waits for the lock
	elif echo "$ss" | grep -q pci_dev_assign_slot; then
		echo slot_mutex
	else
		echo other
	fi
}

cyc=-
case $var in
hostreset)
	( echo "$RP $MS" > $DBG/host_reset; log "H: host_reset returned rc=$?" ) &
	H=$!
	sleep 0.5
	log "S: sriov_numvfs=2"
	( echo 2 > $SV; log "S: sriov_numvfs=2 returned rc=$?" ) &
	S=$!
	if wait_exit $H $((MS / 1000 + 45)) && wait_exit $S 20; then
		o=PASS
	else
		o=HANG
		cyc=$(cycle $H $S)
		dstacks "stuck"
		i=0; while [ "$(nhung)" -eq 0 ] && [ $i -lt 30 ]; do sleep 1; i=$((i + 1)); done
	fi
	NO_ADDED_CHECK=1	# the raw reset doesn't restore the PF
	;;
walk|linkdown)
	hook=aer_reset; [ $var = linkdown ] && hook=link_down
	A=${a:-60}
	mkdir -p /tmp/sr; rm -f /tmp/sr/*
	hr_loop() { local i=0; while [ ! -e /tmp/sr/stop ]; do echo "$RP 0" > $DBG/$hook 2>/dev/null; i=$((i + 1)); echo $i > /tmp/sr/hr; done; }
	sv_loop() { local i=0; while [ ! -e /tmp/sr/stop ]; do echo 2 > $SV 2>/dev/null; echo 0 > $SV 2>/dev/null; i=$((i + 1)); echo $i > /tmp/sr/sv; done; }
	dmesg -n 1	# the hooks log every reset
	hr_loop & P1=$!
	sv_loop & P2=$!
	t=0 last="" still=0 o=PASS
	while [ $t -lt $A ]; do
		sleep 1; t=$((t + 1))
		cur="$(cat /tmp/sr/hr /tmp/sr/sv 2>/dev/null | tr '\n' ' ')"
		if [ "$cur" = "$last" ]; then still=$((still + 1)); else still=0; last=$cur; fi
		[ $still -ge 25 ] && { o=HANG; break; }
	done
	touch /tmp/sr/stop
	dmesg -n 7
	log "loop: t=${t}s counters resets sriov: $cur still=${still}s"
	if [ $o = PASS ]; then
		wait_exit $P1 30 && wait_exit $P2 30 || o=HANG
	fi
	if [ $o = HANG ]; then
		# the loops run in subshells: find the writers by their stacks
		RW=$(for p in /proc/[0-9]*; do grep -qE "pcitest_aer_common|link_down_write" $p/stack 2>/dev/null && basename $p; done | head -1)
		SW=$(for p in /proc/[0-9]*; do grep -q sriov_numvfs_store $p/stack 2>/dev/null && basename $p; done | head -1)
		cyc=$(cycle ${RW:-0} ${SW:-0})
		dstacks "stuck"
		i=0; while [ "$(nhung)" -eq 0 ] && [ $i -lt 30 ]; do sleep 1; i=$((i + 1)); done
		NO_ADDED_CHECK=1	# config accesses below the port block
	fi
	o="$o rounds=$(echo $cur | tr ' ' '/') t=$t"
	;;
esac
sleep 1
result "$o sriov=$var cycle=$cyc pf=$(devs $NIC_V $PF_D | wc -l) vfs=$(devs $NIC_V $VF_D | wc -l) hung=$(nhung)"
lockdep_check
