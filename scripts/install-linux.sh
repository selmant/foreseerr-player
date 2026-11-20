#!/usr/bin/env bash
# Registers a built player with the desktop: a menu entry and the
# foreseerr-player:// link handler browsers hand Foreseerr's play links to.
#
#   scripts/install-linux.sh [bundle-dir]   install (default: the release build)
#   scripts/install-linux.sh --uninstall    remove the entry and the handler
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

bundle=$(cd "${1:-$root/upstream/build/linux/x64/release/bundle}" && pwd)
binary="$bundle/foreseerr-player"
[ -x "$binary" ] || { echo "no player at $binary; build it first" >&2; exit 1; }
# xdg-open's generic handler, which browsers use for foreseerr-player://
# links outside GNOME and KDE, takes Exec's first word as is: no quotes, so
# no spaces either.
case "$binary" in *[[:space:]]*)
  echo "the player's path has a space; xdg-open can't run it: $binary" >&2; exit 1;;
esac

mkdir -p "$apps"
cat > "$entry" <<EOF
[Desktop Entry]
Type=Application
Name=Foreseerr
Comment=Foreseerr, with its own player
Exec=$binary %U
Icon=$bundle/data/flutter_assets/assets/icons/moonfin.png
Categories=AudioVideo;Video;
Terminal=false
StartupWMClass=$app_id
MimeType=x-scheme-handler/foreseerr-player;
EOF
update-desktop-database "$apps" 2>/dev/null || true
xdg-mime default "$app_id.desktop" x-scheme-handler/foreseerr-player
echo "installed $entry"
echo "foreseerr-player:// opens with: $(xdg-mime query default x-scheme-handler/foreseerr-player)"
