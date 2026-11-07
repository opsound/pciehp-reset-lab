# (N18) Recursive down_read(reset_lock) when the pciehp IRQ thread runtime
# resumes its own port.  pciehp_ist() holds reset_lock for reading; for a card
# in an OFF slot, pciehp_enable_slot()/pciehp_disable_slot() call
# pm_runtime_get_sync() on the port, which, if the port is runtime suspended,
# resumes it in the IRQ thread: pciehp_runtime_resume() -> pciehp_resume() ->
# pciehp_check_presence() -> down_read(reset_lock) again.  A slot reset queued
# on reset_lock in between makes the second read wait for the writer, which
# waits for the first read: deadlock.  Lockdep flags the recursion even
# without a writer.
#
# Setup (harness/run.py): pcie_port_pm=force, e1000e nic1 present at boot on
# rp1 (00:10.0, slot 1), so that bridge_d3 is set without a pciehp hot-add.
# QEMU's Root Ports have no PM capability, so the port runtime suspends in D0;
# pci_config_pm_runtime_get() only tests for D3cold, so the path is the same.
# var=remove  unbind the NIC and let it and the port runtime suspend; a loop of
#             slot resets of rp1 (pcitest2/slot_reset) queues writers; then
#             "echo 0 > slots/1/power" (pciehp_disable_slot())
# var=add     safe-remove the boot NIC; the port runtime suspends; QEMU
#             hot-adds nic1 (latched, no interrupt); slot reset loop; then
#             "echo 1 > slots/1/power" (pciehp_enable_slot())
# "+pin" (e.g. remove+pin) pins the slot reset loop to a CPU other than the
# IRQ thread's: the IRQ thread is SCHED_FIFO and doesn't sleep between the two
# reads, so a writer on its CPU can't queue in between.
RP=0000:00:10.0
SLOT=1
OPTS=${var#*+}; [ "$OPTS" = "$var" ] && OPTS=
var=${var%%+*}
PD=/sys/bus/pci/devices/$RP
rpm() { echo "status=$(cat $PD/power/runtime_status) control=$(cat $PD/power/control) active_kids=$(cat $PD/power/runtime_active_kids 2>/dev/null)"; }
# wait_rpm STATUS TIMEOUT_S: wait until the port's runtime_status is STATUS
wait_rpm() {
	local i=0
	while [ "$(cat $PD/power/runtime_status)" != "$1" ] && [ $i -lt $(( $2 * 20 )) ]; do sleep 0.05; i=$((i + 1)); done
	[ "$(cat $PD/power/runtime_status)" = "$1" ]
}
need $DBG2/slot_reset || return
log "port at start: $(rpm)"
B=$(devs $NIC_V $NIC_D)
[ -n "$B" ] || { result "FAIL no boot nic"; return; }
wait_bound_dev $B 5
log "nic $B driver=$(drv_of $B)"
case $var in
remove)
	echo $B > /sys/bus/pci/devices/$B/driver/unbind
	echo auto > /sys/bus/pci/devices/$B/power/control
	sleep 0.5
	log "nic $B driver=$(drv_of $B) rpm=$(cat /sys/bus/pci/devices/$B/power/runtime_status)"
	NO_ADDED_CHECK=1
	;;
add)
	unplug_slot $SLOT $NIC_V $NIC_D 0 || { result "FAIL nic not removed"; return; }
	log "nic removed, slot power=$(cat /sys/bus/pci/slots/$SLOT/power)"
	;;
*) result "FAIL unknown var $var"; return ;;
esac
if ! wait_rpm suspended 10; then
	log "port did not runtime-suspend: $(rpm)"
	result "SKIP port not runtime-suspended"
	return
fi
log "port suspended: $(rpm)"
if [ $var = add ]; then
	act add nic1 rp1
	sleep 3
	log "after hot-add: nics=$(devs $NIC_V $NIC_D | wc -l) slot power=$(cat /sys/bus/pci/slots/$SLOT/power) port: $(rpm)"
	if [ -n "$(devs $NIC_V $NIC_D)" ]; then
		result "SKIP hot-add was handled with the port resumed"
		return
	fi
	if [ "$(cat $PD/power/runtime_status)" != suspended ]; then
		result "SKIP port resumed by the hot-add: $(rpm)"
		return
	fi
fi

dmesg -n 5	# slot_reset logs two lines per reset; keep warnings on the console
H0=$(nhung)
L0=$(dmesg | grep -cE 'possible recursive|possible circular')
IRQ=$(dmesg | grep -m1 "pcieport $RP: PME: Signaling with IRQ" | awk '{print $NF}')
IST=$(for p in /proc/[0-9]*; do [ "$(cat $p/comm 2>/dev/null)" = "irq/$IRQ-pciehp" ] && echo ${p#/proc/}; done | head -1)
ISTCPU=$(awk '{print $39}' /proc/$IST/stat 2>/dev/null)
WCPU=
if [ -n "$OPTS" ] && [ -z "${OPTS##*pin*}" ] && [ -n "$ISTCPU" ]; then
	WCPU=$(( (ISTCPU + 1) % $(grep -c ^processor /proc/cpuinfo) ))
fi
log "IST pid=$IST cpu=$ISTCPU writer cpu=${WCPU:-any}"
if [ -n "$WCPU" ]; then
	taskset -c $WCPU sh -c "while :; do echo $RP > $DBG2/slot_reset; done" 2>/dev/null &
else
	sh -c "while :; do echo $RP > $DBG2/slot_reset; done" 2>/dev/null &
fi
WR=$!
sleep 0.5
if [ $var = remove ]; then
	(echo 0 > /sys/bus/pci/slots/$SLOT/power; log "power=0 returned rc=$?") &
else
	(echo 1 > /sys/bus/pci/slots/$SLOT/power; log "power=1 returned rc=$?") &
fi
PW=$!
if wait_exit $PW 45; then
	STUCK=0
else
	STUCK=1
	log "power write still blocked after 45 s"
fi
dmesg -n 7
log "port: $(rpm)"
if [ -n "$IST" ]; then
	echo "-- IST $IST state=$(awk '{print $3}' /proc/$IST/stat)"
	cat /proc/$IST/stack
fi
dstacks "after power write (stuck=$STUCK)"
kill $WR 2>/dev/null
H=$(( $(nhung) - H0 ))
L=$(( $(dmesg | grep -cE 'possible recursive|possible circular') - L0 ))
log "after: nics=$(devs $NIC_V $NIC_D | wc -l) port: $(rpm) resets=$(dmesg | grep -c 'pcitest2: slot_reset .*done')"
lockdep_check
if [ $STUCK = 1 ]; then
	NO_ADDED_CHECK=1	# the slot is stuck
	result "FAIL HANG power write blocked, hung=$H lockdep=$L"
elif [ $L -gt 0 ]; then
	result "FAIL LOCKDEP recursive reset_lock read, no hang, hung=$H"
else
	result "PASS no hang, no lockdep report"
fi
