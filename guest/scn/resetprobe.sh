# (N16) A bus or slot reset locks a device whose first probe is still pending
# in an enumerator that holds pci_rescan_remove_lock, then waits for a PF
# whose sriov_numvfs_store() holds its device_lock and waits for that lock.
# Nested topology (harness/run.py): rps (00:1e.0) - up1 - dp1, dp2 (igb PF).
#   var=pciehp  dp1 empty at boot.  E: a NIC hot-added on dp1; pciehp sleeps
#               after the scan with the lock held (pciehp test_post_scan_ms),
#               before it adds the NIC and probes it.
#               S: sriov_numvfs=2 on the PF.  R: pcitest/err_reset of rps locks
#               rps, up1, dp1, the NIC, dp2, then waits for the PF.
#   var=rescan  e1000e N on dp1 at boot, removed through sysfs without pciehp
#               noticing.  E: a global rescan re-adds N and waits in
#               device_initial_probe() for N's device_lock; S right behind E,
#               R a random 0-30 ms later (a= fixes it; the lab test uses
#               10).  No delay knobs.
# The raw reset (no error handlers) leaves the switch unconfigured, so the
# added check is skipped.  RESULT: HANG if a task hasn't returned 45 s later;
# cycle=probe if E, R and S form the cycle above.
RPS=0000:00:1e.0 PF_D=0x10c9 VF_D=0x10ca
K=/sys/module/pciehp/parameters/test_post_scan_ms
NO_ADDED_CHECK=1
need $DBG/err_reset || return
[ "$var" = pciehp ] && { need $K || return; }
wait_count $NIC_V $PF_D 1 60 || { result "FAIL setup PF"; return; }
PF=$(devs $NIC_V $PF_D)
SV=/sys/bus/pci/devices/$PF/sriov_numvfs
wait_bound_dev $PF 10 || { result "FAIL setup PF unbound"; return; }
JIT=-
case $var in
pciehp)
	sleep 1
	echo 6000 > $K
	dmesg -C
	act add nicx dp1
	i=0
	while ! dmesg | grep -q "test: sleeping 6000 ms after scan" && [ $i -lt 600 ]; do sleep 0.05; i=$((i + 1)); done
	dmesg | grep -q "test: sleeping 6000 ms after scan" || { result "FAIL no post-scan sleep"; echo 0 > $K; return; }
	log "pciehp sleeps after the scan with the lock held; NIC: $(devs $NIC_V $NIC_D)"
	E=$(for p in /proc/[0-9]*; do grep -q pciehp_configure_device $p/stack 2>/dev/null && basename $p; done | head -1)
	( echo 2 > $SV; log "S: sriov_numvfs=2 returned rc=$?" ) &
	S=$!
	sleep 0.5
	( echo "$RPS 0" > $DBG/err_reset; log "R: err_reset returned rc=$?" ) &
	R=$!
	;;
rescan)
	wait_count $NIC_V $NIC_D 1 60 || { result "FAIL setup NIC"; return; }
	N=$(devs $NIC_V $NIC_D)
	wait_bound_dev $N 20 || { result "FAIL setup: $N unbound"; return; }
	echo 1 > /sys/bus/pci/devices/$N/remove
	wait_count $NIC_V $NIC_D 0 10 || { result "FAIL sysfs remove"; return; }
	sleep 0.5
	JIT=${a:-$(( RANDOM % 31 ))}
	(echo 1 > /sys/bus/pci/rescan; log "E: rescan returned") &
	E=$!
	# S right behind E (E must own pci_rescan_remove_lock first), R JIT ms later
	sleep 0.005
	(echo 2 > $SV; log "S: sriov_numvfs returned rc=$?") &
	S=$!
	sleep $(printf "0.%03d" $JIT)
	(echo "$RPS" > $DBG/err_reset; log "R: err_reset returned rc=$?") &
	R=$!
	log "jitter ${JIT} ms"
	;;
*) result "FAIL unknown var $var"; return ;;
esac
o=HANG
i=0
while [ $i -lt 450 ]; do
	alive $S || alive $R || { [ $var = rescan ] && alive $E; } || { o=PASS; break; }
	sleep 0.1; i=$((i + 1))
done
cyc=-
if [ $o = HANG ]; then
	es=$(cat /proc/$E/stack 2>/dev/null) ss=$(cat /proc/$S/stack 2>/dev/null) rs=$(cat /proc/$R/stack 2>/dev/null)
	if echo "$es" | grep -qE "device_initial_probe|__device_attach" && echo "$ss" | grep -q sriov_numvfs_store &&
	   ! echo "$ss" | grep -q sriov_enable && [ -n "$rs" ]; then
		cyc=probe
	elif echo "$ss" | grep -q pci_dev_assign_slot; then
		cyc=slot_mutex	# S adds a VF, waits for the pci_slot_mutex that R holds
	else
		cyc=other
	fi
	dstacks "stuck"
	i=0; while [ "$(nhung)" -eq 0 ] && [ $i -lt 30 ]; do sleep 1; i=$((i + 1)); done
fi
[ -e $K ] && echo 0 > $K
sleep 1
result "$o probe=$var cycle=$cyc jit=$JIT nic=$(devs $NIC_V $NIC_D | wc -l) pf=$(devs $NIC_V $PF_D | wc -l) vfs=$(devs $NIC_V $VF_D | wc -l) hung=$(nhung)"
lockdep_check
