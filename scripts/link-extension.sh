#!/usr/bin/env bash
# @tg: implements:: [[openspec:extension-runtime#Single Lean runtime per process]]
# Link a LadybugDB extension that carries its own Lean runtime, as ONE shared library:
#   link-extension.sh <out> <strip|nostrip> <exports-base> <whole-archive.a> -- <objects/archives...>
# <whole-archive.a> is the extension's own Lean library (kept whole so its @[export]s survive);
# the rest are objects and archives linked normally, followed by the Lean runtime archives.
# LadybugDB symbols stay undefined and resolve against the host, as for official extensions.
# libleancpp is never linked: the runtime bridge defines a runtime-only lean_initialize.
# KEEP_SYMBOLS=1 skips stripping, for debugging crashes inside the extension.
set -euo pipefail
OUT="$1"; MODE="$2"; EXPORTS="$3"; WHOLE="$4"; shift 4
[ "$1" = "--" ] && shift
PREFIX="$(lean --print-prefix)"
RUNTIME=(-L"$PREFIX/lib/lean" -L"$PREFIX/lib" -lLean -lInit -lStd -lleanrt -lgmp -luv)
case "$(uname -s)" in
  Darwin)
    CXX="${CXX:-/usr/bin/clang++}"
    GC=(); [ "$MODE" = strip ] && GC=(-Wl,-dead_strip)
    # @tg: implements:: [[openspec:extension-runtime#Only the init symbol is exported]]
    "$CXX" -shared -fPIC -o "$OUT" "$@" -Wl,-force_load,"$WHOLE" "${RUNTIME[@]}" \
      -Wl,-undefined,dynamic_lookup -Wl,-exported_symbols_list,"$EXPORTS.txt" \
      ${GC[@]+"${GC[@]}"} -Wl,-dead_strip_dylibs 2> >(grep -v "built for newer" >&2)
    [ -n "${KEEP_SYMBOLS:-}" ] || strip -x "$OUT"
    codesign -s - -f "$OUT" 2>/dev/null
    ;;
  *)
    # Linux: partially link the Lean side (bridge, Lean archives) into one object and localize
    # every symbol except the bridge API (marien_bridge_*), so nothing of the Lean runtime can
    # bind to or be bound by LadybugDB or another extension.
    # The toolchain's libleanrt.a uses local-exec TLS (it crashes once dlopen'ed) and its own
    # libc++. LEAN_RUNTIME_A names a replacement built by build-leanrt-pic.sh (PIC,
    # global-dynamic TLS, libstdc++); with it the Lean side uses the host's libstdc++. Without
    # it the toolchain's libc++ and libc++abi are linked in and localized too.
    CXX="${CXX:-g++}"
    GC=(); [ "$MODE" = strip ] && GC=(-Wl,--gc-sections)
    TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
    CPP_OBJS=(); LEAN_IN=()
    for f in "$@"; do
      case "$f" in *.a) LEAN_IN+=("$f") ;; *bridge*.o) LEAN_IN+=("$f") ;; *) CPP_OBJS+=("$f") ;; esac
    done
    LEANRT="${LEAN_RUNTIME_A:-$PREFIX/lib/lean/libleanrt.a}"
    CXXRT=("$PREFIX/lib/libc++.a" "$PREFIX/lib/libc++abi.a"); [ -n "${LEAN_RUNTIME_A:-}" ] && CXXRT=()
    ld -r -o "$TMP/lean.o" --whole-archive "$WHOLE" --no-whole-archive \
      --start-group "${LEAN_IN[@]}" "$PREFIX/lib/lean/libLean.a" "$PREFIX/lib/lean/libInit.a" \
      "$PREFIX/lib/lean/libStd.a" "$LEANRT" "$PREFIX/lib/libgmp.a" \
      "$PREFIX/lib/libuv.a" ${CXXRT[@]+"${CXXRT[@]}"} --end-group
    nm -g --defined-only "$TMP/lean.o" | awk '{print $3}' | grep '^marien_bridge_' > "$TMP/keep"
    # With libstdc++ on both sides, weak and unique symbols (COMDAT template instantiations
    # shared with the shim) must stay global for the final link; the version script still
    # hides them from the dynamic symbol table.
    [ -z "${LEAN_RUNTIME_A:-}" ] || nm -g --defined-only "$TMP/lean.o" | awk '$2 ~ /^[WVu]$/ {print $3}' >> "$TMP/keep"
    objcopy --keep-global-symbols="$TMP/keep" "$TMP/lean.o"
    "$CXX" -shared -fPIC -o "$OUT" "${CPP_OBJS[@]}" "$TMP/lean.o" \
      -Wl,--version-script="$EXPORTS.map" ${GC[@]+"${GC[@]}"} -Wl,--as-needed -lpthread -ldl -lm
    [ -n "${KEEP_SYMBOLS:-}" ] || strip --strip-unneeded "$OUT"
    ;;
esac
