# Three-party deadlock: two vfio-pci NICs below two root ports, held by one
# process, safe-removed with device_del 2 s apart.
#   var=exit	the holder is SIGKILLed (process exit releases dev B, then dev A)
#   var=ioctl	the holder answers the request for dev A by VFIO_DEVICE_RESET on
#		dev B (after irq/B has started removing it), then closes dev A
#   var=sexit, sioctl	the same with surprise removal of both slots and the
#		devices' default reset methods: each device is detached
#		through its Root Port's Slot Control, as in deadreset.sh
#		(Power Controller and Indicator off with the hotplug interrupt
#		off, then Slot Control restored: Command Completed delivers
#		Presence Detect Changed, pciehp marks the device disconnected)
act add nic1 rp1
act add nic2 rp2
wait_count $NIC_V $NIC_D 2 60 || { result "FAIL setup: NICs not found"; return; }
set -- $(devs $NIC_V $NIC_D)
A=$1 B=$2
# surprise BDF: detach the device below Root Port BDF behind pciehp's back
surprise() {
	local rp=$1 x sc orig gone
	x=$(expcap $rp)
	sc=$((x + 0x18))
	orig=$((0x$(pcicfg $rp $sc 2)))
	gone=$(( (orig & ~0x730) | 0x700 ))
	pciwr $rp $sc 2 $(printf %04x $gone)
	pciwr $rp $sc 2 $(printf %04x $orig)
	log "surprise removal below $rp: sltsta=0x$(pcicfg $rp $((x + 0x1a)) 2) lnksta=0x$(pcicfg $rp $((x + 0x12)) 2)"
}
case $var in
s*) bind_vfio $A; bind_vfio $B ;;
*) bind_vfio $A bus; bind_vfio $B bus ;;
esac
case $var in
ioctl|sioctl) VT_REQ_DELAY_MS=4000 /bin/vtool hold --reset-on-req $A $B > /tmp/h.out 2>&1 & ;;
*) /bin/vtool hold $A $B > /tmp/h.out 2>&1 & ;;
esac
H=$!
sleep 1; cat /tmp/h.out
case $var in
s*) PA=$(port_of $A) PB=$(port_of $B)
	surprise $PA
	sleep 2
	surprise $PB
	sleep 2
	for d in $A $B; do [ -e /sys/bus/pci/devices/$d ] && log "$d still present"; done
	sleep 16 ;;
*) act del nic1
	sleep 2
	act del nic2
	sleep 20 ;;
esac
cat /tmp/h.out
dstacks "before kill"
case $var in ioctl|sioctl) ;; *) kill -9 $H ;; esac
if wait_exit $H 40; then
	sleep 3
	left=$(devs $NIC_V $NIC_D | wc -l)
	[ $left -eq 0 ] && result "PASS holder exited, devices removed" || result "FAIL holder exited, $left devices left"
else
	result "FAIL holder stuck"
	dstacks "after kill"
fi
cat /tmp/h.out
lockdep_check
