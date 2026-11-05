# pciehp reset lab

This repository reproduces deadlocks and use-after-frees between PCIe native
hotplug (pciehp), PCI slot and bus resets, and PCI device removal in Linux
v7.4-rc1, in QEMU guests, without special hardware. The first of them hung
production hosts whose hot-pluggable devices were bound to vfio-pci.

It also builds a reference fix series, branch
[`pciehp-reset-fixes`](https://github.com/opsound/linux/tree/pciehp-reset-fixes)
of https://github.com/opsound/linux, and shows that every reproducer below
passes on it, except those for three known issues it doesn't address.

[docs/catalog.md](docs/catalog.md) catalogs the issues: the production
deadlock (P0), the issues found while testing (N1-N10), pre-existing issues
the series doesn't fix (R1-R5), earlier upstream reports of each (E1-E27),
and related in-flight work and RFCs (W1-W12).

**About the fix series.** It was written and validated with LLM assistance.
Its author doesn't have enough expertise in pciehp, the PCI core reset code and
vfio-pci to take it upstream alone, so it is meant as a reference for
discussion and for whoever fixes these issues, not as a submission. Each
commit message describes its bug, how the commit fixes it, and how it was
tested.

## One-command run

```sh
git clone https://github.com/opsound/pciehp-reset-lab.git
cd pciehp-reset-lab
./run
```

`./run` builds Linux, QEMU, a static busybox, a static helper program and an
initramfs, then runs the whole kernel x test matrix. No source patches are
applied during the build: the pinned commits are exactly what gets compiled.
Build products and serial logs go to `out/`. Each result line names its serial
log under `out/logs/`. The first build is large (eight kernels); later builds
are incremental.

The host needs a C compiler and static libc development files, GNU make,
binutils, flex, bison, bc, OpenSSL and ELF development files, Python 3, Meson,
Ninja, pkg-config, GLib and Pixman development files, curl, `cpio`, gzip, and
access to `/dev/kvm`.

Narrower commands:

```sh
./run build
./run test --dry-run all            # list the matrix
./run test vfio-exit-deadlock       # one test on every kernel it is listed for
./run test mainline                 # every test listed for one kernel
./run test fixed:reset-storm        # one entry
./run test --runs 5 nested-removal  # override the number of runs
./run test --jobs 8 all             # guests in parallel (default 1; ./run uses 4)
```

## Kernels

| kernel | source |
|---|---|
| `mainline` | v7.4-rc1 (6628e7d4c6b2) |
| `fixed` | the fix series on v7.4-rc1 |
| `mainline-hooks` | v7.4-rc1 + one TEST ONLY commit |
| `fixed-hooks` | the fix series + the same TEST ONLY commit |

Each also builds as `<kernel>-kasan` with `configs/kasan.config` (generic inline
KASAN, `SLUB_DEBUG_ON`). All use `configs/linux-x86_64.config`, which has
lockdep (`PROVE_LOCKING`), `DEBUG_ATOMIC_SLEEP`, `DEBUG_LIST` and a 20 s hung task
timeout.

Tier 1 tests run on the exact sources. Tier 2 tests need the TEST ONLY commit
(branches `pciehp-reset-test-hooks` and `pciehp-reset-fixes-test-hooks`). It adds
debugfs hooks under `/sys/kernel/debug/pcitest/` that emulate callers QEMU can't
trigger, such as AER/DPC recovery resets and `pci_host_reset_root_port()`, and
delays that widen windows in pciehp and `pci_device_add()`. The hooks are inert
until written to.

## Tests

| test | tier | issue | mainline | fixed | what it does |
|---|---|---|---|---|---|
| `vfio-exit-deadlock` | 1 | P0 | hang | clean | two vfio-pci NICs below two Root Ports, held by one process; both are safely removed 2 s apart and the process is killed |
| `vfio-reset-deadlock` | 1 | P0 | hang | clean | same, but the process answers the removal request with VFIO_DEVICE_RESET of the other device |
| `sysfs-remove-deadlock` | 1 | P0 | hang | clean | sysfs "remove" holds pci_rescan_remove_lock while vfio-pci waits for the process; the second slot is removed with the Attention Button |
| `sriov-disable-deadlock` | 1 | P0 | hang | clean | `sriov_numvfs=0` on an igb PF holds pci_rescan_remove_lock while a VF is held through vfio-pci |
| `hotadd-lockdep` | 1 | N1 | lockdep | clean | one hot-add, safe removal and re-add |
| `nested-lockdep` | 1 | N1 | lockdep | clean | sysfs rescan of a switch with hotplug Downstream Ports, then hot-plug below one of them |
| `reset-storm` | 1 | N8 | hang | clean | `reset_subordinate` in a loop while NICs are hot-added on eight Root Ports |
| `reset-during-bind` | 1 | N8 | hang | clean | `reset_subordinate` of an empty slot while pciehp checks the link of a hot-added NIC |
| `slot-mutex-lockdep` | 1 | N8 | lockdep | clean | `reset_subordinate` of an empty slot, then a hot-add |
| `nested-removal` | 1 | N10 | hang | clean | removal of a NIC below a switch Downstream Port and of the switch at nearly the same time; hangs in some runs |
| `sysfs-remove-uaf` | 1, KASAN | N9 | kasan | clean | sysfs "remove" of a NIC racing slot power-off |
| `pciehp-unbind-uaf` | 1, KASAN | N6 | kasan | clean | sysfs reset with reset_method=bus while the pciehp service unbinds and rebinds |
| `host-reset-deadlock` | 2 | N2 | hang | clean | emulated `pci_host_reset_root_port()` while pciehp hot-adds a NIC |
| `reset-removal-uaf` | 2, KASAN | N4 | kasan | clean | AER-style resets of two Root Ports in loops while pciehp tears down a vfio-pci NIC below one |
| `reset-adding-device` | 2 | N5 | hang | clean | `reset_subordinate` between `list_add_tail()` and `device_add()` of a hot-added NIC |
| `reset-pciehp-unbind` | 2 | N6, N8 | hang | clean | AER-style reset of a Root Port while pcieport unbinds from it |
| `reset-before-bind` | 2 | N7 | fail | clean | `->reset_slot()` while pciehp waits for a contended pci_rescan_remove_lock; the NIC ends up unbound with BAR0 lost |
| `reset-after-scan` | 2 | N7 | fail | clean | `reset_subordinate` right after pciehp scanned a hot-added NIC; its driver fails to probe in some runs |
| `aer-hotadd-race` | 2 | N8; R2 | hang | fail | `pcie_do_recovery()` of a Root Port while pciehp hot-adds a NIC; with the fix series the NIC loses BAR0 (R2, not fixed) |
| `sriov-remove-abba` | 2 | R3 | hang | hang | sysfs "remove" of an igb PF racing `sriov_numvfs=0` (R3, not fixed) |

Expectations: `hang` (no completion, hung tasks, or a stuck operation),
`lockdep` (a lockdep report), `kasan` (a KASAN report), `oops` (another BUG or
oops), `fail` (the scenario's own check failed, e.g. a hot-added device without
its driver or with BAR0 cleared), `clean` (none of these). An entry with a
symptom as its expectation passes if any of its runs shows it; a `clean` entry
needs every run to be clean. `scripts/run-tests.sh` lists the matrix with the
number of runs per entry.

## Results

The last full run (`./run test --jobs 8 all`, 2026-11-05) passed all 40
entries in about 8 minutes once everything was built. Observed symptoms,
with the kernel in parentheses ("in run N": the earlier runs of that entry
were clean; "(n/n)": clean in every run):

| test | v7.4-rc1 | fix series |
|---|---|---|
| `vfio-exit-deadlock` | hang,lockdep (`mainline`) | clean (1/1) (`fixed`) |
| `vfio-reset-deadlock` | hang,lockdep (`mainline`) | clean (1/1) (`fixed`) |
| `sysfs-remove-deadlock` | hang,lockdep (`mainline`) | clean (1/1) (`fixed`) |
| `sriov-disable-deadlock` | hang,lockdep (`mainline`) | clean (1/1) (`fixed`) |
| `hotadd-lockdep` | lockdep (`mainline`) | clean (1/1) (`fixed`) |
| `reset-storm` | hang,lockdep (`mainline`) | clean (1/1) (`fixed`) |
| `slot-mutex-lockdep` | lockdep (`mainline`) | clean (1/1) (`fixed`) |
| `reset-during-bind` | hang,lockdep (`mainline`) | clean (1/1) (`fixed`) |
| `nested-lockdep` | lockdep (`mainline`) | clean (1/1) (`fixed`) |
| `nested-removal` | hang in run 4 (`mainline`) | clean (2/2) (`fixed`) |
| `sysfs-remove-uaf` | lockdep,kasan (`mainline-kasan`) | clean (1/1) (`fixed-kasan`) |
| `pciehp-unbind-uaf` | lockdep,kasan (`mainline-kasan`) | clean (1/1) (`fixed-kasan`) |
| `host-reset-deadlock` | hang,lockdep (`mainline-hooks`) | clean (1/1) (`fixed-hooks`) |
| `reset-removal-uaf` | lockdep,kasan in run 3 (`mainline-hooks-kasan`) | clean (2/2) (`fixed-hooks-kasan`) |
| `reset-adding-device` | hang,lockdep (`mainline-hooks`) | clean (1/1) (`fixed-hooks`) |
| `reset-pciehp-unbind` | hang (`mainline-hooks`) | clean (1/1) (`fixed-hooks`) |
| `reset-before-bind` | lockdep,fail (`mainline-hooks`) | clean (1/1) (`fixed-hooks`) |
| `reset-after-scan` | lockdep,fail (`mainline-hooks`) | clean (1/1) (`fixed-hooks`) |
| `aer-hotadd-race` | hang,lockdep (`mainline-hooks`) | fail (`fixed-hooks`) |
| `sriov-remove-abba` | hang,lockdep (`mainline-hooks`) | hang (`fixed-hooks`) |

`aer-hotadd-race` and `sriov-remove-abba` show R2 and R3, which the series
doesn't fix. Several of these races are timing-dependent, so a single run
can miss them; `--runs` repeats an entry.

## How a test runs

`harness/run.py` boots a q35 guest with Root Ports `rp1`..`rpN` and, for the
nested tests, an x3130 switch with two hotplug Downstream Ports. The guest's
`/init` runs `guest/scn/<scenario>.sh`, which asks the host for hot-plug actions
(`@@ACT add nic2 rp2`, `@@ACT del nic1`) on a second serial port; the host
executes them over QMP (`device_add`, `device_del`). At the end the guest prints
its result and the kernel log on that port and powers off. `harness/check.py`
classifies the run. `tools/vtool.c` opens vfio-pci devices, holds them and resets
them on request.

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
| `linux/` | submodule: https://github.com/opsound/linux, branch `pciehp-reset-fixes` |
| `qemu/` | submodule: QEMU v11.1.0 |
| `configs/` | kernel configs and `versions.env` (pinned commits, busybox version and checksum) |
| `scripts/build.sh` | fetch, build kernels, QEMU, busybox, tools, initramfs |
| `scripts/run-tests.sh` | the test list and the kernel x test matrix |
| `harness/` | host side: `run.py` (QEMU and QMP), `qxparse.py` (log parser), `check.py` |
| `guest/` | `/init`, helpers (`lib.sh`) and one script per scenario (`scn/`) |
| `tools/vtool.c` | static guest helper for vfio-pci |
| `docs/catalog.md` | the issue catalog |

The Linux and QEMU submodules are shallow. The build checks that they are at
the pinned commits, then fetches only the branches the other kernels need into
generated worktrees under `out/src/`. Busybox is downloaded once and checked
against its SHA-256.
