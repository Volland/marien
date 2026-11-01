#!/usr/bin/env bash
# @tg: verifies:: [[openspec:extension-runtime#Only the init symbol is exported#Coexists with another extension]] {level: integration}
# Load the extension together with LadybugDB's fts and vector extensions, use all three, and
# check with the dynamic linker's binding log (dyld on macOS, LD_DEBUG on Linux) that no image
# binds into ours and ours binds only to the OS runtime and LadybugDB. (The official `algo` 0.22 package cannot load on macOS: its
# libnetworkit.dylib rpath points at the CI runner; see spike/RESULT.md.)
#   spike/coexist.sh <extension>
set -euo pipefail
EXT="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
cd "$(dirname "$0")/.."
LBUG=.deps/cli/lbug
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
out=$("$LBUG" "$T/db" <<EOQ 2>&1
INSTALL fts; INSTALL vector;
LOAD fts; LOAD vector;
LOAD EXTENSION '$EXT';
CREATE NODE TABLE Doc(id INT64 PRIMARY KEY, body STRING, emb FLOAT[3]);
CREATE (:Doc {id:1, body:'lean meets ladybug', emb:[1.0,0.0,0.0]}), (:Doc {id:2, body:'graph rules', emb:[0.0,1.0,0.0]});
CALL create_fts_index('Doc', 'docidx', ['body']);
CALL query_fts_index('Doc', 'docidx', 'ladybug') RETURN 'fts:' + CAST(node.id AS STRING) AS r;
CALL create_vector_index('Doc', 'vidx', 'emb');
CALL query_vector_index('Doc', 'vidx', [0.9,0.1,0.0], 1) RETURN 'vec:' + CAST(node.id AS STRING) AS r;
CALL lean_ping() RETURN 'lean:' + answer AS r;
EOQ
)
for want in fts:1 vec:1 lean:42; do
  echo "$out" | grep -q "$want" || { echo "FAIL: missing $want"; echo "$out" | tail -20; exit 1; }
done
echo "ok: fts, vector and the extension all answer in one database"
if [ "$(uname -s)" = Darwin ]; then
  mkdir -p "$T/b"
  /usr/bin/clang -O2 -I.deps/cli -o "$T/stress" spike/stress.c -L.deps/cli -llbug -Wl,-rpath,"$PWD/.deps/cli"
  DYLD_PRINT_BINDINGS=1 "$T/stress" load "$T/b" "$EXT" > "$T/bind.log" 2>&1
  name=$(basename "$EXT")
  # dyld writes "-> 0x… <lib/sym>" up to macOS 14 and "-> 0x… (lib/sym)" from macOS 15
  into=$(grep -E "<[^/]+/bind#[0-9]+> -> 0x[0-9a-f]+ [<(]$name/" "$T/bind.log" | grep -vc "<$name/bind" || true)
  targets=$(grep -E "<$name/bind#[0-9]+> -> 0x" "$T/bind.log" | sed -E 's/.*-> 0x[0-9a-f]+ [<(]([^/]+)\/.*/\1/' | sort -u)
  bad=$(echo "$targets" | grep -v -E '^(libc\+\+\.1\.dylib|libc\+\+abi\.dylib|libsystem_[a-z_]+\.dylib|libdyld\.dylib|libunwind\.dylib|libcommonCrypto\.dylib|liblbug[.0-9]*\.dylib|lbug)$' || true)
  [ "$into" = 0 ] || { echo "FAIL: $into binds from other images into the extension"; exit 1; }
  [ -z "$bad" ] || { echo "FAIL: extension binds into: $bad"; exit 1; }
  echo "ok: no image binds into the extension; it binds only to: $(echo $targets)"
else
  mkdir -p "$T/b"
  gcc -O2 -I.deps/cli -o "$T/stress" spike/stress.c -L.deps/cli -llbug -Wl,-rpath,"$PWD/.deps/cli" -lpthread
  LD_DEBUG=bindings LD_DEBUG_OUTPUT="$T/bind" "$T/stress" load "$T/b" "$EXT" > /dev/null
  cat "$T"/bind.* > "$T/bind.log"
  into=$(grep -E "binding file [^ ]+ \[[0-9]+\] to $EXT " "$T/bind.log" | grep -vc "binding file $EXT " || true)
  targets=$(grep -E "binding file $EXT \[[0-9]+\] to " "$T/bind.log" | sed -E 's/.* to ([^ ]+) \[.*/\1/' | xargs -n1 basename | sort -u)
  # the extension "binds to itself" only for the loader's dlsym of init and name
  bad=$(echo "$targets" | grep -v -x -F "$(basename "$EXT")" | grep -v -E '^(libc\.so\.6|libm\.so\.6|libstdc\+\+\.so\.6|libgcc_s\.so\.1|ld-linux[-a-z0-9_]*\.so\.[0-9]|liblbug\.so[.0-9]*|stress)$' || true)
  [ "$into" = 0 ] || { echo "FAIL: $into binds from other images into the extension"; exit 1; }
  [ -z "$bad" ] || { echo "FAIL: extension binds into: $bad"; exit 1; }
  echo "ok: no image binds into the extension; it binds only to: $(echo $targets)"
fi
echo PASS
