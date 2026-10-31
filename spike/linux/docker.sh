#!/usr/bin/env bash
# Run the Linux leg of the spike in Docker (linux on the host's CPU architecture).
set -euo pipefail
cd "$(dirname "$0")/../.."
ARCH="$(uname -m | sed -e 's/arm64/aarch64/')"
VER="$(cat scripts/ladybug-version)"
mkdir -p .deps/cli-linux
( cd .deps/cli-linux
  [ -f liblbug.tar.gz ] || gh release download "v$VER" -R LadybugDB/ladybug -p "liblbug-linux-$ARCH.tar.gz" -O liblbug.tar.gz
  [ -f lbug_cli.tar.gz ] || gh release download "v$VER" -R LadybugDB/ladybug -p "lbug_cli-linux-$ARCH.tar.gz" -O lbug_cli.tar.gz )
docker run --rm -v "$PWD/spike:/src/spike:ro" -v "$PWD/scripts:/src/scripts:ro" -v "$PWD/.deps/ladybug:/src/ladybug:ro" \
  -v "$PWD/.deps/cli-linux:/src/cli-linux:ro" ubuntu:24.04 bash /src/spike/linux/run.sh
