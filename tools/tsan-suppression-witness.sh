#!/usr/bin/env bash
#
# ThreadSanitizer suppression witness for issue #1.
#
# This script proves the TSan suppressions are both load-bearing and narrow:
# - selected cases race without suppressions,
# - every manifested race names only approved program-byte access frames,
# - the same cases pass with tsan-suppressions.txt enabled.
#
# It intentionally allows timing-dependent cases not to race on every attempt;
# the witness fails only if none of the selected cases races at all.

set -uo pipefail

BIN=${BIN:-./zig-out/bin/threads-test}
TSAN_SUPPRESSIONS=${TSAN_SUPPRESSIONS:-$PWD/tsan-suppressions.txt}
WITNESS_ATTEMPTS=${WITNESS_ATTEMPTS:-5}
WITNESS_TIMEOUT=${WITNESS_TIMEOUT:-600}
CASES=${CASES:-"cve/mc-df-ta-detach-resize.js cve/mc-prim-arraybuffer-transfer-vs-atomics.js"}

# The only TSan summary frames allowed for suppressed races. Each touches raw JS
# program bytes in shared ArrayBuffer / SharedArrayBuffer storage, not engine
# metadata, roots, waiter queues, object shapes, or GC state. Keep this regex in
# sync with tsan-suppressions.txt and docs/threads/memory-model.md.
OK_FRAMES=${OK_FRAMES:-'ta(Write|Read|AtomicLoadRaw|AtomicStoreRaw|AtomicRmwRaw|AtomicCasRaw|StoreInternal|LoadInternal)|__tsan_memcpy|arrayBufferResizeFn|arrayBufferTransfer'}

tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/zig-js-tsan-witness.XXXXXX")
trap 'rm -rf "$tmpdir"' EXIT

fail=0
any_raced=0

for c in $CASES; do
  safe_name=$(printf '%s' "$c" | tr '/:' '__')
  raw_log="$tmpdir/$safe_name.raw.log"
  supp_log="$tmpdir/$safe_name.supp.log"
  raced=0
  attempt=1
  while [ "$attempt" -le "$WITNESS_ATTEMPTS" ]; do
    TSAN_OPTIONS="halt_on_error=0 exitcode=0" timeout "$WITNESS_TIMEOUT" "$BIN" parallel-js one "$c" > "$raw_log" 2>&1 || true
    if grep -q "SUMMARY: ThreadSanitizer: data race" "$raw_log"; then
      raced=1
      break
    fi
    attempt=$((attempt + 1))
  done

  if [ "$raced" -eq 1 ]; then
    any_raced=1
    if grep "SUMMARY: ThreadSanitizer: data race" "$raw_log" | grep -qvE "$OK_FRAMES"; then
      echo "::error::$c: a suppressed race is NOT purely program-byte; suppression would mask an engine race:"
      grep "SUMMARY: ThreadSanitizer: data race" "$raw_log" | grep -vE "$OK_FRAMES"
      fail=1
    else
      echo "$c: raced, and every TSan race summary is program-byte (narrow)"
    fi
  else
    echo "$c: did not race in $WITNESS_ATTEMPTS attempts (timing-dependent)"
  fi

  if ! TSAN_OPTIONS="halt_on_error=1 suppressions=$TSAN_SUPPRESSIONS" timeout "$WITNESS_TIMEOUT" "$BIN" parallel-js one "$c" > "$supp_log" 2>&1; then
    echo "::error::$c still fails WITH suppressions"
    # Surface the unsuppressed race report (frames + both accesses), not just the
    # abort backtrace `tail` shows — this names which engine frame escaped the
    # suppressions, the diagnostic needed to fix the underlying race.
    if grep -q "WARNING: ThreadSanitizer" "$supp_log"; then
      echo "--- unsuppressed ThreadSanitizer report (suppressions active) ---"
      awk '/WARNING: ThreadSanitizer/{p=1} p{print} /^.*SUMMARY: ThreadSanitizer/{if(p){exit}}' "$supp_log"
    else
      tail -20 "$supp_log"
    fi
    fail=1
  fi
done

if [ "$any_raced" -eq 0 ]; then
  echo "::error::no suppressed case raced without suppressions; suppressions may be inert"
  fail=1
fi

exit "$fail"
