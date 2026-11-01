#!/usr/bin/env bash
# @tg: verifies:: [[openspec:extension-runtime#Only the init symbol is exported#Exported symbol list]] {level: integration}
# @tg: verifies:: [[openspec:distribution#Out-of-tree build#Only entry points are exported]] {level: integration}
# Fail unless the extension exports exactly LadybugDB's loader entry points, `init` and `name`.
#   check-exports.sh <extension>
set -euo pipefail
L="$1"
if [ "$(uname -s)" = Darwin ]; then
  syms=$(nm -gU "$L" | awk '{print $3}' | sed 's/^_//' | sort)
else
  syms=$(nm -D --defined-only "$L" | awk '{print $3}' | sort)
fi
echo "exported: $(echo $syms)"
if [ "$syms" != "$(printf 'init\nname')" ]; then echo "FAIL: expected exactly: init name"; exit 1; fi
echo "PASS: only the loader entry points"
