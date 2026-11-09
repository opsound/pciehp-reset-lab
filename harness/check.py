#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
# Classify one run's result.json into symptoms and compare with an expectation.
# Usage: check.py <result.json> <clean|pass|hang|lockdep|kasan|oops|warn|fail>
# Symptoms:
#   hang     the guest never finished, hung tasks were reported, or the
#            scenario reported a stuck operation
#   lockdep  lockdep reported a locking problem
#   kasan    KASAN reported a memory safety bug
#   oops     an oops, general protection fault or other BUG
#   warn     a WARNING other than lockdep's
#   fail     the scenario's own check failed, e.g. a hot-added device ended up
#            without its driver or with its BARs cleared
#   skip     the scenario didn't run (a hook it needs is missing)
#   error    the guest never booted (harness or QEMU failure)
# "clean" means none of them.  Exit 0 if the expectation is met: "clean"
# requires no symptom; "pass" (series checks) requires that the scenario's own
# check passed and that nothing hung, crashed or hit KASAN, but allows lockdep
# reports and warnings, such as N1's lockdep report on the first hot-add; any
# other expectation requires that symptom.
import json, re, sys

FAILWORDS = ("FAIL", "HUNG", "HANG", "STUCK", "KASAN")
# "stuck", "hung" or "hang" in the scenario's result, as a word or a key with a
# value ("stuck=pciehp"), but not negated ("no hang", "not stuck") or zero
# ("hung=0", "stuck=none")
HANGWORD = re.compile(r"(?<!\bno )(?<!\bnot )\b(stuck|hung|hang)\b(?!=(?:0|none)\b)", re.I)


def symptoms(rec):
    s = []
    res = rec.get("result") or ""
    if res.startswith("SKIP"):
        return ["skip"]
    # The guest never booted (e.g. QEMU failed to start): a harness error, not
    # a symptom of the kernel.
    if not rec.get("ready"):
        return ["error"]
    if rec.get("verdict") == "HANG" or rec.get("hung_tasks") or rec.get("timed_out") or HANGWORD.search(res):
        s.append("hang")
    if rec.get("lockdep"):
        s.append("lockdep")
    if rec.get("kasan"):
        s.append("kasan")
    if any("KASAN" not in b for b in rec.get("bugs") or []):
        s.append("oops")
    if rec.get("warnings"):
        s.append("warn")
    # The scenario reported a failure (or no result at all, e.g. a guest that
    # booted and then hung), or a hot-added device ended up broken.
    res_failed = rec.get("done") and (not res or any(w in res.split()[0] for w in FAILWORDS))
    if res_failed or (rec.get("added") or {}).get("bad") or (rec.get("verdict") in ("FAIL", "HANG") and not s):
        s.append("fail")
    return s


def main():
    rec = json.load(open(sys.argv[1]))
    want = sys.argv[2]
    got = symptoms(rec)
    if want == "clean":
        ok = not got
    elif want == "pass":
        ok = not set(got) & {"hang", "kasan", "oops", "fail", "skip", "error"}
    else:
        ok = want in got
    detail = rec.get("outcome") or rec.get("result") or "no result"
    print("observed %s; scenario: %s" % (",".join(got) or "clean", detail))
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
