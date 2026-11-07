# N24: device_shutdown() vs AER recovery.
#
# device_shutdown() (drivers/base/core.c:4911-4913) locks the parent and the
# device, then calls pci_device_shutdown() -> pcie_portdrv_shutdown()
# (pcie/portdrv.c:739) -> pcie_port_device_remove() -> device_unregister() of
# each port service.  pcie_pme_remove() and the AER service's devres
# (devm_request_threaded_irq(), aer.c:1823) call free_irq(), and
# __free_irq() -> __synchronize_irq() (kernel/irq/manage.c:128) waits until
# no threaded handler of the port's IRQ is active - the IRQ is shared by the
# services (one MSI-X vector on QEMU's pcie-root-port), so this includes
# aer_isr().  aer_isr() -> pcie_do_recovery() -> aer_root_reset() ->
# pci_bus_error_reset() -> pci_reset_bridge() locks the Root Port first:
# pci_slot_reset() -> pci_slot_lock() or pci_bus_reset() -> pci_bus_lock(),
# both __pci_bus_lock() -> pci_dev_lock(bus->self) (pci.c:5429).  If the Root
# Port's shutdown holds its device lock when aer_isr() gets there, shutdown
# waits for the thread and the thread for the lock: the system never powers
# off.  Lockdep does not see it (device mutexes are novalidate, and the IRQ
# synchronization is not annotated), the hung-task detector does.  The bridge
# lock is in pci_bus_lock() since a4e772898f8b (v6.11) and in pci_slot_lock()
# since 1f5e57c622b4 (v7.0).
#
# No hooks or knobs.  Setup (run.py): e1000e nic1 below rp1 (00:10.0) at boot.
# Errors are injected with /dev/aer_inject (aerinj): the kernel fakes the AER
# status of nic1 and rp1 and injects rp1's interrupt, so aer_irq()/aer_isr()
# and the recovery run as for a real error.  One fatal error (DLP, 0x10)
# first checks that recovery works and which reset it uses; then a
# background aerinj injects fatal errors every a= ms (default 10) and keeps
# running into init's poweroff (sysrq o -> kernel_power_off() ->
# device_shutdown()).
#
# var=slot  (default) rp1 is hotplug-capable: pciehp's slot, pci_slot_reset()
# var=bus   rp1 with hotplug=off: no slot, pci_bus_reset() (the reported path)
# a=MS      interval between injected errors; a=once: no background injection
#           (control: the same shutdown without errors); a=poweroff: a single
#           error, injected when "sysrq: Power Off" appears in the kernel log;
#           a=nicdown: a single error when e1000e's shutdown of nic1 logs
#           "EEE TX LPI TIMER" (device_shutdown() holds nic1 and rp1 then)
#
# The guest prints RESULT: PASS ... and "CHECK: poweroff": harness/qxparse.py
# then requires "reboot: Power down" on the console after GUEST-DONE (run.py
# waits shutdown_check s for it), else the result becomes FAIL poweroff=hang
# (or =panic once init exits); hung-task reports (timeout lowered to 5 s
# here) make the verdict HANG.
RP=0000:00:10.0
IV=${a:-10}
NO_ADDED_CHECK=1	# devices are being reset by the injected errors
need /dev/aer_inject /bin/aerinj || return
EP=$(cd /sys/bus/pci/devices/$RP && ls -d 0000:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f].[0-7] 2>/dev/null | head -1)
[ -n "$EP" ] || { result "FAIL setup: no device below $RP"; return; }
ls /sys/bus/pci_express/drivers/aer/ 2>/dev/null | grep -q "^$RP:" || { result "SKIP no AER service on $RP"; return; }
SEC=${EP#0000:}; SEC=${SEC%%:*}
slot=none
for s in /sys/bus/pci/slots/*; do
	[ "$(cat $s/address 2>/dev/null)" = "0000:$SEC:00" ] && slot=${s##*/}
done
log "rp=$RP ep=$EP ($(drv_of $EP)) slot=$slot var=$var interval_ms=$IV"
grep -E "aerdrv|pciehp|PME" /proc/interrupts | sed 's/  */ /g'

# One fatal error: recovery must succeed; record which reset it used
trace_on pci_bus_error_reset pci_slot_reset pciehp_reset_slot pci_bus_reset
n0=$(dmesg | grep -c "device recovery")
t0=$(up)
aerinj $EP 0x10 0 1
i=0
while [ "$(dmesg | grep -c 'device recovery')" = "$n0" ] && [ $i -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
t1=$(up)
tr=$(trace_dump)
echo 0 > $T/tracing_on; echo nop > $T/current_tracer
rec=$(dmesg | grep "device recovery" | tail -1 | grep -o "recovery [a-z]*" | cut -d' ' -f2)
nslot=$(echo "$tr" | grep -c "pciehp_reset_slot <-")
nbus=$(echo "$tr" | grep -c "pci_bus_reset <-")
path=none
[ "$nslot" -gt 0 ] && path=slot
[ "$path" = none ] && [ "$nbus" -gt 0 ] && path=bus
log "single error: recovery=${rec:-none} path=$path pciehp_reset_slot=$nslot pci_bus_reset=$nbus ($(echo "$t1 - $t0" | awk '{print $1 - $3}') s)"
echo "$tr" | head -6
[ "$rec" = successful ] || { result "FAIL setup: recovery=${rec:-none} path=$path"; return; }
case $var in
slot|bus) [ "$path" = "$var" ] || { result "FAIL setup: expected the $var path, recovery used $path"; return; } ;;
esac

echo 5 > /proc/sys/kernel/hung_task_timeout_secs
echo "CHECK: poweroff"
if [ "$IV" = once ]; then
	result "PASS path=$path storm=none"
	return
fi
case $IV in poweroff|nicdown)
	# One fatal error once init's poweroff begins / reaches nic1
	pat="sysrq: Power Off"; [ $IV = nicdown ] && pat="EEE TX LPI TIMER"
	AERINJ_WAIT="$pat" aerinj $EP 0x10 0 1 > /tmp/aerinj.out 2>&1 &
	result "PASS path=$path storm=single-at-$IV"
	return
esac
# Fatal errors every IV ms, into the poweroff.  aerinj keeps its output in a
# file: the scenario's pipe is gone once init powers off.
aerinj $EP 0x10 0 0 $((IV * 1000)) > /tmp/aerinj.out 2>&1 &
sleep 2
head -3 /tmp/aerinj.out
log "storm: injected=$(dmesg | grep -c 'Injecting errors') recoveries=$(dmesg | grep -c 'device recovery')"
result "PASS path=$path interval_ms=$IV"
