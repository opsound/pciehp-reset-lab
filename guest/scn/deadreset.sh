# N14: a reset of a slot whose device stopped answering config
# requests while its link stays up holds the reset's locks for ~65 s
# (pci_bridge_wait_for_secondary_bus() -> pci_dev_wait(), PCIE_RESET_READY_POLL_MS),
# and a surprise removal during the wait does not end it: pciehp waits for the
# reset before it handles the event, so it can't mark the device disconnected.
#
# A dead device with the link up, without test hooks: QEMU has no RRS, but its
# slot power controller does it.  Power Controller Control = off with the Power
# Indicator left on makes QEMU disable the device (config reads return ~0, BARs
# unmapped) while Presence Detect State and Data Link Layer Link Active stay
# set; QEMU only detaches the device once the indicator is off too
# (hw/pci/pcie.c: pcie_cap_update_power(), pcie_cap_slot_write_config()).  The
# write goes through the sysfs config file, behind pciehp's back.
# YANK s after the reset started, the indicator is turned off through config
# mechanism #1 (/bin/cf1: the reset holds the config access lock
# of the device, and with var=sysfs/vfio of the Root Port too): QEMU detaches
# the device, clears Presence Detect State and Link Active and sets Presence
# Detect Changed; that write also clears the hotplug and Command Completed
# interrupt enables, so it raises no interrupt.  A second write restores Slot
# Control as pciehp left it (power and indicator on: pciehp skips the teardown
# of a slot it finds powered off), and its Command Completed interrupt delivers
# Presence Detect Changed to pciehp: a surprise removal during the reset.
#
# var=sysfs     sysfs "reset" of the NIC, reset_method=bus: pci_reset_function()
#               holds device_lock + config access lock of NIC and Root Port,
#               pciehp_reset_slot() reset_lock for writing
#     vfio      NIC bound to vfio-pci (reset_method=bus), held by vtool, which is
#               SIGKILLed: vfio_pci_core_disable() resets the device on release
#               (same locks), then vfio_pci_dev_set_try_reset() tries pci_reset_bus()
#     sub       sysfs "reset_subordinate" of the Root Port: pci_try_reset_bridge()
#               holds pci_slot_mutex, the slot's device locks and reset_lock
#     aer       QEMU injects a fatal AER error into the Root Port
#               (pcie_aer_inject_error rp1 MALF_TLP): pcie_do_recovery() ->
#               aer_root_reset() -> pci_bus_error_reset(), locks as sub
#     linkdown  control: the device is detached (link down) before the reset,
#               with the slot's hotplug interrupt disabled so that the kernel
#               still has the device; re-enabled after the reset
# All but linkdown time a user config read of the Root Port and of the NIC
# (started 3 s into the reset); sub and aer also hot-add nic2 on rp2 (3 s) and
# start a global rescan (4 s): enumeration takes pci_slot_mutex in
# pci_dev_assign_slot() under pci_rescan_remove_lock.
# PASS: the reset returns within 5 s of the surprise removal (linkdown: of its
# start).
RP=0000:00:10.0 RP2=0000:00:11.0 ta=
YANK=${DR_YANK:-5}
case $var in sysfs|vfio|sub|aer|linkdown) ;; *) result "FAIL unknown var $var"; return ;; esac

# c1 BDF REG[=VAL]: config access through mechanism #1, past the kernel's
# config access lock (registers below 0x100 only)
c1() { cf1 "$1" "$2"; }
# since T: seconds since uptime T
since() { awk "BEGIN{printf \"%.1f\", $(up) - $1}"; }
dt() { awk "BEGIN{printf \"%.1f\", $2 - $1}"; }

wait_count $NIC_V $NIC_D 1 60 || { result "FAIL setup e1000e"; return; }
A=$(devs $NIC_V $NIC_D)
wait_bound_dev $A 10
hotadd_check $A > /dev/null
X=$(expcap $RP)
[ $X -ne 0 ] || { result "FAIL no PCIe capability on $RP"; return; }
SLTCTL=$(printf %x $((X + 0x18))) SLTSTA=$(printf %x $((X + 0x1a))) LNKSTA=$(printf %x $((X + 0x12)))
slot() { echo "lnksta=0x$(c1 $RP $LNKSTA.w) sltsta=0x$(c1 $RP $SLTSTA.w) sltctl=0x$(c1 $RP $SLTCTL.w) nic_cmd=0x$(c1 $A 4.w)"; }
[ "$(c1 $RP 0.w)" = "$(pcicfg $RP 0 2)" ] || { result "SKIP config mechanism #1 does not work"; return; }
ORIG=$((0x$(pcicfg $RP 0x$SLTCTL 2)))
DEAD=$(( (ORIG & ~0x700) | 0x500 ))	# Power Controller off, Power Indicator on
GONE=$(( DEAD | 0x300 ))		# Power Indicator off too: QEMU detaches the device
case $var in
vfio) bind_vfio $A bus
	/bin/vtool hold $A > /tmp/h.out 2>&1 &
	H=$!
	sleep 1
	alive $H || { result "FAIL vtool hold"; cat /tmp/h.out; return; } ;;
sysfs|linkdown) echo bus > /sys/bus/pci/devices/$A/reset_method ;;
esac
log "nic $A ($(drv_of $A)) below $RP, reset_method=$(cat /sys/bus/pci/devices/$A/reset_method), slot: $(slot)"
graph_on pciehp_reset_slot pci_reset_function pci_try_reset_bridge pci_bus_error_reset pci_reset_bus vfio_pci_core_disable
echo 1 > $T/options/funcgraph-tail 2>/dev/null

if [ $var = linkdown ]; then
	pciwr $RP 0x$SLTCTL 2 $(printf %04x $(( GONE & ~0x30 )))	# HPIE, CCIE off
	sleep 1
	log "device detached with the hotplug interrupt off: $(slot)"
else
	pciwr $RP 0x$SLTCTL 2 $(printf %04x $DEAD)
	sleep 1
	log "device disabled, link up: $(slot)"
fi

t0=$(up)
case $var in
sysfs|linkdown) (echo 1 > /sys/bus/pci/devices/$A/reset; log "R: reset of $A returned $?") & R=$! ;;
sub) (echo 1 > /sys/bus/pci/devices/$RP/reset_subordinate; log "R: reset_subordinate of $RP returned $?") & R=$! ;;
vfio) kill -9 $H; R=$H ;;
aer) n0=$(dmesg | grep -c 'AER:.*Fatal') n1=$(dmesg | grep -c 'Port link has been reset')
	act qmp human-monitor-command '{"command-line": "pcie_aer_inject_error rp1 MALF_TLP"}'
	i=0
	while [ $(dmesg | grep -c 'AER:.*Fatal') -le $n0 ] && [ $i -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
	[ $(dmesg | grep -c 'AER:.*Fatal') -gt $n0 ] || { result "FAIL no AER error seen"; return; }
	t0=$(up)
	(while [ $(dmesg | grep -c 'Port link has been reset') -le $n1 ]; do sleep 0.2; done
	 log "R: aer_root_reset returned") & R=$! ;;
esac
log "reset started ($var)"
rm -f /tmp/rend
(while alive $R; do sleep 0.05; done; up > /tmp/rend) &
ty=
if [ $var != linkdown ]; then
	sleep 3
	(s=$(up); pcicfg $RP 0 2 > /dev/null; echo "$s $(up)" > /tmp/pcfg) &
	(s=$(up); pcicfg $A 0 2 > /dev/null; echo "$s $(up)" > /tmp/dcfg) &
	if [ $var = sub ] || [ $var = aer ]; then
		ta=$(up)
		act add nic2 rp2 e1000e
		(while :; do
			b=$(ls /sys/bus/pci/devices/$RP2/ 2>/dev/null | grep -m1 -E '^[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-7]$')
			[ -n "$b" ] && [ "$(drv_of $b)" != none ] && break
			sleep 0.1
		done; echo "$(up) $b" > /tmp/add2) &
		sleep 1
		(s=$(up); echo 1 > /sys/bus/pci/rescan; echo "$s $(up)" > /tmp/rescan) &
	fi
	while awk "BEGIN{exit !($(up) - $t0 < $YANK)}"; do sleep 0.1; done
	c1 $RP $SLTCTL.w=$(printf %04x $(( GONE & ~0x30 )))	# no HPIE/CCIE: no interrupt yet
	ty=$(up)
	c1 $RP $SLTCTL.w=$(printf %04x $ORIG)
	log "surprise removal $(since $t0) s into the reset: $(slot)"
	sleep 4
	alive $R && dstacks "$(since $t0) s into the reset"
fi
wait_exit $R 300 || log "reset still running after 300 s"
sleep 0.2
te=$(cat /tmp/rend 2>/dev/null || up)
reset_s=$(dt $t0 $te)
log "reset returned after $reset_s s"
if [ $var = linkdown ]; then
	ty=$t0
	pciwr $RP 0x$SLTCTL 2 $(printf %04x $ORIG)	# power and HPIE back on: pciehp sees Presence Detect Changed
fi
i=0
while [ -e /sys/bus/pci/devices/$A ] && [ $i -lt 1200 ]; do sleep 0.1; i=$((i + 1)); done
[ -e /sys/bus/pci/devices/$A ] && gone_s=none || gone_s=$(since $ty)
after_s=$(dt $ty $te)
st="reset_s=$reset_s"
[ $var = linkdown ] || st="$st after_removal_s=$after_s"
st="$st removed_s=$gone_s"
for p in pcfg:portcfg dcfg:devcfg rescan:rescan; do
	f=/tmp/${p%%:*}
	[ -s $f ] && st="$st ${p#*:}_s=$(dt $(cat $f))"
done
if [ -n "$ta" ]; then
	i=0
	while [ ! -s /tmp/add2 ] && [ $i -lt 300 ]; do sleep 0.1; i=$((i + 1)); done
	[ -s /tmp/add2 ] && st="$st hotadd_s=$(dt $ta $(cut -d' ' -f1 /tmp/add2))" || st="$st hotadd_s=none"
fi
trace_dump > /tmp/tr
# function_graph: "N us | } /* func */" (nested) or "N us | func();" (leaf)
held=$(grep -oE '[0-9.]+ us +\| +(\} /\* [a-z_0-9]+ \*/|[a-z_0-9]+\(\);)' /tmp/tr |
	sed -E 's|[}/*();]||g' | awk '{printf "%s=%.1fs ", $NF, $1/1e6}')
echo "STATS held: $held"
grep -E ' us +\|' /tmp/tr | head -10
dmesg | grep -E 'not ready|ready [0-9]+ms|Link Down|Card not present|Port link has been reset|recovery|pcie_aer|AER:' | tail -12
if [ $var = linkdown ]; then
	awk "BEGIN{exit !($reset_s <= 5)}" && o=PASS || o=FAIL
else
	awk "BEGIN{exit !($after_s <= 5)}" && o=PASS || o=FAIL
fi
result "$o $st"
lockdep_check
