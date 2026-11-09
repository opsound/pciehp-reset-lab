# pci_dpc_recovered(): how long pciehp waits for DPC recovery of its port.
# QEMU's Root Ports have no DPC capability, so the TEST ONLY hook
# pcitest/dpc_reset emulates DPC recovery: it gives rp1 a dpc_cap that reads
# Trigger Status clear and ignores writes, then runs pcie_do_recovery(rp1,
# frozen, dpc_reset_link), and queues the Data Link Layer State Changed event
# that containment causes once dpc_reset_link() has set PCI_DPC_RECOVERING:
# pciehp then waits in pci_dpc_recovered() while dpc_reset_link() polls the
# NIC in pci_bridge_wait_for_secondary_bus().
#
# Before the recovery the NIC on rp1 stops answering config requests while
# presence, link and slot power stay up: rp1's Secondary and Subordinate Bus
# Numbers are moved to an unused bus through config mechanism #1, behind the
# kernel's back, so QEMU no longer routes config requests for bus 1 to the NIC
# (reads return ~0).  Unlike deadreset's power-controller trick, the slot
# stays powered, so pciehp's teardown is not skipped as "Already disabled".
# var=dead  the NIC stays dead and is surprise-removed a= s (3) into the
#           recovery (indicator off through config mechanism #1, then Slot
#           Control restored: Presence Detect Changed).  PASS: pciehp removes
#           the device within 5 s of the surprise removal.
#     slow  the bus numbers are restored a= s (4.5) into the recovery: a device
#           that needs more than 4 s to answer after DPC.  PASS: the recovery
#           succeeds, pciehp ignores the link change and the NIC keeps its
#           pci_dev, driver, netdev and BAR0.
RP=0000:00:10.0
case $var in dead) AT=${a:-3} ;; slow) AT=${a:-4.5} ;; *) result "FAIL unknown var $var"; return ;; esac
need $DBG/dpc_reset || return

c1() { cf1 "$1" "$2"; }
since() { awk "BEGIN{printf \"%.1f\", $(up) - $1}"; }
dt() { awk "BEGIN{printf \"%.1f\", $2 - $1}"; }
ifidx() { cat /sys/bus/pci/devices/$1/net/*/ifindex 2>/dev/null | head -1; }

wait_count $NIC_V $NIC_D 1 60 || { result "FAIL setup e1000e"; return; }
A=$(devs $NIC_V $NIC_D)
wait_bound_dev $A 10
hotadd_check $A > /dev/null
X=$(expcap $RP)
[ $X -ne 0 ] || { result "FAIL no PCIe capability on $RP"; return; }
SLTCTL=$(printf %x $((X + 0x18))) SLTSTA=$(printf %x $((X + 0x1a))) LNKSTA=$(printf %x $((X + 0x12)))
slot() { echo "lnksta=0x$(c1 $RP $LNKSTA.w) sltsta=0x$(c1 $RP $SLTSTA.w) sltctl=0x$(c1 $RP $SLTCTL.w)"; }
[ "$(c1 $RP 0.w)" = "$(pcicfg $RP 0 2)" ] || { result "SKIP config mechanism #1 does not work"; return; }
ORIG=$((0x$(pcicfg $RP 0x$SLTCTL 2)))
GONE=$(( ORIG | 0x700 ))		# Power Controller and Indicator off: QEMU detaches the device
BUS0=$((0x$(c1 $RP 18.l)))
BUSX=$(( (BUS0 & 0xff0000ff) | 0x707000 ))	# secondary = subordinate = 0x70 (unused)
IF0=$(ifidx $A)
log "nic $A ($(drv_of $A), ifindex $IF0) below $RP, slot: $(slot)"
td() { dmesg | grep -cE 'Slot\([0-9]+\): (Link Down|Card not present)$'; }
n_ld=$(td)
log "rp1 AER Header Log DW0 (fake DPC Status): $(pcicfg $RP 0x11c 4)"

c1 $RP 18.l=$(printf %08x $BUSX)
sleep 1
log "device disabled, link up: $(slot) nic_cmd=0x$(c1 $A 4.w)"

t0=$(up)
(echo $RP > $DBG/dpc_reset; log "R: dpc_reset of $RP returned $?") & R=$!
rm -f /tmp/rend
(while alive $R; do sleep 0.05; done; up > /tmp/rend) &
while awk "BEGIN{exit !($(up) - $t0 < $AT)}"; do sleep 0.05; done
ty=$(up)
if [ $var = dead ]; then
	c1 $RP $SLTCTL.w=$(printf %04x $(( GONE & ~0x30 )))	# no HPIE/CCIE: no interrupt yet
	c1 $RP $SLTCTL.w=$(printf %04x $ORIG)
	log "surprise removal $(since $t0) s into the recovery: $(slot)"
	i=0
	while [ -e /sys/bus/pci/devices/$A ] && [ $i -lt 1200 ]; do sleep 0.05; i=$((i + 1)); done
	[ -e /sys/bus/pci/devices/$A ] && gone_s=none || gone_s=$(since $ty)
	log "device removed $gone_s s after the surprise removal"
else
	c1 $RP 18.l=$(printf %08x $BUS0)
	log "bus numbers restored $(since $t0) s into the recovery: $(slot) nic_cmd=0x$(c1 $A 4.w)"
fi
sleep 2
alive $R && dstacks "$(since $t0) s into the recovery"
wait_exit $R 300 || log "recovery still running after 300 s"
sleep 0.5
te=$(cat /tmp/rend 2>/dev/null || up)
rec_s=$(dt $t0 $te)
log "recovery returned after $rec_s s"
log "rp1 AER Header Log DW0 (fake DPC Status) after recovery: $(pcicfg $RP 0x11c 4)"
dmesg | grep -E 'pcitest: dpc|not ready|ready [0-9]+ms|Link Down|Link Up|Card not present|Card present|ignored|recovery|subordinate device reset|e1000e.*(PCI|reset)' | tail -20
n_ld2=$(td)
recov=$(dmesg | grep -c 'device recovery successful')
st="recovery_s=$rec_s teardowns=$((n_ld2 - n_ld)) recovered=$recov"
if [ $var = dead ]; then
	st="$st removed_s=$gone_s after_removal_s=$(dt $ty $te)"
	[ "$gone_s" != none ] && awk "BEGIN{exit !($gone_s <= 5)}" && o=PASS || o=FAIL
else
	sleep 3
	IF1=$(ifidx $A)
	bar_ok $A; b=$?
	st="$st driver=$(drv_of $A) ifindex=$IF0->${IF1:-none} $BAR_INFO"
	[ $recov -ge 1 ] && [ $((n_ld2 - n_ld)) -eq 0 ] && [ "$IF1" = "$IF0" ] && [ $b -eq 0 ] && o=PASS || o=FAIL
	[ -e /sys/bus/pci/devices/$A ] || NO_ADDED_CHECK=1
fi
[ $var = dead ] && NO_ADDED_CHECK=1
result "$o $st"
lockdep_check
