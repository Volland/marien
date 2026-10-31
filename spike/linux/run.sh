#!/usr/bin/env bash
# Linux leg of the spike, run inside a fresh container (see linux/docker.sh):
# install the Lean toolchain, configure LadybugDB headers, rebuild the Lean runtime archive as
# PIC with global-dynamic TLS (scripts/build-leanrt-pic.sh), build the spike, run the checks.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq && apt-get install -y -qq curl git ca-certificates cmake g++ make python3 xz-utils binutils libssl-dev libgmp-dev libuv1-dev >/dev/null
curl -sSf https://raw.githubusercontent.com/leanprover/elan/master/elan-init.sh | sh -s -- -y --default-toolchain none >/dev/null
export PATH="$HOME/.elan/bin:$PATH"
mkdir -p /work && cp -r /src/scripts /work/scripts && cp -r /src/spike /work/spike && rm -rf /work/spike/.lake /work/spike/build
cp -r /src/ladybug /work/ladybug && rm -rf /work/ladybug/build
cd /work/ladybug && cmake -S . -B build/release -DCMAKE_BUILD_TYPE=Release >/dev/null
mkdir -p /work/cli && cd /work/cli && tar xzf /src/cli-linux/liblbug.tar.gz && tar xzf /src/cli-linux/lbug_cli.tar.gz
mkdir -p /work/.deps && ln -sfn /work/cli /work/.deps/cli
cd /work/spike && elan toolchain install "$(cat lean-toolchain)" >/dev/null 2>&1 || true
lake update >/dev/null 2>&1
echo "== PIC Lean runtime"
export LEAN_RUNTIME_A="$(/work/scripts/build-leanrt-pic.sh /work/.deps/leanrt-pic 2>/dev/null | tail -1)"
ar t "$LEAN_RUNTIME_A" | wc -l
echo "== toolchain libs"; ls "$(lean --print-prefix)/lib" "$(lean --print-prefix)/lib/lean" | grep -E "c\+\+|gmp|uv|leanrt" | tr "\n" " "; echo
echo "== build"
LADYBUG_SRC=/work/ladybug ./build.sh strip 2>&1 | tail -20
L=build/libmarien_spike.lbug_extension
echo "== deps"; ldd "$L" || true
echo "== exports"; nm -D --defined-only "$L"
echo "== undefined non-libc"; nm -D --undefined-only "$L" | grep -v -E "GLIBC|GCC_|CXXABI|GLIBCXX|_ZN4lbug|__gmon_start__|_ITM_|__cxa_finalize" || echo none
echo "== check-deps"; ../scripts/check-deps.sh "$L" || true
echo "== check-exports"; ../scripts/check-exports.sh "$L" || true
echo "== size"; stat -c%s "$L"; gzip -9c "$L" | wc -c
gcc -O2 -I/work/cli -o build/stress stress.c -L/work/cli -llbug -Wl,-rpath,/work/cli -lpthread
EXT=$PWD/$L
rm -rf /tmp/d && mkdir -p /tmp/d && ./build/stress load /tmp/d "$EXT"
MARIEN_SPIKE_FAIL_INIT=1 ./build/stress failinit /tmp/d "$EXT" | tail -1
./build/stress stress /tmp/d "$EXT" 16 1000
echo "== coexist"; ./coexist.sh "$L" | tail -2
echo "== cli"; printf "LOAD EXTENSION '%s';\nCALL lean_ping() RETURN answer;\n" "$EXT" | /work/cli/lbug /tmp/d/cli 2>&1 | grep -E "42|rror" || true
echo "== nostrip size"; LADYBUG_SRC=/work/ladybug ./build.sh nostrip >/dev/null 2>&1; stat -c%s "$L"; gzip -9c "$L" | wc -c
