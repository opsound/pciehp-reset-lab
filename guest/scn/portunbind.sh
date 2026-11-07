# Unbinding only the pcieport driver of a hotplug Downstream Port (dp1) while
# dp1's IRQ thread waits for pci_rescan_remove_lock and another task waits for
# dp1.  Nested topology (harness/run.py): rps (00:1e.0) - up1 - dp1, dp2.
# The unbind holds dp1's device_lock and waits for dp1's IRQ thread (free_irq()
# or pci_hp_del()).
# var=lockedadd  (N10) dp1 is empty and nicd2 on dp2 is bound to vfio-pci and
#             held.  pcitest/remove_locked removes up1 with
#             pci_rescan_remove_lock held, like acpiphp or host bridge removal:
#             it waits for the holder of nicd2, then for dp1's device_lock.  A
#             card hot-added on dp1 meanwhile makes dp1's IRQ thread wait for
#             the lock to enumerate it; the unbind of dp1 then waits in
#             free_irq() for that thread.
#     hostlock  (N10) pcitest/host_reset of rps holds the lock for 3 s, then
#             its bus reset waits for dp1's device_lock, as a resetter that
#             holds the lock (EEH, pci_host_reset_root_port()) does; dp1's slot
#             is powered off through sysfs, so dp1's IRQ thread waits for the
#             lock to remove nicd1.
#     nolock  (N11) pcitest/hold_rescan_ms holds the lock for 6 s while dp1's
#             slot is powered off; then AER-style recovery of rps
#             (pcitest/aer_reset, no lock) walks the devices below rps with
#             pci_bus_sem held for reading and waits for dp1's device_lock,
#             while dp1's IRQ thread, which got the lock, waits for pci_bus_sem
#             to remove nicd1.
# PASS: every task returns within 50 s once the lock or the holder is released.
RPS=0000:00:1e.0
N1= N2= DP1=
if [ $var = lockedadd ]; then
	# harness/run.py: dp1 empty, nicd2 on dp2 for this variant
	wait_count $NIC_V $NIC_D 1 60 || { result "FAIL setup"; return; }
	N2=$(devs $NIC_V $NIC_D)
	UP1=$(port_of $(port_of $N2))
	for d in /sys/bus/pci/devices/$UP1/0000:*; do
		[ "$(basename $d)" = "$(port_of $N2)" ] || DP1=$(basename $d)
	done
else
	wait_count $NIC_V $NIC_D 2 60 || { result "FAIL setup"; return; }
	for b in $(devs $NIC_V $NIC_D); do [ -z "$N1" ] && N1=$b || N2=$b; done
	DP1=$(port_of $N1); UP1=$(port_of $DP1)
	wait_bound_dev $N1 10
fi
SEC1=$(ls /sys/bus/pci/devices/$DP1/pci_bus | head -1)
S1=
for s in /sys/bus/pci/slots/*; do [ "$(cat $s/address 2>/dev/null)" = "$SEC1:00" ] && S1=$(basename $s); done
[ -n "$S1" ] || { result "FAIL setup: no slot for $DP1 ($SEC1)"; return; }
wait_bound_dev $N2 10
log "up1=$UP1 dp1=$DP1 slot=$S1 nicd1=$N1 nicd2=$N2 var=$var"
trace_on "pciehp_configure_device pciehp_unconfigure_device pci_unbind_bus_devices pcie_shutdown_notification pci_stop_and_remove_bus_device"
H= HR=
case $var in
lockedadd)
	need $DBG/remove_locked || return
	bind_vfio $N2
	/bin/vtool hold $N2 > /tmp/h.out 2>&1 &
	H=$!
	sleep 1
	(echo "$UP1 0" > $DBG/remove_locked; log "R: remove_locked of up1 returned") &
	HR=$!
	(sleep 6; kill -9 $H; log "holder killed") &
	sleep 1
	;;
nolock)
	need $DBG/hold_rescan_ms $DBG/aer_reset || return
	(echo 6000 > $DBG/hold_rescan_ms; log "hold returned") &
	HR=$!
	sleep 0.3
	;;
hostlock)
	need $DBG/host_reset || return
	NO_ADDED_CHECK=1	# the raw reset leaves the switch unconfigured
	(echo "$RPS 3000" > $DBG/host_reset; log "R: host_reset returned") &
	HR=$!
	sleep 0.5
	;;
*) result "FAIL unknown var $var"; return ;;
esac
P=
if [ $var = lockedadd ]; then
	act add nicx dp1 e1000e
	i=0
	while ! grep -q pciehp_configure_device $T/trace && [ $i -lt 100 ]; do sleep 0.05; i=$((i + 1)); done
	sleep 0.5
else
	(slot_power $S1 0; log "P: slot $S1 power off returned") &
	P=$!
	sleep 1
fi
(echo $DP1 > /sys/bus/pci/drivers/pcieport/unbind; log "U: unbind of $DP1 returned") &
U=$!
W=
if [ $var = nolock ]; then
	sleep 0.5
	(echo "$RPS 0" > $DBG/aer_reset; log "W: aer_reset of rps returned") &
	W=$!
fi
dstacks "parties waiting"
bad=
for t in HR:$HR P:$P U:$U W:$W; do
	[ -n "${t#*:}" ] || continue
	wait_exit ${t#*:} 50 || bad="$bad ${t%%:*}-stuck"
done
cyc=
if [ -n "$bad" ]; then
	dstacks "stuck"
	# nolock: the recovery walk holds pci_bus_sem and waits for dp1, whose
	# IRQ thread waits for pci_bus_sem to remove nicd1
	if [ $var = nolock ] && grep -q "report_.*detected" /proc/$W/stack 2>/dev/null &&
	   cat /proc/[0-9]*/stack 2>/dev/null | grep -qE "pci_remove_bus_device|pci_destroy_dev"; then
		cyc=" cycle=walk"
	fi
fi
[ -n "$H" ] && { wait_exit $H 10 || bad="$bad holder-stuck"; }
trace_dump | tail -40
[ -z "$bad" ] && o=PASS || o="FAIL$bad"
if dmesg | grep -q "blocked for more than"; then o="$o hung"; fi
result "$o$cyc"
lockdep_check
