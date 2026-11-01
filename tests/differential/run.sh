#!/usr/bin/env bash
# Run the differential properties (tests/differential/property.c) against liblbug with the built
# extension, then print the rejection measure (tests/Property/Model.lean).
# Usage: tests/differential/run.sh [cases] [size]   Env: LBUG_DIR (lbug.h and liblbug, default .deps/cli)
set -euo pipefail
cd "$(dirname "$0")/../.."
LBUG="${LBUG_DIR:-.deps/cli}"
CASES="${1:-1000}"
SIZE="${2:-4}"
[ -f build/libmarien.lbug_extension ] || shim/build.sh >/dev/null
lake build marien-gen >/dev/null
mkdir -p build/differential
cc -O1 -g -std=gnu11 -I"$LBUG" -o build/differential/property tests/differential/property.c \
  -L"$LBUG" -llbug -lpthread -Wl,-rpath,"$PWD/$LBUG"
build/differential/property "$PWD/build/libmarien.lbug_extension" "$PWD/.lake/build/bin/marien-gen" \
  "$PWD/build/differential" "$CASES" "$SIZE"
# the rejection measure is tracked, never a failure
# @tg: verifies:: [[openspec:differential-testing#Rejection counterexample property#Rejections are measured]] {level: e2e}
.lake/build/bin/marien-gen rejections 200 "$SIZE" || true
