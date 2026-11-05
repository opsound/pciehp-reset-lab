# Three-party deadlock: two vfio-pci NICs below two root ports, held by one
# process, safe-removed with device_del 2 s apart.
#   var=exit	the holder is SIGKILLed (process exit releases dev B, then dev A)
#   var=ioctl	the holder answers the request for dev A by VFIO_DEVICE_RESET on
#		dev B (after irq/B has started removing it), then closes dev A
act add nic1 rp1
act add nic2 rp2
wait_count $NIC_V $NIC_D 2 60 || { result "FAIL setup: NICs not found"; return; }
set -- $(devs $NIC_V $NIC_D)
A=$1 B=$2
bind_vfio $A bus
bind_vfio $B bus
case $var in
ioctl) VT_REQ_DELAY_MS=4000 /bin/vtool hold --reset-on-req $A $B > /tmp/h.out 2>&1 & ;;
*) /bin/vtool hold $A $B > /tmp/h.out 2>&1 & ;;
esac
H=$!
sleep 1; cat /tmp/h.out
act del nic1
sleep 2
act del nic2
sleep 20
cat /tmp/h.out
dstacks "before kill"
[ "$var" = ioctl ] || kill -9 $H
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
