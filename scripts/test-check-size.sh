#!/usr/bin/env bash
# Tests for check-size.sh: a library within 10% of the baseline passes, one 15% over fails.
set -euo pipefail
cd "$(dirname "$0")"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
case "$(uname -s)-$(uname -m)" in
  Darwin-arm64) PLAT=osx-arm64 ;; Darwin-x86_64) PLAT=osx-x86_64 ;;
  Linux-aarch64) PLAT=linux-aarch64 ;; Linux-x86_64) PLAT=linux-x86_64 ;;
esac
head -c 200000 /dev/urandom > "$T/lib"            # random bytes: gzip cannot shrink them
base=$(gzip -9c "$T/lib" | wc -c | tr -d ' ')
echo "$PLAT $base" > "$T/baseline"

# @tg: verifies:: [[openspec:extension-runtime#Size budget is measured#Size report is produced]] {level: unit}
./size-report.sh "$T/lib" "$T/lib" | grep -q "^strip " && ./size-report.sh "$T/lib" "$T/lib" | grep -q "^nostrip "
echo "ok: size report lists both link modes"

./check-size.sh "$T/lib" "$T/baseline" >/dev/null
echo "ok: same size passes"

# @tg: verifies:: [[openspec:extension-runtime#Size budget is measured#Unnoticed growth fails CI]] {level: unit}
head -c 30000 /dev/urandom >> "$T/lib"            # +15%
if ./check-size.sh "$T/lib" "$T/baseline" >/dev/null; then
  echo "FAIL: 15% growth was not caught"; exit 1
fi
echo "ok: 15% growth over an unchanged baseline fails"
