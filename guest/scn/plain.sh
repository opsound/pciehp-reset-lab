# Plain hot-add, safe removal and re-add of one NIC; lockdep must stay silent.
act add nic1 rp1
wait_count $NIC_V $NIC_D 1 60 || { result "FAIL setup"; return; }
sleep 2
act del nic1
wait_count $NIC_V $NIC_D 0 30 || { result "FAIL removal"; return; }
sleep 3
act add nicx rp1
wait_count $NIC_V $NIC_D 1 60 || { result "FAIL re-add"; return; }
sleep 2
result "PASS"
lockdep_check
