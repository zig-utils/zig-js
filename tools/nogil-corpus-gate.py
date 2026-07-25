#!/usr/bin/env python3
"""Functional no-GIL PR-249 corpus gate, checked against the published baseline.

The TSan sweep next to this one gates `races == 0` and deliberately treats a
functional failure or timeout as a warning, because TSan's ~10x slowdown makes
those signals unreliable. Something still has to notice when a case that used to
work under no-GIL stops working, and that is this gate.

It runs without TSan, so timings are meaningful, and compares each result
against `docs/.data/pr249-execution-nogil.json`:

  * a case the baseline records as `pass` that now does not  -> regression, fails
  * a case the baseline already records as non-passing       -> reported, does not fail
  * a case the baseline does not know about                  -> must pass, or it fails

That last rule matters: a newly promoted case has to earn its place rather than
inheriting an exemption by being absent from the file.

A case that starts passing is reported too. It is not a failure, but it means the
baseline is stale and should be refreshed.

Build mode is part of the expectation. Debug's allocator captures a stack trace
per allocation, so the same case can be ~10x more expensive there — measured on
`cve/mc-val-fire-vs-link.js`, 32.3 s Debug against 3.3 s ReleaseSafe. Against a
fixed per-case deadline that multiplier decides whether a case is gateable at
all, so a case can be genuinely correct and still not fit in Debug.

A baseline entry may therefore carry a `modes` map keyed by build mode, and
`--build-mode` selects which expectation applies. A mode with no entry falls
back to the case's top-level `result`, so existing entries keep working
unchanged. This is deliberately not a blanket exemption: the expectation still
has to be written down per mode, and a mode that says `pass` still fails if the
case does not.

Usage: nogil-corpus-gate.py --shard N --shards M [--deadline S] [--binary PATH]
                            [--build-mode debug|releasesafe]
"""
import argparse
import json
import os
import signal
import subprocess
import sys
import time
from pathlib import Path

BASELINE = Path("docs/.data/pr249-execution-nogil.json")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--shard", type=int, default=0)
    ap.add_argument("--shards", type=int, default=1)
    ap.add_argument("--deadline", type=int, default=600,
                    help="per-case SIGKILL deadline in seconds")
    ap.add_argument("--binary", default="./zig-out/bin/threads-test")
    ap.add_argument("--build-mode", default="debug", choices=("debug", "releasesafe"),
                    help="which per-mode baseline expectation applies")
    args = ap.parse_args()

    baseline = {c["case"]: c for c in json.loads(BASELINE.read_text())["cases"]}

    def expects_pass(name: str) -> bool:
        """Whether this build mode expects `name` to pass.

        An absent case must pass — that is what makes a newly promoted case earn
        its place. A `modes` map overrides the top-level result for the selected
        build only; without one, every mode shares the same expectation.
        """
        entry = baseline.get(name)
        if entry is None:
            return True
        modes = entry.get("modes")
        if isinstance(modes, dict) and args.build_mode in modes:
            return modes[args.build_mode].get("result") == "pass"
        return entry.get("result", "pass") == "pass"

    listing = subprocess.run([args.binary, "parallel-js", "list"],
                             capture_output=True, text=True)
    cases = [c.strip() for c in (listing.stdout + listing.stderr).splitlines()
             if c.strip().endswith(".js")]
    if not cases:
        print("could not read the parallel-js case list", file=sys.stderr)
        return 2
    mine = [c for i, c in enumerate(cases) if i % args.shards == args.shard]
    print(f"shard {args.shard}/{args.shards}: {len(mine)} of {len(cases)} cases, "
          f"{args.deadline}s deadline, {args.build_mode} expectations", flush=True)

    regressions, known, improved, passed = [], [], [], 0
    for name in mine:
        started = time.time()
        # Own process group, killed as a group. These cases spawn threads and
        # can outlive SIGTERM, so the deadline has to be SIGKILL — but reaping
        # by pattern (`pkill -f <binary>`) would also kill an unrelated run on
        # the same machine, which silently reports someone else's kill as this
        # shard's failure. Killing only our own group cannot do that.
        proc = subprocess.Popen(
            [args.binary, "parallel-js", "one", name],
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            text=True, start_new_session=True)
        try:
            proc.communicate(timeout=args.deadline)
            ok = proc.returncode == 0
        except subprocess.TimeoutExpired:
            ok = False
            try:
                os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
            except ProcessLookupError:
                pass
            proc.communicate()
        elapsed = int(time.time() - started)

        expected_pass = expects_pass(name)
        if ok:
            passed += 1
            if not expected_pass:
                improved.append(name)
        elif expected_pass:
            regressions.append((name, elapsed))
        else:
            known.append(name)

    print(f"\npassed {passed}/{len(mine)}")
    for name in known:
        note = (baseline.get(name, {}).get("modes", {}) or {}).get(args.build_mode, {})
        why = note.get("note") or baseline.get(name, {}).get("note", "")
        detail = f" — {why}" if why else ""
        print(f"::notice::known non-passing under no-GIL ({args.build_mode}): {name}{detail}")
    for name in improved:
        print(f"::notice::now passes, baseline is stale: {name}")
    for name, elapsed in regressions:
        print(f"::error::no-GIL regression in {name} (after {elapsed}s)")
    if regressions:
        print(f"\n{len(regressions)} regression(s) against {BASELINE}")
        return 1
    print(f"\nno regressions against {BASELINE}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
