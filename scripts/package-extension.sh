#!/usr/bin/env bash
# @tg: implements:: [[openspec:distribution#Install from extension server]]
# Lay out a built extension the way LadybugDB's `INSTALL marien FROM '<url>'` fetches it:
#   <out>/v<extension version>/<os>_<arch>/marien/libmarien.lbug_extension
# where the extension version is LadybugDB's LBUG_EXTENSION_VERSION (from the pinned source) and
# os_arch is osx_arm64, osx_amd64, linux_arm64 or linux_amd64. Prints the file's path.
#   package-extension.sh <extension> <out-dir>
set -euo pipefail
EXT="$1"; OUT="$2"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EXTVER="$(sed -nE 's/.*-DLBUG_EXTENSION_VERSION="([^"]+)".*/\1/p' "$ROOT/.deps/ladybug/CMakeLists.txt" | head -1)"
[ -n "$EXTVER" ] || { echo "cannot read LBUG_EXTENSION_VERSION from .deps/ladybug/CMakeLists.txt" >&2; exit 1; }
case "$(uname -s)" in Darwin) OS=osx ;; Linux) OS=linux ;; *) echo "unsupported OS" >&2; exit 1 ;; esac
case "$(uname -m)" in arm64|aarch64) ARCH=arm64 ;; x86_64|amd64) ARCH=amd64 ;; *) echo "unsupported CPU" >&2; exit 1 ;; esac
DEST="$OUT/v$EXTVER/${OS}_$ARCH/marien"
mkdir -p "$DEST"
cp "$EXT" "$DEST/libmarien.lbug_extension"
echo "$DEST/libmarien.lbug_extension"
