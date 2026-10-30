#!/usr/bin/env bash
#
# mayhem/build.sh — build this repo's fuzz harness(es). EDIT per repo.
#
# Runs inside the commit image (mayhem/Dockerfile) as `mayhem` in /mayhem. The base image
# (ghcr.io/savantenvs/base) already exports the build contract — use these, don't redefine:
#   CC, CXX             stock clang / clang++
#   LIB_FUZZING_ENGINE  -fsanitize=fuzzer   (link into each harness that has a LLVMFuzzer entry)
#   SANITIZER_FLAGS     -fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer
#                       (ASan + UBSan, both set to HALT — so Mayhem catches memory AND UB defects)
#   DEBUG_FLAGS         -g -gdwarf-3   (DWARF debug info — always on for fuzz/standalone builds,
#                       independent of the sanitizer off-switch; DWARF version must be < 4)
#   RUST_DEBUG_FLAGS    -C debuginfo=2 -C force-frame-pointers=yes -C llvm-args=-gdwarf-3
#                       (thread through RUSTFLAGS on every cargo-fuzz build)
#   GO_DEBUG_FLAGS      -gcflags=all=-N -l
#                       (thread through go build / go-fuzz-build so the linked ELF keeps symbols)
#   SRC                 /mayhem (the repo source)
#
# Contract: build EVERYTHING here — one runnable binary per fuzz harness, AND the project's test
# suite (so mayhem/test.sh only has to RUN it, never compile). Keep it ADDITIVE (build upstream as
# upstream documents; don't edit upstream files). IMPORTANT: build the PROJECT ITSELF with
# $SANITIZER_FLAGS and $DEBUG_FLAGS (not just the harness) so the fuzzed code is instrumented
# AND carries DWARF < 4 symbols — otherwise ASan/UBSan only see the harness, not the library
# you're trying to find bugs in, and backtraces won't resolve project source lines. Build the TEST
# suite with the project's NORMAL flags (a clean, independent build) so test.sh stays an honest
# functional oracle and won't false-fail on benign UB. Leave the test binary/runner where test.sh
# expects it.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' (empty) — it must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# Build knobs come from the ENVIRONMENT (overridable), with sane defaults — no if-statements,
# just parameter-expansion fallbacks. Default sanitizers are the base's ASan+UBSan (halting); override
# per build via the Dockerfile's `--build-arg SANITIZER_FLAGS="..."`.
# NB: SANITIZER_FLAGS uses `=` (no colon) on purpose — `=` only fills when the var is UNSET, so an
# explicit EMPTY value (`--build-arg SANITIZER_FLAGS=`) is honored and builds with NO sanitizers
# (useful when you want the program's natural crash / full backtrace, not an ASan report). The other
# knobs use `:=` (default on empty too). MAYHEM_JOBS sets build parallelism (falls back to nproc).
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
# DEBUG_FLAGS carries DWARF debug info INDEPENDENTLY of the sanitizer off-switch (so an empty
# SANITIZER_FLAGS still yields DWARF symbols). DWARF MUST be < 4 (Mayhem triage can't read >=4); clang-19's
# plain `-g` emits DWARF-5, so `-gdwarf-3` is explicit. Apply $DEBUG_FLAGS to the fuzz/harness/standalone
# builds (NOT the test/oracle build). Rust/Go carry the same intent via their language flags below.
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${RUST_DEBUG_FLAGS:=-C debuginfo=2 -C force-frame-pointers=yes -C llvm-args=-gdwarf-3}"
: "${GO_DEBUG_FLAGS:=-gcflags=all=-N -l}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
# COVERAGE_FLAGS: empty by default → no effect on the normal oracle build. Set it via the Dockerfile's
# `--build-arg COVERAGE_FLAGS="-fprofile-instr-generate -fcoverage-mapping"` to instrument the TEST
# build for source-coverage measurement (how much of the project the test suite actually exercises —
# a quality signal for the oracle; complements the anti-reward-hack sabotage check). APPEND it to the
# test build's compile+link flags in step 3 (NOT the fuzz build); after `test.sh` runs, merge with
# `llvm-profdata` and report with `llvm-cov`. Empty value is honored (`=`, not `:=`).
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS RUST_DEBUG_FLAGS GO_DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"

pkgs="libxml-2.0 librtlsdr libusb-1.0"
PKG_CFLAGS="$(pkg-config --cflags $pkgs)"
PKG_LIBS="$(pkg-config --libs $pkgs)"

# Upstream's own configure; it writes only under build/ (gitignored) and is safe to re-run.
./configure >/dev/null

# 1) The project's TEST suite build, NORMAL flags, in upstream's own build/ (what mayhem/test.sh runs).
make -j"$MAYHEM_JOBS" EXTRA_CXXFLAGS="$COVERAGE_FLAGS" DEBUG_LDFLAGS="$COVERAGE_FLAGS" \
    build/wmbusmeters build/testinternals

# 2) The project again for fuzzing, in build/fuzz (gitignored via build/): sanitized, DWARF 3, SanCov
#    (fuzzer-no-link), and -DFUZZING=true which is upstream's documented fuzz switch (skips CRC checks).
#    The build/fuzz/fuzz target (upstream's src/fuzz.cc) is only used to get all project objects built.
FUZZ_CXXFLAGS="-O1 $SANITIZER_FLAGS $DEBUG_FLAGS -fsanitize=fuzzer-no-link"
make -j"$MAYHEM_JOBS" BUILD=build/fuzz DEBUG_FLAGS="$FUZZ_CXXFLAGS" FUZZFLAGS=-DFUZZING=true build/fuzz/fuzz

PROJECT_OBJS=$(ls build/fuzz/*.o | grep -v -E '/(fuzz|main|testinternals)\.o$')

# 3) Harnesses: libFuzzer binary + standalone run-once reproducer each, leak sanitizer switched off.
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c mayhem/lsan_off.cc -o /tmp/lsan_off.o
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o /tmp/standalone_main.o

for h in fuzz_difvif fuzz_telegram; do
    $CXX -std=gnu++17 -O1 $SANITIZER_FLAGS $DEBUG_FLAGS -fsanitize=fuzzer-no-link -DFUZZING=true \
        -Isrc -Ibuild/fuzz $PKG_CFLAGS -c "mayhem/$h.cc" -o "/tmp/$h.o"
    $CXX $SANITIZER_FLAGS $DEBUG_FLAGS $LIB_FUZZING_ENGINE "/tmp/$h.o" $PROJECT_OBJS /tmp/lsan_off.o \
        $PKG_LIBS -lpthread -o "/mayhem/$h"
    $CXX $SANITIZER_FLAGS $DEBUG_FLAGS -fsanitize=fuzzer-no-link /tmp/standalone_main.o "/tmp/$h.o" \
        $PROJECT_OBJS /tmp/lsan_off.o $PKG_LIBS -lpthread -o "/mayhem/$h-standalone"
done
