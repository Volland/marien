#!/usr/bin/env bash
# @tg: verifies:: [[openspec:distribution#Build matrix#Artifact names carry the matrix entry]]
# @tg: verifies:: [[openspec:distribution#Build matrix#One failing entry blocks the release]]
# Check the release's shape without running it: the matrix (scripts/release-matrix.sh) spans
# LadybugDB versions and both OSes and CPUs, every artifact name carries the LadybugDB version, OS
# and CPU, and publishing needs the whole matrix with fail-fast on, so one failing entry
# publishes nothing.
#   check-release-workflow.sh [workflow]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
W="${1:-$ROOT/.github/workflows/release.yml}"
fail() { echo "FAIL: $1"; exit 1; }
"$ROOT/scripts/release-matrix.sh" | python3 -c '
import json, sys
m = json.load(sys.stdin)
assert m["ladybug"], "no LadybugDB version"
got = {(t["os"], t["cpu"]) for t in m["target"]}
want = {(o, c) for o in ("osx", "linux") for c in ("arm64", "amd64")}
assert got == want, f"targets {sorted(got)} != {sorted(want)}"
' || fail "the matrix must list LadybugDB versions and osx/linux × arm64/amd64"
grep -qE "ARTIFACT: marien-.*\\$\\{\\{ matrix\\.ladybug \\}\\}.*\\$\\{\\{ matrix\\.target\\.os \\}\\}.*\\$\\{\\{ matrix\\.target\\.cpu \\}\\}" "$W" \
  || fail "the artifact name must carry the LadybugDB version, OS and CPU"
grep -qE "name: \\$\\{\\{ env\\.ARTIFACT \\}\\}" "$W" || fail "artifacts must be uploaded under that name"
grep -qE "matrix: \\$\\{\\{ fromJSON\\(needs\\.matrix\\.outputs\\.matrix\\) \\}\\}" "$W" || fail "the build must use scripts/release-matrix.sh"
grep -qE "^    needs: build$" "$W" || fail "publish must need the whole build matrix"
grep -qE "fail-fast: true" "$W" || fail "the matrix must fail fast"
echo "PASS: release matrix, artifact names and publish gate"
