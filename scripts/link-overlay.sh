#!/usr/bin/env bash
# Links every file under overlay/ into a Moonfin checkout at the same path,
# and keeps the links out of that checkout's git status.
#
#   scripts/link-overlay.sh [tree]   (default: upstream/)
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
overlay="$root/overlay"
tree=$(cd "${1:-$root/upstream}" && pwd)

# Links left over from overlay files that are gone.
find "$tree" -path "$tree/build" -prune -o -type l -lname "$overlay/*" \
  ! -exec test -e {} \; -exec rm -v {} +

exclude=$(git -C "$tree" rev-parse --path-format=absolute --git-path info/exclude)
mkdir -p "$(dirname "$exclude")"
touch "$exclude"
(cd "$overlay" && find . -type f -printf '%P\n') | sort | while read -r rel; do
  if [ -e "$tree/$rel" ] && [ ! -L "$tree/$rel" ]; then
    echo "overlay/$rel would replace Moonfin's own file; rename it" >&2
    exit 1
  fi
  mkdir -p "$(dirname "$tree/$rel")"
  ln -sfn "$overlay/$rel" "$tree/$rel"
  grep -qxF "/$rel" "$exclude" || echo "/$rel" >> "$exclude"
done
