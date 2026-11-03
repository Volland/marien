#!/usr/bin/env bash
# @tg: implements:: [[decisions#Landing page on the extension server]]
# Add the landing page (web/) to the Pages site, over the extension-server layout already in
# <site>, with the release version and the pinned LadybugDB version filled in.
#   build-site.sh <site-dir> <version, with or without the leading v>
set -euo pipefail
SITE="$1"; VERSION="${2#v}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LBUG="$(cat "$ROOT/scripts/ladybug-version")"
mkdir -p "$SITE"
cp "$ROOT"/web/*.svg "$SITE/"
sed -e "s/__VERSION__/$VERSION/g" -e "s/__LBUG__/$LBUG/g" "$ROOT/web/index.html" > "$SITE/index.html"
