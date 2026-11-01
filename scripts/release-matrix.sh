#!/usr/bin/env bash
# @tg: implements:: [[openspec:distribution#Build matrix]]
# The release build matrix, as the JSON GitHub Actions reads (.github/workflows/release.yml):
# every supported LadybugDB version × OS (macOS, Linux) × CPU (arm64, amd64). Linux entries build
# in a Docker container (tests/linux/docker.sh). Add a LadybugDB version here to build for it.
set -euo pipefail
cat <<'JSON'
{"ladybug": ["0.22.1"],
 "target": [
  {"runner": "macos-15", "os": "osx", "cpu": "arm64", "docker": false},
  {"runner": "macos-15-intel", "os": "osx", "cpu": "amd64", "docker": false},
  {"runner": "ubuntu-24.04-arm", "os": "linux", "cpu": "arm64", "docker": true},
  {"runner": "ubuntu-24.04", "os": "linux", "cpu": "amd64", "docker": true}]}
JSON
