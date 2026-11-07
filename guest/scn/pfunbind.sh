# N21: a PF driver's unbind removes its VFs without
# pci_rescan_remove_lock.
#
# device_release_driver(PF) -> igb_remove() -> igb_disable_sriov() ->
# pci_disable_sriov() -> sriov_disable() -> sriov_del_vfs() ->
# pci_iov_remove_virtfn() -> pci_stop_and_remove_bus_device(VF), whose
# lockdep_assert_held(&pci_rescan_remove_lock) (remove.c:128 on v7.4-rc1)
# fires: only sriov_numvfs_store() takes the lock around ->sriov_configure(),
# driver unbind (sysfs unbind, rmmod, PF removal through another path) does not.
# Removers that hold the lock iterate bus->devices with list_for_each_entry_safe*
# and keep only the current entry referenced, e.g. pciehp_unconfigure_device()
# (VFs in reverse, then the PF): the unbind frees the next entry under them.
#
# Setup (run.py): igb (82576) PF "pf1" present at boot on rp1 (00:10.0, slot 1),
# so that no pciehp hot-add runs before the test: on v7.4-rc1 a hot-add makes
# lockdep report reset_lock vs pci_rescan_remove_lock (N1) and turn itself off,
# which silences the assert.
#
# var=unbind  (default) NVF VFs (igbvf bound), sysfs unbind of the PF's igb
#             driver, nothing else.  FAIL: the assert fires.
# var=hold    deterministic use-after-free, no delay knobs: VF NVF-1 (the
#             entry pciehp removes first) bound to vfio-pci and held by a
#             process that ignores release requests; slot 1 powered off
#             (pciehp_unconfigure_device() holds pci_rescan_remove_lock, waits
#             in vfio-pci's remove of VF NVF-1, its iterator already points to
#             VF NVF-2); then the PF unbind removes VFs 0..NVF-2 (freeing
#             VF NVF-2) and waits for VF NVF-1; the holder is killed and
#             pciehp steps onto the freed VF.  FAIL: assert, KASAN, Oops,
#             refcount or list warnings.
# var=race    the same without vfio and without any widening: a rounds of
#             slot power off and PF unbind started together (unbind delayed
#             by 0..40 ms, cycling per round); igb re-added after each round.
#             FAIL as hold.
# NVF: 2 for unbind/hold, 7 for race (PFUNBIND_NVF overrides).
PF_D=0x10c9 VF_D=0x10ca
SLOT=1
NO_ADDED_CHECK=1	# the PF is removed (hold/race) or left unbound (unbind) on purpose
case $var in
unbind|hold) NVF=${PFUNBIND_NVF:-2} ;;
race) NVF=${PFUNBIND_NVF:-7} ;;
*) result "FAIL unknown var $var"; return ;;
esac
ROUNDS=${a:-1}; [ $var = race ] || ROUNDS=1

dlstate() { awk '/debug_locks:/ {print $2}' /proc/lockdep_stats 2>/dev/null; }
# counts of the evidence lines in dmesg
evidence() {
	local k=/tmp/dmesg.$$
	dmesg > $k
	E_ASSERT=$(grep -c "WARNING: drivers/pci/remove.c:[0-9]* at pci_stop_and_remove_bus_device" $k)
	E_KASAN=$(grep -c "BUG: KASAN" $k)
	E_GPF=$(grep -c "general protection fault\|Oops:\|BUG: unable to handle" $k)
	E_REF=$(grep -c "refcount_t: " $k)
	E_LIST=$(grep -c "list_add corruption\|list_del corruption\|list_add_tail corruption" $k)
	E_WARN=$(grep -c "WARNING:" $k)
	rm -f $k
}
setup_pf() {
	wait_count $NIC_V $PF_D 1 60 || { log "no PF"; return 1; }
	PF=$(devs $NIC_V $PF_D)
	wait_bound_dev $PF 10 || { log "PF $PF unbound"; return 1; }
	echo $NVF > /sys/bus/pci/devices/$PF/sriov_numvfs || { log "sriov enable failed"; return 1; }
	wait_count $NIC_V $VF_D $NVF 30 || { log "VFs missing"; return 1; }
	local v
	for v in $(devs $NIC_V $VF_D); do wait_bound_dev $v 10; done
	VFS=$(devs $NIC_V $VF_D | tr '\n' ' ')
	log "PF=$PF ($(drv_of $PF)) VFs: $VFS drivers: $(for v in $VFS; do drv_of $v; done | sort | uniq -c | tr -s ' \n' ' ')"
}

log "debug_locks=$(dlstate) before setup"
setup_pf || { result "FAIL setup"; return; }
log "debug_locks=$(dlstate) after setup (1 = lockdep still active)"
DL0=$(dlstate)

case $var in
unbind)
	log "X: unbind $PF from $(drv_of $PF)"
	( echo $PF > /sys/bus/pci/devices/$PF/driver/unbind; log "X: unbind returned" ) &
	X=$!
	wait_exit $X 30 || { dstacks "unbind stuck"; }
	sleep 1
	evidence
	nvf=$(devs $NIC_V $VF_D | wc -l)
	log "after unbind: PF driver=$(drv_of $PF) VFs left=$nvf debug_locks=$(dlstate)"
	dmesg | grep -m1 -A 30 "WARNING: drivers/pci/remove.c:[0-9]* at pci_stop_and_remove_bus_device" | grep -E "WARNING|Comm:|^\[.*\] +[a-z_0-9.]+\+0x|lockdep_assert" | head -24
	[ $E_ASSERT -gt 0 ] && o=FAIL || o=PASS
	alive $X && o=HANG
	result "$o pfunbind=unbind assert=$E_ASSERT warn=$E_WARN vfs_left=$nvf debug_locks_before=$DL0"
	;;
hold)
	HV=$(devs $NIC_V $VF_D | tail -1)
	bind_vfio $HV
	/bin/vtool hold $HV > /tmp/h.out 2>&1 &
	H=$!
	sleep 1
	log "holder $H holds $HV ($(drv_of $HV)); pciehp removes it first"
	( slot_power $SLOT 0; log "P: slot $SLOT power off returned" ) &
	P=$!
	i=0
	while ! dmesg | grep -q "$HV: Relaying device request"; do
		sleep 0.1; i=$((i + 1)); [ $i -gt 100 ] && break
	done
	log "P: pciehp waits for the holder of $HV (request relayed: $([ $i -le 100 ] && echo yes || echo no))"
	log "U: unbind $PF from $(drv_of $PF)"
	( echo $PF > /sys/bus/pci/devices/$PF/driver/unbind; log "U: unbind returned" ) &
	U=$!
	# U removes VFs 0..NVF-2, then waits for HV's device_lock (held by pciehp).
	# Bounded by time: a kernel that serializes the two leaves all VFs in place
	# until the holder is killed (keep the hold below the 20 s hung-task timeout).
	end=$(awk "BEGIN{print $(up) + 5}")
	while [ "$(devs $NIC_V $VF_D | wc -l)" -gt 1 ] && awk "BEGIN{exit !($(up) < $end)}"; do sleep 0.1; done
	sleep 1
	log "VFs left while the holder holds $HV: $(devs $NIC_V $VF_D | tr '\n' ' ')"
	dstacks "before kill"
	evidence
	A0=$E_ASSERT
	kill -9 $H
	log "holder killed"
	stuck=
	wait_exit $P 30 || stuck="$stuck pciehp"
	wait_exit $U 30 || stuck="$stuck unbind"
	sleep 2
	[ -n "$stuck" ] && dstacks "stuck:$stuck"
	evidence
	left=$(( $(devs $NIC_V $PF_D | wc -l) + $(devs $NIC_V $VF_D | wc -l) ))
	bug=$((E_KASAN + E_GPF + E_REF + E_LIST))
	[ $((E_ASSERT + bug)) -gt 0 ] && o=FAIL || o=PASS
	[ -n "$stuck" ] && [ $o = PASS ] && o=HANG
	stuck=${stuck# }
	result "$o pfunbind=hold assert=$E_ASSERT assert_before_kill=$A0 kasan=$E_KASAN oops=$E_GPF refcount=$E_REF listcorr=$E_LIST stuck=${stuck:-none} left=$left debug_locks_before=$DL0"
	;;
race)
	r=1 hits=0 o=PASS
	while [ $r -le $ROUNDS ]; do
		if [ $r -gt 1 ]; then
			act add pf1 rp1 igb
			setup_pf || { o="FAIL setup-round-$r"; break; }
		fi
		d=$(( (r - 1) % 5 * 10 ))
		evidence; B=$((E_KASAN + E_GPF + E_REF + E_LIST))
		log "round $r: slot power off + unbind after $d ms"
		( slot_power $SLOT 0; log "P$r: power off returned" ) &
		P=$!
		sleep $(awk "BEGIN{print $d/1000}")
		( echo $PF > /sys/bus/pci/devices/$PF/driver/unbind 2>/dev/null; log "U$r: unbind returned" ) &
		U=$!
		stuck=
		wait_exit $P 30 || stuck="$stuck pciehp"
		wait_exit $U 30 || stuck="$stuck unbind"
		sleep 1
		evidence
		n=$((E_KASAN + E_GPF + E_REF + E_LIST - B)); stuck=${stuck# }
		log "round $r: delay=${d}ms new-bugs=$n stuck=${stuck:-none} left=$(( $(devs $NIC_V $PF_D | wc -l) + $(devs $NIC_V $VF_D | wc -l) ))"
		[ $n -gt 0 ] && { hits=$((hits + 1)); echo "ROUND-HIT $r delay=${d}ms"; }
		[ $n -gt 0 ] && { o=FAIL; break; }	# a use-after-free leaves the kernel unreliable
		[ -n "$stuck" ] && { dstacks "round $r stuck:$stuck"; o=HANG; break; }
		wait_count $NIC_V $PF_D 0 10 || { o="FAIL pf-left-round-$r"; break; }
		r=$((r + 1))
	done
	[ $r -gt $ROUNDS ] && r=$ROUNDS
	evidence
	[ $((E_ASSERT + E_KASAN + E_GPF + E_REF + E_LIST)) -gt 0 ] && [ $o = PASS ] && o=FAIL
	result "$o pfunbind=race rounds=$r hits=$hits stuck=${stuck:-none} assert=$E_ASSERT kasan=$E_KASAN oops=$E_GPF refcount=$E_REF listcorr=$E_LIST debug_locks_before=$DL0"
	;;
esac
lockdep_check
