# (N4, bus reset path) pci_bus_reset(), reached through pci_bus_error_reset()
# of a bridge without hotplug slots (AER/DPC recovery, host bridge Root Port
# resets), locks and unlocks the devices below by walking bus->devices without
# pci_bus_sem and without references.  Nested topology with rpsopts
# hotplug=off: rps (00:1e.0, no slot) - up1 - dp1 (nicd1), dp2 (nicd2).  Each
# round, a loop writes rps to pcitest/err_reset (pci_bus_error_reset() ->
# pci_bus_reset(), no lock held) while up1 is removed through sysfs 10-490 ms
# later; then the switch is rescanned.  Run on a KASAN kernel.
#   var=plain  (default) resets vs removal
#   var=bind   plus an unbind/bind loop of e1000e on both NICs
#   var=sub    the loop writes rps's reset_subordinate instead
#              (pci_try_reset_bridge() -> pci_try_reset_bus(), no slot)
#   +cont      (e.g. plain+cont) don't stop at a leaked lock, only at KASAN
#              reports, oopses and stuck operations
# a= rounds (default 20).  v7.4-rc1 leaks a device lock taken by the lock walk
# ("lock held when returning to user space", the bind/unbind loop then hangs)
# or hits a freed pci_dev or pci_bus (KASAN).
SW_V=0x104c USP_D=0x8232 DSP_D=0x8233 RPS=0000:00:1e.0
R=${a:-20}
LEAK="lock held when returning"
KBUG="BUG: KASAN|general protection|list_(add|del) corruption|Oops|BUG: unable|kernel BUG|held lock freed"
need $DBG/err_reset || return
case $var in
*cont*) BRK=$KBUG ;;
*) BRK="$KBUG|$LEAK" ;;
esac

setup() {
	wait_count $SW_V $USP_D 1 30 && wait_count $SW_V $DSP_D 2 30 && wait_count $NIC_V $NIC_D 2 30 || return 1
	USP=$(devs $SW_V $USP_D)
	sleep 1
}
reset_loop() {
	( n=0 ok=0 er=0
	  while [ ! -e /tmp/stop ]; do
		case $var in
		*sub*) echo 1 > /sys/bus/pci/devices/$RPS/reset_subordinate ;;
		*) echo "$RPS" > $DBG/err_reset ;;
		esac 2>/dev/null && ok=$((ok + 1)) || er=$((er + 1))
		n=$((n + 1))
	  done
	  echo "RLOOP n=$n ok=$ok err=$er" ) &
}
bind_loop() {
	( while [ ! -e /tmp/stop ]; do
		for b in $NICS; do
			echo $b > /sys/bus/pci/drivers/e1000e/unbind 2>/dev/null
			echo $b > /sys/bus/pci/drivers/e1000e/bind 2>/dev/null
		done
	  done ) &
}
fail=0
for r in $(seq 1 $R); do
	setup || { log "round $r: switch not enumerated"; fail=1; break; }
	NICS=$(devs $NIC_V $NIC_D)
	[ $r = 1 ] && log "USP=$USP NICS=$(echo $NICS) var=$var"
	rm -f /tmp/stop
	reset_loop; RP=$!
	BP=
	case $var in *bind*) bind_loop; BP=$! ;; esac
	d=$(printf "0.%03d" $((RANDOM % 480 + 10)))
	sleep $d
	log "round $r: sysfs remove $USP after ${d}s"
	( echo 1 > /sys/bus/pci/devices/$USP/remove ) & RM=$!
	wait_exit $RM 60 || { log "round $r: sysfs remove stuck"; dstacks "remove stuck"; fail=1; }
	touch /tmp/stop
	wait_exit $RP 60 || { log "round $r: reset loop stuck"; dstacks "reset stuck"; fail=1; }
	[ -n "$BP" ] && { wait_exit $BP 60 || { log "round $r: bind loop stuck"; dstacks "bind stuck"; fail=1; }; }
	if dmesg | grep -qE "$BRK"; then log "round $r: kernel bug reported"; fail=1; fi
	[ $fail = 0 ] || break
	echo 1 > /sys/bus/pci/rescan
done
l=$(dmesg | grep -c "$LEAK") k=$(dmesg | grep -c "BUG: KASAN") o=$(dmesg | grep -vE "BUG: KASAN" | grep -cE "$KBUG") h=$(nhung)
if [ $fail = 0 ] && [ $k = 0 ] && [ $o = 0 ] && [ $l = 0 ] && [ $h = 0 ]; then
	result "PASS busuaf=$var rounds=$R"
else
	result "FAIL busuaf=$var round=$r kasan=$k oops=$o leaked=$l hung=$h"
	dmesg | grep -A45 -m1 -E "$KBUG|$LEAK"
fi
lockdep_check
