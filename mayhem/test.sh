#!/usr/bin/env bash
#
# mayhem/test.sh — RUN espeak-ng's OWN ctest suite (built by mayhem/build.sh in build-tests/).
# This is the project's real unit + functional suite: compiled C tests (api, encoding, ieee80,
# readclause) plus the shell-based behavioral tests (cmd_options, dictionary, language-*,
# ssml, translate, variants, voices, crash, bom, ...). They assert phoneme output, translation
# traces, encoding round-trips and golden results — so a no-op/`exit(0)` sabotage of the library
# FAILS the suite. Emits CTRF and exits non-zero iff a test failed. Does NOT compile.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"
cd "${SRC:-/mayhem}"

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

if [ ! -d build-tests ]; then
  echo "test.sh: build-tests/ missing — mayhem/build.sh must build the ctest suite (not rebuilding here)" >&2
  emit_ctrf ctest 0 1; exit 1
fi

# Run the whole suite. Capture output to parse ctest's summary counts.
out="$(ctest --test-dir build-tests -j"$MAYHEM_JOBS" --output-on-failure 2>&1)"; rc=$?
echo "$out"

# ctest prints e.g. "100% tests passed, 0 tests failed out of 21".
total=$(grep -oE 'out of [0-9]+' <<<"$out" | tail -1 | grep -oE '[0-9]+' || echo 0)
failed=$(grep -oE '[0-9]+ tests failed' <<<"$out" | tail -1 | grep -oE '[0-9]+' || echo 0)
: "${total:=0}"; : "${failed:=0}"
passed=$(( total - failed ))
[ "$passed" -lt 0 ] && passed=0

# Fallback: if parsing yielded nothing but ctest failed, record one failure.
if [ "$total" -eq 0 ] && [ "$rc" -ne 0 ]; then failed=1; fi

emit_ctrf cmake-ctest "$passed" "$failed"
