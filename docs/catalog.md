# pciehp, PCI slot/bus reset and device removal: deadlocks and use-after-frees in v7.4-rc1

Base: v7.4-rc1 (6628e7d4c6b2). Code references are to that tree unless a commit of the reference
series is named. Status as of 2026-11-05.

Conventions:
- Test names refer to this lab (`./run test <name>`, table in the README). Tier 1 tests run on the exact
  mainline and fix-series sources. Tier 2 tests need the TEST ONLY commit on top of either: debugfs hooks
  that emulate callers QEMU can't trigger (AER/DPC recovery resets, pci_host_reset_root_port()) and
  delays that widen windows in pciehp and pci_device_add().
- Counts are "failing runs / runs". Counts not tied to a lab test come from a larger set of scenario
  variants we ran while developing the series.
- Reference fix series: 12 commits on 6628e7d4c6b2 in branch `pciehp-reset-fixes` of
  https://github.com/opsound/linux. It was written and validated with an LLM and is provided for
  reference only; see the README.

<!-- series-table -->

  | # | commit | subject |
  |---|---|---|
  | 1 | [ee2521191c75](https://github.com/opsound/linux/commit/ee2521191c7532abcd5ce36a4222ec576cc3f61f) | PCI: pciehp: Don't hold reset_lock while bringing down the slot |
  | 2 | [2bbf9c91e9b5](https://github.com/opsound/linux/commit/2bbf9c91e9b559f12908c5d6c0b04cfe39d53e69) | PCI: pciehp: Don't wait for reset_lock with pci_rescan_remove_lock held |
  | 3 | [4f8b435b5d30](https://github.com/opsound/linux/commit/4f8b435b5d301d03f646a0acf4ec454ab9991707) | PCI: pciehp: Don't block on pci_rescan_remove_lock with reset_lock held |
  | 4 | [4101e595520e](https://github.com/opsound/linux/commit/4101e595520e30d7de5cf1411fd7ae013769b776) | PCI: pciehp: Look up the device before acquiring reset_lock on spurious link change |
  | 5 | [788ae8c0c03f](https://github.com/opsound/linux/commit/788ae8c0c03f8bdc4add3eb7315b8fdbb26504a6) | PCI: Lock, save and restore a snapshot of the devices to reset |
  | 6 | [b22ba015aee1](https://github.com/opsound/linux/commit/b22ba015aee16dcb1a06a0efb23e4f449591e3d0) | PCI: Don't lock devices for a reset that are still being added |
  | 7 | [c1752ddd1f00](https://github.com/opsound/linux/commit/c1752ddd1f00b271701ed3254206176f3fe91394) | PCI: hotplug: Wait for ->reset_slot() calls in flight in pci_hp_destroy() |
  | 8 | [004ad4e79ced](https://github.com/opsound/linux/commit/004ad4e79cedc81ae71149d5784e0f1d81b6e285) | PCI: Don't hold pci_slot_mutex while resetting slots in pci_reset_bridge() |
  | 9 | [cab4eb6421e4](https://github.com/opsound/linux/commit/cab4eb6421e40ebb79d2cbb9fedafadc43765119) | PCI: Relock the devices to reset if devices were added meanwhile |
  | 10 | [a1a3b6f34fca](https://github.com/opsound/linux/commit/a1a3b6f34fca6e9b6945f3fe83f42c0edeb8d293) | PCI: pciehp: Don't reset devices that were added after the slot was locked |
  | 11 | [9f520662ca30](https://github.com/opsound/linux/commit/9f520662ca30cb96815b7ad2cd1e84a44828d793) | PCI: Pin the device across removal through sysfs |
  | 12 | [f1ceb362d0e9](https://github.com/opsound/linux/commit/f1ceb362d0e9f85ca40d5404b79fe6cbc3bbcb20) | PCI: pciehp: Stop waiting for pci_rescan_remove_lock once the port is removed |

<!-- /series-table -->

---

## 1. Production issue (P0)

**Mechanism.** pciehp_ist() takes the hotplug port's reset_lock for reading
(drivers/pci/hotplug/pciehp_hpc.c:785) and keeps it while pciehp_unconfigure_device() waits for the
global pci_rescan_remove_lock (pciehp_pci.c:107). If the holder of pci_rescan_remove_lock in turn waits
for a reset of that slot, the system deadlocks. With vfio-pci, two slots and one process are enough:

```
irq/A-pciehp                      irq/B-pciehp                    exiting user of A and B
pciehp_unconfigure_device(A)
  pci_lock_rescan_remove()        down_read(reset_lock B)
  vfio_pci_remove()               pciehp_unconfigure_device(B)
    vfio_unregister_group_dev()     pci_lock_rescan_remove()      close(B)
      waits for close(A)              waits for irq/A               vfio_pci_core_disable()
                                                                      __pci_reset_function_locked()
                                                                        pci_reset_bus_function()
                                                                          pciehp_reset_slot()
                                                                            down_write(reset_lock B)
                                                                            waits for irq/B
```

vfio_unregister_group_dev() waits for the last close (drivers/vfio/vfio_main.c:447-465); after a signal
the wait is uninterruptible. vfio_pci_core_disable() trylocks the bridge and the device and resets
(drivers/vfio/pci/vfio_pci_core.c:779-787). For a surprise-removed device FLR and PM reset return
-ENOTTY, so __pci_reset_function_locked() falls through to the slot reset (drivers/pci/pci.c:5240-5252,
4993-5000). In v7.4-rc1, exit closes files synchronously from the highest descriptor down
(c8d9b40eabf0 "fs: make close_files() synchronous", a01971311830); before that, task_work
(LIFO) ran the releases in the same order. Either way the
device with the higher fd is closed first.

Variants (same pciehp-side edge): the pci_rescan_remove_lock holder can be pciehp of another slot,
sysfs "remove", SR-IOV disable or pci_host_reset_root_port(); the reset can come from close,
VFIO_DEVICE_RESET, or sysfs "reset" with reset_method=bus. With safe removal (device still present), the
cycle needs a reset that ends in a slot reset (no working FLR, reset_method=bus). The
VFIO_DEVICE_PCI_HOT_RESET path reaches pciehp_reset_slot() too; we did not demonstrate it.

**Introduced by.** 5b3f7b7d062b "PCI: pciehp: Avoid slot access during reset" (v4.19-rc1), which made
pciehp_ist() hold reset_lock across event handling. f5eff5591b8f (v6.4-rc1) dropped reset_lock only
around driver unbinding and kept the cycle.

**Impact in production.** Hosts with 24 PCIe devices bound to vfio-pci, each below its own Broadcom
PEX890xx switch Downstream Port with native hotplug. A device-side fault took the links of two or more
devices down while one process held them; when the process exited, two pciehp IRQ threads and the
exiting task stayed in D state permanently. pci_rescan_remove_lock stays held, so enumeration and
removal stop system-wide. A normal reboot hangs; the hosts needed a power cycle or sysrq reboot.
Reproduced on that hardware on 6.16- and 7.1-based kernels and on v7.3 (link disable on two or three
Downstream Ports 3 s apart, then SIGKILL). On kernels that carry Keith Busch's sub-tree removal patch
(W3), irq/B waits in pci_trylock_rescan_remove() instead of mutex_lock(), because its port is not
disconnected.

**Mainline status.** Unchanged in v7.4-rc1. Lab, exact mainline: `vfio-exit-deadlock` (process exit),
`vfio-reset-deadlock` (VFIO_DEVICE_RESET), `sysfs-remove-deadlock` (sysfs "remove" as the lock holder)
and `sriov-disable-deadlock` (sriov_numvfs=0 as the lock holder) all hang; all pass from commit 1.
With hooks, `host-reset-deadlock` covers the pci_host_reset_root_port() holder on hot-add (N2). Hung-task
stacks on mainline: irq/B in pciehp_unconfigure_device(), irq/A in vfio_unregister_group_dev(), the
exiting task in pciehp_reset_slot() via do_exit.

**Earlier reports.** E14 (SPDK, 2024, same cycle, open), E18 (Jinhui Guo, 2025, same cycle, not
applied). Precursors fixed by f5eff5591b8f: E2, E3, E4. E17 proposed nearly the same reordering for a
lockdep report and was rejected as a false positive; the deadlock needs the second party (the
close-time reset), which that report did not include.

**Fix in the reference series.** Commit 1 (pciehp no longer holds reset_lock while bringing the slot
down). Commit 3 removes the remaining lockdep reports in these tests.

---

## 2. Earlier upstream reports of the same or matching problems (chronological)

Lore links are https://lore.kernel.org/r/<message-id>. Release = first tag containing the commit.

**E0. 2018-02-26, Xiongfeng Wang (Huawei), "[PATCH] pciehp: fix a race between pciehp and removing
operations by sysfs"** (RFC v2 2018-01-02, 1514879577-47078-1-git-send-email-wangxiongfeng2@huawei.com;
v2 2019-08-05, 1565008378-4733-1-git-send-email-wangxiongfeng2@huawei.com)
https://lore.kernel.org/r/1519648875-38196-1-git-send-email-wangxiongfeng2@huawei.com
Hung tasks on 4.12: sysfs "remove" of a hotplug port holds pci_rescan_remove_lock and waits in
pciehp_remove() for the port's pciehp work, which waits for pci_rescan_remove_lock in
pciehp_unconfigure_device(). Matches N10 (sysfs remover). E1's withdrawal message (below) cites
"a similar race" by Xiongfeng Wang (patchwork.ozlabs.org/patch/877835, from the same weeks; not resolved here),
and E8's "sysfs race" remark refers back to it.
Outcome: not merged. Lukas (2019-08-05) suggested a flag marking devices "about to be removed", set
before taking pci_rescan_remove_lock, so that pciehp_unconfigure_device() skips the lock: "But again,
that approach is just a band-aid and the real fix is to unbind devices without holding the lock."
(20190805114053.srbngho3wbziy2uy@wunner.de). On v2 he raised the sysfs ABI change and asked for a fix
covering all removers (20190811080703.qfnlzfutgamoxzti@wunner.de). No later version. Commit 12 takes
a similar approach.

**E1. 2018-06-16, Lukas Wunner, "[PATCH 03/32] PCI: pciehp: Fix deadlock on unplug"** (in "[PATCH 00/32]
Rework pciehp event handling & add runtime PM", cover.1529173804.git.lukas@wunner.de)
https://lore.kernel.org/r/4c882e25194ba8282b78fe963fec8faae7cf23eb.1529173804.git.lukas@wunner.de
Nested hotplug ports: the parent's removal holds pci_rescan_remove_lock and waits for the child port's
IRQ thread, which waits for the same lock. Matches N10. The same series added reset_lock (23/32,
5b3f7b7d062b, v4.19-rc1; P0 origin) and the hotplug_slot registration (14/32, 51bbf9bee34f, v4.19-rc1;
N6 origin).
Outcome: series merged in v4.19-rc1 except 03/32, which the author withdrew: "it's not a good solution,
it would just add technical debt" and "The first step (unbinding) needs to run lockless."
(20180906162634.ylyp3ydwujf5wuxx@wunner.de). 87d0f2a5536f (v5.5-rc1) only covers the runtime-PM and
system-sleep triggers. Open in v7.4-rc1.

**E2. 2020-03-24, Michael Haeuptle (HPE), "RE: Deadlock during PCIe hot remove"**
https://lore.kernel.org/r/CS1PR8401MB0728FC6FDAB8A35C22BD90EC95F10@CS1PR8401MB0728.NAMPRD84.PROD.OUTLOOK.COM
SPDK with vfio-pci, many NVMe drives removed in parallel: pciehp_ist() holds reset_lock and waits for
device_lock; the vfio release path holds device_lock and waits for reset_lock in pciehp_reset_slot().
Matches: P0 precursor. In the thread Lukas also noted that ->reset_slot() callers don't keep the hotplug
driver from unbinding: "We've never done this correctly." (20200331130139.46oxbade6rcbaicb@wunner.de);
matches N6.
Outcome: fixed by f5eff5591b8f (v6.4-rc1; Reported-by: Michael Haeuptle). The ->reset_slot() vs unbind
lifetime issue was not addressed (N6).

**E3. 2020-06-15, Ian May (Canonical), "[PATCH 0/2] Hotplug interrupt and AER recovery deadlocks"**
https://lore.kernel.org/r/20200615143250.438252-1-ian.may@canonical.com
Two deadlocks between pciehp and AER recovery on the same slot. 1/2: reset_lock vs device_lock (P0
precursor). 2/2: pciehp holds reset_lock and takes pci_slot_mutex in pci_dev_assign_slot(); AER
pci_bus_error_reset() holds pci_slot_mutex and takes reset_lock in pciehp_reset_slot(). 2/2 matches N8.
Outcome: 1/2 superseded by f5eff5591b8f (Reported-by: Ian May). 2/2 not applied. Lukas: taking
pci_slot_mutex in pci_bus_error_reset() "holds the driver of the hotplug port in place... Without that,
dereferencing slot->hotplug in pci_slot_reset() wouldn't be safe" (20200717052000.vsyvbnwbhni4iy6y@wunner.de),
and "I need to think some more to come up with a solution for this particular deadlock"
(20200801161405.bww7kvcfj5lrcso4@wunner.de). No fix followed; open in v7.4-rc1.

**E4. 2023-01-13, Anatoli Antonovitch (AMD), "[PATCH] PCI/hotplug: Replaced down_write_nested with
hotplug_slot_rwsem if ctrl->depth > 0 when taking the ctrl->reset_lock."**
https://lore.kernel.org/r/20230113170131.5086-1-a.antonovitch@gmail.com
pciehp vs AER (bugzilla 215590): AER waits for reset_lock in pciehp_reset_slot(); pciehp holds it and
waits for a device lock during unconfigure. Matches: P0 precursor.
Outcome: superseded. Fixed by 74ff8864cc84 (v6.3-rc1) and f5eff5591b8f (v6.4-rc1, Tested-by
Antonovitch).

**E5. 2023-04-11, Lukas Wunner, "[PATCH v2] PCI: pciehp: Fix AB-BA deadlock between reset_lock and
device_lock"**
https://lore.kernel.org/r/fef2b2e9edf245c049a8c5b94743c0f74ff5008a.1681191902.git.lukas@wunner.de
The fix for E2-E4: releases reset_lock around driver binding and unbinding and re-acquires it with
pci_rescan_remove_lock held, as "best-effort reset protection ... until a general solution is
implemented in the PCI core". The re-acquisition is N1; releasing reset_lock for binding with a reset
queued on it is N7; P0 remains.
Outcome: merged as f5eff5591b8f (v6.4-rc1, Cc stable 4.19+).

**E6. 2023-10-10, Marcel Hamer (Wind River), "pciehp lockdep possible circular locking dependency"**
https://lore.kernel.org/r/ZSUdqxOZ9HUFR32S@windriver.com
Lockdep at hot-add (QEMU, v6.6-rc5): reset_lock re-acquired in pciehp_configure_device() with
pci_rescan_remove_lock held. Matches N1.
Outcome: no change. Lukas: false positive because pciehp_ist() is single-threaded; he weighed
lockdep_set_novalidate_class() for reset_lock and left it open (20231015093722.GA11283@wunner.de).

**E7. 2023-12-07, Jim Harris (Samsung), "Locking between vfio hot-remove and pci sysfs sriov_numvfs"**
https://lore.kernel.org/r/ZXJI5+f8bUelVXqu@ubuntu
vfio-pci's remove holds device_lock while it waits for user space to release the device; the user thread
that would release it blocks in sriov_numvfs_show() on the same device_lock. Related to P0 (remover
waits for user space while holding a lock user space needs). Jason Gunthorpe: "The mechanism of
waiting in remove for userspace is inherently flawed" (20231207234810.GN2692119@nvidia.com).
Outcome: the follow-up "[PATCH v2 0/2] PCI/IOV: sriov_numvfs bug fixes" (2024-02-09,
170752254154.1693615.9176696143128338408.stgit@bgt-140510-bm01.eng.stellus.in) was tabled by Bjorn
pending a v3 (20240213194556.GA1219770@bhelgaas). v3 was posted 2024-02-14
(170795147587.2393.15577527626926144858.stgit@bgt-140510-bm01.eng.stellus.in) and got no replies;
not merged. Unchanged in v7.4-rc1 (sriov_numvfs_show() still takes device_lock).

**E8. 2024-06-12, Keith Busch, "[PATCHv2 0/2] pcie hotplug and error fixes"**
https://lore.kernel.org/r/20240612181625.3604512-1-kbusch@meta.com
1/2: N10; adds pci_trylock_rescan_remove(), which waits until it gets the lock or the port is
disconnected. 2/2: DPC use-after-free on concurrent removal. In the thread Keith notes "The sysfs race
appears to still exist today. My patch wouldn't help with that either." -- the race Lukas cited, E0
(N10 with sysfs "remove" as the remover), not N9.
Outcome: 1/2 not merged. Lukas: "I'm hesitant to endorse a duct tape fix. :(" (Zn0Y-UhMqCo2PCtM@wunner.de).
In 2024-11 he suggested making pci_lock_rescan_remove() take per-bus locks of the sub-hierarchy
bottom-up (ZzG5koPOn16KQ8uM@wunner.de); Keith: "I don't think we can walk the bus bottom-up without
hitting the same deadlock I'm trying to fix." (ZzJF77YoNO-fdmow@kbusch-mbp.dhcp.thefacebook.com).
Reposted as a RESEND in 2025 (W3). 2/2 superseded by Lukas's 11a1f4bc4736 (v6.11-rc1).

**E9. 2024-07-19, Keith Busch, "[PATCH] driver core: get kobject ref when accessing dev_attrs"**
https://lore.kernel.org/r/20240719185513.3376321-1-kbusch@meta.com
Concurrent sysfs "remove" of 04:00.0 and its ancestor 01:00.0 gives a GPF in pci_stop_bus_device() on
freed memory. Matches N9.
Outcome: rejected. Greg KH: "Attributes that when written to remove themselves need to call the correct
function to do so (look at how scsi does it)" (2024072058-dork-ferret-71d5@gregkh). remove_store() is
unchanged in v7.4-rc1.

**E10. 2024-07-22, Keith Busch, "[PATCH RFC 0/8] pci: rescan/remove locking rework"**
https://lore.kernel.org/r/20240722151936.1452299-1-kbusch@meta.com
1-5 make pci_stop_dev()/pci_destroy_dev() concurrent-safe and rework __pci_walk_bus(); 8/8 replaces
pci_rescan_remove_lock in pciehp and rescan with a per-bus mutex ("The global rescan_remove lock has
deadlocks during concurrent removals") and pins the device in remove_store(). Matches N10 (design
alternative), N9 (the pin).
Outcome: 1-5 merged as "[PATCHv3 0/5] pci cleanup/prep patches" (93093ea1f059, e3f30d563a38,
4d6dcd6c2fa3, ee061da777f7, 38a18dfe9035; v6.13-rc1); commits 11 and 12 rely on the idempotent
pci_stop_dev()/pci_destroy_dev() from that series. 6-8 never reposted (see E8 for the 2024-11
exchange on per-bus locking).

**E11. 2024-09-09, Ilkka Koskinen (Ampere), "Deadlock between reset_lock and pci_slot_mutex"**
https://lore.kernel.org/r/9db19c51-dd77-9114-2e7e-ee3fe4c3157@os.amperecomputing.com
Error injection with firmware-first AER on 6.11-rc6: aer_recover_work_func holds pci_slot_mutex in
pci_bus_error_reset() and waits for reset_lock in pciehp_reset_slot(); pciehp holds reset_lock during
hot-add and waits for pci_slot_mutex in pci_dev_assign_slot(). Asks whether E3 2/2 was ever fixed.
Matches N8.
Outcome: no response.

**E12. 2024-09-26, Chia-Lin Kao (AceLan), "[PATCH] PCI: pciehp: Fix system hang on resume after
hot-unplug during suspend"** (v2 2024-10-22, 20241022130243.263737-1-acelan.kao@canonical.com)
https://lore.kernel.org/r/20240926125909.2362244-1-acelan.kao@canonical.com
Hang on resume after unplugging a Thunderbolt dock with an NVMe drive behind it during suspend. The
reporter confirmed E8 fixes it ("Yes, the 2 patches work"). Matches N10.
Outcome: superseded by e3260237aaad (v6.15-rc1), which avoids this trigger only.

**E13. 2024-11-11, Sebastian Ott (Red Hat), "lockdep warning in pciehp"**
https://lore.kernel.org/r/f9f13728-ade8-c5b9-0cc3-2fb23db2f051@redhat.com
Same lockdep report as E6 (arm64 KVM guest, 6.12-rc6), with an inline patch to call
pciehp_configure_device() without reset_lock. Matches N1.
Outcome: rejected. Lukas: "The point is to prevent a slot reset while the bus is being enumerated. It's
not just for reading the Device Serial Number." (ZzJm6QrQyT48jGuN@wunner.de).

**E14. 2024-11-27, fengnan chang, "Deadlock during PCIe hot remove and SPDK exit"**
https://lore.kernel.org/r/D0B37524-9444-423B-9E48-406CF9A29A6A@gmail.com
Exactly P0: SPDK holds two NVMe drives through vfio-pci, both are pulled, SPDK is killed; 100%
reproducible on 6.6.40 and 6.12; the same three stacks. Needs two devices; depends on removal order.
The reporter described a local change making vfio_device_fops_release() asynchronous; no patch was
posted.
Outcome: open, no fix proposed; last message 2024-12-03.

**E15. 2025-02-10, Kenneth Crudup, "Re: diagnosing resume failures after disconnected USB4 drives"**
https://lore.kernel.org/r/83d9302a-f743-43e4-9de2-2dd66d91ab5b@panix.com
Resume fails after disconnecting a TB4 dock with a USB4 NVMe enclosure during suspend. Lukas: "This
looks like the deadlock we've had for years when hot-removing nested hotplug ports"
(Z77ak-4YsdAKXbHr@wunner.de). Matches N10.
Outcome: trigger avoided by e3260237aaad (v6.15-rc1), whose changelog says "A proper fix is being worked
on, but needs more time as it is nontrivial and necessarily intrusive." Underlying deadlock open.

**E16. 2025-03-31, liwei (JK) (Huawei), "[Question] pcie_do_recovery and pci_enable_sriov deadlock
problem"**
https://lore.kernel.org/r/805b2e50-00f7-40a4-975c-6bfe7d3c431b@huawei.com
kdump kernel: an AER walk holds pci_bus_sem for reading and waits for a device_lock; the holder of that
device_lock is in pci_enable_sriov() -> pci_device_add() -> down_write(pci_bus_sem). Matches R1
(two-party variant of the same edge). It cites Jay Fang's 2019 report of the same cycle, "[PATCH]
PCI/AER: Fix AER/sysfs sriov_numvfs deadlock in pcie_do_recovery()"
(1567737238-48866-1-git-send-email-f.fangjian@huawei.com), not merged.
Outcome: no response.

**E17. 2025-06-19, Raju Rangoju (AMD), "[PATCH] PCI: pciehp: fix circular lock dependency b/w
pci_rescan_remove_lock and reset_lock"**
https://lore.kernel.org/r/20250619154610.902892-1-Raju.Rangoju@amd.com
Lockdep (6.14.5) in pciehp_unconfigure_device(); releases reset_lock before pci_lock_rescan_remove().
Close to commit 1. Matches N1 (removal path); P0 by mechanism, though the report shows only lockdep.
Outcome: rejected. Lukas: "This seems to be a false-positive because the two stacktraces are identical
but pciehp_ist() is single-threaded." (aFQ4ncPNdmUgyw63@wunner.de). No v2.

**E18. 2025-12-08, Jinhui Guo (ByteDance), "[PATCH] vfio/pci: Skip hot reset on Link-Down"**; RESEND
2025-12-15
https://lore.kernel.org/r/20251215123029.2746-1-guojinhui.liam@bytedance.com
(v1: 20251208074459.1297-1-guojinhui.liam@bytedance.com)
Exactly P0 with stacks; skips the release-time reset of a disconnected device. Matches P0.
Outcome: not applied. Alex Williamson: the reset and hot-reset ioctls "can trigger this same deadlock";
asked for "a more comprehensive look at enabling vfio-pci to support surprise removal"
(20251223153534.0968cc15.alex@shazbot.org). Author agreed to research it; no follow-up.

**E19. 2026-01-09, Ziming Du (Huawei), "[PATCH] PCI: Fix AB-BA deadlock between aer_isr() and
device_shutdown()"**
https://lore.kernel.org/r/20260109095603.1088620-1-duziming2@huawei.com
device_shutdown() holds a port's device_lock and waits in free_irq() for the AER thread, which waits
in pci_bus_reset() for device locks. Related (reset paths taking device locks from AER context).
Outcome: open, no v2. Lukas: "Simply using trylock doesn't seem bullet-proof"; suggested removing the
device_lock acquisition from pci_bus_reset() (aZ1H4IMMW_4w60EH@wunner.de).

**E20. 2026-03-16, Guenter Roeck, "Re: [PATCH v3 2/2] PCI/IOV: Fix race between SR-IOV enable/disable and
hotplug"**
https://lore.kernel.org/r/0ca9e675-478c-411d-be32-e2d81439288f@roeck-us.net
Relays an AI review of a5338e365c45 (v7.0-rc1): sriov_numvfs_store() takes device_lock then
pci_rescan_remove_lock; remove_store() takes them in the opposite order. Matches R3 (sysfs remover),
i.e. R5.
Outcome: addressed for the remove_store() remover by Block/Nechita v15 2/5 (W2, in flight).

**E21. 2026-04-21, Keith Busch, "[PATCH] pci: don't fallback to bus reset after failed slot reset"**
https://lore.kernel.org/r/20260421150644.3543733-1-kbusch@meta.com
Keith posted the crash that motivated it: GPF on list poison 0xdead000000000100 in
pci_dev_save_and_disable() <- pci_bus_save_and_disable_locked() <- pci_reset_bridge() <-
reset_subordinate_store() while pciehp removed the card; the fallback "walks the bus' device list
without a lock", and there are "pre-existing locking issues that you can hit from a variety of
directions" (aevqGci1hLqZQdOF@kbusch-mbp). Matches N4.
Outcome: merged as cfcbfe5cb116 (v7.1-rc3). It removes the fallback only; the slot-reset walks are
unchanged.

**E22. 2026-07-05, Guangshuo Li, "[PATCH] PCI: Fix AB-BA deadlock between remove and SR-IOV sysfs"**
https://lore.kernel.org/r/20260705152458.291832-1-lgs201920130244@gmail.com
remove_store() unbinds before removal to avoid the E20 cycle. Matches R3/R5.
Outcome: rejected. Krzysztof Wilczyński: "This patch is a no-go, of course, given all the prior work"
(20260706155911.GA2885536@rocinante).

**E23. 2026-07-20, Lukasz Laguna (Intel), "[PATCH] drm/xe/pf: Hold pci_rescan_remove_lock while disabling
VFs"**
https://lore.kernel.org/r/20260720080510.2743242-1-lukasz.laguna@intel.com
PF driver unbind removes VFs without pci_rescan_remove_lock and trips the lockdep_assert_held() added
by 60e7b5aa8571 (v6.18-rc1). Related to R3.
Outcome: not pursued. Michal Wajdeczko replied that the same change had not worked and that xe is
waiting for the Nechita series (9bff9629-31ca-4618-92c6-c63b4f993bd9@intel.com); the author answered
"I missed that, thanks!". No v2.

**E24. 2026-08-17, Qiang Yu (Qualcomm), "[PATCH RFC] PCI: pciehp: Fix AB-BA deadlocks between reset_lock,
pci_rescan_remove_lock and pci_slot_mutex"** -- see W1. Matches N2 and N8.

**E25. 2026-08-21, Zhang Hongtao (Huawei), "PCI: Prevent device lock leak during bus reset"** -- see W4.
Matches N4.

**E26. 2026-09-06, Amit Engel (Dell), "[BUG/RFC] PCI/EDR/DPC: vfio-pci endpoint left disabled after
successful recovery"**
https://lore.kernel.org/r/CO1PR19MB48858DF4BB793A09ABEA7E1DEEB32@CO1PR19MB4885.namprd19.prod.outlook.com
After a successful DPC recovery a vfio-pci NVMe stays bound with PCI_COMMAND=0. Related to R2 (device
left unrestored after a recovery reset; different cause: vfio-pci has no slot_reset handler).
Outcome: Alex: "Known behavior, vfio-pci has never supported recovery from an uncorrected error."
(20260908150140.4f5ead2b@shazbot.org); pointed to W6.

**E27. 2026-09-08, YuanShang Mao (AMD), "[RFC PATCH] vfio/pci: Block for the upstream bridge lock in
vfio_pci_core_disable()"**
https://lore.kernel.org/r/20260908080946.2235849-1-YuanShang.Mao@amd.com
Makes the bridge lock taken by 962ae6892d8b (v7.0-rc1) blocking. The sashiko review found a
three-thread deadlock of the P0 shape: unbind waits in vfio_unregister_group_dev() for close, a bus
reset holds the bridge lock, the closing fd blocks on the bridge lock. Related to P0.
Outcome: rejected. Alex: "So no, it's not safe to promote this to a blocking lock."
(20260915132550.5516b466@shazbot.org).

Checked and not matching: Roman Lozko, "Deadlock in pciehp on dock disconnect" (2024-04-05; igc LED /
rtnl recursion, fixed by c04d1b9ecce5, v6.9-rc6); Kangfenglong, DPC NULL dereference on 5.10
(2026-01-14; already fixed by 11a1f4bc4736); Vidya Sagar's 2023 EDR/pciehp race (presence-detect
quirk); Hamza Mahfooz, reset_root_port() for root-bus devices (2026-10-16; does not take
pci_rescan_remove_lock).

---

## 3. Issues found while testing (N1-N10) and pre-existing issues not fixed (R1-R5)

### N1. pciehp_configure_device() re-acquires reset_lock with pci_rescan_remove_lock held
- Mechanism: hot-add takes reset_lock (read, pciehp_hpc.c:785), then pci_rescan_remove_lock
  (pciehp_pci.c:39); it drops reset_lock for pci_bus_add_devices() (:71-72) and re-acquires it at :73
  with pci_rescan_remove_lock still held, to read the DSN (:75-77). Removal does the same per device
  (:123-125). If a slot reset takes reset_lock for writing in the window, pciehp holds the global
  pci_rescan_remove_lock for the whole reset (a stall on its own, not a deadlock). Lockdep reports
  reset_lock <-> pci_rescan_remove_lock on the first hot-add after boot and then switches itself off,
  hiding later reports.
- Introduced by: f5eff5591b8f (v6.4-rc1). The DSN read after the re-acquire came with 9d573d19547b
  (v6.11-rc1).
- Impact: lockdep disabled for the rest of the boot; enumeration and removal stall system-wide for the
  duration of a pending slot reset (up to PCIE_RESET_READY_POLL_MS).
- Lab: `hotadd-lockdep` (exact mainline, one hot-add, removal and re-add): lockdep report on mainline,
  clean with the series. `nested-lockdep` (rescan of a switch with hotplug Downstream Ports, then
  hot-plug below one of them) reports the reverse edge, pci_rescan_remove_lock after reset_lock of a
  nested port; clean from commit 3.
- Earlier reports: E6, E13 (judged false positives because pciehp_ist() is single-threaded), E17.
  W1 also removes the re-acquisition.
- Fix: commit 2 (hot-add); commit 1 removes the removal-path re-acquisition; commit 3 removes the
  remaining reset_lock -> pci_rescan_remove_lock edge.

### N2. pci_host_reset_root_port() holds pci_rescan_remove_lock across a slot reset
- Mechanism: pci_host_reset_root_port() takes pci_rescan_remove_lock
  (drivers/pci/controller/pci-host-common.c:332), then pci_bus_error_reset() -> pci_reset_bridge() ->
  pci_slot_reset() -> pciehp_reset_slot() -> down_write(reset_lock) (pciehp_hpc.c:948). pciehp holds
  reset_lock (read) and blocks on pci_rescan_remove_lock in pciehp_configure_device() (pciehp_pci.c:39)
  or pciehp_unconfigure_device() (:107). Reached from pci_host_handle_link_down() on Root Port
  link-down via pcie_do_recovery(), or directly with CONFIG_PCIEAER=n (pci-host-common.c:345-352).
  Callers in v7.4-rc1: pcie-qcom.c, pcie-dw-rockchip.c.
- Introduced by: 4c99bace4f4e "PCI: host-common: Add link down handling for Root Ports" (v7.3-rc1;
  merged from v9, 20260729-pci-port-reset-v9-0-53570b92064d@oss.qualcomm.com). v7
  (20260310-pci-port-reset-v7-0-9dd00ccc25ab@oss.qualcomm.com) added the pci_lock_rescan_remove()
  call "as the device could be removed in-between due to Native hotplug interrupt". The order against
  reset_lock was not raised in the v7-v9 threads; a v7 reviewer only noted that the function must not
  be called from interrupt context because of pci_lock_rescan_remove() and pci_slot_mutex
  (2eb738fb-9dfe-1e88-6ea7-afdba9cb3d25@rock-chips.com).
- Impact: deadlock of link-down recovery and pciehp on a Root Port with native hotplug;
  pci_rescan_remove_lock and pci_slot_mutex stay held.
- Lab: `host-reset-deadlock` (hooks: a task takes pci_rescan_remove_lock and resets the Root Port's
  slot through pci_bus_error_reset() while pciehp hot-adds a NIC): hangs on mainline, passes from
  commit 3. The removal variant has the same pciehp-side edge as P0 and passes from commit 1.
- Earlier reports: E24/W1 (Qiang Yu, qcom_pcie_global_irq_thread as the caller). In flight: W7
  (rcar-gen4) and W8 (rzg3s) add pci_host_handle_link_down() callers.
- Fix: commit 3 (hot-add), commit 1 (removal).
- Residual with the series: a hook that resets the Root Port every ~3 ms starves the hot-add until the
  resets stop, because commit 3 redoes the link check after each reset.

### N3. pciehp_ignore_link_change() calls pci_get_slot() (pci_bus_sem) with reset_lock held
- Mechanism: down_read_nested(reset_lock) (pciehp_hpc.c:617) -> pciehp_device_replaced() ->
  pci_get_slot() (:575) -> down_read(pci_bus_sem). Possible cycle: an AER/DPC walk holds pci_bus_sem
  (read) and waits for a device_lock in the slot; the holder of that device_lock (e.g. vfio-pci
  release-time reset) waits for reset_lock (write); pciehp holds reset_lock (read) and its
  down_read(pci_bus_sem) queues behind a pci_bus_sem writer (pci_device_add(), pci_destroy_dev())
  that queued behind the walk.
- Introduced by: c3be50f7547c "PCI: pciehp: Ignore Presence Detect Changed caused by DPC" (v6.16-rc1;
  cover.1744298239.git.lukas@wunner.de). a97396c6eb13 (v5.14-rc1) only read Link Status under
  reset_lock.
- Impact: possible 4-task deadlock after an ignored DPC- or SBR-induced link change. Rare timing.
- Lab: none; found by review.
- Earlier reports: none. Same queued-writer pattern as R1 and the deadlock in W6's cover letter.
- Fix: commit 4.
- Residual (review, not reproduced; same in mainline, not fixed by the series): enumeration still
  takes pci_bus_sem under reset_lock (pci_get_slot() at pciehp_pci.c:41, pci_device_add(),
  pci_hp_add_bridge(), pcie_bus_configure_settings()). pciehp scanning a hot-added device waits for
  pci_bus_sem behind an AER/DPC walk, the walk waits for the hotplug port's device lock, and a slot
  reset that locked the port waits for reset_lock.

### N4. Slot/bus resets walk bus->devices without protection against concurrent removal
- Mechanism: __pci_bus_lock/unlock/trylock (pci.c:5424-5491) and the slot/bus save-and-disable and
  restore helpers (pci.c:5552-5616) iterate bus->devices without pci_bus_sem and without references.
  pci_destroy_dev() unlinks under pci_bus_sem without the device lock and drops the last reference
  (remove.c:47-58). Results: use-after-free, list-poison GPF, or a device lock taken by the lock walk
  and never released by the unlock walk (E25).
- Introduced by: 090a3c5322e9 "PCI: Add pci_reset_slot() and pci_reset_bus()" (v3.12-rc1).
- Impact: memory corruption, oops, or leaked device locks (bind/unbind hang) when a slot/bus reset
  (reset_subordinate, AER, vfio hot reset) races device removal.
- Lab: `reset-removal-uaf` (hooks, KASAN: AER-style resets of two Root Ports in loops while pciehp
  tears down a vfio-pci device below one of them): KASAN reports on mainline, clean with the series.
  Over 48 KASAN runs of four variants (resets through reset_subordinate, vfio hot reset and AER-style
  resets), mainline crashed in 5 and hung in 12 more; none crashed from commit 5. Reports include
  slab-use-after-free in pci_save_dpc_state() and in __mutex_lock (device_lock of a freed device), and
  a GPF at LIST_POISON in pci_try_reset_slot() and __pci_bus_lock().
- Earlier reports: E21 (real-world GPF, one path removed), E25/W4 (lock leak, same approach as commit
  5). Same class, fixed earlier for the DPC wait only: 11a1f4bc4736 (v6.11-rc1).
- Fix: commit 5. Commit 9 relocks if devices were added while the reset waited, as the old walk
  would have reached them.
- Residual (review): the checks whether a slot or bus can be reset at all (pci_slot_resettable(),
  pci_bus_resettable()) still walk bus->devices without pci_bus_sem.

### N5. Slot resets lock devices that are on bus->devices but not yet device_add()ed
- Mechanism: pci_device_add() links the device into bus->devices (probe.c:2765-2767) before
  device_add() (:2776), which takes device_lock in __device_attach() even though binding is not yet
  allowed. pciehp scans with reset_lock held (read). A slot reset that locks the slot in that window
  holds the new device's lock and waits for reset_lock (write) while pciehp waits in device_add().
  Lockdep does not track device locks.
- Introduced by: 5b3f7b7d062b (v4.19-rc1; reset_lock held across enumeration).
- Impact: deadlock of pciehp and the resetting task (reset_subordinate, AER).
- Lab: `reset-adding-device` (delay of 3 s between list_add_tail() and device_add()): hangs on
  mainline, passes from commit 6. The unmodified window is narrow.
- Earlier reports: none found.
- Fix: commit 6.

### N6. ->reset_slot() in flight while the hotplug driver unbinds (use-after-free of struct controller)
- Mechanism: pci_reset_hotplug_slot() (pci.c:4978-4991) calls ->reset_slot() holding only a module
  reference; pci_dev_reset_slot_function() does so with only the function locked. pci_hp_destroy()
  clears pci_slot->hotplug and does not wait for callers (pci_hotplug_core.c:481-488), although its
  kerneldoc says the driver "no longer needs to handle a ->reset_slot callback from this point on".
  pciehp_remove() then frees the controller embedding reset_lock while pciehp_reset_slot() is between
  down_write and up_write. In pci_reset_bridge(), pci_slot_mutex happens to prevent this for its own
  resets (see E3, Lukas 2020).
- Introduced by: 51bbf9bee34f "PCI: hotplug: Demidlayer registration with the core" (v4.19-rc1).
- Impact: use-after-free / rwsem corruption when a function reset with reset_method=bus, or a vfio
  hot reset, races unbinding of the pciehp service or the port driver.
- Lab: `pciehp-unbind-uaf` (exact mainline, KASAN: sysfs reset with reset_method=bus while the pciehp
  service is unbound and rebound in a loop): "slab-use-after-free in up_write <- pciehp_reset_slot",
  freed by unbind_store, on mainline; clean from commit 7. `reset-pciehp-unbind` (hooks: an AER-style
  reset of the port while pcieport unbinds from it) hangs on mainline on N8 and passes from commit 8.
- Earlier reports: E2 (Lukas 2020: "We've never done this correctly."), E3 (Lukas on slot->hotplug
  safety).
- Fix: commit 7, for callers that keep the pci_slot allocated: pci_reset_bridge() does, pci_reset_bus()
  does from commit 9 on. pci_dev_reset_slot_function() still reads dev->slot without a reference, a
  narrow window. Commit 8 depends on commit 7.

### N7. A slot reset queued on reset_lock runs its SBR while pciehp binds drivers to new devices
- Mechanism: pciehp releases reset_lock for pci_bus_add_devices() (pciehp_pci.c:71-73). A slot reset
  waiting in pciehp_reset_slot() gets reset_lock exactly then. pci_bus_add_device() saves config space
  without the device lock (bus.c:361) before probe; the reset restores only devices it locked earlier.
  Observed: pci_save_state() during the SBR, restore of a mid-reset snapshot (BAR0=0), "probe with
  driver e1000e failed with error -2", reset reported success.
- Introduced by: f5eff5591b8f (v6.4-rc1).
- Impact: hot-added device left without a driver or with cleared BARs and Command register after a
  reset_subordinate, AER, vfio hot reset or host reset during hot-add.
- Lab: `reset-before-bind` (hooks: ->reset_slot() called while pciehp waits for a contended
  pci_rescan_remove_lock, as a reset through pci_reset_bus() of an empty slot would): the NIC ends up
  unbound with BAR0 lost on mainline; passes from commit 3, which has pciehp let the queued reset run
  and redo the link check before it scans. `reset-after-scan` (delay of 3 s after the scan, then
  reset_subordinate): the NIC's driver fails to probe in some runs on mainline (timing-dependent);
  passes with the series, where the reset relocks the slot or returns -EAGAIN. On mainline, the
  variant where the slot was empty when locked through pci_reset_bridge() hangs on N8 first
  (`reset-during-bind`).
- Earlier reports: none found. W4's stated limitation ("a device added after the snapshot may be reset
  without its device lock held") is a related window in pci_bus_reset().
- Fix: commit 10, with the relocking of commit 9 (commit 3 for resets queued while pciehp waits for
  pci_rescan_remove_lock). Residual: enumerators other than pciehp, e.g. a sysfs rescan, can add
  devices to a slot during an error-recovery slot reset, which then hits them; they used to wait for
  the reset on pci_slot_mutex in pci_reset_bridge() (commit 8 drops it), as they never did for
  pci_reset_bus(). Try slot resets relock until such devices are added. Error-recovery slot resets
  still hit devices whose drivers probe asynchronously, or that the pciehp of an ancestor port is
  binding, as they never save or restore anything.

### N8. pci_reset_bridge() holds the global pci_slot_mutex across slot resets
- Mechanism: pci_reset_bridge() takes pci_slot_mutex (pci.c:5753) and holds it across
  pci_try_reset_slot()/pci_slot_reset() (5761-5771), which take device locks and then reset_lock
  (write). pciehp holds reset_lock (read) across pci_scan_slot() -> pci_dev_assign_slot() ->
  mutex_lock(pci_slot_mutex) (slot.c:204): AB-BA. Device-lock variant: pciehp_probe()/pciehp_remove()
  create/destroy the slot with the port's device_lock held, while an AER reset holding the mutex waits
  for that lock. Callers: sysfs reset_subordinate (pci_try_reset_bridge), AER aer_root_reset() and
  pci_host_reset_root_port() via pci_bus_error_reset().
- Introduced by: c4eed62a2143 "PCI/ERR: Use slot reset if available" (v4.20-rc1) for AER;
  8238cb69c01f "PCI: Make reset_subordinate hotplug safe" (v7.1-rc1;
  20260217160836.2709885-1-kbusch@meta.com) made reset_subordinate go through pci_reset_bridge().
- Impact: deadlock of hot-add with any reset_subordinate or AER reset of the same port; while stuck,
  pci_slot_mutex blocks slot creation system-wide. Slot resets of different ports serialize globally:
  QEMU, 8 Root Ports reset at once, 1.13 s vs 0.20 s with the series; hardware (24 PEX890xx Downstream
  Ports, v7.1-based backport), 27.7 s vs 1.2 s.
- Lab (exact mainline): `reset-storm` (reset_subordinate in a loop while NICs are hot-added on eight
  Root Ports) and `reset-during-bind` (reset_subordinate of an empty slot during hot-add) hang;
  `slot-mutex-lockdep` reports the cycle. All pass from commit 8. `aer-hotadd-race` (hooks) hangs on
  mainline on this issue before it can show R2.
- Earlier reports: E3 2/2 (Ian May, 2020), E11 (Ilkka Koskinen, 2024, no reply), E24/W1 (Qiang Yu,
  2026; fixes the reset_lock half only).
- Fix: commit 8, relying on commits 5-7 for what the mutex protected by accident (slot->hotplug
  lifetime, the device lists while the reset waits).

### N9. remove_store(): use-after-free of the pci_dev after device_remove_file_self()
- Mechanism: remove_store() (pci-sysfs.c:515-526) calls device_remove_file_self(), which drops the
  kernfs active reference that kept the device alive, then
  pci_stop_and_remove_bus_device_locked(to_pci_dev(dev)) with no reference held. If pciehp or a
  parent's remover gets pci_rescan_remove_lock first and removes the device, the last put frees it.
- Introduced by: bc6caf02ccce "pci: use device_remove_file_self() instead of
  device_schedule_callback()" (v3.15-rc1).
- Impact: use-after-free on concurrent sysfs remove and hot-removal (or removal of an ancestor).
- Lab: `sysfs-remove-uaf` (exact mainline, KASAN: sysfs "remove" of a NIC racing slot power-off):
  slab-use-after-free in pci_stop_bus_device <- remove_store, freed by pciehp_unconfigure_device, on
  mainline; clean from commit 11.
- Earlier reports: E9 (Keith Busch, 2024; driver-core fix rejected), E10 8/8 (same pin as commit 11,
  not merged).
- Fix: commit 11.

### N10. Nested hotplug ports: removal waits in free_irq() for an IRQ thread that waits for pci_rescan_remove_lock
- Mechanism: the remover holds pci_rescan_remove_lock and unbinds the child port: pci_stop_dev() ->
  pciehp_remove() -> pcie_shutdown_notification() -> free_irq(), which waits for the child's IRQ
  thread, blocked in pciehp_unconfigure_device() -> pci_lock_rescan_remove() (pciehp_pci.c:107).
- Introduced by: long-standing; pciehp takes pci_rescan_remove_lock since c4ec84c7db0e (v3.14-rc1).
- Impact: permanent hang when a slot below a switch and the switch (or its parent slot) are removed
  together; pci_rescan_remove_lock stays held.
- Lab: `nested-removal` (exact mainline: remove a NIC below a switch Downstream Port and the switch at
  nearly the same time) hangs in some runs on mainline (free_irq() in the stacks; 3 of 6 in our
  runs), still hangs at every intermediate commit, and passes 6 of 6 with commit 12.
- Earlier reports: E0 (Xiongfeng Wang 2018/2019, sysfs remover), E1 (2018), E8 (2024), E12, E15
  (real-world, triggers avoided by e3260237aaad), E10 (per-bus lock alternative), W3 (Keith Busch
  RESEND, 2025).
- Series note: removing nested ports while reset_subordinate runs on them in loops hung in 0 of 3 runs
  on mainline, in 1-2 of 3 at each of commits 1-4, 0 of 3 at commits 5-7 and 2-3 of 3 at commits 8-11,
  always on this deadlock; it passed 3 of 3 with commit 12. Commit 12 has to be backported with the
  others.
- Fix: commit 12 (generalizes W3 from "port disconnected" to "removal of the port has begun").
  Bringing up a slot while removal of its port begins can still deadlock, as can unbinding just the
  port driver through sysfs while the lock's holder waits for the port.

### R1. pci_bridge_wait_for_secondary_bus() takes pci_bus_sem with device locks held (not fixed)
- Mechanism: pci_bridge_secondary_bus_reset() -> pci_bridge_wait_for_secondary_bus() ->
  down_read(pci_bus_sem) (pci.c:4817), called with the slot/bus device locks held (and reset_lock for
  writing from pciehp_reset_slot()). An AER walk holds pci_bus_sem (read) and waits for one of those
  device locks (pcie/err.c:57); once a writer queues on pci_bus_sem, the reset's down_read blocks.
- Introduced by: ac91e6980563 (v6.3-rc1) routed the SBR wait through
  pci_bridge_wait_for_secondary_bus(), which takes pci_bus_sem since ad9001f2f411 (v5.5-rc1).
- Impact: possible deadlock of an SBR, an AER/DPC recovery walk and any enumeration or removal.
- Lab: none; found by review.
- Earlier reports: E16 (two-party variant; also Jay Fang 2019). W6's cover letter describes four tasks
  with vfio memory_lock and a queued pci_bus_sem writer, found by AI review in the RFC's new recovery
  code, not in mainline. 98693e0897f7 (v6.19-rc1) fixed a different cycle (a lockdep report)
  involving pci_bus_sem.
- Status: not fixed by the series (commits 9 and 10 only trylock pci_bus_sem in their own checks).

### R2. AER/DPC recovery racing a hot-add resets the new device after its driver bound, without notifying it (not fixed)
- Mechanism: pcie_do_recovery() notifies only drivers bound when its error_detected walk ran
  (pcie/err.c:238-242), then resets via pci_bus_error_reset() -> pci_reset_bridge(...,
  PCI_RESET_NO_RESTORE) without save/restore. A device hot-added and bound in between loses its BARs
  and Command register and gets no callbacks. With CONFIG_PCIEAER=n, pci_host_reset_root_port()
  resets with no recovery callbacks at all.
- Introduced by: long-standing design; c4eed62a2143 (v4.20-rc1) made the AER reset a slot reset.
- Impact: a bound device silently loses its configuration.
- Lab: `aer-hotadd-race` (hooks: pcie_do_recovery() of the Root Port while pciehp hot-adds a NIC):
  hangs on N8 on mainline; with the series, the NIC ends up bound with BAR0=0 and Command 0x0400. The
  series turns the hang into this failure. pci_bus_error_reset() without recovery callbacks, as
  pci_host_reset_root_port() does with CONFIG_PCIEAER=n, fails the same way with the series.
- Earlier reports: none of this exact race. Related: E26 (vfio-pci not restored after recovery);
  on v8 of 4c99bace4f4e, the sashiko review asked about the CONFIG_PCIEAER=n reset without driver
  notification and the author, Manivannan Sadhasivam, replied "That's a design limitation."
  (mcdce4u2alwsobdsapnnwjwxofhwrd6gypdu45m3i5wzswhp65@lhrv5tvsvjs7).
- Status: not fixed.

### R3. sriov_numvfs_store() vs removal of the PF: device_lock vs pci_rescan_remove_lock (not fixed)
- Mechanism: sriov_numvfs_store() takes device_lock(PF) (iov.c:452), then pci_lock_rescan_remove()
  around ->sriov_configure() (iov.c:473, 487). A remover holding pci_rescan_remove_lock waits for
  device_lock(PF) when it unbinds the PF: pciehp_unconfigure_device() or remove_store() ->
  pci_stop_and_remove_bus_device_locked().
- Introduced by: a5338e365c45 "PCI/IOV: Fix race between SR-IOV enable/disable and hotplug" (v7.0-rc1;
  20251216-revert_sriov_lock-v3-0-dac4925a7621@linux.ibm.com).
- Impact: deadlock of SR-IOV enable/disable with removal of the PF; pci_rescan_remove_lock stays held.
- Lab: `sriov-remove-abba` (hooks only to order the tasks: sysfs "remove" of an igb PF racing
  sriov_numvfs=0): hangs on mainline and with the series. The pciehp-remover variant hung in 2 of 2
  runs on mainline and 1 of 2 with the series.
- Earlier reports: E20 (Roeck, sysfs remover), E22, E23 (related).
- In flight: W2 (Block/Nechita v15) 2/5 fixes the remove_store() remover. By code reading it does not
  fix the pciehp remover: in v15 sriov_numvfs_store() still holds device_lock(PF) across
  sriov_del_vfs() -> pci_lock_rescan_remove(). Not tested.
- Status: not fixed by the series.

### R4. Resetting a surprise-removed device can hold device locks and reset_lock for up to 60 s (not fixed)
- Mechanism: after an SBR, pci_bridge_wait_for_secondary_bus() calls pci_dev_wait() with up to
  PCIE_RESET_READY_POLL_MS (60 s) (pci.c:4890, 4902). It ends early only if the device is marked
  disconnected or link-state checks short-circuit. On ports faster than 5 GT/s without Data Link Layer
  Link Active Reporting, pcie_wait_for_link_delay() just sleeps and the 60 s poll follows; ports at
  5 GT/s or less without it give up after 1 s. pciehp_ist() takes reset_lock before
  pciehp_unconfigure_device() marks devices disconnected, so pciehp cannot mark them while the reset
  waits.
- Introduced by: 6b2f1351af56 "PCI: Wait for device to become ready after secondary bus reset"
  (v4.17-rc1) and ac91e6980563 (v6.3-rc1).
- Impact: removal and other resets stall for up to 60 s per reset with a device that keeps returning
  Request Retry Status or a link that is up while the device does not respond, and on >5 GT/s ports
  without link-active reporting. With reporting and the link down, each reset gives up after about
  1 s (hardware: the exiting process took 3.5-6.5 s with commit 1).
- Lab: none.
- Earlier reports: none found.
- Status: not fixed (commit 1 still takes reset_lock before marking devices disconnected).

### R5. remove_store() vs SR-IOV: same as R3
On v7.4-rc1 this is R3 with sysfs "remove" as the remover (E20). The unbind_store() variant described
in W2 2/5 (unbind -> .remove() -> pci_disable_sriov() -> sriov_del_vfs() -> pci_lock_rescan_remove())
only exists once W2 1/5 makes sriov_del_vfs() take the lock; mainline sriov_del_vfs() (iov.c:739-746)
does not.

---

## 4. Related in-flight work and RFCs

**W1. Qiang Yu, "[PATCH RFC] PCI: pciehp: Fix AB-BA deadlocks between reset_lock, pci_rescan_remove_lock
and pci_slot_mutex"**, RFC v1, 2026-08-17
https://lore.kernel.org/r/20260817-ab-ba-deadlock-v1-1-e619fd07d1fd@oss.qualcomm.com
Drops reset_lock across all of pciehp_configure_device()/pciehp_unconfigure_device() and moves the
exclusion against SBR to pci_rescan_remove_lock, taken in pci_reset_bridge() and pci_reset_bus();
pci_host_reset_root_port() no longer takes it; adds pci_reset_bus_unlocked() for vmd.
Addresses N1, N2, the reset_lock half of N8, and P0's function-reset path. pci_reset_bridge() still holds
pci_slot_mutex across slot resets (device-lock half of N8 remains). Taking pci_rescan_remove_lock in
pci_reset_bus() can bring P0 back as a two-party deadlock through vfio_pci_dev_set_try_reset() and the
hot-reset ioctl (analysis). Sashiko reported a self-deadlock when pci_reset_bus() runs under
pci_rescan_remove_lock and an AB-BA with vfio dev_set->lock (20260818065238.7739B1F000E9@smtp.kernel.org).
Status: no human response, no v2. Overlaps commits 1, 2, 3, 8 and 10.

**W2. Benjamin Block / Ionut Nechita, "[PATCH v15 0/5] PCI/IOV: Fix SR-IOV locking races and AB-BA
deadlocks"**, v15 2026-09-24 (5/5 resent as v16 2026-10-02,
4c7d6e0ca4772a80059e9feb8e4b113154f420c3.1790945242.git.bblock@linux.ibm.com)
https://lore.kernel.org/r/cover.1790267348.git.bblock@linux.ibm.com
1/5 makes pci_lock_rescan_remove() reentrant (owner + depth; the unlock WARNs and returns if the caller
is not the owner) and takes it in sriov_add_vfs()/sriov_del_vfs(); 2/5 unbinds before removal in
remove_store(); 3-4/5 export a declaration and a guard; 5/5 s390. Earlier: Nechita v1-v14 (from
2026-02-09) and Block's s390 series v1-v4.
Addresses R3 (sysfs remover), R5, E23's assert. Not the pciehp remover of R3 (code reading).
Status: no maintainer feedback; Block pinged on 2026-11-04 (20261104111631.GA19494@p14sgen6-pf6akexs):
"it's basically been stalled for over half a year now". Conflicts with the reference series: commits 3
and 12 use a trylock on the mutex, which would not set v15's owner/depth, so v15's unlock would WARN
and leave the mutex locked; both would need adapting. 2/5 and commit 11 both change remove_store(); 2/5
uses dev after device_remove_file_self() without a reference, so N9 applies to it without commit 11's
pin.

**W3. Keith Busch, "[PATCH RESEND 1/1] PCI: pciehp: fix concurrent sub-tree removal deadlock"**,
2025-10-16 (v1/v2 2024-06, E8)
https://lore.kernel.org/r/20251016193049.881212-2-kbusch@meta.com
pciehp waits for pci_rescan_remove_lock with a trylock in wait_event() until it gets the lock or its
port is disconnected. Addresses N10 for surprise removal of the parent by pciehp only, not safe removal
or other removers.
Status: no maintainer response; kernel test robot build errors (202510171720.AKF8sDMd-lkp@intel.com).
Commit 12 generalizes it and cites it.

**W4. Zhang Hongtao, "PCI: Prevent device lock leak during bus reset"** (RFC), 2026-08-21
https://lore.kernel.org/r/20260821021626.1874602-1-zhanghongtao35@huawei.com
Snapshot of the devices under pci_bus_sem with references, used for both locking and unlocking in
pci_bus_reset(). Same approach as commit 5, for one path. Addresses N4 (lock leak, use-after-free). The
author notes devices added after the snapshot are reset without their lock (N7 window) and that the
slot and try-reset paths are unpatched.
Status: no maintainer response; author pinged on 2026-09-22 asking whether to extend the snapshot or
exclude topology changes for the whole reset (20260922072319.366662-1-zhanghongtao35@huawei.com).

**W5. Abhin Parekadan Jose, "[PATCH RFC v4 0/5] PCI: pciehp: Report surprise removal during safe
removal"**, 2026-09-27 (builds on Michael S. Tsirkin's "pci,virtio: report surprise removal event" RFC
v5, 2025-07-09, cover.1752094439.git.mst@redhat.com)
https://lore.kernel.org/r/20260927182017.938565-1-abhinjoses@gmail.com
pciehp_isr() schedules work that marks devices disconnected while the IRQ thread is busy with a safe
removal. Related to P0 (pciehp thread stuck in a driver's remove), but vfio-pci does not use the
mechanism. 4/5 assumes pciehp_ist() is the only consumer of PCI_LINK_CHANGED; commit 3 also consumes
it from board_added(), so the two would need reconciling.
Status: RFC; mst review (20261012022556-mutt-send-email-mst@kernel.org); no response from Lukas or
Bjorn to any version (v1 2026-09-05, 20260905183905.997833-1-abhinjoses@gmail.com, to v4).

**W6. Shameer Kolothum, "[RFC PATCH v2 00/16] vfio/pci: Handle PCI error recovery and report state to
userspace"**, 2026-09-29 (v1 2026-09-01)
https://lore.kernel.org/r/20260929173305.204856-1-skolothumtho@nvidia.com
Opt-in host AER/DPC recovery for vfio-pci. The cover letter lists an unsolved four-task deadlock in
the RFC's own recovery path, found by AI review, with a queued pci_bus_sem writer (the R1/N3
pattern). Alex replied that he had considered an SRCU-based disconnect of the device from its
user-facing objects for surprise unplug and forced unbind (20261015135718.43d1d27f@shazbot.org), the
direction E18's review asked for. Related to R2 (vfio side), R1, P0.
Status: RFC; the only human reply to v2 is Alex's (2026-10-15).

**W7. Koichiro Den, "[PATCH v5 00/17] PCI: rcar-gen4: Recover from link down and route Root Port
interrupts"**, v5 2026-10-20
https://lore.kernel.org/r/20261020031049.969895-1-den@valinux.co.jp
12/17 calls pci_host_handle_link_down() (or reset_root_port() under pci_lock_rescan_remove() when the
port is absent). Extends N2's exposure to R-Car Gen4 Root Ports with native hotplug.
Status: in review (12/17 Reviewed-by Marek Vasut).

**W8. Claudiu Beznea, "[PATCH v7 00/14] PCI: rzg3s-host: Add PCIe hotplug support"**, v7 2026-10-19
https://lore.kernel.org/r/20261019065025.2146539-1-claudiu.beznea@kernel.org
14/14 adds bridge->reset_root_port() and a pci_host_handle_link_down() caller. Whether the N2
interaction with pciehp applies depends on native hotplug on that Root Port; not examined.
Status: in review.

**W9. Lukas Wunner, "[PATCH] PCI: Fix order of device disablement on reset"**, 2026-09-15
https://lore.kernel.org/r/4c908eaab127d82ecfdc1e9948964b2e641d41d8.1789478646.git.lukas@wunner.de
Reorders pci_bus_save_and_disable_locked() and pci_slot_save_and_disable_locked(). Unrelated to our
issues; textual conflict with commit 5.
Status: respin announced (aqvfUldY5mGMMYrG@wunner.de).

**W10. Alex Williamson, "[RFC PATCH 0/5] PCI/vfio-pci: Guard resets against active SR-IOV VFs"**,
2026-08-11
https://lore.kernel.org/r/20260812045325.2733631-1-alex.williamson@nvidia.com
2/5 adds a callback to pci_reset_bus() evaluated after the hierarchy is locked. Unrelated to our
issues; overlaps commit 5's locking code.
Status: RFC, discussion through 2026-09-22.

**W11. Keith Busch, "[PATCH] vfio/pci: Restore standard PCI config space in .slot_reset()"**, 2026-08-17
https://lore.kernel.org/r/20260817195110.2077698-1-kbusch@meta.com
Discussion starter on AER/DPC recovery for vfio-pci; Lukas mentioned pending patches to invoke
->reset_slot() on fatal errors and to recover unbound devices (aoSCK2Sy0HeyX_la@wunner.de). Related to
R2.
Status: not a formal proposal (author's words); superseded in practice by W6.

**W12. Priyank Rathod, "[PATCH] PCI: pciehp: Fix NULL pointer dereference in
pciehp_configure_device()"**, 2026-10-12
https://lore.kernel.org/r/20261012-pcie-hotplug-nullref-v1-1-6e21c2e89ea4@google.com
NULL check for the DSN read after re-acquiring reset_lock. Unrelated bug; same lines as commit 2.
Status: posted; sashiko comment only.

Review constraints from earlier threads that any fix has to respect:
- A slot reset must not wait for the pciehp IRQ thread while holding reset_lock (Lukas on Keith's
  "pciehp: sync interrupts for bus resets", aLRRh_4YhAZjWeEW@wunner.de) or device locks, which
  pciehp_reset_slot() callers hold (Lukas on Ilpo Järvinen's 2025-03 series,
  Z9Wjk2GzrSURZoTG@wunner.de).
- reset_lock must keep excluding slot resets from the link check through enumeration (E13).
- Without pci_slot_mutex in pci_reset_bridge(), slot->hotplug needs another lifetime guarantee (E3).
- Self-removing sysfs attributes must handle their own lifetime (E9).
- vfio-pci: the bridge lock in vfio_pci_core_disable() cannot block (E27); surprise removal should be
  handled comprehensively, not only at release (E18).

---

## 5. Cross-reference

| ID | Summary | Earlier reports (section 2) | In-flight work (section 4) | Reference fix | Lab tests |
|---|---|---|---|---|---|
| P0 | pciehp holds reset_lock waiting for pci_rescan_remove_lock; vfio close-time reset waits for that reset_lock | E14, E18 (same); E2, E3, E4 (precursors, fixed by f5eff5591b8f); E17 (same reordering, judged lockdep false positive); E7, E27 (related) | W1 (partial), W5, W6 (related) | 1 (+3 for lockdep) | vfio-exit-deadlock, vfio-reset-deadlock, sysfs-remove-deadlock, sriov-disable-deadlock |
| N1 | reset_lock re-acquired with pci_rescan_remove_lock held | E6, E13, E17 | W1 | 2 (+1, +3) | hotadd-lockdep, nested-lockdep |
| N2 | pci_host_reset_root_port() holds pci_rescan_remove_lock across slot reset | E24 | W1; W7, W8 (new callers) | 3 (hot-add), 1 (removal) | host-reset-deadlock |
| N3 | pci_get_slot() under reset_lock in pciehp_ignore_link_change() | none | none | 4 | none |
| N4 | reset walks of bus->devices vs removal (UAF, GPF, leaked lock) | E21, E25 | W4 | 5 (+9) | reset-removal-uaf |
| N5 | resets lock devices not yet device_add()ed | none | none | 6 | reset-adding-device |
| N6 | ->reset_slot() in flight during hotplug driver unbind (UAF) | E2, E3 (maintainer remarks) | none | 7 | pciehp-unbind-uaf, reset-pciehp-unbind |
| N7 | queued slot reset hits devices while drivers bind | none (W4 notes the window) | W4 (limitation) | 10 (+9; 3) | reset-before-bind, reset-after-scan |
| N8 | pci_slot_mutex held across slot resets | E3 (2/2), E11, E24 | W1 (partial) | 8 | reset-storm, reset-during-bind, slot-mutex-lockdep |
| N9 | remove_store() UAF after device_remove_file_self() | E9, E10 (8/8) | W2 2/5 touches the same code | 11 | sysfs-remove-uaf |
| N10 | nested ports: free_irq() vs IRQ thread waiting for pci_rescan_remove_lock | E0, E1, E8, E10, E12, E15 | W3 | 12 | nested-removal |
| R1 | pci_bus_sem taken with device locks held during SBR | E16 | W6 (same pattern) | not fixed | none |
| R2 | recovery reset hits a device bound after error_detected | E26 (related) | W6, W11 (related) | not fixed | aer-hotadd-race |
| R3 | sriov_numvfs_store() vs PF removal | E20, E22, E23 | W2 (sysfs remover only) | not fixed | sriov-remove-abba |
| R4 | up to 60 s with locks held resetting a dead link | none | none | not fixed | none |
| R5 | = R3 with sysfs remove as remover | E20, E22 | W2 2/5 | not fixed | sriov-remove-abba |
