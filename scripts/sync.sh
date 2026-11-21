#!/usr/bin/env bash
# Checks out the pinned Moonfin into upstream/, applies patches/ on a fresh
# foreseerr-player branch and links overlay/ in. Discards uncommitted work
# in upstream/ (overlay files are links, so edits to them are safe).
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
pin=$(tr -d '[:space:]' < "$root/moonfin.rev")
if [ ! -d "$root/upstream/.git" ]; then
  git clone -q --filter=blob:none --no-checkout https://github.com/Moonfin-Client/Moonfin-Core.git "$root/upstream"
fi
cd "$root/upstream"
git cat-file -e "$pin^{commit}" 2>/dev/null || git fetch origin
git checkout -q -f -B foreseerr-player "$pin"
git am -q "$root"/patches/*.patch
"$root/scripts/link-overlay.sh" "$root/upstream"
git log --oneline "$pin"..HEAD
