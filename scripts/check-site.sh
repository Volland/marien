#!/usr/bin/env bash
# @tg: verifies:: [[openspec:distribution#Install from extension server#Every entry is served]] {level: e2e}
# Fetch every extension library under <layout-dir> from the published extension server at <url>
# and compare it byte for byte. Pages can take a little while to serve a new deployment, so each
# file is retried for up to two minutes.
#   check-site.sh <url> <layout-dir>
set -euo pipefail
URL="${1%/}"; DIR="$2"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
n=0
while IFS= read -r f; do
  rel="${f#"$DIR"/}"
  ok=0
  for _ in $(seq 24); do
    if curl -sf -o "$TMP/got" "$URL/$rel" && cmp -s "$TMP/got" "$f"; then ok=1; break; fi
    sleep 5
  done
  [ "$ok" = 1 ] || { echo "FAIL: $URL/$rel is missing or differs from the tested artifact"; exit 1; }
  echo "served: $rel"
  n=$((n + 1))
done < <(find "$DIR" -name 'libmarien.lbug_extension' -type f | sort)
[ "$n" -gt 0 ] || { echo "FAIL: no extension library under $DIR"; exit 1; }
echo "PASS: $n entries served by $URL"
