#!/usr/bin/env bash
# Writes the commits on upstream/'s foreseerr-player branch, past the pin,
# back into patches/.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
pin=$(tr -d '[:space:]' < "$root/moonfin.rev")
rm -f "$root"/patches/*.patch
git -C "$root/upstream" format-patch -q -o "$root/patches" "$pin"..foreseerr-player
ls "$root/patches"
