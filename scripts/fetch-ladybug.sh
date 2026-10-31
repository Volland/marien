#!/usr/bin/env bash
# Fetch the pinned LadybugDB (scripts/ladybug-version) into .deps/: the source at that tag,
# configured with CMake so the generated headers exist (they are part of the extension ABI),
# and the release CLI and shared library for this platform, used as the extension host.
set -euo pipefail
cd "$(dirname "$0")/.."
VER="$(cat scripts/ladybug-version)"
mkdir -p .deps
if [ ! -d .deps/ladybug/.git ]; then
  git clone -q --depth 1 --branch "v$VER" https://github.com/LadybugDB/ladybug .deps/ladybug
fi
if [ ! -f .deps/ladybug/build/release/src/include/common/system_config.h ]; then
  if [ "$(uname -s)" = Darwin ]; then CC=/usr/bin/clang CXX=/usr/bin/clang++; else CC=gcc CXX=g++; fi
  cmake -S .deps/ladybug -B .deps/ladybug/build/release -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" >/dev/null
fi
case "$(uname -s)-$(uname -m)" in
  Darwin-arm64) PLAT=osx-arm64 ;; Darwin-x86_64) PLAT=osx-x86_64 ;;
  Linux-aarch64) PLAT=linux-aarch64 ;; Linux-x86_64) PLAT=linux-x86_64 ;;
  *) echo "unsupported platform" >&2; exit 1 ;;
esac
mkdir -p .deps/cli
if [ ! -x .deps/cli/lbug ]; then
  ( cd .deps/cli && gh release download "v$VER" -R LadybugDB/ladybug \
      -p "lbug_cli-$PLAT.tar.gz" -p "liblbug-$PLAT.tar.gz" --clobber && for f in *.tar.gz; do tar xzf "$f"; done )
fi
echo "LadybugDB $VER ready in .deps/ (source, generated headers, host CLI and liblbug)"
