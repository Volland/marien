#!/usr/bin/env bash
# Build build/libmarien.lbug_extension with shim/CMakeLists.txt.
# Usage: shim/build.sh [strip|nostrip]   Env: LADYBUG_SRC, LADYBUG_GEN, CC, CXX, LEAN_RUNTIME_A,
#   PINNED_VERSION (the LadybugDB version the load check expects; default scripts/ladybug-version)
#   and OUT (default build/libmarien.lbug_extension)
set -euo pipefail
cd "$(dirname "$0")/.."
MODE="${1:-strip}"
if [ "$(uname -s)" = Darwin ]; then
  export CC="${CC:-/usr/bin/clang}" CXX="${CXX:-/usr/bin/clang++}"  # the system libc++, as LadybugDB's releases
else
  export CC="${CC:-gcc}" CXX="${CXX:-g++}"                          # the system libstdc++
fi
ARGS=(-DLINK_MODE="$MODE")
[ -n "${LADYBUG_SRC:-}" ] && ARGS+=(-DLADYBUG_SRC="$LADYBUG_SRC")
[ -n "${LADYBUG_GEN:-}" ] && ARGS+=(-DLADYBUG_GEN="$LADYBUG_GEN")
DIR="build/shim-$MODE"
if [ -n "${PINNED_VERSION:-}" ]; then ARGS+=(-DPINNED_VERSION="$PINNED_VERSION"); DIR="$DIR-$PINNED_VERSION"; fi
OUT="${OUT:-build/libmarien.lbug_extension}"
cmake -S shim -B "$DIR" -DCMAKE_BUILD_TYPE=Release "${ARGS[@]}" >/dev/null
cmake --build "$DIR" --parallel >/dev/null
mkdir -p "$(dirname "$OUT")"
cp "$DIR/libmarien.lbug_extension" "$OUT"
echo "built $OUT ($MODE)"
