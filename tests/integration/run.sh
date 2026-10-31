#!/usr/bin/env bash
# Build the extension and the integration harness, then run the harness against liblbug.
# Usage: tests/integration/run.sh [filter]   Env: LBUG_DIR (lbug.h and liblbug, default .deps/cli)
set -euo pipefail
cd "$(dirname "$0")/../.."
LBUG="${LBUG_DIR:-.deps/cli}"
shim/build.sh >/dev/null
mkdir -p build/integration
cc -O1 -g -std=gnu11 -I"$LBUG" -o build/integration/integration tests/integration/integration.c \
  -L"$LBUG" -llbug -lpthread -Wl,-rpath,"$PWD/$LBUG"
build/integration/integration "$PWD/build/libmarien.lbug_extension" "$PWD/build/integration" "${1:-}"
