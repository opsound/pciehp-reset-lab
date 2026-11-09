# AER recovery from errors injected through /dev/aer_inject (the real AER
# interrupt and pcie_do_recovery()) with devices that have no driver bound, and
# with a bound driver that has no pci_error_handlers.  Every recovery resets
# the bus below rp2 (00:11.0).
#
# var=new        e1000e nic2 hot-added on rp2 with drivers_autoprobe=0, never
#                bound; two fatal errors (DLP) at nic2; then e1000e is bound.
#                PASS: both recoveries successful with BAR0 kept, and e1000e
#                binds with its BARs.
#     nonfatal   the same with one non-fatal error (Completion Timeout)
#     mf         e1000e+e1000e multifunction on rp2 at boot; fn0 unbound via
#                sysfs; fatal error at fn1 (bound); then fn0 is rebound.
#                PASS: recovery successful, fn1 keeps BAR0, fn0 rebinds with
#                its BARs.  fn0's Command register is reported (f0_cmd=).
#     vfs        igb PF on rp2 at boot, sriov_drivers_autoprobe=0, 2 VFs left
#                unbound; fatal error at the PF; then the VFs are bound.
#                PASS: recovery successful, PF keeps BAR0, both VFs present
#                and bound by igbvf afterwards.
#     nohandler  qemu-xhci on rp2 at boot (xhci_hcd has no pci_error_handlers);
#                fatal error at rp2.  PASS: unless the recovery is reported
#                successful although the device lost its BARs (the
#                NO_AER_DRIVER vote must make the recovery fail, as since
#                918b4053184c).
RP=0000:00:11.0
NO_ADDED_CHECK=1
need /dev/aer_inject /bin/aerinj || return

nrec() { dmesg | grep -c "device recovery"; }
# inject BDF UNCOR: one error; REC = successful|failed|none
inject() {
	local n0 i=0
	n0=$(nrec)
	aerinj $1 $2 0 1 > /dev/null
	while [ "$(nrec)" = "$n0" ] && [ $i -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
	sleep 1
	REC=$(dmesg | grep "device recovery" | tail -1 | grep -o "recovery [a-z]*" | cut -d' ' -f2)
	REC=${REC:-none}
}
cfgs() { echo "bar0=0x$(pcicfg $1 0x10 4) bar1=0x$(pcicfg $1 0x14 4) cmd=0x$(pcicfg $1 0x04 2)"; }
# barm BDF: BAR0 register matches resource 0 (decode not required)
barm() {
	local reg res
	reg=$(pcicfg $1 0x10 4); res=$(head -1 /sys/bus/pci/devices/$1/resource | awk '{print $1}')
	[ -n "$reg" ] && [ $(( 0x$reg & ~0xf )) -eq $(( res & 0xffffffff )) ] && echo ok || echo lost
}
kids() { ls -d /sys/bus/pci/devices/$RP/0000:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f].[0-7] 2>/dev/null | sed 's,.*/,,'; }
ers() { dmesg | grep -E "AER:|e1000e|igb|xhci|pcieport $RP" | grep -vE "Corrected|Multiple" | tail -${1:-12}; }

case $var in
new|nonfatal)
	echo 0 > /sys/bus/pci/drivers_autoprobe
	act add nic2 rp2
	wait_count $NIC_V $NIC_D 1 10 || { result "FAIL setup: nic2 not enumerated"; return; }
	sleep 1
	EP=$(devs $NIC_V $NIC_D)
	log "before: $EP driver=$(drv_of $EP) $(cfgs $EP) barm=$(barm $EP)"
	unc=0x10; [ $var = nonfatal ] && unc=0x4000
	inject $EP $unc; r1=$REC; b1=$(barm $EP)
	log "error 1 ($unc): recovery=$r1 $(cfgs $EP) barm=$b1"
	r2=-; b2=-
	if [ $var = new ]; then
		inject $EP $unc; r2=$REC; b2=$(barm $EP)
		log "error 2 ($unc): recovery=$r2 $(cfgs $EP) barm=$b2"
	fi
	ers 16
	echo 1 > /sys/bus/pci/drivers_autoprobe
	echo $EP > /sys/bus/pci/drivers_probe 2>/dev/null
	wait_bound_dev $EP 5
	sleep 1
	net=$(ls /sys/bus/pci/devices/$EP/net 2>/dev/null | head -1)
	bind="$(drv_of $EP)${net:+/$net}"
	bar_ok $EP && bo=ok || bo=bad
	log "bind: driver=$bind $BAR_INFO"
	dmesg | grep -E "e1000e.*$EP|$EP.*e1000e" | tail -6
	o=FAIL
	[ $r1 = successful ] && [ $b1 = ok ] && { [ $var = nonfatal ] || { [ $r2 = successful ] && [ $b2 = ok ]; }; } &&
		[ "$(drv_of $EP)" = e1000e ] && [ $bo = ok ] && o=PASS
	result "$o var=$var rec1=$r1 bar1=$b1 rec2=$r2 bar2=$b2 bind=$bind bound_bar=$bo"
	;;
mf)
	set -- $(kids); F0=$1; F1=$2
	[ -n "$F1" ] || { result "FAIL setup: functions=$(kids | tr '\n' ' ')"; return; }
	echo $F0 > /sys/bus/pci/drivers/e1000e/unbind
	sleep 1
	log "before: f0=$F0 driver=$(drv_of $F0) $(cfgs $F0); f1=$F1 driver=$(drv_of $F1) $(cfgs $F1)"
	inject $F1 0x10
	bar_ok $F1 && b1=ok || b1=bad
	f0cmd=0x$(pcicfg $F0 0x04 2)	# unbound: Bus Master should be off
	log "error: recovery=$REC f0: $(cfgs $F0) barm=$(barm $F0); f1: $BAR_INFO"
	ers 16
	echo $F0 > /sys/bus/pci/drivers_probe 2>/dev/null
	wait_bound_dev $F0 5
	sleep 1
	bar_ok $F0 && b0=ok || b0=bad
	net=$(ls /sys/bus/pci/devices/$F0/net 2>/dev/null | head -1)
	log "rebind f0: driver=$(drv_of $F0)${net:+/$net} $BAR_INFO"
	o=FAIL
	[ $REC = successful ] && [ $b1 = ok ] && [ "$(drv_of $F0)" = e1000e ] && [ $b0 = ok ] && o=PASS
	result "$o var=mf rec=$REC f1_bar=$b1 f0_rebind=$(drv_of $F0)${net:+/$net} f0_bar=$b0 f0_cmd=$f0cmd"
	;;
vfs)
	PF=$(kids | head -1)
	[ "$(drv_of $PF)" = igb ] || { result "FAIL setup: pf=$PF driver=$(drv_of $PF)"; return; }
	echo 0 > /sys/bus/pci/devices/$PF/sriov_drivers_autoprobe
	echo 2 > /sys/bus/pci/devices/$PF/sriov_numvfs
	sleep 2
	VFS=$(ls -d /sys/bus/pci/devices/$PF/virtfn* 2>/dev/null | xargs -n1 readlink -f 2>/dev/null | sed 's,.*/,,')
	log "before: pf=$PF $(cfgs $PF); vfs: $(for v in $VFS; do echo -n "$v=$(drv_of $v) "; done)"
	inject $PF 0x10
	bar_ok $PF && bp=ok || bp=bad
	nv=$(cat /sys/bus/pci/devices/$PF/sriov_numvfs)
	log "error: recovery=$REC pf: $BAR_INFO numvfs=$nv"
	np=0
	for v in $VFS; do
		c=$(pcicfg $v 4 2); [ "$c" != ffff ] && np=$((np + 1))
		log "  vf $v cmd=0x$c (ffff: VF gone)"
	done
	ers 16
	nb=0
	echo 1 > /sys/bus/pci/devices/$PF/sriov_drivers_autoprobe
	for v in $VFS; do echo $v > /sys/bus/pci/drivers_probe 2>/dev/null; done
	sleep 3
	for v in $VFS; do [ "$(drv_of $v)" = igbvf ] && nb=$((nb + 1)); done
	dmesg | grep -E "igbvf" | tail -6
	o=FAIL
	[ $REC = successful ] && [ $bp = ok ] && [ $np = 2 ] && [ $nb = 2 ] && o=PASS
	result "$o var=vfs rec=$REC pf_bar=$bp vfs_present=$np vfs_bound_after=$nb/$(echo $VFS | wc -w)"
	;;
nohandler)
	EP=$(kids | head -1)
	[ -n "$EP" ] || { result "FAIL setup: no device below $RP"; return; }
	log "before: $EP driver=$(drv_of $EP) $(cfgs $EP)"
	b0="$(pcicfg $EP 0x10 4)/$(pcicfg $EP 0x14 4)"
	inject $RP 0x10
	b1="$(pcicfg $EP 0x10 4)/$(pcicfg $EP 0x14 4)"
	[ "$b0" = "$b1" ] && bs=kept || bs=lost
	log "error: recovery=$REC $EP driver=$(drv_of $EP) $(cfgs $EP)"
	ers 16
	o=PASS
	[ $REC = successful ] && [ $bs = lost ] && o=FAIL
	result "$o var=nohandler rec=$REC driver=$(drv_of $EP) bars=$bs"
	;;
*)	result "FAIL unknown var $var" ;;
esac
lockdep_check
