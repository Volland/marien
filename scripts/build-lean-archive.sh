#!/usr/bin/env bash
# Build the prebuilt Lean side of the extension, for builds without a Lean toolchain (upstream
# CI, ladybugdb/extensions): the runtime bridge (shim/lean_bridge.c), Marien's and LeanElpi's Lean
# archives and the Lean runtime, partially linked into one object in which every symbol except the
# bridge API (marien_bridge_*) is local, packed as a static archive with its header and a CMake
# package. On macOS GMP and libuv are a second object whose functions the Lean side calls stay
# global (see below); the extension's export list hides them.
#
#   <out>/lib/libmarien_lean.a
#   <out>/include/lean_bridge.h
#   <out>/lib/cmake/marien_lean/marien_lean-config.cmake    (IMPORTED target marien::lean)
#
# Usage: scripts/build-lean-archive.sh <out-dir>   Env: CC, LEAN_RUNTIME_A (Linux: the PIC runtime
# of scripts/build-leanrt-pic.sh, as for scripts/link-extension.sh)
# Consumed by `cmake -S shim -B <build> -DMARIEN_LEAN_ARCHIVE=<out-dir>` (shim/CMakeLists.txt).
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="$(mkdir -p "$1" && cd "$1" && pwd)"
PREFIX="$(lean --print-prefix)"
lake build Marien:static Elpi:static >/dev/null
MARIEN_A="$PWD/.lake/build/lib/libmarien_Marien.a"
ELPI_LIB="$(lake env printenv LEAN_PATH | tr ':' '\n' | grep 'lean-elpi.*/lib/lean$' | head -1)"
ELPI_A="${ELPI_LIB%/lean}/liblean_x2delpi_Elpi.a"
[ -f "$MARIEN_A" ] && [ -f "$ELPI_A" ] || { echo "Lean archives not found: $MARIEN_A $ELPI_A" >&2; exit 1; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$OUT/lib/cmake/marien_lean" "$OUT/include"

case "$(uname -s)" in
  Darwin)
    CC="${CC:-/usr/bin/clang}"
    "$CC" -c -O2 -fPIC -I"$PREFIX/include" -o "$TMP/lean_bridge.o" shim/lean_bridge.c
    nm -gU "$TMP/lean_bridge.o" | awk '{print $3}' | grep '^_marien_bridge_' > "$TMP/keep"
    # Two objects, because ld64 drops MH_SUBSECTIONS_VIA_SYMBOLS (and with it dead stripping in the
    # final link) when one input lacks it, as GMP's assembly does. marien_lean.o: the bridge,
    # Marien, LeanElpi and the Lean runtime, every symbol private extern except marien_bridge_*.
    ld -r -o "$TMP/marien_lean.o" "$TMP/lean_bridge.o" -force_load "$MARIEN_A" "$ELPI_A" \
      "$PREFIX/lib/lean/libLean.a" "$PREFIX/lib/lean/libInit.a" "$PREFIX/lib/lean/libStd.a" \
      "$PREFIX/lib/lean/libleanrt.a" -exported_symbols_list "$TMP/keep" 2> >(grep -v "built for newer" >&2)
    # marien_gmp_uv.o: the GMP and libuv members it calls. Their symbols stay global, since a
    # private extern definition is not in the archive's table of contents and would never be
    # pulled; the extension's export list hides them (shim/CMakeLists.txt, as link-extension.sh).
    nm -u "$TMP/marien_lean.o" | sort -u > "$TMP/undef"
    { nm -gU "$PREFIX/lib/libgmp.a"; nm -gU "$PREFIX/lib/libuv.a"; } 2>/dev/null | awk 'NF==3 {print $3}' | sort -u > "$TMP/gmpuv"
    comm -12 "$TMP/undef" "$TMP/gmpuv" > "$TMP/need"
    "$CC" -r -nostdlib -o "$TMP/marien_gmp_uv.o" $(sed 's/^/-Wl,-u,/' "$TMP/need") \
      "$PREFIX/lib/libgmp.a" "$PREFIX/lib/libuv.a" -Wl,-exported_symbols_list,"$TMP/need" \
      2> >(grep -v "built for newer" >&2)
    OBJS=("$TMP/marien_lean.o" "$TMP/marien_gmp_uv.o")
    LINK_LIBS=""
    ;;
  *)
    CC="${CC:-gcc}"
    "$CC" -c -O2 -fPIC -I"$PREFIX/include" -o "$TMP/lean_bridge.o" shim/lean_bridge.c
    LEANRT="${LEAN_RUNTIME_A:-$PREFIX/lib/lean/libleanrt.a}"
    CXXRT=("$PREFIX/lib/libc++.a" "$PREFIX/lib/libc++abi.a"); [ -n "${LEAN_RUNTIME_A:-}" ] && CXXRT=()
    ld -r -o "$TMP/marien_lean.o" "$TMP/lean_bridge.o" --whole-archive "$MARIEN_A" --no-whole-archive \
      --start-group "$ELPI_A" "$PREFIX/lib/lean/libLean.a" "$PREFIX/lib/lean/libInit.a" \
      "$PREFIX/lib/lean/libStd.a" "$LEANRT" "$PREFIX/lib/libgmp.a" "$PREFIX/lib/libuv.a" \
      ${CXXRT[@]+"${CXXRT[@]}"} --end-group
    nm -g --defined-only "$TMP/marien_lean.o" | awk '{print $3}' | grep '^marien_bridge_' > "$TMP/keep"
    # with the host's libstdc++ (LEAN_RUNTIME_A), weak and unique symbols stay global for the
    # final link; the extension's version script still hides them (scripts/link-extension.sh)
    [ -z "${LEAN_RUNTIME_A:-}" ] || nm -g --defined-only "$TMP/marien_lean.o" | awk '$2 ~ /^[WVu]$/ {print $3}' >> "$TMP/keep"
    objcopy --keep-global-symbols="$TMP/keep" "$TMP/marien_lean.o"
    OBJS=("$TMP/marien_lean.o")
    LINK_LIBS="pthread;dl;m"
    ;;
esac

rm -f "$OUT/lib/libmarien_lean.a"
# Apple's libtool aligns large members, which BSD ar does not
if [ "$(uname -s)" = Darwin ]; then libtool -static -o "$OUT/lib/libmarien_lean.a" "${OBJS[@]}"
else ar rcs "$OUT/lib/libmarien_lean.a" "${OBJS[@]}"; fi
cp shim/lean_bridge.h "$OUT/include/"
cat > "$OUT/lib/cmake/marien_lean/marien_lean-config.cmake" <<CMAKE
# Marien's prebuilt Lean side (scripts/build-lean-archive.sh): the runtime bridge, Marien,
# LeanElpi and the Lean runtime in one object whose only global symbols are marien_bridge_*.
get_filename_component(_marien_lean_root "\${CMAKE_CURRENT_LIST_DIR}/../../.." ABSOLUTE)
if(NOT TARGET marien::lean)
  add_library(marien::lean STATIC IMPORTED)
  set_target_properties(marien::lean PROPERTIES
    IMPORTED_LOCATION "\${_marien_lean_root}/lib/libmarien_lean.a"
    INTERFACE_INCLUDE_DIRECTORIES "\${_marien_lean_root}/include"
    INTERFACE_LINK_LIBRARIES "$LINK_LIBS")
endif()
set(MARIEN_LEAN_VERSION "$(sed -n 's/.*version := v!"\(.*\)".*/\1/p' lakefile.lean)")
CMAKE
echo "built $OUT/lib/libmarien_lean.a ($(nm -g "$OUT/lib/libmarien_lean.a" 2>/dev/null | grep -c ' T _*marien_bridge_') bridge functions global)"
