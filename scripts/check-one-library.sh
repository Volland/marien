#!/usr/bin/env bash
# @tg: verifies:: [[openspec:distribution#Out-of-tree build#One file is produced]] {level: integration}
# Fail unless the build directory holds exactly one shared library, the extension itself: the
# Lean runtime, GMP, libuv and LeanElpi are linked into it, never shipped beside it.
#   check-one-library.sh <build-dir>
set -euo pipefail
DIR="$1"
libs=$(find "$DIR" -maxdepth 1 -type f \( -name '*.so' -o -name '*.so.*' -o -name '*.dylib' -o -name '*.lbug_extension' \) | sort)
echo "libraries in $DIR:"; echo "$libs" | sed 's/^/  /'
if [ "$libs" != "$DIR/libmarien.lbug_extension" ]; then
  echo "FAIL: expected exactly $DIR/libmarien.lbug_extension"; exit 1
fi
echo "PASS: one extension library"
