#!/usr/bin/env bash
# Build build/libmarien.lbug_extension with shim/CMakeLists.txt.
# Usage: shim/build.sh [strip|nostrip]   Env: LADYBUG_SRC, LADYBUG_GEN, CC, CXX, LEAN_RUNTIME_A
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
cmake -S shim -B "build/shim-$MODE" -DCMAKE_BUILD_TYPE=Release "${ARGS[@]}" >/dev/null
cmake --build "build/shim-$MODE" --parallel >/dev/null
cp "build/shim-$MODE/libmarien.lbug_extension" build/libmarien.lbug_extension
echo "built build/libmarien.lbug_extension ($MODE)"
