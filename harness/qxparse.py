# SPDX-License-Identifier: GPL-2.0-only
"""Parse a guest serial log into a result record (used by run.py)."""
import re

TS = re.compile(r"\[\s*(\d+\.\d{6})\] ?(.*)$")  # kernel timestamp, possibly after interleaved user output
LOCK = re.compile(r"\(([^(){}]+?)\)\{")
LOCKDEP_HDR = re.compile(r"WARNING: (possible circular locking dependency detected|possible recursive locking detected|"
                         r"inconsistent lock state|possible irq lock inversion dependency detected|"
                         r"suspicious RCU usage|bad unlock balance detected!|held lock freed!|"
                         r"lock held when returning to user space!|"
                         r"Nested lock was not taken|possible circular locking deadlock detected)")
HUNG = re.compile(r"INFO: task (\S+) blocked for more than (\d+) seconds")
# Reports of the test tools themselves, never counted as symptoms: aer_inject
# (CONFIG_PCIEAER_INJECT, used through /dev/aer_inject) takes its spinlock_t
# inject_lock in its pci_ops under the raw spinlock pci_lock, which lockdep
# reports once per boot as "BUG: Invalid wait context" (PROVE_RAW_LOCK_NESTING)
# and then turns itself off.  Recorded as "ignored" in result.json.
IGNORED = (("Invalid wait context", "(inject_lock)"),)
NUM = re.compile(r"^-?\d+(\.\d+)?$")
FAILWORDS = ("FAIL", "HUNG", "HANG", "STUCK", "KASAN", "RESET-STUCK")


def kernel_lines(text, dmesg=False):
    """(timestamp, message) for every kernel console line, deduplicated: dmesg
    replays by the guest scripts (lockdep_check) repeat the same timestamp.
    dmesg=True: text is `dmesg` output, whose multi-line records continue on
    indented lines without a timestamp."""
    seen, out, last = set(), [], None
    for l in text.splitlines():
        l = l.strip("\r")
        m = TS.search(l)
        if not m:
            if dmesg and last is not None and l.startswith(" "):
                out.append((last, l.strip()))
            continue
        last = float(m.group(1))
        key = (m.group(1), m.group(2)[:80])
        if key in seen:
            continue
        seen.add(key)
        out.append((last, m.group(2)))
    return out


def lockdep_reports(klines):
    """One entry per lockdep report: type, the lock being acquired, the locks
    held ("already holding"), and the dependency chain (-> #N lines)."""
    reps, cur, want = [], None, None
    for t, msg in klines:
        h = LOCKDEP_HDR.search(msg)
        if h:
            cur = {"t": t, "type": h.group(1), "trying": [], "holding": [], "chain": []}
            reps.append(cur)
            want = None
            continue
        if cur is None:
            continue
        if "is trying to acquire lock" in msg or "trying to release lock" in msg:
            want = "trying"
            continue
        if "already holding lock" in msg or "is holding lock" in msg:
            want = "holding"
            continue
        m = re.match(r"\s*-> #\d+ \(([^(){}]+?)\)\{", msg)
        if m:
            cur["chain"].append(m.group(1))
            continue
        if want:
            m = LOCK.search(msg)
            if m:
                cur[want].append(m.group(1))
            want = None
        if "*** DEADLOCK ***" in msg or "stack backtrace:" in msg:
            cur = None if "stack backtrace:" in msg else cur
    return reps


def lockdep_sig(r):
    """e.g. "circular: pci_slot_mutex <- pci_rescan_remove_lock [+&ctrl->reset_lock]":
    the lock being acquired <- the lock(s) held, [+ other locks of the chain]."""
    kind = {"possible circular locking dependency detected": "circular",
            "possible recursive locking detected": "recursive"}.get(r["type"], r["type"])
    held = [x for x in dict.fromkeys(r["holding"]) if x not in r["trying"]]
    s = "%s: %s" % (kind, " ".join(dict.fromkeys(r["trying"])) or "?")
    if held:
        s += " <- " + " ".join(held)
    rest = [x for x in dict.fromkeys(r["chain"]) if x not in r["trying"] and x not in held]
    if rest:
        s += " [+%s]" % " ".join(rest)
    return s


def kv(s):
    out = {}
    for tok in s.split():
        if "=" in tok:
            k, v = tok.split("=", 1)
            v = v.rstrip(",")
            if NUM.match(v):
                out[k] = float(v)
    return out


def metrics(text):
    """Numeric metrics from PERF/STATS/BENCH/OK/ERRS/RESULT lines (lists of values)."""
    m, seen = {}, {}

    def add(k, v):
        m.setdefault(k, []).append(v)
    for l in text.splitlines():
        l = l.strip("\r")
        p = re.match(r"^PERF (.*)$", l)
        if p:
            d, op = kv(p.group(1)), None
            mm = re.search(r"\bop=(\S+)", p.group(1)) or re.match(r"(\S+)", p.group(1))
            op = mm.group(1) if mm else "perf"
            for k, v in d.items():
                if k not in ("round", "n"):
                    add("%s.%s" % (op, k), v)
            continue
        s = re.match(r"^(?:(VLAT [^:]+): )?STATS (\S+) n=\d+ avg_ms=([\d.]+) min_ms=([\d.]+) max_ms=([\d.]+)", l)
        if s:
            name = ((s.group(1) + " ") if s.group(1) else "") + s.group(2)
            seen[name] = seen.get(name, 0) + 1
            add("%s#%d.avg_ms" % (name, seen[name]), float(s.group(3)))
            continue
        b = re.match(r"^BENCH (\S+) ns_per_op=([\d.]+)", l)
        if b:
            add("bench.%s.ns" % b.group(1), float(b.group(2)))
            continue
        v = re.match(r"^VLAT (par\d+) (loop|reset) wall_s=([\d.]+)", l)
        if v:
            add("vlat.%s.%s.wall_s" % (v.group(1), v.group(2)), float(v.group(3)))
            continue
        e = re.match(r"^ERRS (\S+) (.*)$", l)
        if e and "none" not in e.group(2):
            for k, val in kv(e.group(2)).items():
                add("errs.%s.%s" % (e.group(1), k), val)
            continue
        o = re.match(r"^OK (\S+) (\d+)/(\d+)", l)
        if o:
            add("ok.%s" % o.group(1), float(o.group(2)))
            continue
        r = re.match(r"^RESULT: (.*)$", l)
        if r:
            for k, val in kv(r.group(1)).items():
                add("result.%s" % k, val)
    return m


def ignored_reports(klines):
    """Headers of the reports listed in IGNORED, identified by a line of the
    report that follows within a few lines."""
    out = []
    for i, (t, msg) in enumerate(klines):
        for hdr, mark in IGNORED:
            if hdr in msg and any(mark in m for _, m in klines[i + 1:i + 6]):
                out.append("%s %s" % (hdr, mark))
    return out


def section(text, name):
    if not text:
        return None
    m = re.search(r"^%s-BEGIN\n(.*?)^%s-END$" % (name, name), text.replace("\r", ""), re.S | re.M)
    return m.group(1) if m else None


def parse(serial, guest=""):
    """serial: ttyS0 log (console); guest: ttyS1 log (guest.log) with the clean
    SUMMARY and DMESG sections the guest writes at the end, if it got there."""
    summ, dm = section(guest, "SUMMARY"), section(guest, "DMESG")
    user = summ if summ is not None else serial
    if dm:   # complete kernel log; add console lines printed after the dump
        kl = kernel_lines(dm, dmesg=True)
        last = kl[-1][0] if kl else 0
        kl += [x for x in kernel_lines(serial) if x[0] > last]
    else:
        kl = kernel_lines(serial)
    res = None
    for l in user.splitlines():
        mm = re.search(r"RESULT: (.*)$", l.strip("\r"))
        if mm:
            res = TS.split(mm.group(1))[0].strip()   # drop an interleaved kernel message
            break
    hung_tasks, hung_ts = set(), set()
    for t, msg in kl:
        h = HUNG.search(msg)
        if h:
            hung_ts.add(t)
            hung_tasks.add(h.group(1))
    reps, seen = [], set()
    for r in lockdep_reports(kl):
        if r["t"] not in seen:   # the same report from the dmesg dump and the console
            seen.add(r["t"]); reps.append(r)
    warns = [msg for t, msg in kl if msg.startswith("WARNING:") and not LOCKDEP_HDR.search(msg)]
    # BUG:/KASAN, slub_debug ("BUG kmalloc-64 (Not tainted): Poison overwritten"),
    # oopses, list debugging, and the lifetime reports of lock debugging: lockdep's
    # "held lock freed!" and a freed/corrupted rwsem (DEBUG_RWSEMS magic check).
    ignored = ignored_reports(kl)
    bugs = [msg for t, msg in kl if msg.startswith("BUG:") or "BUG: KASAN" in msg
            or re.match(r"BUG \S+ \(", msg) or msg.startswith(("Oops", "general protection fault"))
            or re.search(r"list_(add|del) corruption", msg) or "held lock freed!" in msg
            or msg.startswith("DEBUG_RWSEMS_WARN_ON(sem->magic != sem)")]
    added, added_bad = None, []
    for l in user.splitlines():
        m = re.match(r"^ADDED-CHECK-SUMMARY devices=(\d+) bad=(\d+)", l)
        if m:
            added = {"devices": int(m.group(1)), "bad": int(m.group(2))}
        elif l.startswith("ADDED-CHECK ") and not l.rstrip().endswith(" ok"):
            added_bad.append(l[len("ADDED-CHECK "):].strip())
    kasan = [msg for t, msg in kl if "BUG: KASAN" in msg]
    # A scenario that prints "CHECK: poweroff" is judged by the poweroff after
    # GUEST-DONE: "reboot: Power down" must follow on the console, else the
    # result becomes FAIL poweroff=hang (or =panic: init exits 30 s after
    # GUEST-DONE, see guest/init).
    poweroff = None
    if res and re.search(r"^CHECK: poweroff", user, re.M) and not res.startswith("SKIP"):
        tail = serial[serial.rfind("GUEST-DONE"):] if "GUEST-DONE" in serial else ""
        poweroff = ("ok" if "reboot: Power down" in tail else
                    "panic" if "Attempted to kill init" in tail else "hang")
        res = res + " poweroff=ok" if poweroff == "ok" else "FAIL poweroff=%s %s" % (poweroff, res)
    return {
        "poweroff": poweroff,
        "added": added,
        "added_bad": added_bad[:10],
        "kasan": kasan[:5],
        "ready": "GUEST-READY" in serial or "GUEST-READY" in (guest or ""),
        "done": "GUEST-DONE" in serial or "GUEST-DONE" in (guest or ""),
        "clean_summary": summ is not None,
        "result": res,
        "hung_tasks": sorted(hung_tasks),
        "hung_reports": len(hung_ts),
        "lockdep": [lockdep_sig(r) for r in reps],
        "lockdep_detail": reps,
        "warnings": warns[:10],
        "bugs": bugs[:10],
        "ignored": ignored[:5],
        "metrics": metrics(user),
    }


def verdict(rec):
    """PASS / FAIL / HANG for one run.  HANG: the guest never finished the
    scenario (no GUEST-DONE before the host timeout) or hung tasks were
    reported.  FAIL: RESULT missing or containing a failure word, or a BUG.
    SKIP: the scenario does not apply to the kernel.  Scenarios whose purpose is
    lockdep (lockdep_check) also FAIL on any lockdep report.  Every scenario
    FAILs if the guest's final added_check found a device below a root port
    without a driver, with BAR0 not matching its resource, or (non-vfio
    drivers) with memory decode off; BUG lines include KASAN reports."""
    r = rec.get("result") or ""
    if r.startswith("SKIP"):
        return "SKIP"
    if not rec.get("done") or rec.get("hung_reports"):
        return "HANG"
    if not r or any(w in r.split()[0] for w in FAILWORDS) or any(w in r for w in (" STUCK", "RESET-STUCK")):
        return "FAIL"
    if rec.get("bugs"):
        return "FAIL"
    if rec.get("lockdep_check") and rec.get("lockdep"):
        return "FAIL"
    if (rec.get("added") or {}).get("bad"):
        return "FAIL"   # a hot-added device ended up without driver or with a cleared BAR
    return "PASS"


def outcome(rec):
    """RESULT reduced to its non-numeric words (e.g. RESET-BEFORE-SCAN sbr=NO-RESET devices=0),
    plus the added_check findings (e.g. "[added: UNBOUND]") and "[KASAN]"."""
    r = rec.get("result")
    extra = ""
    if rec.get("added_bad"):
        extra += " [added: %s]" % ",".join(sorted(set(x.split()[-1] for x in rec["added_bad"])))
    if rec.get("kasan"):
        extra += " [KASAN]"
    tags = []
    for b in rec.get("bugs") or []:
        t = ("" if "KASAN" in b else "Oops" if b.startswith(("Oops", "general protection")) else
             "lock-freed" if "held lock freed" in b else "rwsem-freed" if b.startswith("DEBUG_RWSEMS") else
             "list-corruption" if "corruption" in b else "slab" if re.match(r"BUG \S+ \(", b) else "BUG")
        if t and t not in tags:
            tags.append(t)
    if tags:
        extra += " [%s]" % ",".join(tags)
    if not r:
        return ("no-result" if rec.get("ready") else "no-boot") + extra
    return _outcome(r) + extra


def _outcome(r):
    keep = []
    for tok in r.split():
        if "=" in tok:
            k, v = tok.split("=", 1)
            if NUM.match(v) and k not in ("devices", "left", "devices_left", "early", "stuck"):
                continue
        elif NUM.match(tok):
            continue
        keep.append(tok)
    # No separator left dangling by the dropped counts
    return " ".join(keep).rstrip(",;")
