# Reference fix series: status

Status as of 2026-11-06. Issue IDs and test names are those of [catalog.md](catalog.md).

The reference fix series is 12 commits on v7.4-rc1 (6628e7d4c6b2), branch `pciehp-reset-fixes` of
https://github.com/opsound/linux. It was written and validated with LLM assistance and is provided for
reference only; see the README. Each commit message describes its bug, the fix and how it was tested.
Fix tracking (`./run fixes`) builds it with the TEST ONLY hooks patch
`patches/test-hooks-pciehp-reset-fixes.patch` as `pciehp-reset-fixes-hooks`, `-hooks-kasan` and
`-hooks-hc`, and runs every test of the bug suite plus the fix tracking regression tests on it,
expecting clean runs.

Summary: the series fixes P0, N1, N2, N4-N9 and the original N10 deadlock. It does not fix N3 (the
test still deadlocks, through N11), the N10 variants or N11-N24; commits 9 and 12 address parts of
N17 and N23 that the tests don't exercise.

## Commits

| # | commit | subject | issues |
|---|---|---|---|
| 1 | [ee2521191c75](https://github.com/opsound/linux/commit/ee2521191c7532abcd5ce36a4222ec576cc3f61f) | PCI: pciehp: Don't hold reset_lock while bringing down the slot | P0; N1 and N2 on removal |
| 2 | [2bbf9c91e9b5](https://github.com/opsound/linux/commit/2bbf9c91e9b559f12908c5d6c0b04cfe39d53e69) | PCI: pciehp: Don't wait for reset_lock with pci_rescan_remove_lock held | N1 on hot-add |
| 3 | [4f8b435b5d30](https://github.com/opsound/linux/commit/4f8b435b5d301d03f646a0acf4ec454ab9991707) | PCI: pciehp: Don't block on pci_rescan_remove_lock with reset_lock held | N2 on hot-add; the remaining reset_lock -> pci_rescan_remove_lock edge (N1, P0 lockdep reports); N7 for resets queued while pciehp waits for the lock |
| 4 | [4101e595520e](https://github.com/opsound/linux/commit/4101e595520e30d7de5cf1411fd7ae013769b776) | PCI: pciehp: Look up the device before acquiring reset_lock on spurious link change | N3 |
| 5 | [788ae8c0c03f](https://github.com/opsound/linux/commit/788ae8c0c03f8bdc4add3eb7315b8fdbb26504a6) | PCI: Lock, save and restore a snapshot of the devices to reset | N4 |
| 6 | [b22ba015aee1](https://github.com/opsound/linux/commit/b22ba015aee16dcb1a06a0efb23e4f449591e3d0) | PCI: Don't lock devices for a reset that are still being added | N5 |
| 7 | [c1752ddd1f00](https://github.com/opsound/linux/commit/c1752ddd1f00b271701ed3254206176f3fe91394) | PCI: hotplug: Wait for ->reset_slot() calls in flight in pci_hp_destroy() | N6 |
| 8 | [004ad4e79ced](https://github.com/opsound/linux/commit/004ad4e79cedc81ae71149d5784e0f1d81b6e285) | PCI: Don't hold pci_slot_mutex while resetting slots in pci_reset_bridge() | N8 (relies on 5-7) |
| 9 | [cab4eb6421e4](https://github.com/opsound/linux/commit/cab4eb6421e40ebb79d2cbb9fedafadc43765119) | PCI: Relock the devices to reset if devices were added meanwhile | N4, N7 (devices added while the reset waits); pins the bus between tries and the slot in pci_reset_bus() |
| 10 | [a1a3b6f34fca](https://github.com/opsound/linux/commit/a1a3b6f34fca6e9b6945f3fe83f42c0edeb8d293) | PCI: pciehp: Don't reset devices that were added after the slot was locked | N7 |
| 11 | [9f520662ca30](https://github.com/opsound/linux/commit/9f520662ca30cb96815b7ad2cd1e84a44828d793) | PCI: Pin the device across removal through sysfs | N9 |
| 12 | [f1ceb362d0e9](https://github.com/opsound/linux/commit/f1ceb362d0e9f85ca40d5404b79fe6cbc3bbcb20) | PCI: pciehp: Stop waiting for pci_rescan_remove_lock once the port is removed | N10; disallows binding once pci_stop_dev() starts on a device (part of N23) |

## Fix tracking results

`TEST_JOBS=8 ./run fixes` in a fresh clone on 2026-11-06: 19 of 43 entries clean. "clean (n/n)": every
run was clean; otherwise the symptoms and the number of runs that showed them. An earlier run in the
development tree gave the same results, except for the counts of the racy `sriov-pciehp-abba` (3/6)
and `reset-holds-removing` (2/3).

| test | issue | result on the series |
|---|---|---|
| `vfio-exit-deadlock` | P0 | clean (1/1) |
| `vfio-reset-deadlock` | P0 | clean (1/1) |
| `sysfs-remove-deadlock` | P0 | clean (1/1) |
| `sriov-disable-deadlock` | P0 | clean (1/1) |
| `hotadd-lockdep` | N1 | clean (1/1) |
| `nested-lockdep` | N1 | clean (1/1) |
| `host-reset-deadlock` | N2 | clean (1/1) |
| `spurious-link-lookup-deadlock` | N3 | hang in 2/2, through N11: the resetter holds reset_lock and the device locks and waits for pci_bus_sem in pci_bridge_wait_for_secondary_bus() |
| `reset-removal-uaf` | N4 | clean (2/2) |
| `reset-adding-device` | N5 | clean (1/1) |
| `pciehp-unbind-uaf` | N6 | clean (1/1) |
| `reset-pciehp-unbind` | N6, N8 | clean (1/1) |
| `reset-before-bind` | N7 | clean (1/1) |
| `reset-after-scan` | N7 | clean (2/2) |
| `reset-storm` | N8 | clean (1/1) |
| `reset-during-bind` | N8 | clean (1/1) |
| `slot-mutex-lockdep` | N8 | clean (1/1) |
| `aer-hotadd-race` | N8, N12 | fail, warn in 1/1: N12, the NIC bound with BAR0 lost, and e1000e's MSI-X warning |
| `sysfs-remove-uaf` | N9 | clean (1/1) |
| `nested-removal` | N10 | clean (3/3) |
| `nested-bringup-deadlock` | N10 | hang in 2/2 |
| `port-unbind-deadlock` | N10 | hang in 2/2 |
| `port-unbind-host-reset` | N10 | hang in 2/2 |
| `sriov-recovery-walk-deadlock` | N11 | hang in 3/3 |
| `recovery-walk-deadlock` | N11 | hang in 2/2 |
| `recovery-hotadd-msix` | N12 | warn, fail in 3/3: the MSI-X warning; the NIC loses BAR0 and memory decode |
| `sriov-remove-abba` | N13 | hang in 2/2 |
| `sriov-pciehp-abba` | N13 | hang in 2/6 |
| `dead-link-reset-wait` | N14 | fail in 1/1: the reset takes 69.5 s, as on v7.4-rc1 |
| `reset-holds-removing` | N15 | hang in 3/3 |
| `reset-holds-probing` | N16 | hang in 3/3 |
| `reset-subordinate-uaf` | N17 | kasan in 3/3 |
| `pciehp-rpm-recursion` | N18 | hang in 3/3, with the recursive locking report |
| `rescan-remove-deadlock` | N19 | hang in 3/3 |
| `sriov-host-reset-deadlock` | N20 | hang in 2/2 |
| `sriov-linkdown-deadlock` | N20 | hang in 3/3 |
| `pf-unbind-unlocked-vf-removal` | N21 | warn in 2/2 |
| `removal-stall` | N22 | fail in 2/2: the rescan waits for the vfio-pci holder |
| `bind-during-removal` | N23 | fail in 2/2: the bind succeeds |
| `shutdown-aer-deadlock` | N24 | hang in 2/2 |
| `pciehp-rpm-safe-removal` | - | lockdep in 3/3: N18's recursive locking report; the slot stays off |
| `linkdown-hotadd-bars` | - | clean (3/3) |
| `pf-probe-sriov-removal` | - | warn in 2/2: N21's lockdep_assert_held() when the PF's VFs are removed; no hang |

## Status per issue

"Commits" lists the commits whose messages claim the issue. "Status" is the result of the fix
tracking run above.

| ID | issue | commits | lab tests | status |
|---|---|---|---|---|
| P0 | pciehp reset_lock vs vfio close-time reset | 1 (3 for lockdep) | vfio-exit-deadlock, vfio-reset-deadlock, sysfs-remove-deadlock, sriov-disable-deadlock | fixed |
| N1 | reset_lock re-acquired with pci_rescan_remove_lock held | 2, 1, 3 | hotadd-lockdep, nested-lockdep | fixed |
| N2 | pci_host_reset_root_port() vs pciehp | 3, 1 | host-reset-deadlock | fixed |
| N3 | pci_get_slot() under reset_lock | 4 (not the enumeration variant) | spurious-link-lookup-deadlock | not fixed: the test deadlocks through N11 instead |
| N4 | reset walks vs removal | 5, 9 | reset-removal-uaf | fixed |
| N5 | resets lock devices not yet added | 6 | reset-adding-device | fixed |
| N6 | ->reset_slot() vs hotplug driver unbind | 7 | pciehp-unbind-uaf, reset-pciehp-unbind | fixed |
| N7 | queued slot reset vs driver binding | 10, 9, 3 | reset-before-bind, reset-after-scan | fixed |
| N8 | pci_slot_mutex across slot resets | 8 | reset-storm, reset-during-bind, slot-mutex-lockdep, aer-hotadd-race, reset-pciehp-unbind | fixed (`aer-hotadd-race` then shows N12) |
| N9 | remove_store() UAF | 11 | sysfs-remove-uaf | fixed |
| N10 | nested ports: free_irq() vs pci_rescan_remove_lock | 12 (not the bring-up and port-unbind variants) | nested-removal, nested-bringup-deadlock, port-unbind-deadlock, port-unbind-host-reset | partly: the original case is fixed, the three variants hang |
| N11 | recovery walks vs pci_bus_sem | none | sriov-recovery-walk-deadlock, recovery-walk-deadlock | not addressed |
| N12 | recovery reset vs hot-add | none | recovery-hotadd-msix, aer-hotadd-race | not addressed |
| N13 | sriov_numvfs_store() vs PF removal | none | sriov-remove-abba, sriov-pciehp-abba | not addressed |
| N14 | 60 s reset wait on a dead link | none | dead-link-reset-wait | not addressed |
| N15 | error reset holds a device a remover needs | none | reset-holds-removing | not addressed |
| N16 | reset holds a device whose first probe is pending | none | reset-holds-probing | not addressed |
| N17 | pci_reset_bridge() secondary bus UAF | 9 (pins the bus between tries only) | reset-subordinate-uaf | not fixed |
| N18 | recursive reset_lock read on runtime resume | none | pciehp-rpm-recursion | not addressed |
| N19 | sysfs rescan vs kernfs drain | none | rescan-remove-deadlock | not addressed |
| N20 | sriov_numvfs_store() vs pci_host_reset_root_port() | none | sriov-host-reset-deadlock, sriov-linkdown-deadlock | not addressed |
| N21 | PF unbind removes VFs without the lock | none | pf-unbind-unlocked-vf-removal | not addressed |
| N22 | removal stalls on a vfio-pci user | none | removal-stall | not addressed |
| N23 | binding during removal | 12 (devices already stopped only) | bind-during-removal | not fixed: the test binds a device whose own removal hasn't started |
| N24 | device_shutdown() vs AER recovery | none | shutdown-aer-deadlock | not addressed |

## Known gaps

From code review and the commit messages:
- N2: a Root Port reset every ~3 ms starves the hot-add until the resets stop, because commit 3 redoes
  the link check after each reset.
- N3: commit 4 moves pci_get_slot() out of reset_lock, but `spurious-link-lookup-deadlock` still hangs:
  the resetter now gets reset_lock and then waits for pci_bus_sem in
  pci_bridge_wait_for_secondary_bus() (pci.c:4817 in v7.4-rc1) with the device locks held, behind the
  queued writer: the N11 reset-wait case. The test only passes once the error-recovery walk no longer
  holds pci_bus_sem across device locks. Enumeration also still takes pci_bus_sem under reset_lock
  (the variant in the catalog).
- N4: pci_slot_resettable() and pci_bus_resettable() still walk bus->devices without pci_bus_sem.
- N6: commit 7 covers callers that keep the pci_slot allocated: pci_reset_bridge(), and
  pci_reset_bus() from commit 9 on. pci_dev_reset_slot_function() still reads dev->slot without a
  reference (narrow window).
- N7: with commit 8, other enumerators (e.g. a sysfs rescan) can add devices to a slot during an
  error-recovery slot reset, which then hits them; they used to wait on pci_slot_mutex in
  pci_reset_bridge(), and never did for pci_reset_bus(). Try slot resets relock until such devices are
  added. Error-recovery slot resets still hit devices whose drivers probe asynchronously, or that the
  pciehp of an ancestor port is binding.
- N10: bringing up a slot while removal of its port begins, and unbinding only the port driver while
  the lock's holder waits for the port, still deadlock (commit 12's message).
- N12: the series turns `aer-hotadd-race`'s N8 hang into N12's failure (the NIC bound with BAR0=0 and
  Command 0x0400) and e1000e's MSI-X warning.
- N14: on hardware with commit 1, the exiting process of P0 took 3.5-6.5 s (about 1 s per reset of a
  dead link, with the link down). With the link up, `dead-link-reset-wait` waits as long as on
  v7.4-rc1; commit 8 only shortens the stall of other enumerations, which no longer wait for
  pci_slot_mutex during the reset_subordinate and AER variants (0.3 s instead of 65 s for a hot-add on
  another Root Port in development).
- N17: commit 9 pins the bus between tries only; `reset-subordinate-uaf` still reports the
  use-after-free in every run.
- Commit 12 has to be backported with the others: without it, the earlier commits make N10 more likely
  when the ports are reset during removal, as resets no longer serialize on pci_slot_mutex. Removing
  nested ports while reset_subordinate loops on them hung in 0 of 3 runs on mainline, 1-2 of 3 at each
  of commits 1-4, 0 of 3 at commits 5-7, 2-3 of 3 at commits 8-11, and 0 of 3 with commit 12.
- N8 timing with commit 8: resetting 8 Root Ports at once in QEMU takes 0.20 s instead of 1.13 s; 24
  PEX890xx Downstream Ports on hardware (v7.1-based backport), 1.2 s instead of 27.7 s.

## Overlap with in-flight work

- W1 overlaps commits 1, 2, 3, 8 and 10.
- W2: commits 3 and 12 take pci_rescan_remove_lock with a trylock, which would not set v15's
  owner/depth, so v15's unlock would WARN and leave the mutex locked; both would need adapting. W2 2/5
  and commit 11 both change remove_store().
- W3: commit 12 generalizes it from "port disconnected" to "removal of the port has begun" and cites
  it; E0's flag suggestion is closer to commit 12.
- W4: same approach as commit 5, for pci_bus_reset() only.
- W5: 4/5 relies on pciehp_ist() being the only consumer of PCI_LINK_CHANGED; commit 3 also consumes
  it, but from board_added(), which only pciehp_ist() calls, so that still holds.
- W9: textual conflict with commit 5. W10: overlaps commit 5's locking code.
- W12: commit 2 contains the same check (`ctrl->dsn = dev ? pci_get_dsn(dev) : 0`).
- E8, E10, E20: commit 5 follows Lukas's advice in E8 to hold references rather than locks; commits 11
  and 12 rely on the idempotent pci_stop_dev()/pci_destroy_dev() from E10 1-5 (v6.13-rc1); commit 12
  adds the pci_dev_disallow_binding() helper Lukas suggested in E20.

## Fix-tracking-only regression tests

Not part of the bug suite: they check fix attempts for regressions, not mainline bugs.
- `pciehp-rpm-safe-removal`: safe removal (sysfs power=0) of a card in a slot without a power
  controller while its Root Port is runtime-suspended (pcie_port_pm=force); the slot must stay off, so
  a fix for N18 must not re-enumerate the card on runtime resume.
- `linkdown-hotadd-bars`: a NIC hot-added while the real pci-host-common link-down recovery of its Root
  Port runs (CONFIG_OF and CONFIG_PCI_HOST_GENERIC); the NIC must end up bound with its BARs, so a fix
  for N2 or N20 must not let pciehp bind it between the recovery's error_detected walk and its reset
  (N12).
- `pf-probe-sriov-removal`: a PF driver that enables SR-IOV in ->probe() (igb max_vfs) is bound through
  sysfs while a remover that holds pci_rescan_remove_lock waits for the PF's device lock; must not hang,
  so a fix that takes pci_rescan_remove_lock while adding VFs must not create a cycle at probe time.
