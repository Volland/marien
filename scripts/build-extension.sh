#!/usr/bin/env bash
# @tg: implements:: [[openspec:distribution#Out-of-tree build]]
# Build Marien's extension from a clean checkout: fetch the headers of the pinned LadybugDB
# (scripts/ladybug-version), build the Lean archives with Lake, compile the C++ shim with CMake
# and link everything into ONE library, build/libmarien.lbug_extension, exporting only `init` and
# `name`. On Linux the Lean runtime archive is first rebuilt as PIC (scripts/build-leanrt-pic.sh).
# Needs the Lean toolchain (elan), a C++ compiler, CMake and `gh`.
#   scripts/build-extension.sh [strip|nostrip]
set -euo pipefail
cd "$(dirname "$0")/.."
scripts/fetch-ladybug.sh >/dev/null
if [ "$(uname -s)" = Linux ] && [ -z "${LEAN_RUNTIME_A:-}" ]; then
  export LEAN_RUNTIME_A="$(scripts/build-leanrt-pic.sh | tail -1)"
fi
shim/build.sh "${1:-strip}"
scripts/check-one-library.sh build
