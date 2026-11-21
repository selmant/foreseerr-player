#!/usr/bin/env bash
# Packs dist/bundle as dist/foreseerr-player-<version>-linux-x64.tar.gz, with
# install.sh (the menu entry) next to the app.
#
#   scripts/package.sh [version]   (default: git describe)
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
version=${1:-$(git -C "$root" describe --tags --always --dirty)}
name="foreseerr-player-$version-linux-x64"
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
cp -a "$root/dist/bundle" "$stage/foreseerr-player"
cp "$root/scripts/install-linux.sh" "$stage/foreseerr-player/install.sh"
cp "$root/LICENSE" "$stage/foreseerr-player/LICENSE"
tar -C "$stage" -czf "$root/dist/$name.tar.gz" foreseerr-player
echo "$root/dist/$name.tar.gz"
