# (N22) Removal holds pci_rescan_remove_lock while vfio-pci's ->remove()
# waits for user space to close the device, so enumeration and removal stall
# system-wide.  A device is bound to vfio-pci and held by a process that
# ignores release requests (vtool hold), then its removal starts; while the
# removal waits for the holder, a rescan of rp2's (empty) secondary bus is
# timed: it needs the lock but has nothing to do with rp1.  The holder is
# killed HOLD s (12) after the rescan starts.
# var=pciehp    e1000e on rp1, slot 1 powered off through sysfs
#     sysfs     e1000e on rp1, sysfs "remove" of the NIC
#     pfpciehp  igb PF on rp1 with 2 VFs, VF 0 held; slot 1 powered off
#     pfsysfs   same, sysfs "remove" of the PF
#     numvfs    same, sriov_numvfs=0
# PASS: the rescan returns within 4 s while the holder still holds the device,
# and the removal completes once the holder is killed.
HOLD=12
PF_D=0x10c9 VF_D=0x10ca
case $var in
pciehp|sysfs) act add d1 rp1 e1000e ;;
pfpciehp|pfsysfs|numvfs) act add d1 rp1 igb ;;
*) result "FAIL unknown var $var"; return ;;
esac
PF= A=
case $var in
pciehp|sysfs)
	wait_count $NIC_V $NIC_D 1 60 || { result "FAIL setup e1000e"; return; }
	A=$(devs $NIC_V $NIC_D)
	wait_bound_dev $A 10
	;;
*)
	wait_count $NIC_V $PF_D 1 60 || { result "FAIL setup igb"; return; }
	PF=$(devs $NIC_V $PF_D)
	wait_bound_dev $PF 10
	echo 2 > /sys/bus/pci/devices/$PF/sriov_numvfs
	wait_count $NIC_V $VF_D 2 30 || { result "FAIL setup VFs"; return; }
	A=$(devs $NIC_V $VF_D | head -1)
	;;
esac
bind_vfio $A
/bin/vtool hold $A > /tmp/h.out 2>&1 &
H=$!
sleep 1
log "holder $H holds $A ($(drv_of $A)) pf=$PF var=$var"
case $var in
pciehp|pfpciehp) (slot_power 1 0; log "R: slot 1 power off returned") & ;;
sysfs) (echo 1 > /sys/bus/pci/devices/$A/remove; log "R: remove of $A returned") & ;;
pfsysfs) (echo 1 > /sys/bus/pci/devices/$PF/remove; log "R: remove of $PF returned") & ;;
numvfs) (echo 0 > /sys/bus/pci/devices/$PF/sriov_numvfs; log "R: sriov_numvfs=0 returned") & ;;
esac
R=$!
RP2SEC=$(ls /sys/bus/pci/devices/0000:00:11.0/pci_bus | head -1)
sleep 2
alive $R || log "R returned before the holder was killed"
(sleep $HOLD; kill -9 $H; log "holder killed") &
t0=$(up)
(echo 1 > /sys/class/pci_bus/$RP2SEC/rescan; log "rescan of $RP2SEC returned") &
S=$!
wait_exit $S $((HOLD + 30)) || log "rescan stuck"
t1=$(up)
held=0; alive $H && held=1
rs=$(awk "BEGIN{print $t1-$t0}")
log "rescan took $rs s, holder alive at its return: $held"
[ $held = 1 ] || dstacks "rescan waited for the holder"
bad=
wait_exit $H 30 || bad="$bad holder-stuck"
wait_exit $R 40 || { bad="$bad removal-stuck"; dstacks "removal stuck"; }
sleep 2
nvf=$(devs $NIC_V $VF_D | wc -l)
case $var in
pciehp|sysfs) [ $(devs $NIC_V $NIC_D | wc -l) -eq 0 ] || bad="$bad nic-left" ;;
pfpciehp|pfsysfs) [ $(( $(devs $NIC_V $PF_D | wc -l) + nvf )) -eq 0 ] || bad="$bad pf-or-vfs-left" ;;
*) [ $nvf -eq 0 ] || bad="$bad vfs-left" ;;
esac
awk "BEGIN{exit !($rs < 4)}" && [ $held = 1 ] || bad="$bad rescan-waited"
[ -z "$bad" ] && o=PASS || o="FAIL$bad"
result "$o rescan_s=$rs held=$held"
lockdep_check
