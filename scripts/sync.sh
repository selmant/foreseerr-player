#!/usr/bin/env bash
# Checks out the pinned Moonfin into upstream/ and applies patches/ on a
# fresh foreseerr-player branch. Discards uncommitted work in upstream/.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
pin=$(tr -d '[:space:]' < "$root/moonfin.rev")
if [ ! -d "$root/upstream/.git" ]; then
  git clone --no-checkout https://github.com/Moonfin-Client/Moonfin-Core.git "$root/upstream"
fi
cd "$root/upstream"
git cat-file -e "$pin^{commit}" 2>/dev/null || git fetch origin
git checkout -q -B foreseerr-player "$pin"
git am -q "$root"/patches/*.patch
git log --oneline "$pin"..HEAD
