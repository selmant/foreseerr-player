#!/usr/bin/env bash
# Adds a built app to the desktop's menu.
#
#   scripts/install-linux.sh [bundle-dir]   install (default: the app next to
#                                           this script, else dist/bundle)
#   scripts/install-linux.sh --uninstall    remove the entry
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
app_id=org.foreseerr.player
apps="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
entry="$apps/$app_id.desktop"

if [ "${1:-}" = "--uninstall" ]; then
  rm -f "$entry"
  update-desktop-database "$apps" 2>/dev/null || true
  echo "removed $entry"
  exit 0
fi

here=$(cd "$(dirname "$0")" && pwd)
default="$root/dist/bundle"
[ -x "$here/foreseerr-player" ] && default=$here
bundle=$(cd "${1:-$default}" && pwd)
binary="$bundle/foreseerr-player"
[ -x "$binary" ] || { echo "no player at $binary; build it first" >&2; exit 1; }
# Exec takes the path as is: no quotes, so no spaces either.
case "$binary" in *[[:space:]]*)
  echo "the app's path has a space: $binary" >&2; exit 1;;
esac

mkdir -p "$apps"
cat > "$entry" <<EOF
[Desktop Entry]
Type=Application
Name=Foreseerr
Comment=Foreseerr, with its own player
Exec=$binary
Icon=$bundle/foreseerr.png
Categories=AudioVideo;Video;
Terminal=false
StartupWMClass=$app_id
EOF
update-desktop-database "$apps" 2>/dev/null || true
echo "installed $entry"
