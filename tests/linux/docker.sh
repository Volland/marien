#!/usr/bin/env bash
# Run the Linux leg of the tracer bullet (tests/linux/run.sh) in a fresh Ubuntu 24.04 container,
# on the host's CPU architecture. Needs the LadybugDB source in .deps/ladybug (scripts/fetch-ladybug.sh
# or a plain clone at the pinned tag) and `gh` to download LadybugDB's Linux release. The built
# extension lands in build/linux/.
set -euo pipefail
cd "$(dirname "$0")/../.."
ARCH="$(uname -m | sed -e 's/arm64/aarch64/')"
VER="$(cat scripts/ladybug-version)"
mkdir -p .deps/cli-linux
( cd .deps/cli-linux
  [ -f liblbug.tar.gz ] || gh release download "v$VER" -R LadybugDB/ladybug -p "liblbug-linux-$ARCH.tar.gz" -O liblbug.tar.gz
  [ -f lbug_cli.tar.gz ] || gh release download "v$VER" -R LadybugDB/ladybug -p "lbug_cli-linux-$ARCH.tar.gz" -O lbug_cli.tar.gz )
mkdir -p build/linux
docker run --rm -e MARIEN_NEW_PLATFORM -v "$PWD:/src:ro" -v "$PWD/build/linux:/out" ubuntu:24.04 bash /src/tests/linux/run.sh
