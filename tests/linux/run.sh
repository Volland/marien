#!/usr/bin/env bash
# Linux leg of the tracer bullet, run inside a fresh Ubuntu 24.04 container (tests/linux/docker.sh):
# install the Lean toolchain, configure the LadybugDB headers, run the Lean tests, rebuild the Lean
# runtime archive as PIC with global-dynamic TLS (scripts/build-leanrt-pic.sh), build the
# extension with it, check its dependencies, exports and size, run the integration tests, then
# build the prebuilt Lean archive and test the extension built from it without Lean.
# The repository is mounted read-only at $SRC (default /src), LadybugDB's source at
# $SRC/.deps/ladybug and its Linux release (liblbug and the CLI) at $SRC/.deps/cli-linux;
# everything is built under /work.
set -euo pipefail
SRC="${SRC:-/src}"
export DEBIAN_FRONTEND=noninteractive
if ! command -v cmake >/dev/null; then
  apt-get update -qq && apt-get install -y -qq curl git ca-certificates cmake g++ make python3 \
    xz-utils binutils libssl-dev libgmp-dev libuv1-dev >/dev/null
fi
[ -x "$HOME/.elan/bin/elan" ] || curl -sSf https://raw.githubusercontent.com/leanprover/elan/master/elan-init.sh \
  | sh -s -- -y --default-toolchain none >/dev/null
export PATH="$HOME/.elan/bin:$PATH"

W=/work/marien
mkdir -p "$W"
tar -C "$SRC" --exclude=./.lake --exclude=./build --exclude=./.deps --exclude=./spike -cf - . | tar -C "$W" -xf -
mkdir -p "$W/.deps"
if [ ! -f "$W/.deps/ladybug/build/release/src/include/common/system_config.h" ]; then
  rm -rf "$W/.deps/ladybug" && cp -r "$SRC/.deps/ladybug" "$W/.deps/ladybug" && rm -rf "$W/.deps/ladybug/build"
  cmake -S "$W/.deps/ladybug" -B "$W/.deps/ladybug/build/release" -DCMAKE_BUILD_TYPE=Release >/dev/null
fi
mkdir -p "$W/.deps/cli"
( cd "$W/.deps/cli" && for f in "$SRC"/.deps/cli-linux/*.tar.gz; do tar xzf "$f"; done )

cd "$W"
elan toolchain install "$(cat lean-toolchain)" >/dev/null 2>&1 || true
echo "== Lean tests"
lake test
echo "== PIC Lean runtime"
export LEAN_RUNTIME_A="$(scripts/build-leanrt-pic.sh "$W/.deps/leanrt-pic" | tail -1)"
echo "$LEAN_RUNTIME_A"
echo "== build"
shim/build.sh strip
L=build/libmarien.lbug_extension
scripts/check-one-library.sh build
scripts/check-deps.sh "$L"
scripts/check-exports.sh "$L"
scripts/check-size.sh "$L"
echo "== integration"
tests/integration/run.sh
tests/offline/run.sh
tests/differential/run.sh "${PROPERTY_CASES:-1000}"
if [ "${MARIEN_ORACLE:-}" = 1 ]; then
  # The Soufflé oracle (tests/oracle/souffle/run.sh). Soufflé publishes x86_64 packages only, so
  # it is built from its 2.5 tag here; the oracle runs Soufflé's interpreter, no C++ per program.
  echo "== Soufflé oracle"
  if ! command -v souffle >/dev/null; then
    apt-get install -y -qq bison flex libffi-dev libsqlite3-dev zlib1g-dev libncurses-dev >/dev/null
    [ -d /work/souffle ] || git clone -q --depth 1 --branch 2.5 https://github.com/souffle-lang/souffle /work/souffle
    cmake -S /work/souffle -B /work/souffle/build -DCMAKE_BUILD_TYPE=Release -DSOUFFLE_ENABLE_TESTING=OFF \
      -DSOUFFLE_USE_OPENMP=OFF >/dev/null
    cmake --build /work/souffle/build --parallel "$(nproc)" --target souffle >/dev/null
    export SOUFFLE=/work/souffle/build/src/souffle
  fi
  tests/oracle/souffle/run.sh --self-test
  tests/oracle/souffle/run.sh "${ORACLE_CASES:-200}"
fi
scripts/test-install.sh "$L"
# The prebuilt Lean side for builds without Lean (scripts/build-lean-archive.sh): built with the PIC
# runtime above, then the extension is rebuilt from it with no Lean on PATH and tested again.
echo "== prebuilt Lean archive"
scripts/test-lean-archive.sh
# hand the extension and the archive to the host when it mounted /out (tests/linux/docker.sh)
if [ -d /out ] && [ -w /out ]; then
  cp "$L" /out/libmarien.lbug_extension
  tar -C build/lean-archive -czf /out/marien-lean.tar.gz include lib
fi
