# (N17) pci_reset_bridge(), behind a port's "reset_subordinate" attribute,
# uses bridge->subordinate without a reference.  sysfs removal of the switch
# frees the Downstream Port's secondary bus (pci_remove_bus()) before it
# deletes the port (pci_destroy_dev() -> device_del(), which drains
# reset_subordinate).  Nested topology (harness/run.py): rps (00:1e.0) - up1 -
# dp1 (nicd1), dp2 (empty slot).
# var=W: W wloop processes write dp2's reset_subordinate back to back (default
# 1) while up1 is removed through sysfs 10-490 ms later; then rescan.  a=
# rounds (default 20).  Run on a KASAN kernel.
SW_V=0x104c USP_D=0x8232 DSP_D=0x8233
R=${a:-20}
W=${var:-1}
case $W in ''|*[!0-9]*) W=1 ;; esac
BUGRE="BUG: KASAN|general protection|list_(add|del) corruption|Oops|BUG: unable|kernel BUG"

sub_setup() {
	local d
	wait_count $SW_V $USP_D 1 30 && wait_count $SW_V $DSP_D 2 30 && wait_count $NIC_V $NIC_D 1 30 || return 1
	USP=$(devs $SW_V $USP_D) DSP2=
	for d in $(devs $SW_V $DSP_D); do
		ls -d /sys/bus/pci/devices/$d/0000:??:??.? > /dev/null 2>&1 || DSP2=$d	# no child functions
	done
	[ -n "$DSP2" ] || DSP2=$d
	sleep 1		# let pcieport/pciehp settle on the new ports
}

fail=0 tot_ok=0 tot_eagain=0 tot_enotty=0 tot_other=0
for r in $(seq 1 $R); do
	sub_setup || { log "round $r: switch not enumerated"; fail=1; break; }
	[ $r = 1 ] && log "USP=$USP DSP2=$DSP2 drv=$(drv_of $DSP2) writers=$W"
	rm -f /tmp/wloop; P=
	for w in $(seq 1 $W); do
		/bin/wloop /sys/bus/pci/devices/$DSP2/reset_subordinate 90 >> /tmp/wloop 2>&1 & P="$P $!"
	done
	d=$(printf "0.%03d" $((RANDOM % 480 + 10)))
	sleep $d
	log "round $r: sysfs remove $USP after ${d}s"
	( echo 1 > /sys/bus/pci/devices/$USP/remove ) & RM=$!
	wait_exit $RM 60 || { log "round $r: sysfs remove stuck"; dstacks "remove stuck"; fail=1; break; }
	for p in $P; do wait_exit $p 100 || { log "round $r: reset loop stuck"; dstacks "loop stuck"; fail=1; }; done
	cat /tmp/wloop
	eval "$(awk '{for (i = 3; i <= NF; i++) { split($i, kv, "="); if (kv[1] ~ /^(ok|eagain|enotty|other)$/) s[kv[1]] += kv[2] }}
		END {printf "l_ok=%d l_eagain=%d l_enotty=%d l_other=%d\n", s["ok"], s["eagain"], s["enotty"], s["other"]}' /tmp/wloop)"
	tot_ok=$((tot_ok + l_ok)) tot_eagain=$((tot_eagain + l_eagain)) tot_enotty=$((tot_enotty + l_enotty)) tot_other=$((tot_other + l_other))
	if dmesg | grep -qE "$BUGRE"; then log "round $r: kernel bug reported"; fail=1; break; fi
	[ $fail = 0 ] || break
	echo 1 > /sys/bus/pci/rescan
done
log "writes: rounds=$r ok=$tot_ok eagain=$tot_eagain enotty=$tot_enotty other=$tot_other"
k=$(dmesg | grep -c "BUG: KASAN") o=$(dmesg | grep -cE "general protection|Oops|BUG: unable|list_(add|del) corruption") h=$(nhung)
if [ $fail = 0 ] && [ $k = 0 ] && [ $o = 0 ] && [ $h = 0 ]; then
	result "PASS writers=$W rounds=$R"
else
	result "FAIL writers=$W round=$r kasan=$k oops=$o hung=$h"
	dmesg | grep -A45 -m1 -E "$BUGRE"
fi
lockdep_check
