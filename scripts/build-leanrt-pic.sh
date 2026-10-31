#!/usr/bin/env bash
# @tg: implements:: [[openspec:extension-runtime#Single Lean runtime per process]] {confidence: partial, note: "the Linux Lean runtime archive, dlopen-safe"}
# Rebuild the active toolchain's Lean runtime archive (libleanrt.a) for an extension on Linux.
# The toolchain's copy uses local-exec TLS, which is valid only in the main executable, and is
# compiled against the toolchain's own libc++. This rebuilds the same sources at the toolchain's
# tag with -fPIC, global-dynamic TLS and the system g++/libstdc++ (the C++ runtime LadybugDB
# uses), against the toolchain's own lean/config.h, lean.h and mimalloc.h, so the Lean code in
# libInit/libStd/libLean (plain C over lean.h) links against it unchanged.
#
# Usage: scripts/build-leanrt-pic.sh [out-dir]   (default: .deps/leanrt-pic)
# Needs: git, g++, and the headers of the toolchain's GMP, libuv and OpenSSL 3
# (Ubuntu: libgmp-dev libuv1-dev libssl-dev). Prints the archive path.
set -euo pipefail
OUT="$(mkdir -p "${1:-.deps/leanrt-pic}" && cd "${1:-.deps/leanrt-pic}" && pwd)"
CXX="${CXX:-g++}"
PREFIX="$(lean --print-prefix)"
VER="v$(lean --version | sed -E 's/^Lean \(version ([0-9][^,]*),.*/\1/')"
MI="$(sed -nE 's/^#define MI_MALLOC_VERSION ([0-9])([0-9]{2})([0-9]{2}).*/v\1.\2.\3/p' \
  "$PREFIX/include/lean/mimalloc.h" | sed -E 's/\.0([0-9])/.\1/g')"

SRC="$OUT/lean4-$VER"
if [ ! -d "$SRC/src/runtime" ]; then
  rm -rf "$SRC"
  git clone -q --depth 1 --branch "$VER" --filter=blob:none --sparse \
    https://github.com/leanprover/lean4 "$SRC" 2>/dev/null
  git -C "$SRC" sparse-checkout set --no-cone /src/runtime/ /src/util/ /src/githash.h.in
fi
MISRC="$OUT/mimalloc-$MI"
[ -d "$MISRC/src" ] || git clone -q --depth 1 --branch "$MI" https://github.com/microsoft/mimalloc \
  "$MISRC" 2>/dev/null

# The same githash the toolchain's runtime returns from lean_get_githash.
GEN="$OUT/gen"; OBJ="$OUT/obj"; rm -rf "$OBJ"; mkdir -p "$GEN" "$OBJ/uv"
HASH="$(cd "$OBJ" && ar x "$PREFIX/lib/lean/libleanrt.a" platform.cpp.o && strings platform.cpp.o \
  | grep -E -m1 '^[0-9a-f]{40}$' || true)"; rm -f "$OBJ/platform.cpp.o"
sed "s/@GIT_SHA1@/$HASH/" "$SRC/src/githash.h.in" > "$GEN/githash.h"

# Flags of the toolchain's Release build (src/CMakeLists.txt), except the TLS model and libc++.
FLAGS=(-std=c++20 -O3 -DNDEBUG -fPIC -ftls-model=global-dynamic -ffp-contract=off -w
  -DLEAN_MMAP -DLEAN_MULTI_THREAD -DLEAN_USE_GMP '-DLEAN_BUILD_TYPE="Release"' -DLEAN_EXPORTING
  -I"$SRC/src" -I"$GEN" -I"$PREFIX/include")
OBJS="$(awk '/^  RUNTIME_OBJS$/{f=1;next} f&&/^\)/{exit} f{print $1}' "$SRC/src/runtime/CMakeLists.txt")"
export CXX OBJ SRC; export FLAGS_STR="${FLAGS[*]}"
printf '%s\n' $OBJS | xargs -P "$(nproc)" -I{} bash -c \
  'eval "set -- $FLAGS_STR"; "$CXX" "$@" -c "$SRC/src/runtime/{}" -o "$OBJ/{}.o"'
# mimalloc, compiled into the runtime as the toolchain does (MIMALLOC_OPTS, LEAN_MI_SECURE=0).
"$CXX" "${FLAGS[@]}" -I"$MISRC/include" -I"$MISRC/src" -DMI_SHARED_LIB -DMI_SHARED_LIB_EXPORT \
  -DMI_WIN_NOREDIRECT -DMI_MAX_ALIGN_SIZE=8 -DMI_SECURE=0 -fno-semantic-interposition \
  -c "$SRC/src/runtime/mimalloc.cpp" -o "$OBJ/mimalloc.cpp.o"

rm -f "$OUT/libleanrt.a"
ar rcs "$OUT/libleanrt.a" $(find "$OBJ" -name '*.o' | sort)
# Refuse an archive that still carries executable-only TLS relocations.
if readelf -rW "$OUT/libleanrt.a" | grep -qE 'TLSLE|TPREL'; then
  echo "error: $OUT/libleanrt.a still has local-exec TLS relocations" >&2; exit 1
fi
echo "$OUT/libleanrt.a"
