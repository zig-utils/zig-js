#!/usr/bin/env bash
#
# zig-cache-tool.sh — inspect and safely prune the repository-local Zig caches.
#
# During baseline-JIT development, repeated focused `zig build ... -Dtest-filter`
# runs relink the monolithic test artifact under distinct cache keys and the
# repo-local `.zig-cache` has grown to ~92 GB, tripping LLVM `No space left on
# device`. This tool reports what those reproducible caches hold and prunes them
# without ever being able to touch source or user-owned files (issue #53).
#
# Usage:
#   tools/zig-cache-tool.sh report            # (default) sizes + largest entries
#   tools/zig-cache-tool.sh prune [--dry-run] # remove .zig-cache + zig-out
#
# Only ever operates on <repo>/.zig-cache and <repo>/zig-out — both are fully
# reproducible from a build. It refuses any path that, after symlink resolution,
# is not inside those two directories.

set -euo pipefail

# --- Locate the repository, whatever CWD the tool is invoked from. ------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || true)"
if [ -z "$REPO_ROOT" ]; then
  echo "error: not inside a git repository (run from the zig-js checkout)" >&2
  exit 1
fi
CACHE_DIR="$REPO_ROOT/.zig-cache"
OUT_DIR="$REPO_ROOT/zig-out"

# --- Safety guard: refuse anything outside the two reproducible output dirs. --
# Resolves the target's parent through symlinks (the target itself may not
# exist), then requires the absolute result to be exactly, or a child of,
# CACHE_DIR or OUT_DIR. This is the hard boundary for issue #53's rule that no
# cleanup can target paths outside the repository cache/build outputs.
assert_within_outputs() {
  local target="$1" parent base resolved
  parent="$(dirname "$target")"
  base="$(basename "$target")"
  if ! resolved="$(cd "$parent" 2>/dev/null && printf '%s/%s' "$(pwd -P)" "$base")"; then
    echo "refusing: cannot resolve '$target'" >&2
    return 1
  fi
  case "$resolved" in
    "$CACHE_DIR" | "$CACHE_DIR"/* | "$OUT_DIR" | "$OUT_DIR"/*) return 0 ;;
    *)
      echo "refusing to touch a path outside the repo cache/build outputs:" >&2
      echo "  $resolved" >&2
      return 1
      ;;
  esac
}

human_size() {
  # Total apparent size of the arguments that exist, as a human string.
  local existing=()
  for p in "$@"; do [ -e "$p" ] && existing+=("$p"); done
  if [ ${#existing[@]} -eq 0 ]; then
    echo "0B"
  else
    du -sh -c "${existing[@]}" 2>/dev/null | tail -1 | cut -f1
  fi
}

cmd_report() {
  echo "repository: $REPO_ROOT"
  echo
  if [ -d "$CACHE_DIR" ]; then
    echo ".zig-cache total: $(human_size "$CACHE_DIR")"
    for sub in o tmp h z c; do
      [ -d "$CACHE_DIR/$sub" ] && printf '  %-4s %s\n' "$sub/" "$(human_size "$CACHE_DIR/$sub")"
    done
    if [ -d "$CACHE_DIR/o" ]; then
      echo
      echo "  largest o/ artifacts (compiled test/exe outputs — the reproducible bulk):"
      du -sh "$CACHE_DIR"/o/* 2>/dev/null | sort -rh | head -8 | sed 's/^/    /'
    fi
  else
    echo ".zig-cache: (none)"
  fi
  echo
  if [ -d "$OUT_DIR" ]; then
    echo "zig-out total: $(human_size "$OUT_DIR")"
  else
    echo "zig-out: (none)"
  fi
  echo
  echo "reclaimable now: $(human_size "$CACHE_DIR" "$OUT_DIR")"
  echo "run 'tools/zig-cache-tool.sh prune' to reclaim it."
}

cmd_prune() {
  local dry_run=0
  for arg in "$@"; do
    case "$arg" in
      --dry-run) dry_run=1 ;;
      # Retained as a harmless compatibility alias: prune is now always a
      # coherent fully cold cleanup because Zig 0.17's c/h/z metadata retains
      # references to o/ artifacts and cannot safely survive partial removal.
      --all) ;;
      *) echo "unknown prune option: $arg" >&2; exit 2 ;;
    esac
  done

  # Remove the cache as one coherent unit. Partial removal of o/ and tmp/ while
  # keeping Zig 0.17's c/h/z metadata produces stale manifest references and
  # makes the next build fail with CacheCheckFailed.
  local targets=("$CACHE_DIR" "$OUT_DIR")

  local reclaim
  reclaim="$(human_size "${targets[@]}")"
  echo "would reclaim: $reclaim"

  for t in "${targets[@]}"; do
    assert_within_outputs "$t" || exit 1
    if [ ! -e "$t" ]; then
      continue
    fi
    if [ "$dry_run" -eq 1 ]; then
      echo "  [dry-run] rm -rf $t"
    else
      echo "  removing $t"
      rm -rf -- "$t"
    fi
  done

  if [ "$dry_run" -eq 1 ]; then
    echo "dry run: nothing was deleted."
  else
    echo "done. reclaimed ~$reclaim (rebuilds are fully reproducible)."
  fi
}

case "${1:-report}" in
  report) cmd_report ;;
  prune) shift; cmd_prune "$@" ;;
  -h | --help | help)
    sed -n '2,25p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    ;;
  *)
    echo "unknown command: $1 (expected: report | prune | help)" >&2
    exit 2
    ;;
esac
