# pciehp, PCI slot/bus reset and device removal: deadlocks and use-after-frees in v7.4-rc1

Base: v7.4-rc1 (6628e7d4c6b2). Code references are to that tree. Status as of 2026-11-06.

Conventions:
- Test names refer to this lab (`./run test <name>`, table in the README). Tier 1 tests run on the exact
  v7.4-rc1 sources. Tier 2 tests need a TEST ONLY patch on top (`patches/test-hooks.patch`): debugfs
  hooks that emulate callers and events QEMU can't produce (AER/DPC recovery resets,
  pci_host_reset_root_port(), the link change a real port reports after a reset) and delays that widen
  windows in pciehp, pci_device_add() and probe.
- Counts are "failing runs / runs" on v7.4-rc1. Counts not tied to a lab test come from a larger set
  of scenario variants run during development; the lab's own counts are in the README.
- This document describes the bugs only. Fix work and its status: [fix-status.md](fix-status.md).

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
VFIO_DEVICE_PCI_HOT_RESET path reaches pciehp_reset_slot() too; we did not demonstrate it. The
holder's side on its own, removal waiting for a vfio-pci user with pci_rescan_remove_lock held, is N22.

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
and `sriov-disable-deadlock` (sriov_numvfs=0 as the lock holder) all hang. With hooks,
`host-reset-deadlock` covers the pci_host_reset_root_port() holder on hot-add (N2). Hung-task stacks on
mainline: irq/B in pciehp_unconfigure_device(), irq/A in vfio_unregister_group_dev(), the exiting task
in pciehp_reset_slot() via do_exit.

**Earlier reports.** E14 (SPDK, 2024, same cycle, open), E18 (Jinhui Guo, 2025, same cycle, not
applied). Precursors fixed by f5eff5591b8f: E2, E3, E4. E17 also released reset_lock before
pci_lock_rescan_remove() (but re-acquired it under that lock) for a lockdep report and was rejected as
a false positive; the deadlock needs the second party (the close-time reset), which that report did
not include.

---

## 2. Earlier upstream reports of the same or matching problems

Lore links are https://lore.kernel.org/r/<message-id>. Release = first tag containing the commit.
E0-E27 are in chronological order; E28-E36, found while cataloging N11-N24, follow in their own
chronological order.

**E0. 2018-02-26, Xiongfeng Wang (Huawei), "[PATCH] pciehp: fix a race between pciehp and removing
operations by sysfs"** (RFC v2 2018-01-02, 1514879577-47078-1-git-send-email-wangxiongfeng2@huawei.com;
v2 2019-08-05, 1565008378-4733-1-git-send-email-wangxiongfeng2@huawei.com)
https://lore.kernel.org/r/1519648875-38196-1-git-send-email-wangxiongfeng2@huawei.com
Hung tasks on 4.12: sysfs "remove" of a hotplug port holds pci_rescan_remove_lock and waits in
pciehp_remove() (drain_workqueue()) for the port's pciehp work, which waits for pci_rescan_remove_lock
in pciehp_unconfigure_device(); v2's trace (4.19) has the IRQ thread instead, with the remover in
free_irq(). Matches N10 (sysfs remover). E1's withdrawal message (below) names this patch
(patchwork.ozlabs.org/patch/877835), and E8's "sysfs race" remark refers back to it.
Outcome: not merged. Lukas (2019-08-05) suggested a flag marking devices "about to be removed", set
before taking pci_rescan_remove_lock, so that pciehp_unconfigure_device() skips the lock: "But again,
that approach is just a band-aid and the real fix is to unbind devices without holding the lock."
(20190805114053.srbngho3wbziy2uy@wunner.de). On v2 he raised the sysfs ABI change and asked for "a
solution which addresses all types of deadlocks caused by the pci_rescan_remove_lock()", e.g. two
simultaneous surprise removals of a parent and a child, re-quoting his flag suggestion
(20190811080703.qfnlzfutgamoxzti@wunner.de). No later version.

**E1. 2018-06-16, Lukas Wunner, "[PATCH 03/32] PCI: pciehp: Fix deadlock on unplug"** (in "[PATCH 00/32]
Rework pciehp event handling & add runtime PM", cover.1529173804.git.lukas@wunner.de)
https://lore.kernel.org/r/4c882e25194ba8282b78fe963fec8faae7cf23eb.1529173804.git.lukas@wunner.de
Nested hotplug ports: the parent's removal holds pci_rescan_remove_lock and waits for the child port's
IRQ thread, which waits for the same lock. Matches N10. The same series added reset_lock (23/32,
5b3f7b7d062b, v4.19-rc1; P0 origin) and the hotplug_slot registration (14/32, 51bbf9bee34f, v4.19-rc1;
N6 origin).
Outcome: series merged in v4.19-rc1 except 03/32, which the author withdrew on finding E0's sysfs
variant: "We need a generic solution which works regardless of the contenders' type"
(20180620110140.GA8724@wunner.de). Asked by Mika Westerberg in 2018-09 to resend it: "it's not a good
solution, it would just add technical debt" and "The first step (unbinding) needs to run lockless."
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
precursor). 2/2 (trace taken with 1/2 applied, which moved the down_write() into a new
pciehp_reset_lock() called from pci_slot_reset()): pciehp holds reset_lock and takes pci_slot_mutex in
pci_dev_assign_slot(); AER pci_bus_error_reset() holds pci_slot_mutex and takes reset_lock. 2/2
matches N8; on an unpatched kernel the AER side waits in pciehp_reset_slot() (E11).
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
Outcome: superseded. 74ff8864cc84 (v6.3-rc1) fixes the reported trace, but Antonovitch's setup then hit
a different deadlock (d14fd1b2-41c9-75bd-5b76-d2c396c1ebb7@amd.com, 20230121072148.GA13969@wunner.de);
f5eff5591b8f (v6.4-rc1, Tested-by Antonovitch on 6.3.0-rc5) fixed that
(f0742b10-9caf-d66e-460a-0703d7ce2fc2@amd.com).

**E5. 2023-04-11, Lukas Wunner, "[PATCH v2] PCI: pciehp: Fix AB-BA deadlock between reset_lock and
device_lock"**
https://lore.kernel.org/r/fef2b2e9edf245c049a8c5b94743c0f74ff5008a.1681191902.git.lukas@wunner.de
The fix for E2-E4: releases reset_lock around driver binding and unbinding and re-acquires it with
pci_rescan_remove_lock held, as "best-effort reset protection ... until a general solution is
implemented in the PCI core". The re-acquisition is N1; releasing reset_lock for binding with a reset
queued on it is N7; P0 remains. The changelog also says: "The reset_lock's purpose is to protect slot
registers, not enumeration and de-enumeration of hotplugged devices. That would arguably be the job of
the PCI core"; compare Lukas in E13 (2024).
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
that would release it blocks in sriov_numvfs_show() on the same device_lock. Related to P0 and N22
(remover waits for user space while holding a lock user space needs). Jason Gunthorpe: "The mechanism of
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
In 2024-11 he suggested per-bus locks acquired bottom-up over the sub-hierarchy
(ZzG0W7LGrggNa6Qi@wunner.de), taken by pci_lock_rescan_remove() itself (ZzG5koPOn16KQ8uM@wunner.de);
Keith: "I don't think we can walk the bus bottom-up without hitting the same deadlock I'm trying to
fix." (ZzJF77YoNO-fdmow@kbusch-mbp.dhcp.thefacebook.com). Keith asked to reconsider it in 2024-08
(ZrOVZ04UzAOp5O-Z@kbusch-mbp) and resent it in 2025 (W3). 2/2 superseded by Lukas's 11a1f4bc4736
(v6.11-rc1), following his advice to "hold references on the structs being accessed, not to acquire
locks that happen to prevent the structs from being freed" (Zm2gpY_Yi9JTrS_5@wunner.de).

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
4d6dcd6c2fa3, ee061da777f7, 38a18dfe9035; v6.13-rc1). 6-8 never reposted (see E8 for the 2024-11
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
reporter confirmed E8 fixes it ("Yes, the 2 patches work") and, in the same reply, wrote of Keith's
rework series Lukas had pointed to (E10; 20240827192826.710031-1-kbusch@meta.com), which he adapted to
apply: "this series doesn't work for me" (CAFv23Q=QJ+SmpwvzLmzJeCXwYrAHVvTK96Wz7rY=df7VmGbSmw@mail.gmail.com).
Matches N10.
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
The reporter posted a test diff, not a formal patch, making vfio_device_fops_release() asynchronous
(A8CD6F73-CDBC-45D1-A8DF-CB583962DB8C@gmail.com); Yi Liu: "I don't see a reason why it can work so
far." (5b2b0211-81d9-4ec9-98d5-b39a84581ac0@intel.com).
Outcome: open; last message 2024-12-03.

**E15. 2025-02-10, Kenneth Crudup, "Re: diagnosing resume failures after disconnected USB4 drives"**
https://lore.kernel.org/r/83d9302a-f743-43e4-9de2-2dd66d91ab5b@panix.com
Resume fails after disconnecting a TB4 dock with a USB4 NVMe enclosure during suspend. Mika Westerberg
reproduced it and bisected it to 9d573d19547b (20250226084404.GM3713119@black.fi.intel.com); Lukas,
replying to him: "This looks like the deadlock we've had for years when hot-removing nested hotplug
ports" (Z77ak-4YsdAKXbHr@wunner.de). Matches N10.
Outcome: trigger avoided by e3260237aaad (v6.15-rc1; Tested-by and Reviewed-by Mika), whose changelog
says "A proper fix is being worked on, but needs more time as it is nontrivial and necessarily
intrusive." Underlying deadlock open.

**E16. 2025-03-31, liwei (JK) (Huawei), "[Question] pcie_do_recovery and pci_enable_sriov deadlock
problem"**
https://lore.kernel.org/r/805b2e50-00f7-40a4-975c-6bfe7d3c431b@huawei.com
kdump kernel: an AER walk holds pci_bus_sem for reading and waits for a device_lock; the holder of that
device_lock, a deferred driver probe, is in pci_enable_sriov() -> pci_device_add() ->
down_write(pci_bus_sem). Matches N11 (two-party variant). It cites Jay Fang's 2019 report of the same
lock pair with sriov_numvfs_store() as the device_lock holder (E32), whose patch was not merged.
Outcome: no response.

**E17. 2025-06-19, Raju Rangoju (AMD), "[PATCH] PCI: pciehp: fix circular lock dependency b/w
pci_rescan_remove_lock and reset_lock"**
https://lore.kernel.org/r/20250619154610.902892-1-Raju.Rangoju@amd.com
Lockdep (6.14.5) in pciehp_unconfigure_device(); releases reset_lock before pci_lock_rescan_remove(),
but still re-acquires it with pci_rescan_remove_lock held, after each device and after the loop. It no
longer waits for pci_rescan_remove_lock under reset_lock, but keeps the N1 edge. Matches N1 (removal
path); P0 by mechanism, though the report shows only lockdep.
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
in pci_bus_reset() for device locks. Matches N24.
Outcome: open, no v2. Bjorn asked whether the pci_slot_reset() path has the same deadlock
(20260113185130.GA774840@bhelgaas); the author agreed it likely does but could not test it
(3a045365-3cd0-408e-a366-4c81a1b60cbb@huawei.com). Lukas: one lock, not AB-BA; device_shutdown() takes
device_lock since d1c6c030fcec, and "It's unclear why pci_bus_reset() needs to acquire device_lock.
This was introduced by 090a3c5322e9"; "Simply using trylock doesn't seem bullet-proof"; he suggested
first looking into removal of the device_lock acquisition in pci_bus_reset()
(aZ1H4IMMW_4w60EH@wunner.de). Tested here: the pci_slot_reset() path deadlocks the same way, and the
posted patch fixes only the pci_bus_reset() path (N24).

**E20. 2026-03-16, Guenter Roeck, "Re: [PATCH v3 2/2] PCI/IOV: Fix race between SR-IOV enable/disable and
hotplug"**
https://lore.kernel.org/r/0ca9e675-478c-411d-be32-e2d81439288f@roeck-us.net
Relays an AI review of a5338e365c45 (v7.0-rc1): sriov_numvfs_store() takes device_lock then
pci_rescan_remove_lock; remove_store() takes them in the opposite order. Matches N13 (sysfs remover).
In the thread Lukas called unbinding before removal "a bandaid to work around the too
coarse-grained pci_lock_rescan_remove()" (ablUiODohaE7_RKH@wunner.de). Benjamin Block noted that a
driver could bind again between such an unbind and the removal and used kill_device()
(20260317113334.GJ2161595@p1gen4-pw042f0m); Lukas suggested a pci_dev_disallow_binding() helper for
PCI_DEV_ALLOW_BINDING instead (ablSO1rA8D2blipG@wunner.de). Related to N23.
Outcome: addressed for sysfs "remove" of the PF itself by Block/Nechita v15 2/5 (W2, in flight);
removing an upstream bridge still unbinds the PF with pci_rescan_remove_lock held.

**E21. 2026-04-21, Keith Busch, "[PATCH] pci: don't fallback to bus reset after failed slot reset"**
https://lore.kernel.org/r/20260421150644.3543733-1-kbusch@meta.com
Keith posted the crash that motivated it: GPF at 0xdead000000000180 (offset 0x80 into a LIST_POISON1
pci_dev pointer) in pci_dev_save_and_disable() <- pci_bus_save_and_disable_locked() <-
pci_reset_bridge() <- reset_subordinate_store() while pciehp removed the card; the fallback "walks the bus' device list
without a lock", and there are "pre-existing locking issues that you can hit from a variety of
directions" (aevqGci1hLqZQdOF@kbusch-mbp). Matches N4. Related to N17 (same entry point, freed bus).
Outcome: merged as cfcbfe5cb116 (v7.1-rc3). It removes the fallback only; the slot-reset walks are
unchanged.

**E22. 2026-07-05, Guangshuo Li, "[PATCH] PCI: Fix AB-BA deadlock between remove and SR-IOV sysfs"**
https://lore.kernel.org/r/20260705152458.291832-1-lgs201920130244@gmail.com
remove_store() unbinds before removal to avoid the E20 cycle. Matches N13.
Outcome: rejected. Niklas Schnelle: "a complete duplicate of Ionut Nechita's patch" from April,
though the fix "remains valid" and his R-b on Ionut's version stands
(21033e817082413fc343ad155a0c8c5458e5e254.camel@linux.ibm.com); Benjamin Block +1'd
(20260706143653.GB17215@p1gen4-pw042f0m). Krzysztof Wilczyński: "This patch is a no-go, of course,
given all the prior work" (20260706155911.GA2885536@rocinante). Sashiko noted it covers neither native
PCIe hotplug nor removal of an upstream bridge (20260705154941.0E24E1F000E9@smtp.kernel.org).

**E23. 2026-07-20, Lukasz Laguna (Intel), "[PATCH] drm/xe/pf: Hold pci_rescan_remove_lock while disabling
VFs"**
https://lore.kernel.org/r/20260720080510.2743242-1-lukasz.laguna@intel.com
PF driver unbind removes VFs without pci_rescan_remove_lock and trips the lockdep_assert_held() added
by 60e7b5aa8571 (v6.18-rc1). Matches N21.
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
After a successful DPC recovery a vfio-pci NVMe stays bound with PCI_COMMAND=0. Related to N12 (device
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

**E28. 2012-12-27, Lin Feng (Fujitsu), "[PATCH] pci-sysfs: replace mutex_lock with mutex_trylock to avoid
potential deadlock situation"**; continued by Gu Zheng (Fujitsu): RESEND 2013-01-18
(50F8DEE9.9060905@cn.fujitsu.com), workqueue version 2013-02-06 (51122D9A.6040002@cn.fujitsu.com),
"[PATCH] pci-sysfs: fix a potential deadlock when concurrent remove&rescan pci device via sysfs"
2013-10-30 (5270DB8B.6070600@cn.fujitsu.com; bugzilla 60672, 60695)
https://lore.kernel.org/r/1356594177-29453-1-git-send-email-linfeng@cn.fujitsu.com
Hung tasks: dev_rescan_store() waits for the rescan/remove mutex with its attribute active; the sysfs
remover (then a deferred callback) holds the mutex and waits in sysfs_deactivate() for the rescan
writer. Matches N19.
Outcome: not merged. Bjorn: "now I'm worried about related locking issues outside sysfs"
(CAErSpo58qUuwd+8bGMWQHQ6KrfQMvHGb+REVkpJqQdrfAQe3Qw@mail.gmail.com); "it's tangled up with the whole
pci_bus and pci_dev reference counting situation"
(CAErSpo5B1eDxwZ+Uu=M5tWaunYEZj_en81RdXj1rdpanYqMcxw@mail.gmail.com); on the last version: "There are
very few uses of restart_syscall()" (20131030171949.GB25745@google.com).

**E29. 2017-09-27, Govindarajulu Varadarajan (Cisco), "[PATCH 3/4] pci aer: fix deadlock in do_recovery"**
https://lore.kernel.org/r/20170927214220.41216-4-gvaradar@cisco.com
4.13: a driver's probe (device_lock held by the driver core) enables SR-IOV and waits for pci_bus_sem
(write) in pci_device_add(); AER do_recovery() holds pci_bus_sem (read) in pci_walk_bus() and waits for
that device_lock in report_error_detected(). "This can also happen when aer error occurs while
pci_dev->sriov_config() is called." Matches N11.
Outcome: not merged; the walk still takes device locks under pci_bus_sem in v7.4-rc1.

**E30. 2018-09-21, Keith Busch (Intel), "[PATCH] PCI: Device removal rescan deadlock"**
https://lore.kernel.org/r/20180921205752.3191-1-keith.busch@intel.com
`echo 1 > <parent>/remove & echo 1 > <child>/rescan &` deadlocks: "the parent can't release the lock
until the child thread releases the device"; "Similar deadlocks are possible in the surprise removal
path due to deadlocked interrupt handlers". Adds pci_lock_rescan_remove_or_die(), which waits until it
gets the lock or the device is no longer added, for the rescan store, sysfs removal and pciehp.
Matches N19 and N10. W3 (2025) uses the same trylock-in-wait_event() approach for pciehp only.
Outcome: not merged.

**E31. 2019-04-01, Theodore Ts'o, "Lockdep warning in pciehp (v5.0-based kernel)"**; Hans de Goede,
"Lockdep warning in PCI-e hotplug code" (2020-08-09, b469d86a-7567-db43-23d1-e499b32cb449@redhat.com)
and "Lockdep warning about ctrl->reset_lock in pciehp_check_presence/pciehp_ist on TB3 dock unplug"
(2021-11-22, de684a28-9038-8fc6-27ca-3f6f2f6400d7@redhat.com)
https://lore.kernel.org/r/20190402021933.GA2966@mit.edu
"possible recursive locking detected" on reset_lock: pciehp_check_presence() while pciehp_ist() holds
reset_lock. The 2021 trace has N18's call chain (pciehp_runtime_resume() -> pciehp_check_presence()
inside pciehp_ist()), but for a nested port's lock, a different instance of the same class. Related to
N18. Lukas: false positive; different locks, "and in addition they're of type rw_semaphore and both the
IRQ thread and the probe routine only acquire the locks for reading, hence wouldn't block each other
even if it was the same lock" (20190402083257.kyqmirq4ovzscxsv@wunner.de;
20211124041317.GA1887@wunner.de). That holds only while no writer is queued.
Outcome: 085a9f43433f (v5.17-rc1; 20211217141709.379663-1-hdegoede@redhat.com) gives reset_lock a lockdep
subclass per hotplug port depth. A recursion on the same instance has no earlier report.

**E32. 2019-06-04, Jay Fang (Huawei), "Bug report: AER driver deadlock"**; patch "[PATCH] PCI/AER: Fix
AER/sysfs sriov_numvfs deadlock in pcie_do_recovery()" 2019-09-06
(1567737238-48866-1-git-send-email-f.fangjian@huawei.com)
https://lore.kernel.org/r/a7dcc378-6101-ac08-ec8e-be7d5c183b49@huawei.com
5.1-rc1, hung tasks: sriov_numvfs_store() holds the PF's device_lock and waits for pci_bus_sem (write)
in pci_device_add(); pcie_do_recovery() holds pci_bus_sem (read) in pci_walk_bus() and waits for the
device_lock in report_resume(). Matches N11.
Outcome: not merged. Sinan Kaya suggested trylock loops
(CAK9iUCPREGruU7zGqnkS9w_x8Q7iE8twveEp2dn8ArupTTQyHA@mail.gmail.com); Benjamin Herrenschmidt: "I think
the issue here is that sriov shouldn't device_lock before doing something that can take the
pci_bus_sem." (a1c90cfb9ce4062b4823c6647d7709baf1c5534f.camel@kernel.crashing.org).
On the patch, Bjorn asked how often it happens (20191114223951.GA2419@google.com); the author: "Although
not very frequent, the impact is fatal" (bdfaaa34-3d3d-ad9a-4e24-4be97e85d216@huawei.com).

**E33. 2020-02-05, Yicong Yang (HiSilicon), "[PATCH 2/2] PCI/AER: Fix deadlock triggered by AER and sriov
enable routine"**
https://lore.kernel.org/r/1580894289-21498-1-git-send-email-yangyicong@hisilicon.com
Same cycle as E32 (bugzilla 203981); locks the devices with pci_bus_lock() before walking them. Matches
N11.
Outcome: not merged. Bjorn: the device_lock in sriov_numvfs_store() came with 17530e71e016; "I do feel
a little queasy about pci_device_add() and pci_bus_add_device() and pci_bus_sem being held while holding
device_lock. Maybe the device addition should be done by a separate thread or something."
(20200630235853.GA3500801@bjorn-Precision-5520); the author asked how to proceed
(fade5ccd-c80f-9bee-5710-87c855f4a649@hisilicon.com).

**E34. 2022-06-14, Shin'ichiro Kawasaki (WDC), "Re: blktests failures with v5.19-rc1"**
https://lore.kernel.org/r/20220614010907.bvbrgbz7nnvpnw5w@shindev
blktests nvme/032 lockdep report, reduced to writing "rescan" and then "remove" of the same device:
kn->active of "rescan" vs pci_rescan_remove_lock. "It looks for me that the deadlock possibility exists
for real". Keith Busch had proposed marking the attribute __ATTR_IGNORE_LOCKDEP (quoted there). Matches
N19.
Outcome: no fix; dev_attr_dev_rescan has no lockdep annotation in v7.4-rc1 (pci-sysfs.c:512).

**E35. 2025-08-26, Niklas Schnelle (IBM), "PCI/IOV: Add PCI rescan-remove locking when enabling/disabling
SR-IOV"**
https://lore.kernel.org/r/20250826-pci_fix_sriov_disable-v1-1-2d0bc938f2a3@linux.ibm.com
s390: platform hot-unplug events for VFs race with sriov_del_vfs(), which removes the VFs without
pci_rescan_remove_lock: double removal and list corruption (klist_put in device_del()). Matches N21.
Outcome: merged as 05703271c3cd (v6.18-rc1); reverted by 2fa119c0e5e5 (v7.0-rc1) because removing a PF
already holds the lock, so sriov_disable() deadlocked on it (revert series
20251216-revert_sriov_lock-v3-0-dac4925a7621@linux.ibm.com, which also added a5338e365c45; see N13).

**E36. 2026-02-23, Dragos Tatulea (NVIDIA), "Re: [PATCH v3 0/2] PCI/IOV: Fix deadlock when removing PF
with enabled SR-IOV"**
https://lore.kernel.org/r/0cd079ce-b658-4058-9d75-0e79987611de@nvidia.com
After the revert in E35, "WARNING: drivers/pci/remove.c:130 at pci_stop_and_remove_bus_device" on
mlx5_core module removal with VFs enabled, "in many internal tests". Matches N21.
Outcome: the reporter found Nechita's v2 (20260219212648.82606-2-ionut.nechita@windriver.com) fixes it
for them (a02222aa-64a2-43b9-86f3-a31b4668206c@nvidia.com); that series is W2, in flight.

Checked and not matching: Roman Lozko, "Deadlock in pciehp on dock disconnect" (2024-04-05; igc LED /
rtnl recursion, fixed by c04d1b9ecce5, v6.9-rc6); Kangfenglong, DPC NULL dereference on 5.10
(2026-01-14; already fixed by 11a1f4bc4736); Vidya Sagar's 2023 EDR/pciehp race (presence-detect
quirk); Hamza Mahfooz, reset_root_port() for root-bus devices (2026-10-16; does not take
pci_rescan_remove_lock); Marek Vasut, "[PATCH] [RFC] PCI: sysfs: Ignore lockdep for remove attribute"
(2019-05-27, 20190526225151.3865-1-marek.vasut@gmail.com; recursive kn->active report inside
remove_store(), a false positive; "remove" is DEVICE_ATTR_IGNORE_LOCKDEP in v7.4-rc1).

---

## 3. Issues (N1-N24)

N1-N10 and N15-N24 were found while testing; N11-N14 were found by review or are known from earlier
reports. All of them are present in v7.4-rc1. Earlier versions of this catalog called N11-N14 R1-R5
(R1 = N11, R2 = N12, R3 and R5 = N13, R4 = N14).

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
- Lab: `hotadd-lockdep` (exact mainline, one hot-add, removal and re-add): lockdep report on mainline.
  `nested-lockdep` (rescan of a switch with hotplug Downstream Ports, then hot-plug below one of them)
  reports the reverse edge, pci_rescan_remove_lock after reset_lock of a nested port.
- Earlier reports: E6, E13 (judged false positives because pciehp_ist() is single-threaded), E17.
  W1 also removes the re-acquisition.

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
  reset_lock was not raised in the v7-v9 threads; the only locking remark, from a v7 reviewer who also
  asked whether the pci_ers_result_t return value should be checked, was that the function must not be
  called from interrupt context because of pci_lock_rescan_remove() and pci_slot_mutex
  (2eb738fb-9dfe-1e88-6ea7-afdba9cb3d25@rock-chips.com).
- Impact: deadlock of link-down recovery and pciehp on a Root Port with native hotplug;
  pci_rescan_remove_lock and pci_slot_mutex stay held.
- Lab: `host-reset-deadlock` (hooks: a task takes pci_rescan_remove_lock and resets the Root Port's
  slot through pci_bus_error_reset() while pciehp hot-adds a NIC): hangs on mainline. The removal
  variant has the same pciehp-side edge as P0.
- Earlier reports: E24/W1 (Qiang Yu, qcom_pcie_global_irq_thread as the caller). In flight: W7
  (rcar-gen4) adds a pci_host_handle_link_down() caller; W8 (rzg3s) adds one on controllers that
  cannot use pciehp. The same holder deadlocks with SR-IOV configuration (N20).

### N3. pciehp_ignore_link_change() calls pci_get_slot() (pci_bus_sem) with reset_lock held
- Mechanism: down_read_nested(reset_lock) (pciehp_hpc.c:617) -> pciehp_device_replaced() ->
  pci_get_slot() (:575) -> down_read(pci_bus_sem). Possible cycle: an AER/DPC walk holds pci_bus_sem
  (read) and waits for a device_lock in the slot; the holder of that device_lock (e.g. vfio-pci
  release-time reset) waits for reset_lock (write); pciehp holds reset_lock (read) and its
  down_read(pci_bus_sem) queues behind a pci_bus_sem writer (pci_device_add(), pci_destroy_dev())
  that queued behind the walk.
- Variant (review, not reproduced): enumeration also takes pci_bus_sem under reset_lock (pci_get_slot()
  at pciehp_pci.c:41, pci_device_add(), pci_hp_add_bridge(), pcie_bus_configure_settings()). pciehp
  scanning a hot-added device waits for pci_bus_sem behind an AER/DPC walk, the walk waits for the
  hotplug port's device lock, and a slot reset that locked the port waits for reset_lock.
- Introduced by: c3be50f7547c "PCI: pciehp: Ignore Presence Detect Changed caused by DPC" (v6.16-rc1;
  cover.1744298239.git.lukas@wunner.de). a97396c6eb13 (v5.14-rc1) only read Link Status under
  reset_lock.
- Impact: 4-task deadlock after an ignored DPC- or SBR-induced link change: pciehp, the resetter, the
  recovery and the pci_bus_sem writer hang for good. It needs the walk to wait for a device lock in the
  slot while a writer queues. Lockdep does not validate device locks; only the hung-task detector
  reports it.
- Lab: `spurious-link-lookup-deadlock` (hooks: a slot reset of a switch Downstream Port; the
  error-recovery walk of the Root Port above (pcie_do_recovery()) parked on a vfio-pci function whose
  release is pending; a sysfs "remove" below another Root Port queued as the pci_bus_sem writer; a
  TEST ONLY hook delivers the Data Link Layer State Changed event that a real port reports after the
  slot reset, as QEMU's ports never report link changes; then a sysfs reset of the slot's NIC, which
  holds its device locks; no delay knobs): hangs on v7.4-rc1 with pciehp holding reset_lock in
  pci_get_slot() and the resetter waiting for it. In development, 18 of 18 runs of three variants hung
  in this cycle: sysfs resets, vfio-pci's open- and release-time resets of the NIC, and the event raised
  while the first reset waits for the link, as on hardware. Found by review.
- Earlier reports: none. Same queued-writer pattern as N11 and the deadlock in W6's cover letter.

### N4. Slot/bus resets walk bus->devices without protection against concurrent removal
- Mechanism: __pci_bus_lock/unlock/trylock (pci.c:5424-5491) and the slot/bus save-and-disable and
  restore helpers (pci.c:5552-5616) iterate bus->devices without pci_bus_sem and without references;
  so do the checks whether a bus or slot can be reset at all (pci_bus_resettable(), pci.c:5402;
  pci_slot_resettable(), :5512). pci_destroy_dev() unlinks under pci_bus_sem without the device lock and
  drops the last reference (remove.c:47-58). Results: use-after-free, list-poison GPF, or a device lock
  taken by the lock walk and never released by the unlock walk (E25).
- Introduced by: 090a3c5322e9 "PCI: Add pci_reset_slot() and pci_reset_bus()" (v3.12-rc1).
- Impact: memory corruption, oops, or leaked device locks (bind/unbind hang) when a slot/bus reset
  (reset_subordinate, AER, vfio hot reset) races device removal.
- Lab: `reset-removal-uaf` (hooks, KASAN: AER-style resets of two Root Ports in loops while pciehp
  tears down a vfio-pci device below one of them): KASAN reports on mainline, in 6 of 23 runs of 20
  rounds each. Over 48 KASAN runs of four
  variants (resets through reset_subordinate, vfio hot reset and AER-style resets), mainline crashed in
  5 and hung in 12 more. Reports include slab-use-after-free in pci_save_dpc_state() and in __mutex_lock
  (device_lock of a freed device), and a GPF at LIST_POISON in pci_try_reset_slot() and __pci_bus_lock().
- Earlier reports: E21 (real-world GPF, one path removed), E25/W4 (lock leak). Same class, fixed earlier
  for the DPC wait only: 11a1f4bc4736 (v6.11-rc1).

### N5. Slot resets lock devices that are on bus->devices but not yet device_add()ed
- Mechanism: pci_device_add() links the device into bus->devices (probe.c:2765-2767) before
  device_add() (:2776), which takes device_lock in __device_attach() even though binding is not yet
  allowed. pciehp scans with reset_lock held (read). A slot reset that locks the slot in that window
  holds the new device's lock and waits for reset_lock (write) while pciehp waits in device_add().
  Lockdep does not track device locks.
- Introduced by: 5b3f7b7d062b (v4.19-rc1; reset_lock held across enumeration).
- Impact: deadlock of pciehp and the resetting task (reset_subordinate, AER).
- Lab: `reset-adding-device` (delay of 3 s between list_add_tail() and device_add()): hangs on
  mainline. The unmodified window is narrow.
- Earlier reports: none found.

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
  freed by unbind_store, on mainline. `reset-pciehp-unbind` (hooks: an AER-style reset of the port while
  pcieport unbinds from it) hangs on mainline on N8.
- Earlier reports: E2 (Lukas 2020: "We've never done this correctly."), E3 (Lukas on slot->hotplug
  safety).

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
  unbound with BAR0 lost on mainline. `reset-after-scan` (delay of 3 s after the scan, then
  reset_subordinate): the NIC's driver fails to probe in some runs on mainline (6 of 12;
  timing-dependent). On mainline, the variant where the slot was empty when locked through
  pci_reset_bridge() hangs on N8 first (`reset-during-bind`).
- Earlier reports: none found. W4's stated limitation ("a device added after the snapshot may be reset
  without its device lock held") is a related window in pci_bus_reset().

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
  in QEMU, resetting 8 Root Ports at once takes 1.13 s; on hardware (24 PEX890xx Downstream Ports,
  v7.1-based kernel), 27.7 s.
- Lab (exact mainline): `reset-storm` (reset_subordinate in a loop while NICs are hot-added on eight
  Root Ports) and `reset-during-bind` (reset_subordinate of an empty slot during hot-add) hang;
  `slot-mutex-lockdep` reports the cycle. With hooks, `aer-hotadd-race` hangs on mainline on this issue
  before it can show N12, and `reset-pciehp-unbind` (the device-lock variant) before it can show N6.
- Earlier reports: E3 2/2 (Ian May, 2020; trace with his 1/2 applied), E11 (Ilkka Koskinen, 2024, no
  reply), E24/W1 (Qiang Yu, 2026; W1 removes the reset_lock half only).

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
  mainline.
- Earlier reports: E9 (Keith Busch, 2024; driver-core fix rejected), E10 8/8 (pins the device; not
  merged).

### N10. Nested hotplug ports: removal waits in free_irq() for an IRQ thread that waits for pci_rescan_remove_lock
- Mechanism: the remover holds pci_rescan_remove_lock and unbinds the child port: pci_stop_dev() ->
  pciehp_remove() -> pcie_shutdown_notification() -> free_irq(), which waits for the child's IRQ
  thread, blocked in pciehp_unconfigure_device() -> pci_lock_rescan_remove() (pciehp_pci.c:107).
- Variants (same edge, the IRQ thread waits for the lock while its port's unbinding waits for the
  thread):
  - Bring-up: the child's IRQ thread waits for the lock in pciehp_configure_device() (pciehp_pci.c:39)
    to enumerate a card hot-added while removal of its port begins.
  - Port-driver unbind: a sysfs unbind of the child port's pcieport driver takes the port's device lock
    and waits in free_irq() for the IRQ thread; the lock's holder waits for the port's device lock,
    e.g. a remover of the parent unbinding the port (sysfs "remove" of the switch).
  - Resetting holder: the lock's holder resets the bus above the port, as pci_host_reset_root_port()
    does (pci-host-common.c:332-333), and waits for the port's device lock, held by the unbind.
- Introduced by: long-standing; pciehp takes pci_rescan_remove_lock since c4ec84c7db0e (v3.14-rc1).
- Impact: permanent hang when a slot below a switch and the switch (or its parent slot) are removed
  together; pci_rescan_remove_lock stays held.
- Lab: `nested-removal` (exact mainline: remove a NIC below a switch Downstream Port and the switch at
  nearly the same time) hangs in some runs on mainline (free_irq() in the stacks; 6 of 13 runs on
  v7.4-rc1). Variants, all with hooks that order the tasks: `nested-bringup-deadlock` (a hook holds the
  lock, the remover of the switch's Upstream Port queues on it, a NIC is hot-added on an empty
  Downstream Port), 12 of 12 runs hung on v7.4-rc1; `port-unbind-deadlock` (sysfs unbind of an empty
  Downstream Port's pcieport driver while its IRQ thread waits for the lock to enumerate a hot-added
  card, and a hook that removes the switch with the lock held, as acpiphp and host bridge removal do,
  waits for the port), 12 of 12 hung; `port-unbind-host-reset` (the same with an emulated
  pci_host_reset_root_port() as the lock holder, whose bus reset waits for the port, and a slot
  power-off as the IRQ thread's event), 6 of 6 hung.
- Earlier reports: E0 (Xiongfeng Wang 2018/2019, sysfs remover), E1 (2018), E8 (2024), E12, E15
  (real-world, triggers avoided by e3260237aaad), E10 (per-bus lock alternative), E30 (Keith Busch
  2018), W3 (Keith Busch RESEND, 2025).

### N11. Error-recovery walks and the post-reset wait take pci_bus_sem against device locks
- Mechanism: pcie_do_recovery() walks the affected buses under pci_bus_sem (read; pci_walk_bridge() ->
  pci_walk_bus(), bus.c:463) and takes each device's lock in the report_*() callbacks (pcie/err.c:57,
  135, 154, 173). A task that holds one of those device locks and then waits for pci_bus_sem (write:
  pci_device_add(), probe.c:2765; pci_destroy_dev(), remove.c:49) deadlocks with the walk; once a writer
  is queued, new readers wait as well. Cases:
  - Two-party: sriov_numvfs_store() holds the PF's device lock (iov.c:452) while ->sriov_configure()
    adds VFs (pci_iov_add_virtfn() -> pci_device_add()). The same with a PF driver that enables SR-IOV
    in ->probe() (device lock held by the driver core).
  - Three-party: a sysfs unbind of a hotplug port's pcieport driver holds the port's device lock and
    waits in free_irq() for the port's pciehp IRQ thread, which is removing a device below and waits
    for pci_bus_sem (write) in pci_destroy_dev(); the walk holds pci_bus_sem and waits for the port's
    device lock.
  - Reset wait (review): pci_bridge_secondary_bus_reset() -> pci_bridge_wait_for_secondary_bus() ->
    down_read(pci_bus_sem) (pci.c:4817), called with the slot/bus device locks held (and reset_lock for
    writing from pciehp_reset_slot()). An AER walk holds pci_bus_sem (read) and waits for one of those
    device locks; once a writer queues on pci_bus_sem, the reset's down_read blocks.
- Introduced by: the walk has locked each device under pci_bus_sem since before v3.7 (90b5c1d7c45e moved
  the lock into the callbacks). The sriov_numvfs_store() case since 17530e71e016 "PCI: Protect
  pci_driver->sriov_configure() usage with device_lock()" (v4.13-rc1). The reset-wait case since
  ac91e6980563 (v6.3-rc1), which routed the SBR wait through pci_bridge_wait_for_secondary_bus(), which
  takes pci_bus_sem since ad9001f2f411 (v5.5-rc1).
- Impact: permanent hang of AER/DPC recovery and of SR-IOV configuration, enumeration or removal below
  the port.
- Lab: `sriov-recovery-walk-deadlock` (hooks: an igb PF present at boot below a Root Port without a
  hotplug slot, so that the recovery resets the bus and N8 can't interfere; pcie_do_recovery() of
  that Root Port in a loop, one recovery at a time, while sriov_numvfs is written 2 and 0 in a loop):
  hangs on v7.4-rc1 in this cycle (6 of 6 runs in development). With the PF below a hotplug Root
  Port, most v7.4-rc1 runs hang on N8 first (5 of 6 in one development set: pci_slot_mutex in
  pci_dev_assign_slot() during the VF add). `recovery-walk-deadlock` (hooks: the three-party case: a hook
  holds pci_rescan_remove_lock for 6 s while a Downstream Port's slot is powered off, its pcieport
  driver is unbound through sysfs and the Root Port above is recovered with pcie_do_recovery()): hangs
  on v7.4-rc1 (8 of 8 runs). The reset-wait case: found by review, not reproduced.
- Earlier reports: E29 (2017, probe-time SR-IOV), E32 (Jay Fang 2019, sriov_numvfs_store()), E33
  (Yicong Yang 2020), E16 (2025, deferred probe); none merged. W6's cover letter describes four tasks
  with vfio memory_lock and a queued pci_bus_sem writer, found by AI review in the RFC's new recovery
  code, not in mainline. 98693e0897f7 (v6.19-rc1) fixed a different cycle (a lockdep report)
  involving pci_bus_sem.

### N12. AER/DPC recovery racing a hot-add resets the new device after its driver bound, without telling it
- Mechanism: pcie_do_recovery() notifies only drivers bound when its error_detected walk ran
  (pcie/err.c:238-242), then resets via pci_bus_error_reset() -> pci_reset_bridge(...,
  PCI_RESET_NO_RESTORE) without save/restore. A device hot-added and bound in between loses its BARs
  and Command register and gets no callbacks. With CONFIG_PCIEAER=n, pci_host_reset_root_port()
  resets with no recovery callbacks at all; any error reset of a bus that pciehp populates meanwhile
  hits devices the same way.
- Symptom variant: each recovery walk rereads the bus (pcie/err.c:240-268), so a device added between
  the walks gets ->resume() without ->error_detected(); e1000e then warns in __pci_enable_msix_range()
  (drivers/pci/msi/msi.c:816) from e1000_io_resume(). Without a window between the walk and the
  reset, the QEMU runs of this race hang on N8 first on v7.4-rc1.
- Introduced by: long-standing design; c4eed62a2143 (v4.20-rc1) made the AER reset a slot reset.
- Impact: a bound device silently loses its configuration.
- Lab: `recovery-hotadd-msix` (hooks: pcie_do_recovery() of an empty Root Port sleeps 5 s between its
  error_detected walk and the reset, holding no lock, while pciehp hot-adds and binds a NIC): e1000e's
  MSI-X warning on v7.4-rc1. `aer-hotadd-race` (hooks: the same recovery without the window; the check
  flags a NIC bound with BAR0=0 or decode off): on v7.4-rc1 it hangs on N8 before it can show N12.
- Earlier reports: none of this exact race. Related: E26 (vfio-pci not restored after recovery);
  on v8 of 4c99bace4f4e, the sashiko review asked about the CONFIG_PCIEAER=n reset without driver
  notification and the author, Manivannan Sadhasivam, replied "That's a design limitation."
  (mcdce4u2alwsobdsapnnwjwxofhwrd6gypdu45m3i5wzswhp65@lhrv5tvsvjs7).

### N13. sriov_numvfs_store() vs removal of the PF: device_lock vs pci_rescan_remove_lock
- Mechanism: sriov_numvfs_store() takes device_lock(PF) (iov.c:452), then pci_lock_rescan_remove()
  around ->sriov_configure() (iov.c:473, 487). A remover holding pci_rescan_remove_lock waits for
  device_lock(PF) when it unbinds the PF: pciehp_unconfigure_device(), or remove_store() ->
  pci_stop_and_remove_bus_device_locked() for sysfs "remove" of the PF or of an upstream bridge (E20).
  The unbind_store() variant described in W2 2/5 (unbind -> .remove() -> pci_disable_sriov() ->
  sriov_del_vfs() -> pci_lock_rescan_remove()) only exists once W2 1/5 makes sriov_del_vfs() take the
  lock; mainline sriov_del_vfs() (iov.c:739-746) does not (N21).
- Introduced by: a5338e365c45 "PCI/IOV: Fix race between SR-IOV enable/disable and hotplug" (v7.0-rc1;
  20251216-revert_sriov_lock-v3-0-dac4925a7621@linux.ibm.com). v6.18 and v6.19 had the same order
  through 05703271c3cd, which took the lock in sriov_add_vfs()/sriov_del_vfs() (E35).
- Impact: deadlock of SR-IOV enable/disable with removal of the PF; pci_rescan_remove_lock stays held.
- Lab: `sriov-remove-abba` (hooks only to order the tasks: sysfs "remove" of an igb PF racing
  sriov_numvfs=0): hangs on mainline. `sriov-pciehp-abba` (the same with pciehp removing the PF): hangs
  on v7.4-rc1 (6 of 6 runs).
- Earlier reports: E20 (Roeck, sysfs remover), E22, E23 (related).
- In flight: W2 (Block/Nechita v15) 2/5 fixes sysfs "remove" of the PF itself. By code reading it
  does not fix the pciehp remover or sysfs "remove" of an upstream bridge, which unbinds the PF in
  pci_stop_bus_device() with pci_rescan_remove_lock held (sashiko noted the latter on E22's identical
  change): in v15 sriov_numvfs_store() still holds device_lock(PF) across sriov_del_vfs() ->
  pci_lock_rescan_remove(). Not tested.

### N14. Resetting a dead link can hold device locks and reset_lock for up to 60 s
- Mechanism: after an SBR, pci_bridge_wait_for_secondary_bus() (pci.c:4806-4904) polls the first device
  below the port with pci_dev_wait() (pci.c:1228-1316) for up to PCIE_RESET_READY_POLL_MS (60 s; its
  sleeps add up to 65.5 s) whenever the link reports active. The poll ends early only if the device
  answers or is marked disconnected (pci.c:1266); it does not look at link or presence again. Since
  e8df1d194c39 (v7.3), a ~0 Vendor ID under RRS Software Visibility no longer ends it either. On
  ports faster than 5 GT/s without Data Link Layer Link Active Reporting, pcie_wait_for_link_delay()
  just sleeps and the 60 s poll follows; ports at 5 GT/s or less without it give up after 1 s.
  Throughout, the resetter holds the slot's reset_lock for writing (pciehp_reset_slot(),
  pciehp_hpc.c:939-958) and the device and config access locks of the device and its bridge
  (pci_reset_function(), pci.c:5307-5335; __pci_bus_lock(), :5424-5439); AER/DPC recovery and
  reset_subordinate (pci_reset_bridge(), :5744-5779) also hold the global pci_slot_mutex. A surprise
  removal during the wait does not end it: pciehp_ist() first waits for the reset in
  pci_hp_spurious_link_change() (pciehp_hpc.c:770, pci_hotplug_core.c:552-558), then for reset_lock in
  pciehp_ignore_link_change() (pciehp_hpc.c:617), before pciehp_unconfigure_device() can mark the
  device disconnected.
- Introduced by: 6b2f1351af56 "PCI: Wait for device to become ready after secondary bus reset"
  (v4.17-rc1) and ac91e6980563 (v6.3-rc1).
- Impact: with a device that keeps returning Request Retry Status or stops answering while its link
  stays up, and on >5 GT/s ports without link-active reporting, each reset stalls for over a minute:
  slot teardown, user config reads (lspci) of the port and the device, a vfio-pci user's close or exit
  and, through pci_slot_mutex, every enumeration and rescan in the system. With link-active reporting
  and the link down, each reset gives up after about 1 s.
- Lab: `dead-link-reset-wait` (exact mainline: an e1000e below a QEMU Root Port stops answering config
  requests while presence and link stay up, because the slot's Power Controller is turned off behind
  pciehp's back with the Power Indicator left on; a sysfs reset of the NIC with reset_method=bus; 5 s
  later the indicator is turned off through config mechanism #1, so QEMU detaches the device and
  reports Presence Detect Changed, a surprise removal during the reset): passes if the reset returns
  within 5 s of the removal. On v7.4-rc1 it returns about 64 s after it (69.5 s in total), and config
  reads of the port and the NIC block for 66 s. It is not a race: in development every run gave the
  same numbers to within 0.2 s, for the sysfs reset, vfio-pci's release-time reset (close/exit takes
  72.4 s), reset_subordinate (68.5 s) and a fatal AER error injected by QEMU (68.2-68.4 s). With
  reset_subordinate or AER, a hot-add on another Root Port waits 65 s in pci_dev_assign_slot() holding
  pci_rescan_remove_lock, and a global rescan waits 64 s. Controls: with the link down before the
  reset, it returns after 2.1 s; at 2.5 GT/s, where QEMU omits link-active reporting, it gives up
  after 1.2 s. QEMU has no RRS, so the RRS branch is not exercised.
- Earlier reports: none of this case. Related, for resume: 7b3ba09febf4 (v6.5-rc1; the 1 s limit above)
  and 6613443ffc49 (v6.10-rc1; the disconnected check). Alex suggested testing for disconnected devices
  before reset, possibly in the PCI core (20251223153534.0968cc15.alex@shazbot.org).

### N15. An error reset holds a device that a remover needs (three-party with sriov_numvfs_store())
- Mechanism: pci_bus_error_reset() (aer_root_reset(), pci_host_reset_root_port()) -> pci_reset_bridge()
  (pci.c:5744) -> pci_slot_reset() (:5618) or pci_bus_reset() (:5685) locks every device below the
  port top-down with blocking device_lock() (__pci_bus_lock(), :5424). A remover holding
  pci_rescan_remove_lock (pciehp_unconfigure_device(), pciehp_pci.c:107) takes each device's lock to
  unbind it in pci_stop_dev() -> device_release_driver() (remove.c:27); the device is marked removed
  only later (remove.c:34). sriov_numvfs_store() holds device_lock(PF) (iov.c:452) and waits for
  pci_rescan_remove_lock (iov.c:473, 487). With a switch below a Root Port, pciehp removing endpoint X
  below one Downstream Port and sriov_numvfs written for PF Y below the other, an error reset of the
  Root Port that locks X before pciehp reaches it closes the cycle: pciehp waits for X (reset), the
  reset for Y (sriov_numvfs_store()), sriov_numvfs_store() for pci_rescan_remove_lock (pciehp). On
  v7.4-rc1 the reset also holds pci_slot_mutex. Lockdep does not validate device locks; only the
  hung-task detector reports it.
- Introduced by: the sriov_numvfs_store() order (device_lock(PF), then pci_rescan_remove_lock), from
  05703271c3cd (v6.18-rc1), kept by a5338e365c45 (v7.0-rc1). Resets lock top-down since 090a3c5322e9
  (v3.12-rc1); AER resets slots since c4eed62a2143 (v4.20-rc1).
- Impact: permanent hang of the error recovery, the remover and the sriov_numvfs writer;
  pci_rescan_remove_lock stays held.
- Lab: `reset-holds-removing` (hooks; a QEMU x3130 switch with an e1000e X and an igb PF Y: a hook
  holds pci_rescan_remove_lock for 8 s while pciehp queues on it to remove X after a slot power-off,
  sriov_numvfs is written for Y, and pci_bus_error_reset() of the Root Port locks X first; no delay
  knobs): hangs on v7.4-rc1 in this cycle. In development, 18 of 18 runs of three variants hung in it:
  this one, pciehp delayed after taking the lock, and the reset through pcie_do_recovery().
- Earlier reports: no earlier report found.

### N16. A reset holds a device whose first probe is pending under pci_rescan_remove_lock (with sriov_numvfs_store())
- Mechanism: pci_bus_add_device() calls device_initial_probe() (bus.c:373) and marks the device added
  only afterwards (:375); enumerators (sysfs rescan, pciehp, SR-IOV) hold pci_rescan_remove_lock across
  it. A blocking bus or slot reset (__pci_bus_lock(), pci.c:5424) locks every device on the bus lists
  top-down, including devices whose first probe is still pending, and then waits for device_lock(PF),
  held by sriov_numvfs_store() (iov.c:452), which waits for pci_rescan_remove_lock (iov.c:473/487). The
  enumerator waits for the new device's lock in __device_attach(). With a multi-function device,
  function 1's first probe is pending for as long as function 0 probes. Unlike N5, the device has gone
  through device_add().
- Introduced by: as N15.
- Impact: permanent hang of the reset, the enumerator and the writer; pci_rescan_remove_lock stays held.
- Lab: `reset-holds-probing` (hooks for the reset only, no delays: an e1000e removed through sysfs and
  re-added by a global rescan below one switch Downstream Port, sriov_numvfs written for an igb PF
  below the other right behind the rescan, and 10 ms after the rescan starts pci_bus_error_reset() of
  the Root Port above, which has no hotplug slot, so that the reset is a bus reset and N8 can't
  interfere): hangs on v7.4-rc1 in this cycle (7 of 7 runs in development; with the reset 0-30 ms
  after the rescan at random, 4 of 7, all with offsets up to 16 ms). The scenario's `pciehp` variant
  (pciehp sleeps after scanning a hot-added NIC with the lock held, through a TEST ONLY knob) hangs
  every time. With a Root Port that has a hotplug slot, the no-delay runs hang on N8 instead in about a
  third of the runs (6 of 16 with a two-function e1000e; 10 in this cycle).
- Earlier reports: no earlier report found.

### N17. reset_subordinate and pci_reset_bridge() use the secondary bus without a reference
- Mechanism: pci_reset_bridge() reads bus = bridge->subordinate (pci.c:5746) without a reference and
  uses it until the reset is over: bus->slots under pci_slot_mutex (:5753-5770), then
  pci_try_reset_bus(bus) (:5777), whose pci_bus_restore_locked() and pci_bus_unlock() run after the SBR
  (:5724-5725), or pci_bus_reset(bridge->subordinate) (:5778), which rereads the pointer, possibly NULL
  by then (code reading). Callers pin only the bridge: reset_subordinate_store() (pci-sysfs.c:567)
  holds the attribute's kernfs active reference. Removing an ancestor frees the bus in
  pci_remove_bus_device() -> pci_remove_bus() -> device_unregister() (remove.c:107, 73) before it
  clears bridge->subordinate (:108) and deletes the bridge (pci_destroy_dev() -> device_del(), :47),
  which is what would wait for the sysfs writer. Freeing the bus needs no device lock, so the bridge's
  lock, held by the reset, does not help.
- Introduced by: 2fa046449a82 "PCI: Add 'reset_subordinate' to reset hierarchy below bridge"
  (v6.13-rc1) for the sysfs path; 8238cb69c01f (v7.1-rc1) routed it through pci_reset_bridge().
  pci_bus_error_reset() (AER, pci_host_reset_root_port()) uses bridge->subordinate the same way.
- Impact: use-after-free of struct pci_bus; GPF without KASAN.
- Lab: `reset-subordinate-uaf` (exact mainline, KASAN: a loop writing a switch Downstream Port's
  reset_subordinate while the switch's Upstream Port is removed through sysfs): "KASAN:
  slab-use-after-free in pci_bus_restore_locked" <- pci_try_reset_bus <- reset_subordinate_store, freed
  by remove_store -> pci_remove_bus_device, in the first round of every run (18 of 18 runs of three
  variants on v7.4-rc1). With slub_debug=P instead of KASAN: GPF at 0x6b6b6b6b6b6b6beb.
- Earlier reports: no earlier report found. Related: E21 (same entry point, a freed pci_dev; N4).

### N18. Recursive read of reset_lock when pciehp's IRQ thread runtime-resumes its port
- Mechanism: pciehp_ist() takes reset_lock for reading (pciehp_hpc.c:785); at its start it resumes the
  port only from D3cold (pci_config_pm_runtime_get(), pci.c:2944-2945). pciehp_enable_slot() and
  pciehp_disable_slot() then call pm_runtime_get_sync() on the port (pciehp_ctrl.c:346, 382). A port
  runtime-suspended in D3hot (or in D0 without a PM capability) is resumed synchronously in the IRQ
  thread: pciehp_runtime_resume() (pciehp_core.c:336) -> pciehp_resume() -> pciehp_check_presence() ->
  down_read_nested(reset_lock) (:171), a second read of the same rwsem. A slot reset that queues for
  writing between the two reads (pciehp_reset_slot(), pciehp_hpc.c:948) blocks the second read: the
  IRQ thread waits for the reset, the reset for the IRQ thread. The port stays "resuming", so anything
  that resumes or barriers it blocks too (reads of the slot's power attribute in pm_runtime_barrier()).
  Lockdep reports "possible recursive locking detected" even without a writer. The IRQ thread runs
  with the port suspended when pciehp_request() wakes it without resuming the port, as a sysfs slot
  power write does (pciehp_sysfs_enable_slot(), pciehp_ctrl.c:393-407); by code reading, also the
  attention-button work and hotplug interrupts from D3hot without native PME.
- Introduced by: 9c62f0bfb832 "PCI: pciehp: Implement runtime PM callbacks" (v4.20-rc1), whose
  runtime resume checks presence, on top of 5b3f7b7d062b (reset_lock held in pciehp_ist() and taken in
  pciehp_check_presence()) and 835030745424 "PCI: pciehp: Resume to D0 on enable/disable" (both
  v4.19-rc1).
- Impact: the slot and its port hang for good; slot resets and power-state queries of the port block.
- Lab: `pciehp-rpm-recursion` (pcie_port_pm=force, as QEMU's Root Ports lack a PM capability and then
  suspend in D0; slot resets in a loop while a sysfs power write enables or disables the slot of a
  runtime-suspended Root Port): v7.4-rc1 hung in 28 of 33 runs of six variants. Lockdep reports the
  recursion only if it comes before N1's report, which turns lockdep off.
- Earlier reports: E31 (2019-2021: the same lockdep splat for a nested port's lock, judged a false
  positive). A recursion on the same instance: no earlier report found.

### N19. sysfs "rescan" waits for pci_rescan_remove_lock with an active kernfs reference that removal drains
- Mechanism: dev_rescan_store() and bus_rescan_store() (pci-sysfs.c:495-511, 530-549) wait for
  pci_rescan_remove_lock (:506, :541) while kernfs_fop_write_iter() holds the attribute's active
  reference. A task that holds the lock and removes that device or bus (sysfs "remove" of the device
  or an upstream bridge, pciehp removal of a slot above, any remover) calls device_del() or
  device_unregister(), which removes the attribute and waits in kernfs_drain() (fs/kernfs/dir.c:539-540)
  for the active reference. Both tasks hang; every later rescan, removal and hotplug event blocks on the
  lock. Lockdep reports kn->active vs pci_rescan_remove_lock only when the drain actually waits.
  remove_store() avoids this with device_remove_file_self() (pci-sysfs.c:523), s390's "recover"
  attribute with sysfs_break_active_protection() (arch/s390/pci/pci_sysfs.c:87-97).
- Introduced by: long-standing: the rescan attributes have waited for the rescan/remove mutex with the
  attribute active since they were added (738a6396c223, v2.6.30-rc1); since 9d16947b7583 (v3.14-rc1)
  every remover holds the same global lock.
- Impact: permanent hang; pci_rescan_remove_lock stays held.
- Lab: `rescan-remove-deadlock` (exact mainline: a loop writing "rescan" of a NIC below a switch, or of
  the NIC's bus, while the switch's Upstream Port is removed through sysfs): hangs in the first round.
  42 of 42 runs of ten variants hung on v7.4-rc1, including ones with pciehp as the remover and with a
  remover that waits for a vfio-pci user.
- Earlier reports: E28 (Lin Feng, Gu Zheng, 2012-2013), E30 (Keith Busch, 2018), E34 (Shin'ichiro
  Kawasaki, 2022); none merged.

### N20. sriov_numvfs_store() vs pci_host_reset_root_port() (and any resetter holding pci_rescan_remove_lock)
- Mechanism: sriov_numvfs_store() takes device_lock(PF) (iov.c:452), then pci_rescan_remove_lock
  (iov.c:473, 487). pci_host_reset_root_port() takes pci_rescan_remove_lock (pci-host-common.c:332),
  then pci_bus_error_reset() (:333) locks the Root Port and every device below it, the PF included
  (__pci_bus_lock(), pci.c:5424): AB-BA. Reached from pci_host_handle_link_down() through
  pcie_do_recovery() (pcie-qcom.c, pcie-dw-rockchip.c), where no artificial window is needed. Any task
  that locks the PF for a reset with pci_rescan_remove_lock held deadlocks the same way. Unlike N2, no
  hotplug slot is involved. Lockdep does not validate device locks.
- Introduced by: 4c99bace4f4e (v7.3-rc1) for pci_host_reset_root_port(); the sriov_numvfs_store()
  order as in N15.
- Impact: deadlock of link-down recovery with SR-IOV enable or disable below the Root Port;
  pci_rescan_remove_lock stays held.
- Lab: `sriov-host-reset-deadlock` (hooks: pci_host_reset_root_port() run through a debugfs hook, with
  and without pcie_do_recovery(), while sriov_numvfs of an igb PF below the Root Port is written): 30 of
  30 runs of five variants hung on v7.4-rc1, among them reset loops with no added delay.
  `sriov-linkdown-deadlock` (a hook runs the real pci_host_handle_link_down() of the Root Ports; needs
  CONFIG_OF and CONFIG_PCI_HOST_GENERIC): 6 of 6 hung on v7.4-rc1.
- Earlier reports: no earlier report found (see N2 for the review of 4c99bace4f4e). In flight: W7
  (rcar-gen4) and W8 (rzg3s) add pci_host_handle_link_down() callers; N20 needs no pciehp, so it
  applies to both.

### N21. A PF driver's unbind removes its VFs without pci_rescan_remove_lock
- Mechanism: a PF driver's ->remove() disables SR-IOV: pci_disable_sriov() -> sriov_disable() ->
  sriov_del_vfs() (iov.c:739-746) -> pci_iov_remove_virtfn() (:378) -> pci_stop_and_remove_bus_device()
  (:399), without pci_rescan_remove_lock unless the unbind comes from a remover that holds it. sysfs
  unbind and module removal don't. pci_stop_and_remove_bus_device() asserts the lock (remove.c:128).
  Removers that hold the lock are not serialized against such an unbind: pciehp_unconfigure_device()
  walks the bus's device list in reverse with list_for_each_entry_safe_reverse() and a reference on
  the current entry only (pciehp_pci.c:115-117), so a concurrent PF unbind deletes and frees the next
  VF under it. The list itself stays consistent (list_del() runs under pci_bus_sem); the loop's next
  pointer is what breaks: use-after-free, then an Oops in the pciehp IRQ thread, which dies holding
  pci_rescan_remove_lock. On s390 a concurrent platform hot-unplug of the VFs reported list corruption
  (E35).
- Introduced by: long-standing; VF removal never took the lock. 05703271c3cd (v6.18-rc1) added it and
  2fa119c0e5e5 (v7.0-rc1) reverted it, because removing a PF already holds the lock (E35).
  60e7b5aa8571 (v6.18-rc1) added the assertion.
- Impact: lockdep_assert_held WARN on every such unbind with VFs enabled; use-after-free and an Oops,
  with pci_rescan_remove_lock left held, when pciehp removes the slot at the same time; list
  corruption on s390. With lockdep, the assertion only fires while lockdep is still on (on v7.4-rc1
  N1's first-hot-add report turns it off).
- Lab: `pf-unbind-unlocked-vf-removal` (exact mainline: an igb PF present at boot below a hotplug Root
  Port, so that no hot-add runs first and lockdep is still on; two VFs bound to igbvf; then only a
  sysfs unbind of igb from the PF): the assertion fires for both VFs on v7.4-rc1 (it needs a lockdep
  kernel). The scenario's `hold` variant crashes deterministically: VF 1 bound to vfio-pci and held,
  the slot powered off so that pciehp stalls in VF 1's removal with its iterator on VF 0, then the PF
  unbind frees VF 0 and the holder is killed: KASAN reports a slab-use-after-free in
  pciehp_unconfigure_device(), non-KASAN kernels Oops in pci_stop_bus_device(). The `race` variant
  (slot power-off and PF unbind started together, seven VFs, no vfio) crashes the same way in the first
  round. In development, 6 of 6 runs of each variant failed on v7.4-rc1, with and without KASAN.
- Earlier reports: E35 (s390, 2025), E36 (mlx5, 2026), E23 (xe, 2026). In flight: W2 1/5 takes the
  lock in sriov_add_vfs()/sriov_del_vfs() through a reentrant pci_lock_rescan_remove().

### N22. Removal holds pci_rescan_remove_lock while vfio-pci waits for user space
- Mechanism: removers hold the global pci_rescan_remove_lock while they unbind drivers:
  pciehp_unconfigure_device() (pciehp_pci.c:107), remove_store() ->
  pci_stop_and_remove_bus_device_locked() (remove.c:136), sriov_numvfs_store() (iov.c:473),
  pci_host_reset_root_port() (pci-host-common.c:332). vfio-pci's ->remove() waits in
  vfio_unregister_group_dev() for user space to close the device (vfio_main.c:447-465), without limit,
  and uninterruptibly after a signal. Meanwhile every enumeration and removal in the system waits for
  the lock: hotplug events of other slots, sysfs rescan and remove, SR-IOV enable and disable. P0 is
  this stall plus a close-time reset that waits for one of the stalled pciehp threads.
- Introduced by: vfio-pci has waited in ->remove() for user space since vfio was added (cba3345cc494,
  v3.6-rc1); removers hold the global pci_rescan_remove_lock across that wait since 9d16947b7583
  (v3.14-rc1).
- Impact: enumeration and removal stall system-wide for as long as a vfio user keeps a device being
  removed open; with P0, forever.
- Lab: `removal-stall` (no hooks: a vfio-pci device is held by a process that ignores release requests
  while its removal starts: slot power-off, sysfs "remove", or sriov_numvfs=0 of a PF whose VF is held;
  a rescan of another, empty Root Port must return within 4 s): the rescan waits for the holder on
  v7.4-rc1 in 30 of 30 runs of five variants.
- Earlier reports: E7 (Jim Harris 2023, the device_lock variant; Jason Gunthorpe: "The mechanism of
  waiting in remove for userspace is inherently flawed"), E18 (Alex's request for comprehensive
  surprise-removal support in vfio-pci). Related: W6 (Alex's SRCU-based disconnect idea).

### N23. A driver can bind to a device whose removal has begun
- Mechanism: removal unbinds a device's driver in pci_stop_dev() (remove.c:27), after stopping the
  devices below it, and deletes the device later in pci_destroy_dev() (device_del(), :47), after the
  whole subtree has been stopped. PCI_DEV_ALLOW_BINDING, which pci_bus_match() checks
  (pci-driver.c:1606), is set when the device is added (bus.c:371) and never cleared. Until device_del(),
  a driver can bind to any device of the subtree, stopped or not yet stopped: sysfs bind and
  drivers_probe, driver registration, deferred probe. When the remover waits for something else, e.g.
  for a vfio-pci user of a sibling (N22), the window has no bound. The new driver probes a device that
  is about to be deleted, possibly with its link already down, and is unbound again by device_del().
- Introduced by: long-standing; the flag (the match_driver field before v6.16-rc1) came with
  58d9a38f6fac (v3.9-rc1) and has never been cleared on removal.
- Impact: drivers probe and set up devices under removal; with surprise removal, probe failures and
  config accesses to absent devices.
- Lab: `bind-during-removal` (no hooks: a switch with a NIC below each Downstream Port; one NIC is
  unbound beforehand, the other bound to vfio-pci and held, so that the removal of the switch (sysfs
  "remove" of its Upstream Port, or power-off of the Root Port's slot) stalls on the holder; meanwhile
  the unbound NIC is bound to e1000e): the bind succeeds on v7.4-rc1 in 12 of 12 runs.
- Earlier reports: in E20's thread, for an unbind before sysfs removal, Benjamin Block noted that a
  driver could rebind in between and Lukas suggested a pci_dev_disallow_binding() helper. The general
  case: no earlier report found.

### N24. device_shutdown() vs AER recovery: shutdown holds a device lock and waits for the AER IRQ thread
- Mechanism: device_shutdown() takes the device locks of a device and its parent
  (drivers/base/core.c:4911-4913) and calls ->shutdown(). For a Root Port, pcie_portdrv_shutdown()
  (pcie/portdrv.c:739) removes the port services (:747). Their free_irq() calls (pcie_pme_remove()
  first, then the AER service's devm-managed IRQ, pcie/aer.c:1823) wait in __synchronize_irq()
  (kernel/irq/manage.c:128) for every threaded handler of the shared vector, aer_isr() included. An AER
  recovery running at that time resets below the Root Port (aer_root_reset() -> pci_bus_error_reset(),
  aer.c:1894 -> pci_reset_bridge() -> pci_slot_reset() or pci_bus_reset()), and __pci_bus_lock() locks
  the bridge first (pci.c:5429): the Root Port, whose lock shutdown holds. One lock and an IRQ wait, not
  AB-BA; lockdep does not see it. The hung-task detector shows the poweroff task in
  __synchronize_irq() and irq/N-aerdrv in __pci_bus_lock().
- Introduced by: a4e772898f8b "PCI: Add missing bridge lock to pci_bus_lock()" (v6.11-rc1) for the
  bus-reset path and 1f5e57c622b4 "PCI: Fix pci_slot_lock () device locking" (v7.0-rc1) for the
  slot-reset path; before them the resets did not lock the bridge. device_shutdown() takes device
  locks since d1c6c030fcec (v3.6-rc1).
- Impact: shutdown or reboot hangs when an uncorrectable error is being recovered at that time.
- Lab: `shutdown-aer-deadlock` (exact mainline: an e1000e below a Root Port at boot; one fatal error
  injected through /dev/aer_inject, which raises the real AER interrupt, checks that recovery works
  and resets the slot; then a background process injects a fatal error every 10 ms and the guest
  powers off): passes if the kernel prints "reboot: Power down". On v7.4-rc1 the poweroff hangs with
  the two hung tasks above. In development, 8 of 8 runs hung with the slot-reset path and 8 of 8 with
  the bus-reset path (the Root Port without a hotplug slot); with an error every 200 ms, 9 of 16. A
  single error is enough but the window is narrow: injected right after the endpoint's shutdown, it
  hung 1 of 32 runs with the slot-reset path and 0 of 32 with the bus-reset path; injected when the
  poweroff starts, 0 of 64. Without errors at poweroff, 0 of 12. The trylock patch posted in E19 fixes
  only the pci_bus_reset() path: with it, the slot-reset path still hung in 8 of 8 runs. No hooks or
  delay knobs.
- Earlier reports: E19 (Ziming Du, 2026, open).

---

## 4. Related in-flight work and RFCs

**W1. Qiang Yu, "[PATCH RFC] PCI: pciehp: Fix AB-BA deadlocks between reset_lock, pci_rescan_remove_lock
and pci_slot_mutex"**, RFC v1, 2026-08-17
https://lore.kernel.org/r/20260817-ab-ba-deadlock-v1-1-e619fd07d1fd@oss.qualcomm.com
Drops reset_lock across pciehp_configure_device() and, in pciehp_unconfigure_device(), from
pci_lock_rescan_remove() on (the surprise-removal pci_walk_bus() still runs under it); moves the
exclusion against SBR to pci_rescan_remove_lock, taken in pci_reset_bridge() and pci_reset_bus();
pci_host_reset_root_port() no longer takes it; adds pci_reset_bus_unlocked() for vmd.
Addresses N1, N2, the reset_lock half of N8, and P0's function-reset path. pci_reset_bridge() still holds
pci_slot_mutex across slot resets (device-lock half of N8 remains). Taking pci_rescan_remove_lock in
pci_reset_bus() can bring P0 back as a two-party deadlock through vfio_pci_dev_set_try_reset() and the
hot-reset ioctl (analysis). Sashiko reported a self-deadlock when pci_reset_bus() runs under
pci_rescan_remove_lock and an AB-BA with vfio dev_set->lock (20260818065238.7739B1F000E9@smtp.kernel.org).
Status: no human response, no v2.

**W2. Benjamin Block / Ionut Nechita, "[PATCH v15 0/5] PCI/IOV: Fix SR-IOV locking races and AB-BA
deadlocks"**, v15 2026-09-24 (5/5 resent as v16 2026-10-02,
4c7d6e0ca4772a80059e9feb8e4b113154f420c3.1790945242.git.bblock@linux.ibm.com)
https://lore.kernel.org/r/cover.1790267348.git.bblock@linux.ibm.com
1/5 makes pci_lock_rescan_remove() reentrant (owner + depth; the unlock WARNs and returns if the caller
is not the owner) and takes it in sriov_add_vfs()/sriov_del_vfs() instead of sriov_numvfs_store();
2/5 unbinds the device before removal in remove_store(); 3-4/5 export a declaration and a guard; 5/5
s390. Earlier: Nechita's 2026-02-09 patch (20260209075706.16367-2-ionut.nechita@windriver.com),
Nechita v1-v14 (from 2026-02-14 per the v15 cover) and Block's s390 series v1-v4.
Addresses N13 for sysfs "remove" of the PF itself, and N21 (E23's assert). Not the pciehp remover of
N13 or sysfs "remove" of an upstream bridge (code reading). 2/5 uses dev after
device_remove_file_self() without a reference, so N9 applies to it.
Status: no maintainer feedback; Block pinged on 2026-11-04 (20261104111631.GA19494@p14sgen6-pf6akexs):
"it's basically been stalled for over half a year now".

**W3. Keith Busch, "[PATCH RESEND 1/1] PCI: pciehp: fix concurrent sub-tree removal deadlock"**,
2025-10-16 (v1/v2 2024-06, E8)
https://lore.kernel.org/r/20251016193049.881212-2-kbusch@meta.com
pciehp waits for pci_rescan_remove_lock with a trylock in wait_event() until it gets the lock or its
port is disconnected. Addresses N10 for surprise removal of the parent by pciehp only, not safe removal
or other removers.
Status: no maintainer response; kernel test robot build errors on arm and arc allnoconfig
(202510171720.AKF8sDMd-lkp@intel.com, 202510171744.AnmSOlry-lkp@intel.com): the RESEND drops v2's
!CONFIG_PCI stub of pci_notify_disconnected().

**W4. Zhang Hongtao, "PCI: Prevent device lock leak during bus reset"** (RFC), 2026-08-21
https://lore.kernel.org/r/20260821021626.1874602-1-zhanghongtao35@huawei.com
Snapshot of the devices under pci_bus_sem with references, used for both locking and unlocking in
pci_bus_reset(). Addresses N4 (lock leak, use-after-free) for that path. The author notes devices
added after the snapshot are reset without their lock (N7 window) and that the slot and try-reset
paths are unpatched.
Status: no maintainer response; author pinged on 2026-09-22 asking whether to extend the snapshot or
exclude topology changes for the whole reset (20260922072319.366662-1-zhanghongtao35@huawei.com).

**W5. Abhin Parekadan Jose, "[PATCH RFC v4 0/5] PCI: pciehp: Report surprise removal during safe
removal"**, 2026-09-27 (builds on Michael S. Tsirkin's "pci,virtio: report surprise removal event" RFC
v5, 2025-07-09, cover.1752094439.git.mst@redhat.com)
https://lore.kernel.org/r/20260927182017.938565-1-abhinjoses@gmail.com
pciehp_isr() schedules work that marks devices disconnected while the IRQ thread is busy with a safe
removal. Related to P0 (pciehp thread stuck in a driver's remove), but vfio-pci does not use the
mechanism. 4/5 relies on pciehp_ist() being the only consumer of PCI_LINK_CHANGED.
Status: RFC; mst review (20261012022556-mutt-send-email-mst@kernel.org); no response from Lukas or
Bjorn to any version (v1 2026-09-05, 20260905183905.997833-1-abhinjoses@gmail.com, to v4).

**W6. Shameer Kolothum, "[RFC PATCH v2 00/16] vfio/pci: Handle PCI error recovery and report state to
userspace"**, 2026-09-29 (v1 2026-09-01)
https://lore.kernel.org/r/20260929173305.204856-1-skolothumtho@nvidia.com
Opt-in host AER/DPC recovery for vfio-pci. The cover letter lists an unsolved four-task deadlock in
the RFC's own recovery path, found by AI review, with a queued pci_bus_sem writer (the N11/N3
pattern). Alex replied that he had considered an SRCU-based disconnect of the device from its
user-facing objects for surprise unplug and forced unbind (20261015135718.43d1d27f@shazbot.org), the
direction E18's review asked for. Related to N12 (vfio side), N11, N22, P0.
Status: RFC; the only human reply to v2 is Alex's (2026-10-15).

**W7. Koichiro Den, "[PATCH v5 00/17] PCI: rcar-gen4: Recover from link down and route Root Port
interrupts"**, v5 2026-10-20
https://lore.kernel.org/r/20261020031049.969895-1-den@valinux.co.jp
12/17 calls pci_host_handle_link_down() (or reset_root_port() under pci_lock_rescan_remove() when the
port is absent). Extends N2's and N20's exposure to R-Car Gen4 Root Ports.
Status: in review (12/17 Reviewed-by Marek Vasut).

**W8. Claudiu Beznea, "[PATCH v7 00/14] PCI: rzg3s-host: Add PCIe hotplug support"**, v7 2026-10-19
https://lore.kernel.org/r/20261019065025.2146539-1-claudiu.beznea@kernel.org
14/14 adds bridge->reset_root_port() and a pci_host_handle_link_down() caller. Per 13/14 the
controllers do not expose the Slot Capability registers, "so the generic pciehp driver cannot be used"
(20261019065025.2146539-14-claudiu.beznea@kernel.org); N2's interaction with pciehp does not apply,
N20 does.
Status: in review.

**W9. Lukas Wunner, "[PATCH] PCI: Fix order of device disablement on reset"**, 2026-09-15
https://lore.kernel.org/r/4c908eaab127d82ecfdc1e9948964b2e641d41d8.1789478646.git.lukas@wunner.de
Reorders pci_bus_save_and_disable_locked() and pci_slot_save_and_disable_locked(). Unrelated to these
issues.
Status: respin announced (aqvfUldY5mGMMYrG@wunner.de).

**W10. Alex Williamson, "[RFC PATCH 0/5] PCI/vfio-pci: Guard resets against active SR-IOV VFs"**,
2026-08-11
https://lore.kernel.org/r/20260812045325.2733631-1-alex.williamson@nvidia.com
2/5 adds a callback to pci_reset_bus() evaluated after the hierarchy is locked. Unrelated to these
issues.
Status: RFC, discussion through 2026-09-22.

**W11. Keith Busch, "[PATCH] vfio/pci: Restore standard PCI config space in .slot_reset()"**, 2026-08-17
https://lore.kernel.org/r/20260817195110.2077698-1-kbusch@meta.com
Discussion starter on AER/DPC recovery for vfio-pci; Lukas mentioned pending patches to invoke
->reset_slot() on fatal errors and to recover unbound devices (aoSCK2Sy0HeyX_la@wunner.de). Related to
N12.
Status: not a formal proposal (author's words); superseded in practice by W6.

**W12. Priyank Rathod, "[PATCH] PCI: pciehp: Fix NULL pointer dereference in
pciehp_configure_device()"**, 2026-10-12
https://lore.kernel.org/r/20261012-pcie-hotplug-nullref-v1-1-6e21c2e89ea4@google.com
NULL check for the DSN read after re-acquiring reset_lock (a bug of its own, not N1).
Status: posted; sashiko comment only.

Maintainer positions from earlier threads:
- A slot reset must not wait for the pciehp IRQ thread while holding reset_lock (Lukas on Keith's
  "pciehp: sync interrupts for bus resets", aLRRh_4YhAZjWeEW@wunner.de) or device locks, which
  pciehp_reset_slot() callers hold (Lukas on Ilpo Järvinen's 2025-03 series,
  Z9Wjk2GzrSURZoTG@wunner.de).
- reset_lock must keep excluding slot resets from the link check through enumeration (E13; E5's
  changelog instead calls protecting enumeration the PCI core's job).
- Without pci_slot_mutex in pci_reset_bridge(), slot->hotplug needs another lifetime guarantee (E3).
- Self-removing sysfs attributes must handle their own lifetime (E9).
- vfio-pci: the bridge lock in vfio_pci_core_disable() cannot block (E27); surprise removal should be
  handled comprehensively, not only at release (E18).
- pci_rescan_remove_lock is too coarse; unbinding before removal is "a bandaid" (E20, Lukas 2026), and
  "the real fix is to unbind devices without holding the lock" (E0, Lukas 2019).

---

## 5. Cross-reference

| ID | Summary | Earlier reports (section 2) | In-flight work (section 4) | Lab tests |
|---|---|---|---|---|
| P0 | pciehp holds reset_lock waiting for pci_rescan_remove_lock; vfio close-time reset waits for that reset_lock | E14, E18 (same); E2, E3, E4 (precursors, fixed by f5eff5591b8f); E17 (similar reordering, judged lockdep false positive); E7, E27 (related) | W1 (partial), W5, W6 (related) | vfio-exit-deadlock, vfio-reset-deadlock, sysfs-remove-deadlock, sriov-disable-deadlock |
| N1 | reset_lock re-acquired with pci_rescan_remove_lock held | E6, E13, E17 | W1; W12 (same lines) | hotadd-lockdep, nested-lockdep |
| N2 | pci_host_reset_root_port() holds pci_rescan_remove_lock across slot reset | E24 | W1; W7 (new caller) | host-reset-deadlock |
| N3 | pci_get_slot() under reset_lock in pciehp_ignore_link_change() | none | none | spurious-link-lookup-deadlock |
| N4 | reset walks of bus->devices vs removal (UAF, GPF, leaked lock) | E21, E25 | W4 | reset-removal-uaf |
| N5 | resets lock devices not yet device_add()ed | none | none | reset-adding-device |
| N6 | ->reset_slot() in flight during hotplug driver unbind (UAF) | E2, E3 (maintainer remarks) | none | pciehp-unbind-uaf, reset-pciehp-unbind |
| N7 | queued slot reset hits devices while drivers bind | none (W4 notes the window) | W4 (limitation) | reset-before-bind, reset-after-scan |
| N8 | pci_slot_mutex held across slot resets | E3 (2/2), E11, E24 | W1 (partial) | reset-storm, reset-during-bind, slot-mutex-lockdep, aer-hotadd-race, reset-pciehp-unbind |
| N9 | remove_store() UAF after device_remove_file_self() | E9, E10 (8/8) | W2 2/5 touches the same code | sysfs-remove-uaf |
| N10 | nested ports: free_irq() vs IRQ thread waiting for pci_rescan_remove_lock; bring-up, port-unbind and resetting-holder variants | E0, E1, E8, E10, E12, E15, E30 | W3 | nested-removal, nested-bringup-deadlock, port-unbind-deadlock, port-unbind-host-reset |
| N11 | recovery walks and the post-reset wait take pci_bus_sem against device locks | E16, E29, E32, E33 | W6 (same pattern) | sriov-recovery-walk-deadlock, recovery-walk-deadlock |
| N12 | recovery reset hits a device bound after error_detected | E26 (related) | W6, W11 (related) | recovery-hotadd-msix, aer-hotadd-race |
| N13 | sriov_numvfs_store() vs PF removal (sysfs, pciehp) | E20, E22, E23 (related) | W2 (sysfs remove of the PF only) | sriov-remove-abba, sriov-pciehp-abba |
| N14 | up to 60 s with locks held resetting a dead link | none | none | dead-link-reset-wait |
| N15 | error reset holds a device that a remover needs (with sriov_numvfs_store()) | none | none | reset-holds-removing |
| N16 | reset holds a not-yet-probed device that an enumerator probes (with sriov_numvfs_store()) | none | none | reset-holds-probing |
| N17 | reset_subordinate / pci_reset_bridge() UAF of the secondary bus | none (E21 related) | none | reset-subordinate-uaf |
| N18 | recursive reset_lock read on runtime resume in the pciehp IRQ thread | E31 (same splat, nested ports) | none | pciehp-rpm-recursion |
| N19 | sysfs rescan vs kernfs drain under pci_rescan_remove_lock | E28, E30, E34 | none | rescan-remove-deadlock |
| N20 | sriov_numvfs_store() vs pci_host_reset_root_port() | none | W7, W8 (new callers) | sriov-host-reset-deadlock, sriov-linkdown-deadlock |
| N21 | PF driver unbind removes VFs without pci_rescan_remove_lock | E23, E35, E36 | W2 1/5 | pf-unbind-unlocked-vf-removal |
| N22 | removal holds pci_rescan_remove_lock while vfio-pci waits for user space | E7, E18 (related) | W6 (related) | removal-stall |
| N23 | binding to a device whose removal has begun | E20 (remark) | none | bind-during-removal |
| N24 | device_shutdown() vs AER recovery | E19 | none | shutdown-aer-deadlock |
