#!/usr/bin/env bash
#
# mayhem/build.sh — build the espeak-ng ssml-fuzzer harness + a standalone reproducer, plus the
# project's OWN ctest suite (so mayhem/test.sh only RUNS it, never compiles).
#
#   build/ssml-fuzzer             sanitized + libFuzzer  -> Mayhem target `ssml-fuzzer`
#   build/ssml-fuzzer-standalone  sanitized, run-once    -> crash reproducer (no libFuzzer runtime)
#   build-tests/                  NORMAL flags, ctest     -> the upstream unit+functional suite
#
# The binaries live under build/ (not the /mayhem root) so espeak's own
# non-executable-files-with-executable-bit ctest — which scans the repo tree — ignores them, and so
# the harness's dirname(argv[0]) data-path lookup resolves at build/espeak-ng-data (built alongside).
#
# The ssml-fuzzer harness (tests/ssml-fuzzer.c, upstream/OSS-Fuzz) drives espeak_Synth() over
# SSML/text input. The library itself is built with $SANITIZER_FLAGS so the fuzzed code (not just the
# harness) is instrumented.
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
# SanitizerCoverage for the WHOLE library, not just the harness — without it libFuzzer/Mayhem get no
# coverage feedback from the fuzzed code (0 edges). fuzzer-no-link instruments without hijacking main.
FUZZ_COV="-fsanitize=fuzzer-no-link"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS FUZZ_COV

cd "${SRC:-/mayhem}"

# ── 1) Sanitized build of the library (BUILD_SHARED_LIBS=OFF -> static archives to link the harness) ──
# detect_leaks=0 only for the data-compilation step: intonation/dict compilation runs the just-built
# (ASan) espeak-ng binary which allocates-and-exits per invocation; that is not a fuzz-time setting.
export ASAN_OPTIONS="detect_leaks=0"
cmake -S . -B build -G Ninja \
  -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" \
  -DCMAKE_C_FLAGS="$SANITIZER_FLAGS $FUZZ_COV $DEBUG_FLAGS" \
  -DCMAKE_CXX_FLAGS="$SANITIZER_FLAGS $FUZZ_COV $DEBUG_FLAGS" \
  -DBUILD_SHARED_LIBS=OFF -DENABLE_TESTS=OFF
cmake --build build -j"$MAYHEM_JOBS"
unset ASAN_OPTIONS

LIBS=(
  build/src/libespeak-ng/libespeak-ng.a
  build/src/speechPlayer/libspeechPlayer.a
  build/src/ucd-tools/libucd.a
)
INCS=(-Ibuild/src/libespeak-ng/include -I. -Isrc/include)

# ── 2) Harness: fuzzer binary + standalone reproducer (both sanitized, DWARF < 4) ──
# The harness is C, but libespeak-ng/speechPlayer are C++ (RTTI/vtables) — link the FINAL binaries
# with $CXX so the C++ runtime is pulled in. Compile the standalone driver as a C object first so its
# LLVMFuzzerTestOneInput reference keeps C linkage.
$CC $SANITIZER_FLAGS $FUZZ_COV $DEBUG_FLAGS "${INCS[@]}" -c tests/ssml-fuzzer.c -o tests/ssml-fuzzer.o
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS $LIB_FUZZING_ENGINE tests/ssml-fuzzer.o \
  "${LIBS[@]}" -o build/ssml-fuzzer -lm
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o /tmp/standalone_main.o
$CXX $SANITIZER_FLAGS $FUZZ_COV $DEBUG_FLAGS /tmp/standalone_main.o tests/ssml-fuzzer.o \
  "${LIBS[@]}" -o build/ssml-fuzzer-standalone -lm

# The harness sets ESPEAK_DATA_PATH from dirname(argv[0]) (=/mayhem/build); build/espeak-ng-data was
# produced by the cmake build above, so the binary finds its data with no extra copy.

# ── 3) The project's OWN test suite, NORMAL flags (clean, independent of the sanitized build) ──
# ENABLE_TESTS builds the compiled_test/*shell_test targets; ctest runs them. $COVERAGE_FLAGS is empty
# by default (no effect) and only instruments the suite when a coverage build passes it in.
cmake -S . -B build-tests -G Ninja \
  -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" \
  -DCMAKE_C_FLAGS="$COVERAGE_FLAGS" -DCMAKE_CXX_FLAGS="$COVERAGE_FLAGS" \
  -DBUILD_SHARED_LIBS=OFF -DENABLE_TESTS=ON
cmake --build build-tests -j"$MAYHEM_JOBS"

echo "build.sh: built /mayhem/ssml-fuzzer (+ -standalone) and the ctest suite in build-tests/"
