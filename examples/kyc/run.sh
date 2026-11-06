#!/usr/bin/env bash
# Run the KYC example of the website (web/tour.html) in a fresh in-memory LadybugDB with the built
# extension and print what the CLI prints, as CSV. With --check, compare that with
# examples/kyc/expected.txt, the output the site quotes, and fail on any difference.
# Usage: examples/kyc/run.sh [--check] [extension]   Env: LBUG (the CLI, default .deps/cli/lbug)
set -euo pipefail
cd "$(dirname "$0")/../.."
CHECK=0; [ "${1:-}" = --check ] && { CHECK=1; shift; }
EXT="${1:-$PWD/build/libmarien.lbug_extension}"
LBUG="${LBUG:-.deps/cli/lbug}"
DIR=examples/kyc
# the module as a Cypher string literal: backslashes and single quotes escaped
SRC=$(sed -e 's/\\/\\\\/g' -e "s/'/\\\\'/g" "$DIR/kyc.elpi")
run() {
  {
    echo "LOAD EXTENSION '$EXT';"
    cat "$DIR/schema.cypher"
    echo "CALL elpi_init();"
    printf "CALL elpi_save('kyc', '%s');\n" "$SRC"
    cat "$DIR/queries.cypher"
  } | "$LBUG" :memory: -s -b -m csv 2>&1 | sed -e "s|$EXT|<extension>|g"
}
if [ "$CHECK" = 1 ]; then
  if diff -u "$DIR/expected.txt" <(run); then echo "PASS: the KYC example prints what the site shows"
  else echo "FAIL: the KYC example's output changed; update examples/kyc/expected.txt and web/tour.html"; exit 1; fi
else
  run
fi
