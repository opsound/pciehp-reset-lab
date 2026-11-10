# pciehp reset lab

This repository reproduces deadlocks, stalls and use-after-frees between PCIe
native hotplug (pciehp), PCI slot and bus resets, PCI error recovery and PCI
device removal in Linux v7.4-rc1, in QEMU guests, without special hardware.
The first of them hung production hosts whose hot-pluggable devices were bound
to vfio-pci.

[docs/catalog.md](docs/catalog.md) catalogs the issues: the production
deadlock (P0), the issues found while testing or by review (N1-N27), earlier
upstream reports of each (E0-E36), and related in-flight work and RFCs
(W1-W12). Earlier versions called N11-N14 R1-R5.

The lab has two suites, plus checks for posted series:

- **The bug suite** runs every test on v7.4-rc1 and expects the symptom of
  its bug. This is what `./run` does.
- **Fix tracking** runs the same tests, plus regression tests for fix
  attempts, on fix trees and expects every run to be clean. It has its own
  section, [Fix tracking](#fix-tracking), and status file,
  [docs/fix-status.md](docs/fix-status.md).
- **Series checks** test what posted series claim to fix outside the catalog,
  and regressions that posted series introduced. `./run checks` runs them on
  v7.4-rc1, expecting each check's v7.4-rc1 result; on a tree under test they
  have to pass. See [Series checks](#series-checks); the results of posted
  series are in [docs/fix-status.md](docs/fix-status.md#posted-series).

## One-command run

```sh
git clone https://github.com/opsound/pciehp-reset-lab.git
cd pciehp-reset-lab
./run
```

`./run` builds Linux, QEMU, a static busybox, static helper programs and an
initramfs, then runs the bug suite. Build products and serial logs go to
`out/`. Each result line names its serial log under `out/logs/`. The first
build is large (six kernels); later builds are incremental.

A built lab can be copied (`cp -a`) to try changes side by side. The copy's
first build relinks or recreates the worktrees under `out/src` that still
point into the original clone, and configures and builds QEMU and busybox in
its own `out/`, so the original is left alone. Its kernels rebuild, as their
build directories record absolute source paths.

The host needs a C compiler and static libc development files, GNU make,
binutils, flex, bison, bc, OpenSSL and ELF development files, Python 3, Meson,
Ninja, pkg-config, GLib and Pixman development files, curl, `cpio`, gzip, and
access to `/dev/kvm`.

Narrower commands:

```sh
./run build
./run test --dry-run all            # list the bug suite
./run test vfio-exit-deadlock       # one test
./run test N11                      # the tests of one issue
./run test mainline-hooks           # every test that runs on one kernel
./run test --runs 5 nested-removal  # override the number of runs
./run test --all-runs all           # every run, also after the symptom showed
./run test --jobs 8 all             # guests in parallel (default 1; ./run uses 4)
./run checks                        # the series checks on v7.4-rc1
./run checks --tree ~/linux@my-fix aer-unbound   # one check on a local tree
```

## Kernels

| kernel | source |
|---|---|
| `mainline` | v7.4-rc1 (6628e7d4c6b2) |
| `mainline-hooks` | v7.4-rc1 + `patches/test-hooks.patch` (TEST ONLY) |
| `mainline-hooks-hc` | the same, with `configs/hc.config` (`CONFIG_OF`, `CONFIG_PCI_HOST_GENERIC`) |
| `mainline-hooks-jh` | the same, with `configs/jh.config` (`CONFIG_JAILHOUSE_GUEST`) |

`mainline` and `mainline-hooks` also build as `-kasan` with
`configs/kasan.config` (generic inline KASAN, `SLUB_DEBUG_ON`). All use
`configs/linux-x86_64.config`, which has lockdep (`PROVE_LOCKING`),
`DEBUG_ATOMIC_SLEEP`, `DEBUG_LIST`, `PCIEAER_INJECT` and a 20 s hung task
timeout.

Tier 1 tests run on the exact v7.4-rc1 sources. Tier 2 tests need the TEST
ONLY patch, which adds debugfs hooks under `/sys/kernel/debug/pcitest/` that
emulate callers and events QEMU can't produce, such as AER/DPC recovery
resets, `pci_host_reset_root_port()` and the link change a real port reports
after a Secondary Bus Reset, and delays that widen windows in pciehp,
`pci_device_add()` and probe. The hooks are inert until written to.
`link_down` exists only in the `-hc` kernels: it runs the real
pci-host-common link-down recovery, which q35 can't reach otherwise.
`dpc_reset` emulates DPC recovery, as QEMU's Root Ports have no DPC.

"jh" tests run on `mainline-hooks-jh` with Jailhouse's CPUID signature in the
guest (`-cpu host,hv-vendor-id=Jailhouse`), so that
`hypervisor_isolated_pci_functions()` is true and slots without function 0
get scanned, as on s390, LoongArch and Jailhouse. Without that signature the
option is inert.

## Tests

The bug suite (`scripts/run-tests.sh` lists it with the number of runs per
test). "v7.4-rc1" is the symptom the test expects there.

| test | tier | issue | v7.4-rc1 | what it does |
|---|---|---|---|---|
| `vfio-exit-deadlock` | 1 | P0 | hang | two vfio-pci NICs below two Root Ports, held by one process; both are safely removed 2 s apart and the process is killed |
| `vfio-reset-deadlock` | 1 | P0 | hang | same, but the process answers the removal request with VFIO_DEVICE_RESET of the other device |
| `vfio-exit-surprise` | 1 | P0 | hang | `vfio-exit-deadlock` with surprise removal of both NICs (detached through their Root Ports' Slot Control, marked disconnected by pciehp) and their default reset methods |
| `vfio-reset-surprise` | 1 | P0 | hang | `vfio-reset-deadlock` with the same surprise removal |
| `sysfs-remove-deadlock` | 1 | P0 | hang | sysfs "remove" holds pci_rescan_remove_lock while vfio-pci waits for the process; the second slot is removed with the Attention Button |
| `sriov-disable-deadlock` | 1 | P0 | hang | `sriov_numvfs=0` on an igb PF holds pci_rescan_remove_lock while a VF is held through vfio-pci |
| `hotadd-lockdep` | 1 | N1 | lockdep | one hot-add, safe removal and re-add |
| `nested-lockdep` | 1 | N1 | lockdep | sysfs rescan of a switch with hotplug Downstream Ports, then hot-plug below one of them |
| `host-reset-deadlock` | 2 | N2 | hang | emulated `pci_host_reset_root_port()` while pciehp hot-adds a NIC |
| `spurious-link-lookup-deadlock` | 2 | N3 | hang | a recovery walk parked on a vfio-pci function, a queued pci_bus_sem writer, the link change a real port reports after a slot reset (hook), then a slot reset with the device locks held |
| `reset-removal-uaf` | 2, KASAN | N4 | kasan | AER-style resets of two hotplug Root Ports in loops (slot resets) while pciehp tears down a vfio-pci NIC below one |
| `bus-reset-removal-uaf` | 2, KASAN | N4 | lockdep | AER-style resets of a Root Port without a hotplug slot in a loop (`pci_bus_reset()`) while the switch below it is removed through sysfs; the first round leaks a device lock taken in `__pci_bus_lock()` |
| `reset-adding-device` | 2 | N5 | hang | `reset_subordinate` between `list_add_tail()` and `device_add()` of a hot-added NIC |
| `pciehp-unbind-uaf` | 1, KASAN | N6 | kasan | sysfs reset with reset_method=bus while the pciehp service unbinds and rebinds |
| `pciehp-unbind-hot-reset-uaf` | 1, KASAN | N6 | kasan | the same with VFIO_DEVICE_PCI_HOT_RESET of a vfio-pci NIC in a loop: `pci_reset_bus()` -> `pci_try_reset_slot()`, which also uses the `struct pci_slot` |
| `reset-pciehp-unbind` | 2 | N6, N8 | hang | AER-style reset of a Root Port while pcieport unbinds from it |
| `reset-before-bind` | 2 | N7 | fail | `->reset_slot()` while pciehp waits for a contended pci_rescan_remove_lock; the NIC ends up unbound with BAR0 lost |
| `reset-after-scan` | 2 | N7 | fail | `reset_subordinate` right after pciehp scanned a hot-added NIC; its driver fails to probe in some runs |
| `reset-storm` | 1 | N8 | hang | `reset_subordinate` in a loop while NICs are hot-added on eight Root Ports |
| `reset-during-bind` | 1 | N8 | hang | `reset_subordinate` of an empty slot while pciehp checks the link of a hot-added NIC |
| `slot-mutex-lockdep` | 1 | N8 | lockdep | `reset_subordinate` of an empty slot, then a hot-add |
| `aer-hotadd-race` | 2 | N8, N12 | hang | `pcie_do_recovery()` of a Root Port while pciehp hot-adds a NIC; hangs on N8 before it can show N12 |
| `sysfs-remove-uaf` | 1, KASAN | N9 | kasan | sysfs "remove" of a NIC racing slot power-off |
| `nested-removal` | 1 | N10 | hang | removal of a NIC below a switch Downstream Port and of the switch at nearly the same time; hangs in some runs |
| `nested-surprise-removal` | 2 | N10 | hang | a NIC below a switch Downstream Port is surprise-removed, and its pciehp is held between the slot check and pci_rescan_remove_lock (delay knob) while the Root Port's pciehp surprise-removes the switch after a link change (hook) |
| `nested-bringup-deadlock` | 2 | N10 | hang | a NIC hot-added on an empty Downstream Port while the sysfs remover of the switch waits for pci_rescan_remove_lock, held by a hook |
| `port-unbind-deadlock` | 2 | N10 | hang | sysfs unbind of a Downstream Port's pcieport driver while its pciehp waits for pci_rescan_remove_lock, held by a remover of the switch that waits for the port |
| `port-unbind-host-reset` | 2 | N10 | hang | the same with an emulated `pci_host_reset_root_port()` as the lock holder |
| `sriov-recovery-walk-deadlock` | 2 | N11 | hang | `pcie_do_recovery()` of a Root Port in a loop while `sriov_numvfs` of an igb PF below it is written 2 and 0 in a loop |
| `recovery-walk-deadlock` | 2 | N11 | hang | `pcie_do_recovery()` of a Root Port while a Downstream Port's pcieport unbinds and its pciehp waits to remove a NIC |
| `recovery-hotadd-msix` | 2 | N12 | warn | `pcie_do_recovery()` of an empty Root Port pauses between its error_detected walk and the reset while pciehp hot-adds a NIC: e1000e's MSI-X warning |
| `sriov-remove-abba` | 2 | N13 | hang | sysfs "remove" of an igb PF racing `sriov_numvfs=0` |
| `sriov-pciehp-abba` | 2 | N13 | hang | the same with pciehp removing the PF |
| `dead-link-reset-wait` | 1 | N14 | fail | a slot reset of a NIC that stopped answering while its link stays up, surprise-removed 5 s in; the reset must return within 5 s of the removal |
| `reset-holds-removing` | 2 | N15 | hang | `pci_bus_error_reset()` of a Root Port locks a NIC that pciehp is about to remove, then waits for an igb PF that `sriov_numvfs` holds |
| `reset-holds-probing` | 2 | N16 | hang | `pci_bus_error_reset()` of a Root Port locks a NIC whose first probe a rescan is about to run, then waits for an igb PF that `sriov_numvfs` holds; runs that don't hang can show N4's unbalanced unlock of VFs added during the reset |
| `reset-subordinate-uaf` | 1, KASAN | N17 | kasan | `reset_subordinate` of a Downstream Port in loops while the switch is removed through sysfs |
| `pciehp-rpm-recursion` | 2 | N18 | hang | slot resets in a loop while a sysfs power write disables the slot of a runtime-suspended Root Port |
| `rescan-remove-deadlock` | 1 | N19 | hang | a loop writing a NIC's "rescan" attribute while the switch above it is removed through sysfs |
| `sriov-host-reset-deadlock` | 2 | N20 | hang | emulated `pci_host_reset_root_port()` while `sriov_numvfs` of an igb PF below the Root Port is written |
| `sriov-linkdown-deadlock` | 2, hc | N20 | hang | the real pci-host-common link-down recovery in a loop while `sriov_numvfs` is written 2 and 0 in a loop |
| `pf-unbind-unlocked-vf-removal` | 1 | N21 | warn | sysfs unbind of igb from a PF with two VFs: `lockdep_assert_held()` fires for each VF |
| `removal-stall` | 1 | N22 | fail | a rescan of an empty Root Port while pciehp's removal of a vfio-pci NIC waits for its holder; it must return within 4 s |
| `bind-during-removal` | 1 | N23 | fail | e1000e is bound to a NIC below a switch whose sysfs removal waits for a vfio-pci holder; the bind must fail |
| `shutdown-aer-deadlock` | 1 | N24 | hang | fatal AER errors injected every 10 ms through `/dev/aer_inject` into a poweroff |
| `reset-prepare-order` | 1 | N25 | hang | `reset_subordinate` of a Root Port above a switch with a virtio-blk below it, while the disk is read |
| `isolated-fn-aspm-oops` | 2, jh | N26 | oops | a two-function e1000e hot-added while a knob hides function 0 after the link check; ASPM on |
| `isolated-fn-resume-removal` | 2, jh | N27 | fail | function 1 of an e1000e alone at boot, then s2idle (`pm_test=platform`); the slot must survive the resume (uses no hook) |
| `hotadd-fn0-vanish` | 2, jh | N27 | oops | `isolated-fn-aspm-oops` with `pcie_aspm=off`: the DSN read of the missing function 0 |

Expectations: `hang` (no completion, hung tasks, or a stuck operation),
`lockdep` (a lockdep report), `kasan` (a KASAN report), `oops` (another BUG or
oops), `warn` (a WARNING other than lockdep's), `fail` (the scenario's own
check failed, e.g. a hot-added device without its driver or with BAR0
cleared, or an operation that took too long), `clean` (none of these), `pass`
(series checks only: the scenario's check passed with no hang, oops or KASAN
report; lockdep reports and warnings are allowed, as v7.4-rc1 shows N1's on
the first hot-add). A run
whose guest never booted counts as a harness error, never as a symptom. In
the bug suite an entry passes once a run shows its symptom; `--all-runs` makes
it do every run, to measure the rate.

## Results

From a fresh clone, `JOBS=64 TEST_JOBS=8 ./run` (2026-11-06) built everything
and passed all 40 bug suite tests in 20 minutes. A second pass,
`./run test --jobs 8 --all-runs all`, did every run of every test: "hang in
k/n" counts the runs that showed the expected symptom, and "also" lists the
other symptoms these runs showed.

| test | v7.4-rc1 |
|---|---|
| `vfio-exit-deadlock` | hang in 1/1 (also fail, lockdep) |
| `vfio-reset-deadlock` | hang in 1/1 (also fail, lockdep) |
| `sysfs-remove-deadlock` | hang in 1/1 (also fail, lockdep) |
| `sriov-disable-deadlock` | hang in 1/1 (also fail, lockdep) |
| `hotadd-lockdep` | lockdep in 1/1 |
| `nested-lockdep` | lockdep in 1/1 |
| `host-reset-deadlock` | hang in 1/1 (also fail, lockdep) |
| `spurious-link-lookup-deadlock` | hang in 2/2 (also fail) |
| `reset-removal-uaf` | kasan in 4/12 (also fail, lockdep) |
| `reset-adding-device` | hang in 1/1 (also fail, lockdep) |
| `pciehp-unbind-uaf` | kasan in 1/1 (also fail, lockdep) |
| `reset-pciehp-unbind` | hang in 1/1 (also fail) |
| `reset-before-bind` | fail in 1/1 (also lockdep) |
| `reset-after-scan` | fail in 2/4 (also lockdep) |
| `reset-storm` | hang in 1/1 (also fail, lockdep) |
| `reset-during-bind` | hang in 1/1 (also fail, lockdep) |
| `slot-mutex-lockdep` | lockdep in 1/1 |
| `aer-hotadd-race` | hang in 1/1 (also fail, lockdep) |
| `sysfs-remove-uaf` | kasan in 1/1 (also fail, lockdep) |
| `nested-removal` | hang in 1/6 (also fail, lockdep) |
| `nested-bringup-deadlock` | hang in 2/2 (also fail) |
| `port-unbind-deadlock` | hang in 2/2 (also fail) |
| `port-unbind-host-reset` | hang in 2/2 (also fail) |
| `sriov-recovery-walk-deadlock` | hang in 2/2 (also fail) |
| `recovery-walk-deadlock` | hang in 2/2 (also fail) |
| `recovery-hotadd-msix` | warn in 2/2 (also fail, lockdep) |
| `sriov-remove-abba` | hang in 1/1 (also fail, lockdep) |
| `sriov-pciehp-abba` | hang in 2/2 (also fail, lockdep) |
| `dead-link-reset-wait` | fail in 1/1 (also hang, lockdep) |
| `reset-holds-removing` | hang in 2/2 (also fail) |
| `reset-holds-probing` | hang in 2/2 (also fail) |
| `reset-subordinate-uaf` | kasan in 2/2 (also fail) |
| `pciehp-rpm-recursion` | hang in 2/2 (also fail, lockdep) |
| `rescan-remove-deadlock` | hang in 2/2 (also fail, lockdep) |
| `sriov-host-reset-deadlock` | hang in 1/1 (also fail, lockdep) |
| `sriov-linkdown-deadlock` | hang in 2/2 (also fail, lockdep) |
| `pf-unbind-unlocked-vf-removal` | warn in 1/1 (also fail) |
| `removal-stall` | fail in 1/1 (also lockdep) |
| `bind-during-removal` | fail in 1/1 |
| `shutdown-aer-deadlock` | hang in 1/1 (also fail) |

On v7.4-rc1 most tests show their bug in every run. `reset-removal-uaf`,
`nested-removal` and `reset-after-scan` are races without a widened window:
over the three passes run for this table (two from the fresh clone, one in the
development tree), they showed their bug in 6 of 23, 6 of 13 and 6 of 12 runs,
which is why the bug suite now allows them 16, 12 and 8 runs (the table's
`--all-runs` pass had 12, 6 and 4). The lockdep reports in most runs are N1's
report on the first hot-add, which then turns lockdep off for the rest of the
boot.

The tests added on 2026-11-09, and `sriov-disable-deadlock` after its setup
and timing fixes, from a fresh clone that day (`./run test --all-runs --runs 3
TEST`; 4 runs for `pciehp-unbind-hot-reset-uaf`, added later):

| test | v7.4-rc1 |
|---|---|
| `vfio-exit-surprise` | hang in 3/3 (also fail, lockdep) |
| `vfio-reset-surprise` | hang in 3/3 (also fail, lockdep) |
| `sriov-disable-deadlock` | hang in 3/3 (also fail, lockdep) |
| `bus-reset-removal-uaf` | lockdep in 3/3 (also fail) |
| `pciehp-unbind-hot-reset-uaf` | kasan in 4/4 (also fail, lockdep) |
| `nested-surprise-removal` | hang in 3/3 (also fail) |
| `reset-prepare-order` | hang in 3/3 (also fail) |
| `isolated-fn-aspm-oops` | oops in 3/3 (also fail) |
| `isolated-fn-resume-removal` | fail in 3/3 (also lockdep) |
| `hotadd-fn0-vanish` | oops in 3/3 (also fail, lockdep) |

`reset-holds-probing` hung in 6 of 6 runs that day; on a heavily loaded host
some of its runs don't deadlock and show N4's unbalanced unlock instead (3 of
6 in development). The whole bug suite, `./run test --jobs 4 all` from the
same clone, passed 47 of its 48 entries: `sysfs-remove-uaf` missed its race in
its single run, then showed its KASAN report in 8 of 8 reruns, and now gets a
second run.

## Fix tracking

Fix tracking runs every test of the bug suite on each tree of
`configs/fix-trees.conf`, expecting every run to be clean, plus regression
tests that check fix attempts rather than v7.4-rc1 bugs. An entry needs every
run to be clean.

```sh
./run fixes                         # fix tracking on configs/fix-trees.conf
./run fixes --dry-run all           # list the fix tracking matrix
./run fixes --tree ~/linux@my-fix --name my-fix   # fix tracking on a local tree
```

`./run fixes --tree PATH[@REV]` tests a commit of a local Linux tree without
modifying it. Each fix tree is built as `<tree>-hooks`, `<tree>-hooks-kasan`,
`<tree>-hooks-hc` and `<tree>-hooks-jh`: every test runs with the TEST ONLY
patch, so a tree needs a variant of it that applies. The build uses the tree's
patch from `configs/fix-trees.conf`, or for a local tree the first
`patches/test-hooks*.patch` that applies (or `--patch FILE`).

The regression tests:

| test | tier | guards against | what it does |
|---|---|---|---|
| `pciehp-rpm-safe-removal` | 2 | a fix for N18 that re-enumerates a safely removed card on runtime resume | safe removal (sysfs power=0) of a card, present at boot in a slot without a power controller, while its Root Port is runtime-suspended; the slot must stay off |
| `linkdown-hotadd-bars` | 2, hc | a fix for N2 or N20 that lets pciehp bind a device between the recovery's error_detected walk and its reset (N12) | a NIC hot-added while the real link-down recovery of its Root Port runs; it must end up bound with its BARs |
| `pf-probe-sriov-removal` | 2 | a fix that takes pci_rescan_remove_lock while adding VFs and so deadlocks at probe time | a PF driver that enables SR-IOV in `->probe()` (igb max_vfs) is bound while a remover that holds pci_rescan_remove_lock waits for the PF |

It currently tracks a reference fix series, branch
[`pciehp-reset-fixes`](https://github.com/opsound/linux/tree/pciehp-reset-fixes)
of https://github.com/opsound/linux, built with
`patches/test-hooks-pciehp-reset-fixes.patch`. Other trees can be added.

**About the fix series.** It was written and validated with LLM assistance.
Its author doesn't have enough expertise in pciehp, the PCI core reset code and
vfio-pci to take it upstream alone, so it is meant as a reference for
discussion and for whoever fixes these issues, not as a submission. Each
commit message describes its bug, how the commit fixes it, and how it was
tested. It fixes P0, N1, N2, N4-N9, the original N10 deadlock and its
surprise-removal case, and the hot-add half of N27, not N3, the other N10
variants, N11-N26 or the resume half of N27.

`TEST_JOBS=8 ./run fixes` from the same fresh clone: 19 of 43 entries clean.
The series is clean on the tests of P0, N1, N2 and N4-N9, on `nested-removal`
(N10) and on `linkdown-hotadd-bars`. With it, `aer-hotadd-race` shows N12
instead of hanging on N8, `spurious-link-lookup-deadlock` deadlocks through N11
instead of N3, and `pciehp-rpm-safe-removal` and `pf-probe-sriov-removal` show
N18's lockdep report and N21's warning, not regressions. Of the eight tests
added since (run on 2026-11-09), it is clean on `vfio-exit-surprise`,
`vfio-reset-surprise`, `bus-reset-removal-uaf`, `nested-surprise-removal` and
`hotadd-fn0-vanish`, and on `pciehp-unbind-hot-reset-uaf`, added later, so 25
of 52 entries. Results per test and status per issue:
[docs/fix-status.md](docs/fix-status.md).

## Series checks

Tests written while testing posted series: what a series claims to fix,
where that is not a bug of the catalog, and regressions that a series
introduced. They are neither in the bug suite nor in fix tracking.
`./run checks` runs them on v7.4-rc1 and expects the result in the table;
`./run checks --tree PATH[@REV]` (or a tree of `configs/fix-trees.conf`)
builds a tree like fix tracking and expects every run to pass. The results of
the posted series: [docs/fix-status.md](docs/fix-status.md#posted-series).

| test | tier | series | v7.4-rc1 | what it checks |
|---|---|---|---|---|
| `pf-reset-vf-wipe` | 1 | W10 | fail | a sysfs reset of an igb PF with 2 VFs must not wipe the VFs (VF0's Command register), and the PF must still be reset at `sriov_numvfs=0` |
| `pf-reset-vf-wipe-vfio` | 1 | W10 | fail | the same through vfio-pci: open and close, VFIO_DEVICE_RESET and VFIO_DEVICE_PCI_HOT_RESET of the PF |
| `vfio-recovery-restore` | 1 | W11, aer_unbound | fail | a vfio-pci NIC below a Root Port, held open with Bus Master set through vfio, gets a fatal error (`/dev/aer_inject`); it must keep BAR0 and memory decode after "device recovery successful" (E26) |
| `vfio-recovery-restore-switch` | 1 | W11 | fail | the same below a switch, with the error at the switch's Upstream Port |
| `aer-unbound` | 1 | aer_unbound | fail | a hot-added e1000e that was never bound gets two fatal errors, then e1000e is bound: both recoveries must succeed with BAR0 kept, and e1000e must bind |
| `aer-unbound-mf` | 1 | aer_unbound | fail | function 0 of a two-function e1000e unbound, a fatal error at function 1: recovery must succeed and function 0 must rebind |
| `aer-unbound-vfs` | 1 | aer_unbound | fail | an igb PF with 2 unbound VFs gets a fatal error: recovery must succeed, and the VFs must stay and bind afterwards |
| `aer-no-handler` | 1 | aer_unbound | pass | a fatal error below a Root Port with an xhci controller, whose driver has no error handlers: recovery must not be reported successful while the BARs are lost (918b4053184c) |
| `dpcwait-slow` | 2 | DPC timeout | fail | DPC recovery (emulated by a hook; QEMU's ports have no DPC) of a NIC that answers 4.5 s later: it must keep its driver, netdev and BAR0 |
| `dpcwait-dead` | 2 | DPC timeout | pass | the same with a NIC that never answers and is surprise-removed 3 s into the recovery: pciehp must remove it within 5 s |
| `vfio-pm-sriov-race` | 1 | vfio PM vs SR-IOV | warn | 10 rounds: a vfio-pci igb PF put in D3hot through vfio is closed while `sriov_numvfs=1` is written; no WARNING, no device left outside D0, no failed `sriov_numvfs` write |
| `numa-pf-probe-hotadd` | 1 | W2 | pass | a hot-added igb PF that enables VFs in probe (`igb.max_vfs=2`) below a host bridge on a second NUMA node, so that pci_call_probe() probes it from pci_probe_wq: its VFs must appear |
| `numa-pf-probe-rescan` | 1 | W2 | pass | the same through a sysfs rescan |

"W" IDs are those of the catalog's section 4; aer_unbound is Lukas Wunner's
branch from the W11 thread, "DPC timeout" Ziyou Wang's "PCI/DPC: Increase
recovery timeout to 60 seconds" and "vfio PM vs SR-IOV" David Matlack's
"vfio/pci: Fix power state race with SR-IOV enablement".

## How a test runs

`harness/run.py` boots a q35 guest with Root Ports `rp1`..`rpN` and, for the
nested tests, an x3130 switch with two hotplug Downstream Ports below a Root
Port at 00:1e.0, plus the devices a scenario wants present at boot. The
guest's `/init` runs `guest/scn/<scenario>.sh`, which asks the host for
hot-plug actions (`@@ACT add nic2 rp2`, `@@ACT del nic1`, QMP commands) on a
second serial port; the host executes them over QMP. At the end the guest
prints its result and the kernel log on that port and powers off.
`harness/check.py` classifies the run. The static guest helpers are
`tools/vtool.c` (opens vfio-pci devices, holds them and resets them on
request), `tools/wloop.c` (writes a sysfs file in a loop), `tools/cf1.c`
(config access through configuration mechanism #1, past the kernel's config
access lock), `tools/aerinj.c` (injects AER errors through
`/dev/aer_inject`) and `tools/pmrace.c` (closes a vfio-pci PF in D3hot while
another thread enables SR-IOV).

Limits of the setup that tests work around:

- QEMU has no surprise removal. Turning off a Root Port's Power Controller
  and Power Indicator through configuration mechanism #1, behind the
  kernel's back, makes QEMU detach the device, and restoring Slot Control
  then delivers Presence Detect Changed (`deadreset.sh`, `deadlock.sh`'s
  surprise variants). Doing that to the Root Port above a switch crashes
  QEMU 11.1, so `nested-surprise-removal` removes the switch through
  `pcitest/link_change` instead.
- QEMU exposes a hot-added non-zero function only once function 0 is
  there, so the N26 and N27 hot-add tests hide function 0 with a knob.
- aer_inject takes its spinlock_t `inject_lock` under the raw spinlock
  `pci_lock`, which lockdep reports as "BUG: Invalid wait context" on the
  first config access after an injection and then turns itself off. The
  harness lists that report as "ignored" in `result.json` and never counts
  it; tests that inject errors can't show later lockdep reports.
- Timing-dependent tests are noisy on a heavily loaded host; rerun them
  before taking a single result for a change.

A scenario's other variants run directly, e.g. the KASAN use-after-free of
N21:

```sh
harness/run.py out/linux-mainline-kasan/arch/x86/boot/bzImage pfunbind /tmp/n21 --var hold --kasan
```

On mainline, `vfio-exit-deadlock` ends with three tasks blocked for good
(trimmed from `out/logs/mainline/vfio-exit-deadlock/1/serial.log`):

```
INFO: task irq/26-pciehp:90 blocked for more than 20 seconds.
 __mutex_lock+0x8b6/0x10b0
 pciehp_unconfigure_device+0x43/0x120
 pciehp_disable_slot+0x68/0x140
 pciehp_handle_disable_request+0x4a/0x70
 pciehp_ist+0x184/0x340
INFO: task irq/26-pciehp:90 is blocked on a mutex likely owned by task irq/25-pciehp:88.
INFO: task vtool:591 blocked for more than 20 seconds.
 rwsem_down_write_slowpath+0x2f1/0x920
 down_write_nested+0xc6/0xd0
 pciehp_reset_slot+0x37/0x70
 pci_reset_hotplug_slot+0x3e/0x60
 pci_reset_bus_function+0xb2/0x1e0
 __pci_reset_function_locked+0x57/0xa0
 vfio_pci_core_disable+0x4be/0x4e0
 vfio_pci_core_close_device+0x6c/0xb0
 vfio_df_close+0xa3/0x100
 vfio_df_group_close+0x3a/0x70
 vfio_device_fops_release+0x23/0x50
 __fput+0xfd/0x2d0
 filp_close_sync+0x1f/0x30
 put_files_struct.part.0+0x75/0xe0
 do_exit+0x2bd/0xc10
```

irq/25-pciehp, which holds pci_rescan_remove_lock, waits in vfio-pci's
`->remove()` for vtool to close the first device.

## Layout

| path | contents |
|---|---|
| `linux/` | submodule: https://github.com/torvalds/linux at v7.4-rc1 |
| `qemu/` | submodule: QEMU v11.1.0 |
| `configs/` | kernel configs (`hc.config`, `jh.config` and `kasan.config` on top of `linux-x86_64.config`), `versions.env` (pinned commits, busybox version and checksum), `fix-trees.conf` (the trees fix tracking builds) |
| `patches/` | the TEST ONLY hooks patch, for v7.4-rc1 and for the reference fix series |
| `scripts/build.sh` | fetch, build kernels, QEMU, busybox, tools, initramfs |
| `scripts/run-tests.sh` | the tests, both suites and the series checks |
| `harness/` | host side: `run.py` (QEMU and QMP), `qxparse.py` (log parser), `check.py` |
| `guest/` | `/init`, helpers (`lib.sh`) and one script per scenario (`scn/`) |
| `tools/` | static guest helpers |
| `docs/catalog.md` | the issue catalog |
| `docs/fix-status.md` | the reference fix series against the catalog, the fix tracking results, and the results of posted series |

The Linux and QEMU submodules are shallow. The build checks that they are at
the pinned commits, then creates the hooks kernels' sources as generated
worktrees under `out/src/`; fix tracking fetches each fix tree's pinned commit
into the same object store. Busybox is downloaded once and checked against
its SHA-256.
