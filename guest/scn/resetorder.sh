# (N25) Order of pci_dev_save_and_disable() in a slot/bus reset with a switch
# below the reset port: "reset_subordinate" of rps (00:1e.0) ->
# pci_try_reset_bridge() -> pci_slot_save_and_disable_locked() (var=*bus:
# hotplug=off on rps, so pci_bus_save_and_disable_locked()).  Nested topology: rps - up1 - dp1
# (virtio-blk, whose ->reset_prepare() resets the device through its BAR and
# waits for its requests), dp2 (e1000e nicd2).  v7.4-rc1 clears up1's Command
# register before the drivers below get ->reset_prepare(): their MMIO goes
# nowhere.  var=io (default) / busio: direct reads of /dev/vda in a loop across
# the resets; a request whose doorbell write is lost never completes and
# virtio-blk's ->reset_prepare() waits for it with the device locks held.
# var=x / bus: no I/O; the status read in virtio_device_reset_prepare() must
# return the live status (0xf), not 0.  a= resets.
RPS=0000:00:1e.0
rounds=${a:-3}
VBV=0x1af4 VBD=0x1042
wait_count $VBV $VBD 1 20 || { result "FAIL no virtio-blk"; return; }
wait_count $NIC_V $NIC_D 1 20 || { result "FAIL no e1000e"; return; }
VB=$(devs $VBV $VBD); NIC=$(devs $NIC_V $NIC_D)
wait_bound_dev $VB 10; wait_bound_dev $NIC 10
i=0; while [ ! -b /dev/vda ] && [ $i -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
[ -b /dev/vda ] || { result "FAIL no /dev/vda"; return; }
log "virtio-blk $VB ($(drv_of $VB)) below $(port_of $VB), e1000e $NIC ($(drv_of $NIC))"
dd if=/dev/vda of=/dev/null bs=4k count=64 iflag=direct 2>/dev/null || { result "FAIL read before reset"; return; }

echo 0 > $T/tracing_on
echo > $T/trace
echo 'r:resetorder/vstatus vp_modern_get_status st=$retval:x8' >> $T/kprobe_events
echo 1 > $T/events/resetorder/enable
echo 1 > $T/events/printk/console/enable 2>/dev/null

IOP=
case "$var" in *io) ( while :; do dd if=/dev/vda of=/dev/null bs=64k count=16 iflag=direct 2>/dev/null ||
	echo "dd failed $(up)" >> /tmp/ioerr; done ) & IOP=$! ;; esac
bad= unreach=
r=1
while [ $r -le $rounds ]; do
	echo > $T/trace
	echo 1 > $T/tracing_on
	rm -f /tmp/rs
	( echo 1 > /sys/bus/pci/devices/$RPS/reset_subordinate; echo "rc=$?" > /tmp/rs ) &
	P=$!
	if ! wait_exit $P 30; then
		result "HANG reset_subordinate round $r"
		log "vda inflight (read write): $(cat /sys/block/vda/inflight)"
		dstacks "reset round $r"
		return
	fi
	echo 0 > $T/tracing_on
	# The order the devices were disabled in ("resetting": drivers without
	# ->reset_prepare()) and the status virtio-blk read before its own.
	log "round $r: reset_subordinate $(cat /tmp/rs); order: $(grep -oE 'console: [a-z0-9_]+ [0-9a-f:.]+: resetting|virtio_device_reset_prepare[^ ]* <- vp_modern_get_status\) st=0x[0-9a-f]+' $T/trace |
		sed -e 's/console: [a-z0-9_]* \([0-9a-f:.]*\): resetting/\1/' -e 's/.*st=/virtio-status=/' | tr '\n' ' ')"
	st=$(grep -o 'virtio_device_reset_prepare[^ ]* <- vp_modern_get_status) st=0x[0-9a-f]*' $T/trace | head -1 | sed 's/.*st=//')
	[ "$st" = 0xf ] || unreach="$unreach r$r:${st:-none}"
	timeout 10 dd if=/dev/vda of=/dev/null bs=4k count=64 iflag=direct 2>/dev/null || bad="$bad read-after-$r"
	r=$((r + 1))
done
[ -n "$IOP" ] && { kill $IOP; wait $IOP 2>/dev/null; }
echo 0 > $T/events/resetorder/enable
[ -s /tmp/ioerr ] && bad="$bad io-errors=$(wc -l < /tmp/ioerr)"
nb=$(dmesg | grep -c "I/O error")
[ "$nb" -gt 0 ] && bad="$bad kernel-io-errors=$nb"
[ "$(drv_of $VB)" = none ] && bad="$bad virtio-unbound"
[ "$(drv_of $NIC)" = none ] && bad="$bad e1000e-unbound"
[ -n "$unreach" ] && bad="$bad reset_prepare-unreachable:$unreach"
if [ -n "$bad" ]; then result "FAIL$bad"; else result "OK resets=$rounds"; fi
