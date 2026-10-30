#!/usr/bin/env bash
#
# mayhem/test.sh — RUN upstream's own functional suite (built by mayhem/build.sh). The scripts under
# tests/ feed telegrams through wmbusmeters and diff the produced json/fields against asserted
# values; build/testinternals holds the C++ unit/known-answer tests. Every script counts as one test.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
cd "$SRC"

emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

PROG=build/wmbusmeters
for f in "$PROG" build/testinternals; do
  [ -x "$f" ] || { echo "missing $f: mayhem/build.sh must build it" >&2; emit_ctrf "wmbusmeters-tests" 0 1; exit 1; }
done
command -v jq >/dev/null || { echo "jq is required by the upstream tests" >&2; emit_ctrf "wmbusmeters-tests" 0 1; exit 1; }

export TZ=UTC PROG
passed=0
failed=0

if build/testinternals >/dev/null 2>&1; then passed=$((passed+1)); else failed=$((failed+1)); echo "FAILED: build/testinternals"; fi

# The test list is upstream's own test.sh: every "tests/<name>.sh $PROG ..." invocation.
mapfile -t cases < <(grep -E '^\.?/?tests/[A-Za-z0-9_]+\.sh' test.sh)
[ "${#cases[@]}" -gt 0 ] || { echo "no tests found in test.sh" >&2; emit_ctrf "wmbusmeters-tests" 0 1; exit 1; }
for c in "${cases[@]}"; do
  if out=$(eval "$c" 2>&1); then
    passed=$((passed+1))
  else
    failed=$((failed+1)); echo "FAILED: $c"; echo "$out" | tail -n 15
  fi
done

emit_ctrf "wmbusmeters-tests" "$passed" "$failed" 0
