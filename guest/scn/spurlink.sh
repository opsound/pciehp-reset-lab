# N3: pciehp_ignore_link_change() looks up the slot's device with
# pci_get_slot() (pci_bus_sem, read) while it holds reset_lock (read).
# Four tasks:
#   I  pciehp IRQ thread of dp2: after a slot reset of dp2 it ignores the
#      resulting DLLSC event; holds dp2's reset_lock (read), waits for
#      pci_bus_sem (read) in pci_get_slot() behind W
#   W  sysfs remove of B (e1000e on rp1, another port): pci_destroy_dev()
#      queues for pci_bus_sem (write) behind A
#   A  error recovery of rps (pcitest/aer_reset = pcie_do_recovery()):
#      its error_detected walk holds pci_bus_sem (read) and waits for the
#      device_lock of nicd2 (or dp2)
#   H  holds nicd2's device_lock and waits for dp2's reset_lock (write) to
#      reset the slot
# Topology: rps (00:1e.0) - up1 - dp1 (nicd1: two-function e1000e F0, F1),
# dp2 (nicd2), e1000e B on rp1 (run.py nestdevs/qemu_extra).  A must hold
# pci_bus_sem while W and I queue and H locks nicd2, so A is parked first: F0
# and F1 are bound to vfio-pci and held by a process (vtool) that ignores
# release requests, and Y (sysfs unbind of F0) holds F0's device_lock while
# it waits for that process; A's walk visits up1, dp1, F0 (waits), F1, dp2,
# nicd2.  The holder later closes F0 only (SIGUSR2): with F1 still open,
# vfio-pci skips the slot reset on release, which would walk the bus under
# pci_bus_sem and queue behind W.  Order: slot reset R1 of dp2 (leaves
# PCI_LINK_CHANGED set), Y, A waits for F0, W queues, DLLSC event for dp2
# (pcitest/link_change: QEMU's ports don't report link changes after an
# SBR; real ones report DLLSC during the reset) -> I ignores it, H locks
# nicd2 and resets dp2's slot, then the holder closes F0: Y returns and A
# moves on to dp2/nicd2.  No delay knobs.
# var=reset  R1 and H are sysfs resets of nicd2 (reset_method=bus)
#     vfio   nicd2 is bound to vfio-pci (reset_method=bus) and held by a second
#            process: R1 is its open-time reset, H its release-time reset
#            (killed), which holds dp2's and nicd2's device_lock
#     inreset  as reset, but in hardware order: R1 runs after A is parked,
#            and the DLLSC event is raised while R1 sleeps in
#            pci_bridge_wait_for_secondary_bus() after its pci_bus_sem
#            lookup (as a real port reports it during the reset); W starts
#            at the same moment and must queue within R1's wait for the link
#            (1.1 s here: QEMU's downstream ports lack link active reporting)
#            (B is unbound first so that its removal is quick).  Racy: if W
#            queues before R1's lookup, R1 waits for pci_bus_sem with dp2's
#            and nicd2's device_lock held (cycle=other/N11); if W is late,
#            I passes pci_get_slot() and H waits in
#            pci_bridge_wait_for_secondary_bus() (N11).
# PASS: every task returns within 45 s.  No added check: F0 has no driver
# when A's walk reaches it, so the recovery of rps fails after its reset
# ("can't recover (no error_detected callback)") and leaves the switch below
# rps unrestored.  On a hang, cycle= names the chain:
#   N3   I in pci_get_slot() under pciehp_ignore_link_change() holding
#        reset_lock, H waits for reset_lock in pciehp_reset_slot()
#   N11  H got reset_lock and waits for pci_bus_sem in
#        pci_bridge_wait_for_secondary_bus() (the same cycle without pciehp)
RPS=0000:00:1e.0
NO_ADDED_CHECK=1
need $DBG/link_change $DBG/aer_reset || return
case $var in reset|vfio|inreset) ;; *) result "FAIL unknown var $var"; return ;; esac
wait_count $NIC_V $NIC_D 4 60 || { result "FAIL setup: $(devs $NIC_V $NIC_D | wc -l) e1000e"; return; }
F0= F1= N2= B=
for b in $(devs $NIC_V $NIC_D); do
	case $b in
	*.1) F1=$b ;;
	*) case $(port_of $b) in 0000:00:10.0) B=$b ;; *) [ -z "$F0" ] && F0=$b || N2=$b ;; esac ;;
	esac
done
[ "$(port_of $F1)" = "$(port_of $F0)" ] || { result "FAIL setup: F0=$F0 F1=$F1 N2=$N2"; return; }
DP1=$(port_of $F0) DP2=$(port_of $N2)
for b in $F0 $F1 $N2 $B; do wait_bound_dev $b 20; done
SEC2=$(ls /sys/bus/pci/devices/$DP2/pci_bus | head -1)
S2=
for s in /sys/bus/pci/slots/*; do [ "$(cat $s/address 2>/dev/null)" = "$SEC2:00" ] && S2=$(basename $s); done
log "F0=$F0 F1=$F1 dp1=$DP1 nicd2=$N2 dp2=$DP2 slot=$S2 B=$B var=$var"

# kstack PID: the kernel stack of a task on one line
kstack() {
	tr -s ' \n' ' ' < /proc/$1/stack 2>/dev/null | sed 's/\[<0>\] //g; s/+0x[0-9a-f/x]*//g' | cut -c1-500
}
# wait_stack PID PATTERN TIMEOUT_S: until PID's stack matches or PID exits
wait_stack() {
	local i=0
	while alive $1 && ! grep -qE "$2" /proc/$1/stack 2>/dev/null; do
		[ $i -ge $(( $3 * 20 )) ] && return 1
		sleep 0.05; i=$((i + 1))
	done
}
# ist_of PATTERN: the pciehp IRQ thread whose stack matches
ist_of() {
	local p
	for p in /proc/[0-9]*; do
		case $(cat $p/comm 2>/dev/null) in irq/*-pciehp) ;; *) continue ;; esac
		grep -qE "$1" $p/stack 2>/dev/null && { basename $p; return; }
	done
}
# locks PID: lockdep's "locks held" entries of PID from the last sysrq-d dump,
# "ADDRESS (name)..." (a blocked task lists the lock it waits for last)
locks() {
	dmesg | awk -v t="/$1:" '
		/locks? held by / && index($0, t) { n = 0; on = 1; delete a; next }
		on && /#[0-9]+: / { a[++n] = $0; next }
		{ on = 0 }
		END { for (i = 1; i <= n; i++) print a[i] }' | sed -E 's/.*#[0-9]+: //'
}
lname() { sed -E 's/^[0-9a-f]+ \(([^)]*)\).*/\1/'; }	# lock name of a locks() line
held() { sed '$d'; }	# all but the lock waited for
trace_on "pciehp_ignore_link_change pciehp_device_replaced pciehp_reset_slot pci_bridge_wait_for_secondary_bus pci_destroy_dev pcie_do_recovery"

# R1: a slot reset of dp2; QEMU reports no link change, so PCI_LINK_CHANGED stays set
H2=
if [ $var = vfio ]; then
	bind_vfio $N2 bus
	/bin/vtool hold $N2 > /tmp/h2.out 2>&1 &
	H2=$!
	i=0; while ! grep -q READY /tmp/h2.out && [ $i -lt 100 ]; do sleep 0.05; i=$((i + 1)); done
	grep -q READY /tmp/h2.out || { result "FAIL setup: holder of nicd2: $(cat /tmp/h2.out)"; return; }
	log "R1: vfio open of nicd2 (reset_method=$(cat /sys/bus/pci/devices/$N2/reset_method))"
elif [ $var = reset ]; then
	echo bus > /sys/bus/pci/devices/$N2/reset_method
	echo 1 > /sys/bus/pci/devices/$N2/reset || { result "FAIL setup: reset of nicd2"; return; }
	log "R1: sysfs reset of nicd2 done"
else
	echo bus > /sys/bus/pci/devices/$N2/reset_method
	echo $B > /sys/bus/pci/drivers/e1000e/unbind
	log "R1 after A is parked (inreset); B unbound: $(drv_of $B)"
fi
sleep 0.5
dmesg | grep -q "Link Down/Up ignored" && log "unexpected: link change already ignored"

# park A on F0: Y unbinds F0 from vfio-pci while H1 holds F0 and F1
bind_vfio $F0
bind_vfio $F1
/bin/vtool hold $F0 $F1 > /tmp/h1.out 2>&1 &
H1=$!
i=0; while ! grep -q READY /tmp/h1.out && [ $i -lt 100 ]; do sleep 0.05; i=$((i + 1)); done
grep -q READY /tmp/h1.out || { result "FAIL setup: holder of nicd1: $(cat /tmp/h1.out)"; return; }
(echo $F0 > /sys/bus/pci/drivers/vfio-pci/unbind; log "Y: unbind of F0 returned") &
Y=$!
wait_stack $Y "vfio_unregister_group_dev|vfio_pci_core_unregister_device" 5 || log "Y not in vfio unregister"
log "Y stack: $(kstack $Y)"
(echo "$RPS 0" > $DBG/aer_reset; log "A: aer_reset of rps returned rc=$?") &
A=$!
wait_stack $A "report_error_detected" 5 || log "A not in report_error_detected"
log "A stack: $(kstack $A)"
if [ $var = inreset ]; then
	# R1, then the DLLSC event and W once R1 sleeps after its pci_bus_sem lookup
	(echo 1 > /sys/bus/pci/devices/$N2/reset; log "R1: reset of nicd2 returned") &
	R1=$!
	i=0 st=
	while [ $i -lt 100000 ] && [ -d /proc/$R1 ]; do
		read -r -d '' st < /proc/$R1/stack
		l1=${st%%$'\n'*} l2=${st#*$'\n'}; l2=${l2%%$'\n'*}
		case $l1:$l2 in *msleep*:*pci_bridge_wait_for_secondary_bus*|*msleep*:*pcie_wait_for_link_delay*|*pci_dev_wait*:*) break ;; esac
		i=$((i + 1))
	done
	echo $DP2 > $DBG/link_change
	(echo 1 > /sys/bus/pci/devices/$B/remove; log "W: remove of B returned") &
	W=$!
	log "R1 polls=$i stack: $(echo "$st" | tr -s ' \n' ' ' | sed 's/\[<0>\] //g; s/+0x[0-9a-f/x]*//g' | cut -c1-200)"
	wait_exit $R1 10 || log "R1 stuck: $(kstack $R1)"
else
	(echo 1 > /sys/bus/pci/devices/$B/remove; log "W: remove of B returned") &
	W=$!
fi
# W queued: D state with pci_remove_bus_device()/pci_destroy_dev() on top
i=0
while alive $W && ! { [ "$(awk '{print $3}' /proc/$W/stat 2>/dev/null)" = D ] &&
		     head -1 /proc/$W/stack 2>/dev/null | grep -qE "pci_remove_bus_device|pci_destroy_dev"; }; do
	[ $i -ge 100 ] && { log "W not queued"; break; }
	sleep 0.05; i=$((i + 1))
done
alive $W && log "W stack: $(kstack $W)" || log "W returned before the event"

# the DLLSC event a real port reports for R1
[ $var = inreset ] || echo $DP2 > $DBG/link_change || { result "FAIL link_change"; return; }
i=0; while ! dmesg | grep -q "Slot($S2): Link Down/Up ignored" && [ $i -lt 60 ]; do sleep 0.05; i=$((i + 1)); done
dmesg | grep -q "Slot($S2): Link Down/Up ignored" && IGN=1 || IGN=0
sleep 0.3
I=$(ist_of "pciehp_ignore_link_change|pciehp_device_replaced")
log "ignored=$IGN I=${I:-none} $([ -n "$I" ] && echo "($(cat /proc/$I/comm)) stack: $(kstack $I)")"

# H: a reset of dp2's slot with nicd2's device_lock held
if [ $var = vfio ]; then
	kill -9 $H2
	HO=$H2
else
	(echo 1 > /sys/bus/pci/devices/$N2/reset; log "H: reset of nicd2 returned") &
	HO=$!
fi
wait_stack $HO "pciehp_reset_slot" 5
sleep 0.3
alive $HO && log "H stack: $(kstack $HO)" || log "H returned before nicd1's holder was killed"

# release F0 (F1 stays open): Y returns, A's walk moves on to dp2 and nicd2
kill -USR2 $H1
log "holder closes F0"
o=PASS
i=0
while [ $i -lt 450 ]; do
	alive $Y || alive $A || alive $W || alive $HO || break
	sleep 0.1; i=$((i + 1))
done
for p in Y:$Y A:$A W:$W H:$HO; do alive ${p#*:} && o=HANG; done
[ -n "$I" ] && grep -qE "pciehp_ignore_link_change|pciehp_device_replaced" /proc/$I/stack 2>/dev/null && o=HANG
CYCLE=-
if [ $o = HANG ]; then
	for p in Y:$Y A:$A W:$W H:$HO I:$I H1:$H1; do
		[ -n "${p#*:}" ] && alive ${p#*:} || continue
		echo "== ${p%%:*} pid ${p#*:} ($(cat /proc/${p#*:}/comm)) state $(awk '{print $3}' /proc/${p#*:}/stat)"
		cat /proc/${p#*:}/stack 2>/dev/null | head -24
	done
	echo d > /proc/sysrq-trigger	# lockdep: all held locks
	sleep 1
	for p in A:$A W:$W H:$HO I:$I; do
		[ -n "${p#*:}" ] || continue
		echo "-- ${p%%:*} locks:"; locks ${p#*:}
	done
	# A waits for device lock X under pci_bus_sem, H holds X and waits for
	# reset_lock (N3: I holds it and waits for pci_bus_sem) or for pci_bus_sem
	# itself (N11), W waits for pci_bus_sem (write) behind A
	al=$(locks $A) wl=$(locks $W) hl=$(locks $HO) il=$(locks $I)
	X=$(echo "$al" | tail -n 1); X=${X%% *}
	aw=$(echo "$al" | tail -n 1 | lname) ww=$(echo "$wl" | tail -n 1 | lname)
	hw=$(echo "$hl" | tail -n 1 | lname) iw=$(echo "$il" | tail -n 1 | lname)
	ahb=$(echo "$al" | held | lname | grep -c pci_bus_sem)
	hx=$(echo "$hl" | held | grep -c "^$X ")
	irl=$(echo "$il" | held | lname | grep -c reset_lock)
	CYCLE=other
	if [ "$aw" = "&dev->mutex" ] && [ $ahb -gt 0 ] && [ $hx -gt 0 ] && [ "$ww" = pci_bus_sem ]; then
		case $hw in
		*reset_lock*) [ "$iw" = pci_bus_sem ] && [ $irl -gt 0 ] && CYCLE=N3 ;;
		pci_bus_sem) CYCLE=N11 ;;
		esac
	fi
	echo "CHECK: A holds pci_bus_sem=$ahb waits=$aw $X; H holds it=$hx waits=$hw at $(echo "$hl" | tail -n 1 | sed 's/.*at: //'); I holds reset_lock=$irl waits=$iw at $(echo "$il" | tail -n 1 | sed 's/.*at: //'); W waits=$ww"
	o="FAIL deadlock"
fi
trace_dump | tail -30
h=$(nhung)
[ $h -gt 0 ] && o="$o hung"
alive $H1 && kill -9 $H1
result "$o spurlink=$var cycle=$CYCLE ignored=$IGN hung=$h"
lockdep_check
