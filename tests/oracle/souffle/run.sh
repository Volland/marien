#!/usr/bin/env bash
# The Soufflé oracle: for each seed, `marien-gen oracle` writes a case (schema and graph, the
# modules, and per target a Soufflé program over the generated facts, or SKIP with the reason
# the module is outside the fragment), `property rows` writes Marien's answers in an embedded
# LadybugDB, and Soufflé's answers are compared with them as multisets. Targets: full (validation
# at full scope), part (the same module partitioned, against Soufflé at full scope), narrow-full
# and narrow (the reasoning predicate q at full and at a narrowed scope).
#
# A difference fails the run and leaves a reproducer (schema, facts, module, query, both answer
# sets) under tests/oracle/souffle/failures/. Skips and refusals are counted, so coverage shows.
#
# Usage: tests/oracle/souffle/run.sh [cases] [size]      the random cases, seeds 1..cases
#        tests/oracle/souffle/run.sh --self-test          an injected fault must leave a reproducer
# Env: LBUG_DIR (lbug.h and liblbug, default .deps/cli), SOUFFLE (default souffle on PATH),
#      FAILURES (default tests/oracle/souffle/failures)
# @tg: implements:: [[openspec:differential-testing#Soufflé oracle]] {note: "the harness: both engines, multiset comparison, reproducers"}
set -euo pipefail
cd "$(dirname "$0")/../../.."
LBUG="${LBUG_DIR:-.deps/cli}"
SOUFFLE="${SOUFFLE:-souffle}"
FAILURES="${FAILURES:-tests/oracle/souffle/failures}"
command -v "$SOUFFLE" >/dev/null || { echo "souffle not found (set SOUFFLE)" >&2; exit 2; }
[ -f build/libmarien.lbug_extension ] || shim/build.sh >/dev/null
lake build marien-gen >/dev/null
mkdir -p build/oracle
cc -O1 -g -std=gnu11 -I"$LBUG" -o build/oracle/property tests/differential/property.c \
  -L"$LBUG" -llbug -lpthread -Wl,-rpath,"$PWD/$LBUG"
GEN=.lake/build/bin/marien-gen
EXT="$PWD/build/libmarien.lbug_extension"

agree=0; differ=0; skipped=0; refused=0
REASONS=build/oracle/skip-reasons.txt
: >"$REASONS"

# compare <case-dir> <target> <marien-rows-file> <label>: 0 agree, 1 differ
compare() {
  local dir=$1 t=$2 rows=$3 label=$4
  local td="$dir/$t"
  rm -rf "$td/out"; mkdir -p "$td/out"
  if ! "$SOUFFLE" -F "$td/facts" -D "$td/out" "$td/prog.dl" >"$td/souffle.log" 2>&1; then
    echo "FAIL $label: souffle failed"; cat "$td/souffle.log"; return 1
  fi
  : >"$td/souffle.rows"
  while read -r rel k; do
    [ -s "$td/out/$rel.csv" ] && cut -f1-"$k" "$td/out/$rel.csv" | tr '\t' '|' >>"$td/souffle.rows"
  done <"$td/outputs"
  LC_ALL=C sort -o "$td/souffle.rows" "$td/souffle.rows"
  LC_ALL=C sort "$rows" >"$td/marien.sorted"
  if cmp -s "$td/souffle.rows" "$td/marien.sorted"; then return 0; fi
  echo "FAIL $label: Marien and Soufflé disagree ($(wc -l <"$td/marien.sorted" | tr -d ' ') vs $(wc -l <"$td/souffle.rows" | tr -d ' ') rows)"
  diff "$td/marien.sorted" "$td/souffle.rows" | head -10 || true
  return 1
}

# reproducer <case-dir> <target> <name>: schema, facts, module, query and both answer sets
reproducer() {
  local dir=$1 t=$2 name=$3
  local out="$FAILURES/$name"
  rm -rf "$out"; mkdir -p "$out"
  cp "$dir/schema.cypher" "$dir/case.txt" "$out/"
  cp -R "$dir/$t/facts" "$out/facts"
  cp "$dir/$t/module.elpi" "$dir/$t/query.txt" "$dir/$t/prog.dl" "$dir/$t/souffle.rows" "$out/"
  cp "$dir/$t/marien.sorted" "$out/marien.rows"
  echo "  reproducer: $out"
}

# one_case <seed> <size> <variant> [drop-one]: 0 when every translated target agrees
one_case() {
  local seed=$1 size=$2 variant=$3 fault=${4:-}
  local dir="build/oracle/seed$seed-size$size${variant:+-$variant}"
  rm -rf "$dir"
  "$GEN" oracle "$seed" "$size" "$dir" $variant >"$dir.targets"
  if ! build/oracle/property rows "$EXT" "$dir" $fault 2>"$dir.err"; then
    echo "FAIL seed $seed: Marien failed: $(cat "$dir.err")"; return 1
  fi
  local bad=0
  for t in full part narrow-full narrow; do
    local td="$dir/$t"
    if [ -f "$td/SKIP" ]; then
      skipped=$((skipped + 1)); cat "$td/SKIP" >>"$REASONS"; continue
    fi
    if [ -f "$td/refused" ]; then refused=$((refused + 1)); continue; fi
    local files=("$td/marien.rows")
    [ "$t" = part ] && files+=("$td/marien-default.rows")
    for f in "${files[@]}"; do
      if compare "$dir" "$t" "$f" "seed $seed size $size${variant:+ $variant} $t${f##*/marien}"; then
        agree=$((agree + 1))
      else
        differ=$((differ + 1)); bad=1
        reproducer "$dir" "$t" "seed$seed-size$size${variant:+-$variant}-$t"
      fi
    done
  done
  return $bad
}

if [ "${1:-}" = --self-test ]; then
  # @tg: verifies:: [[openspec:differential-testing#Soufflé oracle#Mismatch leaves a reproducer]] {level: e2e}
  FAILURES=build/oracle/self-test-failures
  rm -rf "$FAILURES"
  for seed in $(seq 1 50); do
    "$GEN" oracle "$seed" 4 "build/oracle/probe" >build/oracle/probe.targets
    grep -q '^full translated' build/oracle/probe.targets || continue
    build/oracle/property rows "$EXT" build/oracle/probe 2>/dev/null || continue
    [ -s build/oracle/probe/full/marien.rows ] || continue
    if one_case "$seed" 4 "" drop-one >build/oracle/self-test.log; then
      echo "FAIL self-test: a dropped answer went unnoticed (seed $seed)"; exit 1
    fi
    for f in schema.cypher facts module.elpi query.txt marien.rows souffle.rows; do
      [ -e "$FAILURES/seed$seed-size4-full/$f" ] || { echo "FAIL self-test: reproducer lacks $f"; exit 1; }
    done
    echo "PASS self-test: the dropped answer fails seed $seed and leaves $FAILURES/seed$seed-size4-full"
    exit 0
  done
  echo "FAIL self-test: no seed in 1..50 has a translated module with answers"; exit 1
fi

CASES="${1:-100}"
SIZE="${2:-4}"
fail=0
# @tg: verifies:: [[openspec:differential-testing#Soufflé oracle#Agreement on a validation rule]] {level: e2e}
# @tg: verifies:: [[openspec:differential-testing#Soufflé oracle#Agreement under partitioning]] {level: e2e}
for seed in $(seq 1 10); do one_case "$seed" "$SIZE" rule || fail=1; done
for seed in $(seq 1 "$CASES"); do one_case "$seed" "$SIZE" "" || fail=1; done
echo "souffle oracle: $agree comparisons agree, $differ differ, $refused refused by Marien's analysis, $skipped targets outside the fragment"
LC_ALL=C sort "$REASONS" | uniq -c | sort -rn | sed 's/^ */  skipped /' 
[ "$agree" -gt 0 ] || { echo "FAIL: nothing was compared"; fail=1; }
exit $fail
