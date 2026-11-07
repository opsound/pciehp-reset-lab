# (N23) A driver can bind to a device whose removal has begun.  Nested
# topology (harness/run.py): rps (00:1e.0, slot 40) - up1 - dp1 (nicd1), dp2
# (nicd2).  nicd1 is unbound from e1000e beforehand; nicd2 is bound to
# vfio-pci and held for 10 s, so that the removal of the switch waits for the
# holder in nicd2's unbinding.
# var=sysfs   sysfs "remove" of up1
#     pciehp  rps's slot powered off through sysfs (pciehp)
# While the removal waits: binding nicd1 to e1000e must fail with ENODEV and
# drivers_probe must leave it unbound.  Once the holder is killed, the switch
# and both NICs must be gone.  The time a rescan of rp1's (empty) secondary bus
# takes meanwhile is logged (rescan_waited=1: it waited for the removal, N22).
RPS=0000:00:1e.0
wait_count $NIC_V $NIC_D 2 60 || { result "FAIL setup"; return; }
N1= N2=
for b in $(devs $NIC_V $NIC_D); do
	[ -z "$N1" ] && N1=$b || N2=$b
done
DP1=$(port_of $N1); DP2=$(port_of $N2); UP1=$(port_of $DP1)
wait_bound_dev $N1 10; wait_bound_dev $N2 10
log "up1=$UP1 dp1=$DP1 nicd1=$N1 dp2=$DP2 nicd2=$N2 var=$var"
echo $N1 > /sys/bus/pci/devices/$N1/driver/unbind
bind_vfio $N2
/bin/vtool hold $N2 > /tmp/h.out 2>&1 &
H=$!
sleep 1
case $var in
sysfs) (echo 1 > /sys/bus/pci/devices/$UP1/remove; log "R: remove of up1 returned") & ;;
pciehp) (slot_power 40 0; log "R: slot 40 power off returned") & ;;
*) result "FAIL unknown var $var"; kill -9 $H; return ;;
esac
R=$!
RP1SEC=$(ls /sys/bus/pci/devices/0000:00:10.0/pci_bus | head -1)
(sleep 10; kill -9 $H; log "holder killed") &
sleep 2
bad=
alive $R || bad="$bad removal-returned-early"
if echo $N1 > /sys/bus/pci/drivers/e1000e/bind 2>/tmp/bind.err; then
	bad="$bad bind-succeeded"
else
	log "bind: $(cat /tmp/bind.err)"
	grep -q "No such device" /tmp/bind.err || bad="$bad bind-errno"
fi
echo $N1 > /sys/bus/pci/drivers_probe 2>/dev/null
d=$(drv_of $N1)
[ "$d" = none ] || bad="$bad probed:$d"
t0=$(up)
(echo 1 > /sys/class/pci_bus/$RP1SEC/rescan; log "rescan of $RP1SEC returned") &
S=$!
wait_exit $S 30 || bad="$bad rescan-stuck"
t1=$(up)
rw=0; alive $H || rw=1
log "rescan took $(awk "BEGIN{print $t1-$t0}") s"
wait_exit $H 20 || bad="$bad holder-stuck"
wait_exit $R 40 || { bad="$bad removal-stuck"; dstacks "removal stuck"; }
sleep 2
left=$(devs $NIC_V $NIC_D | wc -l)
[ -e /sys/bus/pci/devices/$UP1 ] && bad="$bad up1-left"
[ $left -eq 0 ] || bad="$bad nics-left:$left"
[ -z "$bad" ] && o=PASS || o="FAIL$bad"
result "$o rescan_waited=$rw rescan_s=$(awk "BEGIN{print $t1-$t0}")"
lockdep_check
