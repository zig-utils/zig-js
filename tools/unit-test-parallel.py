#!/usr/bin/env python3
"""Run the zig-js unit suite as parallel shards against one built binary.

The suite is single-threaded per process and large enough that an unsharded run
takes hours on one core while the rest of the machine idles. The test runner has
always supported `UNIT_SHARD_INDEX`/`UNIT_SHARD_COUNT`; this driver is what
actually spends the cores, and `zig build test-parallel` wires it up so the fast
path is the default one rather than something you have to remember.

Every shard runs the same already-built binary, so there is no per-shard link
and the shard count is free to change. Output is per-shard files rather than
interleaved stdout, and each shard's failures are replayed at the end with its
own name attached, so a failure is still attributable to one test.

Usage:
  tools/unit-test-parallel.py <test-binary> [--jobs N] [--log-dir DIR]
"""

from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys
import time
from pathlib import Path


SUMMARY = re.compile(
    r"summary: (\d+) passed; (\d+) skipped; (\d+) failed; (\d+) leaked(?:; (\d+) ms)?"
)
SLOW = re.compile(r"slow: (\d+) ms (.+)$")


def default_jobs() -> int:
    # Leave a core for the OS and for whatever else the developer is running;
    # oversubscribing makes every shard slower without finishing sooner.
    return max(1, (os.cpu_count() or 2) - 1)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("binary", type=Path)
    parser.add_argument("--jobs", type=int, default=default_jobs())
    parser.add_argument("--log-dir", type=Path, default=None)
    parser.add_argument(
        "--slowest",
        type=int,
        default=10,
        help="how many of the slowest tests across all shards to report",
    )
    args = parser.parse_args()

    if not args.binary.exists():
        print(f"test binary not found: {args.binary}", file=sys.stderr)
        return 1
    jobs = max(1, args.jobs)
    log_dir = args.log_dir or Path(
        os.environ.get("ZIG_JS_UNIT_LOG_DIR", ".zig-cache/unit-shards")
    )
    log_dir.mkdir(parents=True, exist_ok=True)

    print(f"zig-js unit tests: {jobs} parallel shards -> {log_dir}", flush=True)
    started = time.monotonic()
    running = []
    for index in range(jobs):
        log_path = log_dir / f"shard-{index}.log"
        handle = log_path.open("w")
        env = dict(os.environ, UNIT_SHARD_INDEX=str(index), UNIT_SHARD_COUNT=str(jobs))
        # start_new_session so a signal to this driver does not race the shards
        # into a half-reaped state; each shard is killed explicitly instead.
        process = subprocess.Popen(
            [str(args.binary)],
            stdout=handle,
            stderr=subprocess.STDOUT,
            env=env,
            start_new_session=True,
        )
        running.append((index, process, handle, log_path))

    codes = {}
    try:
        for index, process, handle, _ in running:
            codes[index] = process.wait()
            handle.close()
    except KeyboardInterrupt:
        for _, process, _, _ in running:
            process.kill()
        raise

    passed = skipped = failed = leaked = 0
    slow: list[tuple[int, str]] = []
    failures: list[str] = []
    for index, _, _, log_path in running:
        text = log_path.read_text(errors="replace")
        match = SUMMARY.search(text)
        if match:
            passed += int(match.group(1))
            skipped += int(match.group(2))
            failed += int(match.group(3))
            leaked += int(match.group(4))
        else:
            # No summary line means the shard died before finishing — a crash or
            # a kill. Count it as a failure rather than silently dropping it.
            failed += 1
            failures.append(f"shard {index}: produced no summary (exit {codes[index]})")
        for line in text.splitlines():
            slow_match = SLOW.search(line)
            if slow_match:
                slow.append((int(slow_match.group(1)), slow_match.group(2)))
            elif "FAIL" in line or line.startswith("error:"):
                failures.append(f"shard {index}: {line.strip()}")

    elapsed = time.monotonic() - started
    for line in failures:
        print(line, flush=True)
    slow.sort(reverse=True)
    for ms, name in slow[: args.slowest]:
        print(f"slowest: {ms} ms {name}", flush=True)
    print(
        f"zig-js unit tests: {passed} passed; {skipped} skipped; "
        f"{failed} failed; {leaked} leaked; {elapsed:.1f}s wall across {jobs} shards",
        flush=True,
    )
    print(f"per-shard logs: {log_dir}", flush=True)
    return 1 if (failed or leaked or any(codes.values())) else 0


if __name__ == "__main__":
    sys.exit(main())
