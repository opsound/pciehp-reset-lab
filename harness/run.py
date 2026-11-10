#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
# Host side of one test run: boot a q35 guest with the topology a scenario
# needs, execute the guest's "@@ACT ..." requests over QMP until GUEST-DONE (or
# timeout), and write serial.log (console), guest.log (ttyS1: actions, clean
# summary, dmesg), host.txt, summary.txt and result.json to <outdir>.
#
# Usage: run.py <bzImage> <scenario> <outdir> [--var V] [--n N] [--a A]
#               [--timeout S] [--kasan] [--cpu CPU] [--smp SMP] [--qemu PATH]
#               [--initrd F]
# Per-scenario defaults (SCN below) supply var, n, timeout, kernel arguments and
# topology, per variant where by_var says so.
#
# Topology: rp1..rpN pcie-root-ports (N = max(n, 2), chassis/slot i, rp1 at
# 00:10.0, rp2 at 00:11.0, ...), optionally a root port rps at 00:1e.0 with an
# x3130 switch (up1) and two hotplug downstream ports dp1/dp2 carrying the
# devices of nestdevs ("DEV1,DEV2": "-" for an empty slot, drivers joined by
# "+" for the functions of a multifunction device; default e1000e nicd1/nicd2),
# plus qemu_extra devices (post_extra after the switch).  Hot-added devices
# come from the guest's @@ACT requests (e1000e by default, igb for SR-IOV).  The
# guest sends @@ACT lines on ttyS1 (guest.log), which only it writes to, so
# kernel messages on ttyS0 can't corrupt them; only complete lines are executed.
import argparse, json, os, re, shutil, socket, subprocess, sys, tempfile, time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)
import qxparse  # noqa: E402

# Per-scenario defaults.  n: root ports (and the scenario's n=), var: default
# variant, a: rounds/seconds, timeout: host-side limit in s, nested: switch
# topology, nestdevs: devices below the switch, rpsopts: extra properties of
# the switch's root port, rpopts: extra properties of rp1..rpN, qemu_extra:
# more -device arguments, post_extra: -device arguments that need the switch's
# ports, append: extra kernel args, cpu: -cpu, smp: -smp, lockdep_check: a
# lockdep report fails the run, shutdown_check: seconds to wait for the
# poweroff after the guest is done (its result depends on it: qxparse "CHECK:
# poweroff"), by_var: per-variant overrides (a variant "X+FLAG..." without an
# entry of its own takes X's).
PCP_OFF = "power_controller_present=off"
# A Root Port without a hotplug slot, with an igb PF present at boot.
RPC_IGB = ["-device", "pcie-root-port,id=rpc,bus=pcie.0,chassis=50,slot=50,addr=0x1d,hotplug=off",
           "-device", "igb,id=pf1,bus=rpc"]
# Two NUMA nodes of 4 CPUs and 2G each, and a pxb-pcie host bridge on node 1
# with a hotplug Root Port rpn.
NUMA2 = ["-object", "memory-backend-ram,id=m0,size=2G", "-object", "memory-backend-ram,id=m1,size=2G",
         "-numa", "node,nodeid=0,cpus=0-3,memdev=m0", "-numa", "node,nodeid=1,cpus=4-7,memdev=m1",
         "-device", "pxb-pcie,id=pxb1,bus_nr=64,numa_node=1,bus=pcie.0,addr=0x1c",
         "-device", "pcie-root-port,id=rpn,bus=pxb1,chassis=60,slot=60"]
# Jailhouse's CPUID signature: hypervisor_isolated_pci_functions() is true in
# a -jh kernel (configs/jh.config).
JAILHOUSE_CPU = "host,hv-relaxed,hv-vendor-id=Jailhouse"
SCN = {
    "deadlock": dict(var="exit", timeout=150),
    "sysfsrm": dict(var="del", timeout=150),
    "sriovdl": dict(timeout=200),
    "plain": dict(timeout=120, lockdep_check=True),
    "storm": dict(n=8, timeout=200),
    "slotmx": dict(timeout=120, lockdep_check=True),
    "bindreset": dict(timeout=120),
    "nestlock": dict(nested=True, timeout=150, lockdep_check=True),
    "nested": dict(nested=True, timeout=120),
    "nestsurprise": dict(nested=True, var="prelock", timeout=200),
    "sysremove": dict(var="e1000e", a="10", timeout=600),
    "svcunbind": dict(var="fn", a="20", timeout=300),
    "hostreset": dict(timeout=120),
    "teardown": dict(var="err", a="3", timeout=600),
    "addwin": dict(var="win", timeout=150),
    "lifetime": dict(var="r1", timeout=180),
    "window2": dict(var="hold", timeout=120),
    "scanwin": dict(var="post", timeout=150),
    "single": dict(var="aer", a="5", timeout=400),
    "sriovabba": dict(var="sysfs", timeout=150),
    "portunbind": dict(nested=True, var="lockedadd", timeout=200,
                       by_var={"lockedadd": dict(nestdevs="-,e1000e")}),
    "nestbringup": dict(nested=True, nestdevs="-,e1000e", var="sysfs", timeout=200),
    "sriovreset": dict(var="hostreset", a="60", timeout=400, by_var={"walk": dict(qemu_extra=RPC_IGB)}),
    "resetremove": dict(nested=True, nestdevs="e1000e,igb", timeout=200),
    "resetprobe": dict(nested=True, nestdevs="-,igb", var="pciehp", timeout=150,
                       by_var={"rescan": dict(nestdevs="e1000e,igb", rpsopts="hotplug=off")}),
    "subuaf": dict(nested=True, nestdevs="e1000e,-", var="1", a="20", timeout=400),
    # The switch's Root Port without a hotplug slot: error resets are bus resets
    "busuaf": dict(nested=True, rpsopts="hotplug=off", var="plain", a="20", timeout=400),
    # A NIC present at boot on rp1, so that bridge_d3 gets set without a pciehp hot-add
    "rpmrec": dict(var="remove+pin", append="pcie_port_pm=force", timeout=200, lockdep_check=True,
                   qemu_extra=["-device", "e1000e,id=nic1,bus=rp1"]),
    "rescanrm": dict(nested=True, var="race-dev", a="10", timeout=300),
    "vfstall": dict(var="pciehp", timeout=200),
    "bindremove": dict(nested=True, var="sysfs", timeout=200),
    "aermsix": dict(timeout=150),
    # virtio-blk (null backend) below dp1, after the switch: post_extra
    "resetorder": dict(nested=True, nestdevs="-,e1000e", var="io", a="3", timeout=200,
                       post_extra=["-blockdev", "driver=null-co,node-name=nb1,size=67108864,read-zeroes=on",
                                   "-device", "virtio-blk-pci,id=vblk1,drive=nb1,bus=dp1"],
                       by_var={"bus": dict(rpsopts="hotplug=off"), "busio": dict(rpsopts="hotplug=off")}),
    # vfio-pci NIC after fatal-error recovery: ep below rp1, sw below the switch
    # (sw2: with a second NIC on dp2)
    "vfiorec": dict(var="ep", timeout=150, qemu_extra=["-device", "e1000e,id=nic1,bus=rp1"],
                    by_var={"sw": dict(nested=True, nestdevs="e1000e,-", qemu_extra=[]),
                            "sw2": dict(nested=True, nestdevs="e1000e,e1000e", qemu_extra=[])}),
    # W6 locking: vfio-pci NIC on rp1 at boot (no hot-add, so lockdep stays on
    # unless +inject: aer_inject's own report turns it off),
    # an unbound NIC on rp2 (dl: removed and rescanned in a loop, the pci_bus_sem
    # writer), igb PF on rpc (dl+sriov: sriov_numvfs loop as the writer)
    "w6pm": dict(var="lockdep-d3", timeout=200, qemu_extra=["-device", "e1000e,id=nic1,bus=rp1",
                                                            "-device", "e1000e,id=nicw,bus=rp2"] + RPC_IGB,
                 by_var={"dl": dict(a="90", timeout=400)}),
    # AER recovery with unbound devices, and with a driver without error handlers
    "aerunb": dict(var="new", timeout=150, by_var={
        "mf": dict(qemu_extra=["-device", "e1000e,id=nic2,bus=rp2,addr=0.0,multifunction=on",
                               "-device", "e1000e,id=nic2f1,bus=rp2,addr=0.1"]),
        "vfs": dict(qemu_extra=["-device", "igb,id=pf1,bus=rp2"]),
        "nohandler": dict(qemu_extra=["-device", "qemu-xhci,id=xhci2,bus=rp2"])}),
    # The TEST ONLY DPC emulation (pcitest/dpc_reset), with a NIC on rp1 at boot
    "dpcwait": dict(var="dead", timeout=300, qemu_extra=["-device", "e1000e,id=nic1,bus=rp1"]),
    # The igb PF is present at boot (no hot-add, so lockdep stays on).
    "pmsriov": dict(a="10", timeout=300, qemu_extra=["-device", "igb,id=pf1,bus=rp1"]),
    "sriovguard": dict(var="sysfs", timeout=200, qemu_extra=["-device", "igb,id=pf1,bus=rp1"]),
    "numaprobe": dict(var="pciehp", append="igb.max_vfs=2", timeout=200, smp="8,sockets=2,cores=4,threads=1",
                      qemu_extra=NUMA2, by_var={"rescan": dict(qemu_extra=NUMA2 + ["-device", "igb,id=pf1,bus=rpn"])}),
    # Slots without function 0 (Jailhouse signature, -jh kernels).  pcie_aspm=off
    # avoids N26 (and then needs pcie_ports=native: without ASPM support, _OSC
    # grants no native hotplug).  resume, boot-aspm: 01:00.1 alone at boot, in
    # a slot without power controller (QEMU powers a slot with one off at
    # reset, so the boot scan finds nothing), which also keeps the card through
    # pciehp's teardown.
    "isolfn": dict(var="vanish", timeout=150, cpu=JAILHOUSE_CPU, append="pcie_aspm=off pcie_ports=native",
                   by_var={"vanish-aspm": dict(append=""),
                           "resume": dict(rpopts=PCP_OFF, qemu_extra=["-device", "e1000e,id=nic1,bus=rp1,addr=0.1"]),
                           "boot-aspm": dict(append="", rpopts=PCP_OFF, qemu_extra=["-device", "e1000e,id=nic1,bus=rp1,addr=0.1"])}),
    # nic2 present at boot, in a slot without power controller
    "rpmsafe": dict(var="rpm", rpopts=PCP_OFF, append="pcie_port_pm=force", timeout=120,
                    qemu_extra=["-device", "e1000e,id=nic2,bus=rp2"]),
    "linkdownadd": dict(timeout=120),
    "pfprobe": dict(append="igb.max_vfs=2", timeout=150),
    # B = e1000e on rp1, removed through sysfs: the pci_bus_sem writer
    "spurlink": dict(nested=True, nestdevs="e1000e+e1000e,e1000e", var="reset", timeout=200,
                     qemu_extra=["-device", "e1000e,id=nic1,bus=rp1"]),
    # vfio waits for two resets of the dead device
    "deadreset": dict(var="sysfs", timeout=300, by_var={"vfio": dict(timeout=420)},
                      qemu_extra=["-device", "e1000e,id=nic1,bus=rp1"]),
    # The igb PF is present at boot, so that no hot-add (and N1's lockdep
    # report, which turns lockdep off) precedes the test; race re-adds it.
    "pfunbind": dict(var="unbind", timeout=150, qemu_extra=["-device", "igb,id=pf1,bus=rp1"],
                     by_var={"race": dict(a="12", timeout=400)}),
    "shutaer": dict(var="slot", a="10", timeout=150, shutdown_check=45,
                    qemu_extra=["-device", "e1000e,id=nic1,bus=rp1"],
                    by_var={"bus": dict(rpopts="hotplug=off")}),
}


def defaults(scn, var):
    d = dict(n=2, var="x", a="", timeout=200, nested=False, nestdevs="e1000e,e1000e", rpsopts="", rpopts="",
             qemu_extra=[], post_extra=[], append="", cpu="host", smp=None, loglevel=7, lockdep_check=False,
             shutdown_check=0)
    d.update({k: v for k, v in SCN.get(scn, {}).items() if k != "by_var"})
    v = var if var is not None else d["var"]
    bv = SCN.get(scn, {}).get("by_var", {})
    d.update(bv.get(v, bv.get(v.split("+")[0], {})))
    d["var"] = v
    return d


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("kernel"); ap.add_argument("scn"); ap.add_argument("out")
    ap.add_argument("--var"); ap.add_argument("--n", type=int); ap.add_argument("--timeout", type=int)
    ap.add_argument("--a", help="a= for the guest (rounds or seconds)")
    ap.add_argument("--append", help="extra kernel arguments (added to the scenario's)")
    ap.add_argument("--rpopts", help="pcie-root-port properties (replaces the scenario's)")
    ap.add_argument("--cpu", help="-cpu argument (replaces the scenario's)")
    ap.add_argument("--nested", action="store_true", default=None); ap.add_argument("--no-nested", dest="nested", action="store_false")
    ap.add_argument("--loglevel", type=int); ap.add_argument("--smp", help="-smp argument (default 8)")
    ap.add_argument("--mem", default="4G")
    ap.add_argument("--kasan", action="store_true", help="KASAN kernel: double the timeout")
    ap.add_argument("--qemu", default=os.environ.get("QEMU", os.path.join(ROOT, "out/qemu/qemu-system-x86_64")))
    ap.add_argument("--initrd", default=os.path.join(ROOT, "out/initramfs.cpio.gz"))
    ap.add_argument("--label", help="label stored in result.json")
    a = ap.parse_args()
    d = defaults(a.scn, a.var)
    n = a.n if a.n is not None else d["n"]
    timeout = a.timeout if a.timeout is not None else d["timeout"]
    rpopts = a.rpopts if a.rpopts is not None else d["rpopts"]
    nested = a.nested if a.nested is not None else d["nested"]
    loglevel = a.loglevel if a.loglevel is not None else d["loglevel"]
    append = " ".join(x for x in (d["append"], a.append or "") if x)
    kernel = a.kernel
    if not os.path.isfile(kernel):
        sys.exit("no kernel %s" % kernel)
    binfo = {"kasan": a.kasan}
    if a.kasan and a.timeout is None:
        timeout *= 2   # KASAN guests run 2-3x slower

    os.makedirs(a.out, exist_ok=True)
    log, act = (os.path.join(a.out, f) for f in ("serial.log", "guest.log"))
    # AF_UNIX socket paths are limited to 108 bytes, so the QMP socket lives in
    # a short private directory rather than in the output directory.
    a.qdir = tempfile.mkdtemp(prefix="pciehp-lab-")
    qmp = os.path.join(a.qdir, "qmp.sock")
    for f in (log, act, os.path.join(a.out, "result.json")):
        if os.path.exists(f):
            os.unlink(f)
    nrp = max(n, 2)
    if nrp > 28:
        sys.exit("at most 28 root ports")
    cpu = a.cpu if a.cpu is not None else d["cpu"]
    smp = a.smp if a.smp is not None else (d["smp"] or "8")
    cmd = [a.qemu, "-M", "q35,kernel-irqchip=split", "-accel", "kvm", "-cpu", cpu,
           "-smp", smp, "-m", a.mem, "-display", "none", "-vga", "none", "-no-reboot", "-nic", "none",
           "-device", "intel-iommu,intremap=on,caching-mode=on",
           "-global", "ICH9-LPC.acpi-pci-hotplug-with-bridge-support=off"]
    for i in range(1, nrp + 1):
        addr = 0x10 + i - 1 if i <= 15 else 0x03 + i - 16
        if nested and addr == 0x1e:
            sys.exit("rp%d would collide with the switch's root port at 00:1e.0" % i)
        cmd += ["-device", "pcie-root-port,id=rp%d,bus=pcie.0,chassis=%d,slot=%d,addr=0x%x%s"
                % (i, i, i, addr, ("," + rpopts) if rpopts else "")]
    cmd += list(d["qemu_extra"])
    if nested:
        cmd += ["-device", "pcie-root-port,id=rps,bus=pcie.0,chassis=40,slot=40,addr=0x1e%s"
                % (("," + d["rpsopts"]) if d["rpsopts"] else ""),
                "-device", "x3130-upstream,id=up1,bus=rps",
                "-device", "xio3130-downstream,id=dp1,bus=up1,chassis=41,slot=1",
                "-device", "xio3130-downstream,id=dp2,bus=up1,chassis=42,slot=2"]
        for i, spec in enumerate(d["nestdevs"].split(","), 1):
            fns = [] if spec in ("", "-") else spec.split("+")
            for fn, drv in enumerate(fns):
                if len(fns) == 1:
                    cmd += ["-device", "%s,id=nicd%d,bus=dp%d" % (drv, i, i)]
                else:
                    cmd += ["-device", "%s,id=nicd%d%s,bus=dp%d,addr=0.%d%s" % (
                        drv, i, "f%d" % fn if fn else "", i, fn, ",multifunction=on" if fn == 0 else "")]
    cmd += list(d["post_extra"])
    av = a.a if a.a is not None else d["a"]
    cmdline = "console=ttyS0 intel_iommu=on panic=-1 loglevel=%d log_buf_len=8M printk.devkmsg=on scn=%s var=%s n=%d%s %s" % (
        loglevel, a.scn, d["var"], n, (" a=%s" % av) if av else "", append)
    cmd += ["-kernel", kernel, "-initrd", a.initrd, "-append", cmdline.strip(),
            "-serial", "file:" + log, "-serial", "file:" + act,
            "-qmp", "unix:%s,server=on,wait=off" % qmp, "-monitor", "none"]
    q = subprocess.Popen(cmd, stdout=open(os.path.join(a.out, "qemu.out"), "w"), stderr=subprocess.STDOUT)
    T0 = time.time()
    hostlog = open(os.path.join(a.out, "host.txt"), "w")

    def stamp(msg):
        line = "[h %6.2f] %s" % (time.time() - T0, msg)
        print(line, flush=True); hostlog.write(line + "\n"); hostlog.flush()
    stamp("qemu: " + " ".join(cmd))
    # QMP: the socket appears asynchronously; retry until connected.
    s = None
    for _ in range(300):
        if q.poll() is not None:
            break
        try:
            s = socket.socket(socket.AF_UNIX); s.connect(qmp); break
        except OSError:
            s = None; time.sleep(0.05)
    if s is None:
        stamp("qemu exited or QMP unavailable: rc=%s %s" % (q.poll(), open(os.path.join(a.out, "qemu.out")).read()[-500:]))
        finish(a, d, n, kernel, binfo, q, stamp, timed_out=False, nact=0)
        return
    f = s.makefile("rw")

    def qcmd(c, **kw):
        f.write(json.dumps({"execute": c, "arguments": kw} if kw else {"execute": c}) + "\n"); f.flush()
        while True:
            r = json.loads(f.readline())
            if "return" in r or "error" in r:
                return r

    def add(drv, id, bus):
        # device_del completes when the guest has ejected the device; a re-add
        # with the same ID before that fails, so retry for up to 20 s.
        for k in range(100):
            r = qcmd("device_add", driver=drv, id=id, bus=bus)
            if "error" not in r or "Duplicate" not in r["error"].get("desc", ""):
                return r if k == 0 else dict(r, retries=k)
            time.sleep(0.2)
        return r
    f.readline(); qcmd("qmp_capabilities")
    nact, timed_out, chan = 0, True, None
    end = T0 + timeout
    while time.time() < end:
        txt = open(log, errors="replace").read() if os.path.exists(log) else ""
        if chan is None:
            # The guest announces the channel on both ports; the console copy can
            # be split by kernel messages, the ttyS1 copy can't.
            g = open(act, errors="replace").read() if os.path.exists(act) else ""
            m = re.search(r"GUEST-READY .*act=(\w+)", g) or re.search(r"GUEST-READY .*act=(console)", txt)
            chan = m.group(1) if m else None
        if chan:
            src = (open(act, errors="replace").read() if os.path.exists(act) else "") if chan == "tty" else txt
            src = src.replace("\r", "")
            acts = re.findall(r"^@@ACT (.*)\n", src, re.M)  # complete lines only
            while nact < len(acts):
                w = acts[nact].split(); nact += 1
                if not w:
                    continue
                if w[0] == "add" and len(w) >= 3:
                    r = add(w[3] if len(w) > 3 else "e1000e", w[1], w[2])
                elif w[0] == "del" and len(w) >= 2:
                    r = qcmd("device_del", id=w[1])
                elif w[0] in ("addall", "delall") and len(w) >= 2:
                    rs = []
                    for i in range(1, int(w[1]) + 1):
                        rs.append(add(w[2] if len(w) > 2 else "e1000e", "nic%d" % i, "rp%d" % i) if w[0] == "addall"
                                  else qcmd("device_del", id="nic%d" % i))
                    r = "%d ok, errors=%s" % (len(rs), [x["error"]["desc"] for x in rs if "error" in x])
                elif w[0] == "qmp" and len(w) >= 2:   # qmp COMMAND [JSON-ARGS]
                    r = qcmd(w[1], **json.loads(" ".join(w[2:]) or "{}"))
                else:
                    r = "unknown action"
                stamp("ACT %s -> %s" % (" ".join(w), r))
        gtxt = open(act, errors="replace").read() if chan == "tty" and os.path.exists(act) else ""
        # With the tty channel, wait for its GUEST-DONE (after the summary and dmesg).
        if ("GUEST-DONE" in gtxt) if chan == "tty" else ("GUEST-DONE" in txt):
            timed_out = False
            break
        if q.poll() is not None:
            timed_out = not any("GUEST-DONE" in open(x, errors="replace").read() for x in (log, act) if os.path.exists(x))
            break
        time.sleep(0.2)
    # Let the guest power off (it may not: device_shutdown() blocks behind a deadlock).
    for _ in range(int((d["shutdown_check"] or 6) * 5)):
        if q.poll() is not None:
            break
        time.sleep(0.2)
    finish(a, d, n, kernel, binfo, q, stamp, timed_out, nact)


def finish(a, d, n, kernel, binfo, q, stamp, timed_out, nact):
    if q.poll() is None:
        q.kill(); q.wait()
        stamp("killed qemu")
    shutil.rmtree(a.qdir, ignore_errors=True)
    rd = lambda f: open(os.path.join(a.out, f), errors="replace").read() if os.path.exists(os.path.join(a.out, f)) else ""
    txt, gtxt = rd("serial.log"), rd("guest.log")
    rec = qxparse.parse(txt, gtxt)
    rec.update(scenario=a.scn, var=d["var"], n=n, a=(a.a if a.a is not None else d["a"]), label=a.label or a.scn,
               kernel=kernel, build=binfo,
               timed_out=bool(timed_out), actions=nact, lockdep_check=d["lockdep_check"])
    rec["verdict"] = qxparse.verdict(rec)
    rec["outcome"] = qxparse.outcome(rec)
    stamp("done=%s timed_out=%s verdict=%s result=%s" % (rec["done"], rec["timed_out"], rec["verdict"], rec["result"]))
    json.dump(rec, open(os.path.join(a.out, "result.json"), "w"), indent=1)
    user = qxparse.section(gtxt, "SUMMARY")
    summ = (user.splitlines() if user is not None else
            [l for l in txt.splitlines() if re.search(r"RESULT:|PERF |STATS |LOCKDEP-LINES", l)])
    summ += [l for l in txt.splitlines() if re.search(r"possible circular|possible recursive|blocked for more than|WARNING:|BUG:", l)
             and "] " in l][:20]
    summ += ["lockdep: %s" % x for x in rec["lockdep"]]
    summ += ["ignored (test tool): %s" % x for x in rec["ignored"]]
    summ += ["hung tasks: %s" % " ".join(rec["hung_tasks"])] if rec["hung_tasks"] else []
    summ += ["VERDICT: %s" % rec["verdict"]]
    open(os.path.join(a.out, "summary.txt"), "w").write("\n".join(summ) + "\n")
    for l in summ:
        print("  " + l)


if __name__ == "__main__":
    main()
