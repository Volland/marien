#!/usr/bin/env bash
# marien-codegen end to end: the dump a real LadybugDB wrote (tests/integration/run.sh, test
# "dump is canonical", leaves it in build/integration/dump-rich.json), the emitted module built
# with `lake env lean`, and the exit codes of a usage error and of a schema the tool rejects.
# Usage: tests/offline/run.sh [dump.json]
set -euo pipefail
cd "$(dirname "$0")/../.."
DUMP="${1:-build/integration/dump-rich.json}"
[ -f "$DUMP" ] || { echo "no dump at $DUMP: run tests/integration/run.sh 'dump is canonical' first" >&2; exit 2; }
OUT=build/offline
mkdir -p "$OUT"
lake build marien-codegen >/dev/null
fail=0
pass() { echo "PASS $1"; }
flunk() { echo "FAIL $1"; fail=1; }

if lake exe marien-codegen "$DUMP" -o "$OUT/Schema.lean" >"$OUT/codegen.log" 2>&1 \
   && lake env lean "$OUT/Schema.lean" >"$OUT/build.log" 2>&1; then
  pass "module from a LadybugDB dump builds"
else
  flunk "module from a LadybugDB dump builds"; cat "$OUT/codegen.log" "$OUT/build.log"
fi

set +e
lake exe marien-codegen >/dev/null 2>&1; code=$?
set -e
[ "$code" = 2 ] && pass "usage error exits 2" || flunk "usage error exits 2 (got $code)"

printf '%s' '{"annotations":[],"format":"marien.schema/1","nodes":[{"key":"id","name":"Rec","properties":[{"name":"id","type":"INT64"}]}],"rels":[]}' >"$OUT/rec.json"
set +e
msg=$(lake exe marien-codegen "$OUT/rec.json" -o "$OUT/Rec.lean" 2>&1); code=$?
set -e
if [ "$code" = 1 ] && grep -q "rename" <<<"$msg" && [ ! -f "$OUT/Rec.lean" ]; then
  pass "rejected schema exits 1 and writes nothing"
else
  flunk "rejected schema exits 1 and writes nothing (got $code: $msg)"
fi
exit $fail
