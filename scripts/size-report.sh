#!/usr/bin/env bash
# @tg: implements:: [[openspec:extension-runtime#Size budget is measured]]
# Report the extension size, uncompressed and gzip -9, for both link modes.
#   size-report.sh <stripped-extension> <unstripped-extension>
set -euo pipefail
sz() { if [ "$(uname -s)" = Darwin ]; then stat -f%z "$1"; else stat -c%s "$1"; fi; }
printf "%-10s %14s %14s\n" mode uncompressed gzip-9
for pair in "strip:$1" "nostrip:$2"; do
  m="${pair%%:*}"; f="${pair#*:}"
  printf "%-10s %14d %14d\n" "$m" "$(sz "$f")" "$(gzip -9c "$f" | wc -c | tr -d ' ')"
done
