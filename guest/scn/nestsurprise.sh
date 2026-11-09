# (N10) Nested hotplug ports with a surprise removal of the parent: a NIC on
# dp1 is surprise-removed, and rps (00:1e.0) handles a link change of the
# switch's slot.  Nested topology (harness/run.py): rps - up1 - dp1 (nicd1),
# dp2 (nicd2).
#
# Child (dp1): QEMU has no surprise removal, but its slot power controller
# does it (see deadreset.sh): Slot Control with Power Controller and Power
# Indicator off and HPIE/CCIE off makes QEMU detach the NIC and set Presence
# Detect Changed without an interrupt; restoring Slot Control (powered, as
# pciehp left it) delivers the event through Command Completed.
# Parent (rps): pcitest/link_change queues a Data Link Layer State Changed
# event for rps's pciehp, which handles it as a surprise removal:
# pciehp_unconfigure_device(ctrl, false) marks the switch and everything below
# it disconnected, then takes pci_rescan_remove_lock and removes the switch
# (unbinding dp1 and dp2, whose pciehp_remove() waits in free_irq() for their
# IRQ threads); QEMU detaches the switch when pciehp powers the slot off.
# Detaching the switch with the slot power trick instead crashes QEMU 11.1.
#
# var=prelock  (default) dp1's remove_board() sleeps 3 s before
#              pciehp_unconfigure_device() (pciehp test_pre_remove_ms and
#              test_pre_remove_port): dp1's IRQ thread has passed its slot
#              power check when rps marks the switch disconnected, takes the
#              lock and unbinds dp1; dp1's IRQ thread then asks for the lock.
#     queued   pcitest/hold_rescan_ms holds the lock for 6 s; dp1's IRQ thread
#              waits for it before rps marks the switch disconnected; rps
#              queues behind it (the mutex hands the lock to dp1 first).
#     race     no delay and no hold: rps's link change 20 ms after the yank.
# PASS: rps's removal finished (switch and NICs gone) and no task hung within
# 45 s.
case $var in prelock|queued|race) ;; *) result "FAIL unknown var $var"; return ;; esac
need $DBG/link_change || return
[ $var = prelock ] && { need $KNOBS/test_pre_remove_ms $KNOBS/test_pre_remove_port || return; }
[ $var = queued ] && { need $DBG/hold_rescan_ms || return; }
RPS=0000:00:1e.0
wait_count $NIC_V $NIC_D 2 60 || { result "FAIL setup"; return; }
NICD1=$(devs $NIC_V $NIC_D | head -1)
DP1=$(port_of $NICD1)
UP1=$(port_of $DP1)
log "rps=$RPS up1=$UP1 dp1=$DP1 nicd1=$NICD1 var=$var"
c1() { cf1 "$1" "$2"; }
[ "$(c1 $RPS 0.w)" = "$(pcicfg $RPS 0 2)" ] || { result "SKIP config mechanism #1 does not work"; return; }
# yank PORT: surprise removal of the device below PORT
yank() {
	local x sc orig gone
	x=$(expcap $1)
	sc=$(printf %x $((x + 0x18)))
	orig=$((0x$(pcicfg $1 0x$sc 2)))
	gone=$(( (orig & ~0x730) | 0x700 ))	# PCC off, PIC off, no HPIE/CCIE
	c1 $1 $sc.w=$(printf %04x $gone)
	c1 $1 $sc.w=$(printf %04x $orig)
	log "yanked below $1 (sltctl 0x$(printf %04x $orig))"
}
parent() { echo $RPS > $DBG/link_change; log "link change queued for $RPS"; }
ist_waiting() {	# D-state tasks in pciehp_unconfigure_device
	local p
	for p in /proc/[0-9]*; do
		[ "$(awk '{print $3}' $p/stat 2>/dev/null)" = D ] || continue
		grep -q pciehp_unconfigure_device $p/stack 2>/dev/null && echo "$(basename $p)"
	done
}
wait_msg() {	# PATTERN TIMEOUT_S
	local i=0
	while ! dmesg | grep -q "$1" && [ $i -lt $(( $2 * 20 )) ]; do sleep 0.05; i=$((i + 1)); done
	dmesg | grep -q "$1"
}
trace_on pciehp_unconfigure_device pcie_shutdown_notification pci_stop_and_remove_bus_device pci_trylock_rescan_remove
case $var in
prelock)
	echo $DP1 > $KNOBS/test_pre_remove_port
	echo 3000 > $KNOBS/test_pre_remove_ms
	yank $DP1
	wait_msg "test: sleeping 3000 ms before unconfigure" 5 ||
		{ result "FAIL dp1 did not reach remove_board"; dmesg | tail -20; return; }
	echo 0 > $KNOBS/test_pre_remove_ms
	parent
	;;
queued)
	(echo 6000 > $DBG/hold_rescan_ms; log "H: released") &
	wait_msg "pcitest: hold_rescan: locked" 5 || { result "FAIL hold"; return; }
	yank $DP1
	i=0; while [ -z "$(ist_waiting)" ] && [ $i -lt 40 ]; do sleep 0.05; i=$((i + 1)); done
	log "IRQ threads in pciehp_unconfigure_device before rps: $(ist_waiting | tr '\n' ' ')"
	parent
	sleep 1
	log "IRQ threads in pciehp_unconfigure_device after rps: $(ist_waiting | tr '\n' ' ')"
	dstacks "while H holds the lock"
	;;
race)
	yank $DP1
	sleep 0.02
	parent
	;;
esac
i=0
while [ -e /sys/bus/pci/devices/$UP1 ] && [ $i -lt 450 ]; do sleep 0.1; i=$((i + 1)); done
sleep 2
n=$(devs $NIC_V $NIC_D | wc -l)
up=0; [ -e /sys/bus/pci/devices/$UP1 ] && up=1
dstacks "after removal"
trace_dump | grep -v "^$" | tail -40
dmesg | grep -E 'pciehp|test:|pcitest' | grep -v 'Slot #' | tail -30
if [ $(nhung) -gt 0 ]; then
	result "FAIL hung tasks, devices=$n switch=$up"
elif [ $up -eq 0 ] && [ $n -eq 0 ]; then
	result "PASS devices=0 switch=0"
else
	result "FAIL stuck removal devices=$n switch=$up"
fi
lockdep_check
