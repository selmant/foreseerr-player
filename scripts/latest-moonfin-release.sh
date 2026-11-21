#!/usr/bin/env bash
# Prints Moonfin's newest release tag (x.y.z), from upstream/'s fetched tags.
#
#   scripts/latest-moonfin-release.sh [--fetch]
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
[ "${1:-}" = "--fetch" ] && git -C "$root/upstream" fetch -q --tags origin
git -C "$root/upstream" tag --list | grep -E '^v?[0-9]+\.[0-9]+\.[0-9]+$' |
  sort -V | tail -1
