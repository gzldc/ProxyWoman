#!/usr/bin/env bash
# Runs every test target in its own `swift test` process, one after another.
# Running all targets in one process can stall under heavy parallel load; one target at a time is reliable.
# A target that stalls (no result within 5 minutes) is stopped and run once more.
set -uo pipefail
cd "$(dirname "$0")/.."
targets=$(sed -n 's/^ *name: "\([A-Za-z]*Tests\)",*$/\1/p' Package.swift)
[[ -n "$targets" ]] || { echo "no test targets found in Package.swift" >&2; exit 1; }
log=$(mktemp "${TMPDIR:-/tmp}/proxywoman-test.XXXXXX")
trap 'rm -f "$log"' EXIT

run_target() {
  swift test --filter "^$1\." >"$log" 2>&1 &
  local pid=$! waited=0
  while kill -0 "$pid" 2>/dev/null; do
    if ((waited >= 300)); then
      pkill -P "$pid" 2>/dev/null; kill "$pid" 2>/dev/null
      pkill -f "swiftpm-testing-helper.*--filter \^$1" 2>/dev/null
      wait "$pid" 2>/dev/null
      return 2
    fi
    sleep 2; ((waited += 2))
  done
  wait "$pid" 2>/dev/null
  grep -q 'Test run with' "$log"
}

failed=0
for target in $targets; do
  run_target "$target" || { echo "$target: stalled or no result, retrying"; run_target "$target"; }
  if summary=$(grep -E 'Test run with' "$log"); then
    echo "$target: ${summary#* }"
    [[ "$summary" == *failed* ]] && failed=1
  else
    echo "$target: no result"; tail -20 "$log"; failed=1
  fi
done
exit $failed
