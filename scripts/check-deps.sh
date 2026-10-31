#!/usr/bin/env bash
# @tg: verifies:: [[openspec:extension-runtime#Single Lean runtime per process#Library has no Lean shared-library dependency]] {level: integration}
# Fail if the extension depends on any shared library other than the OS C/C++ runtime,
# in particular on a Lean runtime library (libleanshared, libleanelpi, libInit_shared).
#   check-deps.sh <extension>
set -euo pipefail
L="$1"
if [ "$(uname -s)" = Darwin ]; then
  deps=$(otool -L "$L" | tail -n +2 | awk '{print $1}' | grep -v "$(basename "$L")$" || true)
  allowed='^(/usr/lib/libc\+\+\.1\.dylib|/usr/lib/libSystem\.B\.dylib)$'
else
  deps=$(readelf -d "$L" | awk '/NEEDED/ {gsub(/[\[\]]/,"",$5); print $5}')
  allowed='^(libc\.so\.6|libm\.so\.6|libstdc\+\+\.so\.6|libgcc_s\.so\.1|ld-linux-[a-z0-9_-]+\.so\.[0-9]+|libpthread\.so\.0|libdl\.so\.2|librt\.so\.1)$'
fi
bad=$(echo "$deps" | grep -v -E "$allowed" | grep -v '^$' || true)
echo "dependencies:"; echo "$deps" | sed 's/^/  /'
if [ -n "$bad" ]; then echo "FAIL: unexpected dependencies:"; echo "$bad" | sed 's/^/  /'; exit 1; fi
echo "PASS: only the OS C/C++ runtime"
