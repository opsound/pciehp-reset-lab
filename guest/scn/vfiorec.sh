# (E26; W11, W6) A vfio-pci device's config space after AER recovery.
# pcie_do_recovery() resets the bridge's secondary bus
# (aer_root_reset() -> pci_bus_error_reset()) without saving or restoring
# config space; only drivers whose ->slot_reset() runs restore their devices,
# and report_slot_reset() runs only when the error_detected votes merge to
# NEED_RESET.  Mainline vfio-pci votes CAN_RECOVER.
#
# A vfio-pci NIC is opened by vtool, which sets Bus Master through vfio's
# config region (VT_CMD_OR=4), as a user driver would, and mmaps BAR0.  One
# fatal error (DLP, 0x10) is injected through /dev/aer_inject.  Before and
# after the recovery the scenario reads BAR0 and COMMAND from sysfs config and
# has vtool read COMMAND through vfio, BAR0 + 8 (e1000e STATUS) through vfio's
# BAR0 region and through the mmap.
#
# var=TOPO[+FLAG...]
#   TOPO ep  (default) nic1 on rp1 (00:10.0); the error is injected on the NIC:
#            recovery runs on rp1's bus, where only vfio-pci votes (E26's shape)
#   TOPO sw  nicd1 below the switch's dp1 (Root Port 00:1e.0); the error is
#            injected on the switch's Upstream Port: recovery runs on the Root
#            Port's bus, the switch ports (pcieport) vote NEED_RESET
#   +rec     vtool opts in to W6's VFIO_DEVICE_FEATURE_PCI_ERROR_RECOVERY with
#            an eventfd and reports its state (ENOTTY without W6)
#   +nf      a non-fatal error (Completion Timeout, 0x4000) instead
#   +hook    no aer_inject: pcitest/aer_reset (pcie_do_recovery(), frozen) of
#            the Root Port with a 4 s aer_link_delay_ms; vtool probes during
#            the delay, after error_detected and before the reset
#   +msix, +intx  vtool arms one interrupt of that type and re-arms it after a
#            reported reset (VT_REARM)
#   +d3      vtool puts the NIC into D3hot before the error
#   TOPO sw2 the same with a second e1000e on dp2
#   +fail    the second NIC (sw2) is unbound, so the recovery fails (no
#            driver: NO_AER_DRIVER)
# a=N: N errors in a row (default 1).
#
# After the recovery vtool closes the device and the scenario reopens it
# (vtool loop 1): "reopen=ok|ERR".
#
# RESULT: PASS if after the recovery BAR0 matches the resource and memory
# decode is on, else FAIL BAR-LOST.  Bus Master, the MMIO reads, W6's state and
# the probe during the recovery (+hook) are reported.
topo=${var%%+*}
has() { case "+$var+" in *"+$1+"*) return 0;; esac; return 1; }
case $topo in
sw|sw2) topo=sw RP=0000:00:1e.0 ;;
*) topo=ep RP=0000:00:10.0 ;;
esac
need /bin/vtool || return
if has hook; then need $DBG/aer_reset $DBG/aer_link_delay_ms || return; else need /dev/aer_inject /bin/aerinj || return; fi
EPS=$(for d in $(devs $NIC_V $NIC_D); do readlink -f /sys/bus/pci/devices/$d | grep -q "/$RP/" && echo $d; done)
EP=$(echo "$EPS" | head -1)
[ -n "$EP" ] || { result "FAIL setup: no NIC below $RP"; return; }
if [ $topo = sw ] && ! has hook; then
	TGT=$(cd /sys/bus/pci/devices/$RP && ls -d 0000:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f].[0-7] 2>/dev/null | head -1)
else
	TGT=$EP
fi
ls /sys/bus/pci_express/drivers/aer/ 2>/dev/null | grep -q "^$RP:" || { result "SKIP no AER service on $RP"; return; }
if has fail; then
	EP2=$(echo "$EPS" | sed -n 2p)
	[ -n "$EP2" ] || { result "FAIL setup: no second NIC below $RP"; return; }
	echo $EP2 > /sys/bus/pci/devices/$EP2/driver/unbind
	NO_ADDED_CHECK=1
	log "unbound $EP2 (driver=$(drv_of $EP2))"
fi
bind_vfio $EP
[ "$(drv_of $EP)" = vfio-pci ] || { result "FAIL setup: $EP not bound to vfio-pci"; return; }
VTENV="VT_CMD_OR=4 VT_MMAP=1"
has rec && VTENV="$VTENV VT_REC=1"
has msix && VTENV="$VTENV VT_IRQ=msix VT_REARM=1"
has intx && VTENV="$VTENV VT_IRQ=intx VT_REARM=1"
has d3 && VTENV="$VTENV VT_D3=1"
env $VTENV vtool hold $EP > /tmp/vt.out 2>&1 &
VT=$!
i=0; while ! grep -q READY /tmp/vt.out && [ $i -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
grep -q READY /tmp/vt.out || { cat /tmp/vt.out; result "FAIL setup: vtool did not open $EP"; return; }
grep -E "^VT(REC|IRQ|MMAP|PM|CMD) " /tmp/vt.out
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
wait_msg() {	# PATTERN TIMEOUT_S
	local i=0
	while ! dmesg | grep -q "$1"; do
		[ $i -ge $(( $2 * 20 )) ] && return 1
		sleep 0.05; i=$((i + 1))
	done
}
bar_ok $EP; pre=$BAR_INFO
vprobe before
pre_v=$VTP
log "rp=$RP ep=$EP target=$TGT var=$var before: $pre ($(grep VTCMD /tmp/vt.out))"

trace_on vfio_pci_core_aer_err_detected vfio_pci_core_aer_slot_reset vfio_pci_core_aer_resume pcie_portdrv_slot_reset pci_bus_error_reset pciehp_reset_slot pci_bus_reset pci_slot_reset
unc=0x10; has nf && unc=0x4000
during=-
for e in $(seq 1 ${a:-1}); do
	n0=$(dmesg | grep -c "device recovery")
	if has hook; then
		echo 4000 > $DBG/aer_link_delay_ms
		( echo "$RP" > $DBG/aer_reset; log "R: aer_reset returned rc=$?" ) &
		R=$!
		if wait_msg "aer_reset $RP: link delay" 10; then
			sleep 0.5
			vprobe during
			during=$(echo "$VTP" | tr ' ' ',')
		fi
		wait_exit $R 40 || { echo 0 > $DBG/aer_link_delay_ms; dstacks "stuck"; result "FAIL HANG recovery stuck"; lockdep_check; return; }
		echo 0 > $DBG/aer_link_delay_ms
	else
		aerinj $TGT $unc 0 1
		i=0
		while [ "$(dmesg | grep -c 'device recovery')" = "$n0" ] && [ $i -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
	fi
	sleep 1
done
tr=$(trace_dump)
echo 0 > $T/tracing_on; echo nop > $T/current_tracer
rec=$(dmesg | grep "device recovery" | tail -1 | grep -o "recovery [a-z]*" | cut -d' ' -f2)
nvs=$(echo "$tr" | grep -c "vfio_pci_core_aer_slot_reset <-")
nvr=$(echo "$tr" | grep -c "vfio_pci_core_aer_resume <-")
nps=$(echo "$tr" | grep -c "pcie_portdrv_slot_reset <-")
dmesg | grep -E "AER:|recovery|aer_inject|Port link|vfio|pcitest" | tail -14
echo "$tr" | awk '{print $4, $5, $6}' | head -14

bar_ok $EP; r=$?
# A loaded host can stall the guest past bar_ok's 3 s bound: read again
[ "$BAR_INFO" = cfg-blocked ] && { sleep 1; bar_ok $EP; r=$?; }
if [ $r = 0 ]; then st=RESTORED; else st=BAR-LOST; fi
post=$BAR_INFO
vprobe after
cmd=${post##*cmd=0x}
case $cmd in ""|*[!0-9a-f]*) bme=unknown ;; *) bme=$(( (0x$cmd & 4) != 0 )) ;; esac
recst=$(echo "$VTP" | grep -o "rec=[^ ]*" | head -1); recst=${recst#rec=}
seq=$(echo "$VTP" | grep -o "seq=[0-9]*" | head -1); seq=${seq#seq=}
nev=$(grep -c "^VTREVT" /tmp/vt.out)
log "after: $post bme=$bme recovery=${rec:-none} vfio_slot_reset=$nvs vfio_resume=$nvr portdrv_slot_reset=$nps"
echo "CHECK: before $pre | $pre_v"
echo "CHECK: after $post | $VTP"
has hook && echo "CHECK: during $during"
kill -USR1 $VT; wait_exit $VT 20 || dstacks "vtool close"
grep -v VTPROBE /tmp/vt.out
ro=$(vtool loop 1 $EP 2>&1)
echo "$ro"
echo "$ro" | grep -q "^OK open+close 1/1" && reopen=ok || reopen=ERR:$(echo "$ro" | grep -o "GET_DEVICE_FD: .*" | head -1 | cut -d' ' -f2- | tr ' ' '_')
info="bme=$bme rec=${recst:--} seq=${seq:--} events=$nev during=$during reopen=$reopen vfio_slot_reset=$nvs vfio_resume=$nvr portdrv_slot_reset=$nps var=$var"
if [ "$rec" != successful ] && ! has fail; then
	result "FAIL recovery=${rec:-none} state=$st $info"
elif [ $st = RESTORED ] || has fail; then
	result "PASS recovery=${rec:-none} state=$st $info"
else
	result "FAIL recovery=${rec:-none} state=BAR-LOST $info"
fi
lockdep_check
