#!/usr/bin/env bash
# Build spike/build/libmarien_spike.lbug_extension: the C++ shim, the C runtime bridge, the
# Spike Lean module, LeanElpi, the Lean runtime, GMP and libuv in ONE shared library.
# LadybugDB symbols stay undefined and resolve against the host process (-undefined
# dynamic_lookup on macOS, the default for shared objects on Linux), as LadybugDB's own
# extensions do. libleancpp is NOT linked: bridge.c defines a runtime-only lean_initialize.
#
# Usage: spike/build.sh [strip|nostrip]   (default: strip, i.e. -dead_strip)
set -euo pipefail
cd "$(dirname "$0")"
MODE="${1:-strip}"

LB="${LADYBUG_SRC:-../.deps/ladybug}"          # LadybugDB source at the pinned tag
LBGEN="${LADYBUG_GEN:-$LB/build/release}"       # its CMake-configured tree (generated headers)
PREFIX="$(lean --print-prefix)"
if [ "$(uname -s)" = Darwin ]; then
  CXX="${CXX:-/usr/bin/clang++}"                # system clang: same libc++ as LadybugDB releases
  CC="${CC:-/usr/bin/clang}"
else
  CXX="${CXX:-g++}"                             # system g++: same libstdc++ as LadybugDB releases
  CC="${CC:-gcc}"
fi
OUT=build
mkdir -p "$OUT"

lake build Spike:static Elpi:static >/dev/null
SPIKE_A=.lake/build/lib/libmarien_x2dspike_Spike.a
ELPI_A=.lake/packages/lean-elpi/.lake/build/lib/liblean_x2delpi_Elpi.a

"$CC" -c -O2 -fPIC -fvisibility=hidden -I"$PREFIX/include" -o "$OUT/bridge.o" bridge.c
"$CXX" -c -std=c++20 -O2 -fPIC -fvisibility=hidden -fvisibility-inlines-hidden -DNDEBUG \
  -I"$LB/src/include" -I"$LBGEN/src/include" -o "$OUT/shim.o" shim.cpp

LIB="$OUT/libmarien_spike.lbug_extension"
"${SCRIPTS:-../scripts}/link-extension.sh" "$LIB" "$MODE" exports "$SPIKE_A" -- \
  "$OUT/shim.o" "$OUT/bridge.o" "$ELPI_A"
echo "built $LIB ($MODE)"
