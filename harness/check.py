#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
# Classify one run's result.json into symptoms and compare with an expectation.
# Usage: check.py <result.json> <clean|hang|lockdep|kasan|oops|fail>
# Symptoms:
#   hang     the guest never finished, hung tasks were reported, or the
#            scenario reported a stuck operation
#   lockdep  lockdep reported a locking problem
#   kasan    KASAN reported a memory safety bug
#   oops     an oops, general protection fault or other BUG
#   fail     the scenario failed otherwise, e.g. a hot-added device ended up
#            without its driver or with its BARs cleared
# "clean" means none of them.  Exit 0 if the expectation is met: "clean"
# requires no symptom, any other expectation requires that symptom.
import json, re, sys


def symptoms(rec):
    s = []
    res = rec.get("result") or ""
    # "stuck", "hung" or "hang" in the result, but not a zero count like "hung=0"
    if (rec.get("verdict") == "HANG" or rec.get("hung_tasks") or rec.get("timed_out")
            or re.search(r"\b(stuck|hung|hang)\b(?!=0\b)", res, re.I)):
        s.append("hang")
    if rec.get("lockdep"):
        s.append("lockdep")
    if rec.get("kasan"):
        s.append("kasan")
    if any("KASAN" not in b for b in rec.get("bugs") or []):
        s.append("oops")
    if rec.get("verdict") in ("FAIL", "HANG") and not s:
        s.append("fail")
    elif rec.get("verdict") == "FAIL" and (rec.get("added") or {}).get("bad"):
        s.append("fail")
    return s


def main():
    rec = json.load(open(sys.argv[1]))
    want = sys.argv[2]
    got = symptoms(rec)
    ok = not got if want == "clean" else want in got
    detail = rec.get("outcome") or rec.get("result") or "no result"
    print("observed %s; scenario: %s" % (",".join(got) or "clean", detail))
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
