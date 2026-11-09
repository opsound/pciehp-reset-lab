# Resets of an igb PF with 2 enabled VFs.  igb PF "pf1" present at boot on rp1
# (slot 1).  Bus Master is set in VF0's Command register before each step; a
# reset of the PF clears VF Enable, so the re-created VF0 reads Command 0
# afterwards.  Reset calls are counted with the function tracer.
#
# var=sysfs   (default) igb on the PF, igbvf on the VFs: "reset" attribute of
#             the PF, then again after sriov_numvfs=0.
# var=vfio    PF bound to vfio-pci (enable_sriov=1), VFs enabled through
#             vfio-pci: open+close, VFIO_DEVICE_RESET, VFIO_DEVICE_PCI_HOT_RESET
#             (vtool loop/resetloop/hotresetloop 1), then open+close after
#             sriov_numvfs=0.
# PASS: VF0 keeps its Command register through every step with VFs enabled
# (the reset may be refused), and the PF is still reset at sriov_numvfs=0.
PF_D=0x10c9 VF_D=0x10ca
FUNCS="__pci_reset_function_locked pcie_flr pciehp_reset_slot pci_bridge_secondary_bus_reset pci_reset_bus_function"

sriov_ctrl() {	# PF SR-IOV Control register (hex)
	local p=256 h id
	while [ $p -ne 0 ]; do
		h=$((0x$(pcicfg $PF $p 4)))
		id=$((h & 0xffff))
		[ $id -eq 16 ] && { pcicfg $PF $((p + 8)) 2; return; }
		p=$(( (h >> 20) & 0xffc ))
	done
	echo none
}
vf0cmd() { pcicfg $VF0 0x04 2; }
setbm() { local c=$((0x$(vf0cmd))); pciwr $VF0 4 2 $(printf %04x $((c | 4))); }
counts() {	# "func=N ..." from the trace
	local t=/tmp/tr.$$ f out=
	trace_dump > $t
	for f in $FUNCS; do out="$out $f=$(grep -c " $f <-" $t)"; done
	rm -f $t
	echo "${out# }"
}
step_begin() {
	setbm
	B_CMD=$(vf0cmd) B_CTRL=$(sriov_ctrl)
	trace_on $FUNCS
}
step_end() {	# LABEL RESULT
	local c=$(counts) a=$(vf0cmd)
	echo "STEP $1: $2; resets: $c; VF0 cmd $B_CMD->$a; sriov_ctrl $B_CTRL->$(sriov_ctrl); numvfs=$(cat /sys/bus/pci/devices/$PF/sriov_numvfs)"
	echo "$1 $2 | $c | VF0cmd $B_CMD->$a" >> /tmp/steps
	[ "$a" = "$B_CMD" ] || WIPED="$WIPED $1"
}
# novfs_end LABEL RESULT: the reset at sriov_numvfs=0 must still happen
novfs_end() {
	local c=$(counts)
	echo "STEP $1: $2; resets: $c"
	echo "$1 $2 | $c" >> /tmp/steps
	echo "$c" | grep -qE "=[1-9]" || NORESET="$NORESET $1"
}
WIPED= NORESET=

wait_count $NIC_V $PF_D 1 60 || { result "FAIL setup: no PF"; return; }
PF=$(devs $NIC_V $PF_D)
wait_bound_dev $PF 10
log "PF=$PF driver=$(drv_of $PF) reset_method=$(cat /sys/bus/pci/devices/$PF/reset_method)"
: > /tmp/steps

case $var in
sysfs)
	echo 2 > /sys/bus/pci/devices/$PF/sriov_numvfs || { result "FAIL setup: sriov_numvfs"; return; }
	wait_count $NIC_V $VF_D 2 30 || { result "FAIL setup: VFs"; return; }
	VF0=$(devs $NIC_V $VF_D | head -1)
	wait_bound_dev $VF0 10
	log "VF0=$VF0 driver=$(drv_of $VF0)"
	step_begin
	( echo 1 > /sys/bus/pci/devices/$PF/reset ) 2> /tmp/err && r=ok || r="err:$(sed 's/.*error: //' /tmp/err)"
	step_end sysfs-reset-vfs "$r"
	echo 0 > /sys/bus/pci/devices/$PF/sriov_numvfs
	wait_count $NIC_V $VF_D 0 30
	trace_on $FUNCS
	( echo 1 > /sys/bus/pci/devices/$PF/reset ) 2> /tmp/err && r=ok || r="err:$(sed 's/.*error: //' /tmp/err)"
	novfs_end sysfs-reset-novfs "$r"
	;;
vfio)
	bind_vfio $PF
	echo 1 > /sys/module/vfio_pci/parameters/enable_sriov
	echo 2 > /sys/bus/pci/devices/$PF/sriov_numvfs || { result "FAIL setup: sriov_numvfs"; return; }
	wait_count $NIC_V $VF_D 2 30 || { result "FAIL setup: VFs"; return; }
	VF0=$(devs $NIC_V $VF_D | head -1)
	sleep 1
	log "VF0=$VF0 driver=$(drv_of $VF0)"
	for s in loop resetloop hotresetloop; do
		step_begin
		/bin/vtool $s 1 $PF > /tmp/v.out 2>&1
		step_end vfio-$s-vfs "$(grep -E '^(OK|ERRS|reset 0)' /tmp/v.out | tr '\n' ' ')"
	done
	echo 0 > /sys/bus/pci/devices/$PF/sriov_numvfs
	wait_count $NIC_V $VF_D 0 30
	trace_on $FUNCS
	/bin/vtool loop 1 $PF > /tmp/v.out 2>&1
	novfs_end vfio-loop-novfs "$(grep -E '^(OK|ERRS)' /tmp/v.out | tr '\n' ' ')"
	;;
*) result "FAIL unknown var $var"; return ;;
esac
cat /tmp/steps
if [ -n "$WIPED" ] || [ -n "$NORESET" ]; then
	result "FAIL var=$var VFs-wiped-by:${WIPED:- none} no-reset:${NORESET:- none}"
else
	result "PASS var=$var steps=$(wc -l < /tmp/steps)"
fi
lockdep_check
