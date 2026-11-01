#!/usr/bin/env bash
# @tg: implements:: [[openspec:extension-runtime#Size budget is measured]]
# Fail when the gzip -9 size of the stripped extension exceeds the recorded baseline for this
# platform by more than 10%. Growth is accepted only by updating the baseline file. With
# MARIEN_NEW_PLATFORM=1 a platform that has no baseline yet only reports its size.
#   check-size.sh <stripped-extension> [baseline-file]
set -euo pipefail
L="$1"; BASE="${2:-$(dirname "$0")/size-baseline.txt}"
case "$(uname -s)-$(uname -m)" in
  Darwin-arm64) PLAT=osx-arm64 ;; Darwin-x86_64) PLAT=osx-x86_64 ;;
  Linux-aarch64) PLAT=linux-aarch64 ;; Linux-x86_64) PLAT=linux-x86_64 ;;
esac
now=$(gzip -9c "$L" | wc -c | tr -d ' ')
base=$(awk -v p="$PLAT" '$1 == p {print $2}' "$BASE")
if [ -z "$base" ]; then
  if [ "${MARIEN_NEW_PLATFORM:-}" = 1 ]; then echo "gzip size $now bytes; no baseline for $PLAT yet (record it in $BASE)"; exit 0; fi
  echo "FAIL: no baseline for $PLAT in $BASE"; exit 1
fi
limit=$(( base + base / 10 ))
echo "gzip size $now bytes; baseline $base; limit $limit ($PLAT)"
if [ "$now" -gt "$limit" ]; then
  echo "FAIL: more than 10% over the baseline; update $BASE if the growth is intended"; exit 1
fi
echo "PASS"
