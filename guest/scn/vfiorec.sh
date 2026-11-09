# (E26) A vfio-pci device's config space after AER recovery from a fatal
# error.  pcie_do_recovery() resets the bridge's secondary bus
# (aer_root_reset() -> pci_bus_error_reset()) without saving or restoring
# config space; only drivers whose ->slot_reset() runs restore their devices,
# and report_slot_reset() runs only when the error_detected votes merge to
# NEED_RESET.  vfio-pci votes CAN_RECOVER.
#
# A vfio-pci NIC is opened by vtool, which sets Bus Master through vfio's
# config region (VT_CMD_OR=4), as a user driver would.  One fatal error (DLP,
# 0x10) is injected through /dev/aer_inject.  Before and after the recovery the
# scenario reads BAR0 and COMMAND from sysfs config and has vtool read COMMAND
# through vfio and BAR0 + 8 (e1000e STATUS) through vfio's BAR0 region.
#
# var=ep  (default) nic1 on rp1 (00:10.0); the error is injected on the NIC:
#         recovery runs on rp1's bus, where only vfio-pci votes (E26's shape)
# var=sw  nicd1 below the switch's dp1 (Root Port 00:1e.0); the error is
#         injected on the switch's Upstream Port: recovery runs on the Root
#         Port's bus, the switch ports (pcieport) vote NEED_RESET
#
# RESULT: PASS if after the recovery BAR0 matches the resource and memory
# decode is on, else FAIL BAR-LOST.  Bus Master (bme=, set by the user before
# the error) and the MMIO read are reported, not checked.
case $var in
sw) RP=0000:00:1e.0 ;;
*) var=ep RP=0000:00:10.0 ;;
esac
need /dev/aer_inject /bin/aerinj /bin/vtool || return
EP=$(for d in $(devs $NIC_V $NIC_D); do readlink -f /sys/bus/pci/devices/$d | grep -q "/$RP/" && echo $d; done | head -1)
[ -n "$EP" ] || { result "FAIL setup: no NIC below $RP"; return; }
if [ $var = sw ]; then
	TGT=$(cd /sys/bus/pci/devices/$RP && ls -d 0000:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f].[0-7] 2>/dev/null | head -1)
else
	TGT=$EP
fi
ls /sys/bus/pci_express/drivers/aer/ 2>/dev/null | grep -q "^$RP:" || { result "SKIP no AER service on $RP"; return; }
bind_vfio $EP
[ "$(drv_of $EP)" = vfio-pci ] || { result "FAIL setup: $EP not bound to vfio-pci"; return; }
VT_CMD_OR=4 vtool hold $EP > /tmp/vt.out 2>&1 &
VT=$!
i=0; while ! grep -q READY /tmp/vt.out && [ $i -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
grep -q READY /tmp/vt.out || { cat /tmp/vt.out; result "FAIL setup: vtool did not open $EP"; return; }
vprobe() {	# LABEL: vtool's reads through vfio
	local n0 i=0
	n0=$(grep -c VTPROBE /tmp/vt.out)
	kill -HUP $VT
	while [ "$(grep -c VTPROBE /tmp/vt.out)" = "$n0" ] && [ $i -lt 30 ]; do
		sleep 0.1; i=$((i + 1))
		[ $i = 10 ] && kill -HUP $VT
	done
	VTP=$(grep VTPROBE /tmp/vt.out | tail -1 | cut -d' ' -f3-)
	log "$1 vfio: $VTP"
}
bar_ok $EP; pre=$BAR_INFO
vprobe before
pre_v=$VTP
log "rp=$RP ep=$EP target=$TGT var=$var before: $pre ($(grep VTCMD /tmp/vt.out))"

trace_on vfio_pci_core_aer_slot_reset pcie_portdrv_slot_reset pci_bus_error_reset pciehp_reset_slot pci_bus_reset pci_slot_reset
# a=N: N fatal errors in a row (default 1), each after the previous recovery
for e in $(seq 1 ${a:-1}); do
	n0=$(dmesg | grep -c "device recovery")
	aerinj $TGT 0x10 0 1
	i=0
	while [ "$(dmesg | grep -c 'device recovery')" = "$n0" ] && [ $i -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
	sleep 1
done
tr=$(trace_dump)
echo 0 > $T/tracing_on; echo nop > $T/current_tracer
rec=$(dmesg | grep "device recovery" | tail -1 | grep -o "recovery [a-z]*" | cut -d' ' -f2)
nvs=$(echo "$tr" | grep -c "vfio_pci_core_aer_slot_reset <-")
nps=$(echo "$tr" | grep -c "pcie_portdrv_slot_reset <-")
dmesg | grep -E "AER:|recovery|aer_inject|Port link|vfio" | tail -12
echo "$tr" | awk '{print $4, $5, $6}' | head -12

bar_ok $EP; r=$?
# A loaded host can stall the guest past bar_ok's 3 s bound: read again
[ "$BAR_INFO" = cfg-blocked ] && { sleep 1; bar_ok $EP; r=$?; }
if [ $r = 0 ]; then st=RESTORED; else st=BAR-LOST; fi
post=$BAR_INFO
vprobe after
cmd=${post##*cmd=0x}
case $cmd in ""|*[!0-9a-f]*) bme=unknown ;; *) bme=$(( (0x$cmd & 4) != 0 )) ;; esac
log "after: $post bme=$bme recovery=${rec:-none} vfio_slot_reset=$nvs portdrv_slot_reset=$nps"
echo "CHECK: before $pre | $pre_v"
echo "CHECK: after $post | $VTP"
kill -USR1 $VT; wait_exit $VT 20 || dstacks "vtool close"
cat /tmp/vt.out | grep -v VTPROBE
[ "$rec" = successful ] || { result "FAIL recovery=${rec:-none} state=$st vfio_slot_reset=$nvs"; lockdep_check; return; }
if [ $st = RESTORED ]; then
	result "PASS state=RESTORED bme=$bme vfio_slot_reset=$nvs portdrv_slot_reset=$nps var=$var"
else
	result "FAIL state=BAR-LOST bme=$bme vfio_slot_reset=$nvs portdrv_slot_reset=$nps var=$var"
fi
lockdep_check
