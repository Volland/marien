#!/usr/bin/env bash
# Serve a packaged extension over HTTP in the extension-server layout, download it as a user
# would and load it into LadybugDB's CLI by path, then call elpi_signature.
#
# LadybugDB 0.22.1 accepts `INSTALL <name> FROM '<url>'` and `LOAD <name>` only for the names on
# its built-in list of official extensions, so `INSTALL marien FROM ...` is refused before any
# download; until that changes, users fetch the file from the same layout and use
# `LOAD EXTENSION '<path>'`. This script checks that path; it does not verify the scenario
# "Install and load" (constraint "INSTALL accepts only official extensions").
#   test-install.sh <extension> [lbug-cli]
set -euo pipefail
EXT="$1"; CLI="${2:-$(cd "$(dirname "$0")/.." && pwd)/.deps/cli/lbug}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'kill "${SERVER:-0}" 2>/dev/null || true; wait "${SERVER:-0}" 2>/dev/null || true; rm -rf "$TMP"' EXIT
PACKAGED="$("$ROOT/scripts/package-extension.sh" "$EXT" "$TMP/server")"
REL="${PACKAGED#"$TMP/server/"}"
PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')
python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$TMP/server" >"$TMP/server.log" 2>&1 &
SERVER=$!
for _ in $(seq 50); do curl -s "http://127.0.0.1:$PORT/" >/dev/null && break; sleep 0.1; done
# what INSTALL would do for an official extension: refused for marien
REFUSED=$(printf "INSTALL marien FROM 'http://127.0.0.1:%s/';\n" "$PORT" | HOME="$TMP/home" "$CLI" "$TMP/db0" 2>&1 || true)
echo "$REFUSED" | grep -q "not an official extension" && echo "note: INSTALL marien is refused by LadybugDB (not an official extension)"
curl -sf -o "$TMP/libmarien.lbug_extension" "http://127.0.0.1:$PORT/$REL"
OUTPUT=$(printf "LOAD EXTENSION '%s';\nCALL elpi_signature() RETURN kind;\n" "$TMP/libmarien.lbug_extension" \
  | HOME="$TMP/home" "$CLI" "$TMP/db" 2>&1)
if echo "$OUTPUT" | grep -q "rror"; then echo "FAIL: download and load"; echo "$OUTPUT"; exit 1; fi
echo "$OUTPUT" | grep -q "protocol" || { echo "FAIL: elpi_signature did not answer"; echo "$OUTPUT"; exit 1; }
echo "PASS: downloaded $REL from the server, LOAD EXTENSION, CALL elpi_signature()"
