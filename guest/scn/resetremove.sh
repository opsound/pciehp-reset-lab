# (N15) An error reset holds the device_lock of a device that a remover
# holding pci_rescan_remove_lock needs, and waits for a PF whose
# sriov_numvfs_store() waits for that lock.  Nested topology (harness/run.py):
# rps (00:1e.0) - up1 - dp1 (e1000e X), dp2 (igb PF Y).
#   Q  pcitest/hold_rescan_ms holds pci_rescan_remove_lock for 8 s
#   P  dp1's slot is powered off through sysfs: dp1's IRQ thread queues on the
#      lock to remove X (it then needs device_lock(X) to unbind it)
#   S  sriov_numvfs=2 on Y: device_lock(Y), then queues on the lock
#   R  pcitest/err_reset of rps (pci_bus_error_reset(), what aer_root_reset()
#      calls): locks rps, up1, dp1, X, dp2, then waits for device_lock(Y)
# Q's release hands the lock to P, which waits for X: P -> R -> S -> P.
# RESULT: HANG with cycle=yes if the three tasks form that cycle.
RPS=0000:00:1e.0
PF_D=0x10c9 VF_D=0x10ca
NO_ADDED_CHECK=1	# the raw reset leaves the devices below rps unconfigured
need $DBG/hold_rescan_ms $DBG/err_reset || return
wait_count $NIC_V $NIC_D 1 60 || { result "FAIL setup e1000e"; return; }
wait_count $NIC_V $PF_D 1 60 || { result "FAIL setup igb"; return; }
X=$(devs $NIC_V $NIC_D); Y=$(devs $NIC_V $PF_D)
DP1=$(port_of $X); DP2=$(port_of $Y)
wait_bound_dev $X 20; wait_bound_dev $Y 20
S1=
for s in /sys/bus/pci/slots/*; do
	[ "$(cat $s/address 2>/dev/null)" = "${X%.*}" ] && S1=$(basename $s)
done
[ -n "$S1" ] || { result "FAIL no slot for $X"; return; }
log "X=$X ($(drv_of $X)) dp1=$DP1 slot=$S1  Y=$Y ($(drv_of $Y)) dp2=$DP2 rps=$RPS"

# kstack PID: the PCI-relevant frames of a task's kernel stack on one line
kstack() {
	tr -s ' \n' ' ' < /proc/$1/stack 2>/dev/null | sed 's/\[<0>\] //g; s/+0x[0-9a-f/x]*//g' | cut -c1-400
}
wait_msg() {	# PATTERN TIMEOUT_S
	local i=0
	while ! dmesg | grep -q "$1"; do
		[ $i -ge $(( $2 * 20 )) ] && return 1
		sleep 0.05; i=$((i + 1))
	done
}

(echo 8000 > $DBG/hold_rescan_ms; log "Q: hold_rescan returned") &
Q=$!
wait_msg "pcitest: hold_rescan: locked" 10
(slot_power $S1 0; log "P: slot $S1 power off returned") &
P=$!
sleep 1
(echo 2 > /sys/bus/pci/devices/$Y/sriov_numvfs; log "S: sriov_numvfs returned rc=$?") &
S=$!
sleep 1
(echo "$RPS" > $DBG/err_reset; log "R: err_reset returned rc=$?") &
R=$!
sleep 1
log "S stack: $(kstack $S)"
log "R stack: $(kstack $R)"

# 60 s in total (the hung-task detector reports after 20 s), then 5 s each
stuck= tmo=60
for t in R:$R S:$S P:$P Q:$Q; do
	wait_exit ${t#*:} $tmo || stuck="$stuck ${t%%:*}"
	[ -n "$stuck" ] && tmo=5
done
if [ -n "$stuck" ]; then
	PI=$(for p in /proc/[0-9]*; do grep -q pciehp_unconfigure_device $p/stack 2>/dev/null && basename $p; done | head -1)
	log "stuck:$stuck"
	log "R stack: $(kstack $R)"
	log "S stack: $(kstack $S)"
	[ -n "$PI" ] && log "P ($(cat /proc/$PI/comm)) stack: $(kstack $PI)"
	dstacks "after 60 s"
	cyc=no
	[ -n "$PI" ] && grep -q device_release_driver /proc/$PI/stack && grep -q sriov_numvfs_store /proc/$S/stack 2>/dev/null &&
		grep -qE "pci_reset_devs|pci_slot_lock|pci_bus_lock|pci_slot_reset" /proc/$R/stack 2>/dev/null && cyc=yes
	o="HANG stuck=$(echo $stuck | tr ' ' ,) cycle=$cyc"
else
	o=PASS
fi
result "$o x=$(devs $NIC_V $NIC_D | wc -l) pf=$(devs $NIC_V $PF_D | wc -l) vfs=$(devs $NIC_V $VF_D | wc -l) hung=$(nhung)"
lockdep_check
