#!/usr/bin/env bash
# The prebuilt Lean side end to end: build it (scripts/build-lean-archive.sh), build the extension
# from it with no Lean toolchain on PATH (shim/CMakeLists.txt, -DMARIEN_LEAN_ARCHIVE), check that the
# archive's only global symbols are the bridge API (and, on macOS, the GMP and libuv functions the
# Lean side calls), and run the binary checks and the integration tests against that extension.
# Usage: scripts/test-lean-archive.sh   Env: LBUG_DIR (default .deps/cli), LEAN_RUNTIME_A (Linux)
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=build/lean-archive
scripts/build-lean-archive.sh "$OUT"
case "$(uname -s)" in
  Darwin) GLOBALS=$(nm -gU "$OUT/lib/libmarien_lean.a" | awk 'NF==3 {print $3}' | grep -v '^_marien_bridge_' | grep -v '^___gmp\|^_uv_' || true)
          CC=/usr/bin/clang; CXX=/usr/bin/clang++ ;;
  *)      GLOBALS=$(nm -g --defined-only "$OUT/lib/libmarien_lean.a" | awk 'NF==3 && $2 ~ /[TDBR]/ {print $3}' | grep -v '^marien_bridge_' || true)
          CC=${CC:-gcc}; CXX=${CXX:-g++} ;;
esac
[ -z "$GLOBALS" ] || { echo "FAIL: global symbols besides the bridge API:"; echo "$GLOBALS" | head; exit 1; }
echo "PASS: the archive exports only the bridge API"
# no lean, lake or elan on PATH: only CMake, the C++ compiler and the system tools
CLEAN_PATH=$(echo "$PATH" | tr ':' '\n' | grep -v '\.elan' | paste -sd: -)
rm -rf build/shim-prebuilt
env PATH="$CLEAN_PATH" bash -c "! command -v lake >/dev/null && cmake -S shim -B build/shim-prebuilt -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_C_COMPILER=$CC -DCMAKE_CXX_COMPILER=$CXX -DMARIEN_LEAN_ARCHIVE=$PWD/$OUT >/dev/null && cmake --build build/shim-prebuilt --parallel >/dev/null"
EXT="$PWD/build/shim-prebuilt/libmarien.lbug_extension"
echo "PASS: built $EXT without a Lean toolchain"
scripts/check-exports.sh "$EXT"
scripts/check-deps.sh "$EXT"
scripts/check-size.sh "$EXT"
LBUG="${LBUG_DIR:-.deps/cli}"
mkdir -p build/integration
cc -O1 -g -std=gnu11 -I"$LBUG" -o build/integration/integration tests/integration/integration.c \
  -L"$LBUG" -llbug -lpthread -Wl,-rpath,"$PWD/$LBUG"
[ -f build/integration/mismatch.lbug_extension ] && export MARIEN_MISMATCH_EXT="$PWD/build/integration/mismatch.lbug_extension"
build/integration/integration "$EXT" "$PWD/build/integration"
