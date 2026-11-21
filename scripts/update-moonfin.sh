#!/usr/bin/env bash
# Moves the pin to another Moonfin (default: its latest release tag) if
# patches/ still apply and overlay/ still compiles against it, then syncs
# upstream/. Otherwise changes nothing and says what broke.
#
#   FLUTTER=/path/to/flutter scripts/update-moonfin.sh [tag-or-rev]
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
flutter=${FLUTTER:-flutter}
upstream="$root/upstream"
old=$(tr -d '[:space:]' < "$root/moonfin.rev")

git -C "$upstream" fetch -q --tags origin
target=${1:-$("$root/scripts/latest-moonfin-release.sh")}
new=$(git -C "$upstream" rev-parse "$target^{commit}")
if [ "$new" = "$old" ]; then
  echo "already at $new"
  exit 0
fi
echo "Moonfin $old -> $target ($new)"

tree=$(mktemp -d "${TMPDIR:-/tmp}/foreseerr-player-update.XXXXXX")
cleanup() {
  git -C "$upstream" worktree remove -f "$tree" 2>/dev/null || rm -rf "$tree"
  git -C "$upstream" worktree prune
}
trap cleanup EXIT
git -C "$upstream" worktree add -q --detach "$tree" "$new"

if ! git -C "$tree" am -q --3way "$root"/patches/*.patch; then
  echo "a patch no longer applies:" >&2
  git -C "$tree" am --show-current-patch=diff | head -40 >&2 || true
  git -C "$tree" am --abort || true
  exit 1
fi
"$root/scripts/link-overlay.sh" "$tree"

# Everything of ours that Dart compiles: a renamed Moonfin API shows here.
(cd "$tree" && "$flutter" pub get >/dev/null &&
  "$flutter" analyze --no-fatal-infos --no-fatal-warnings lib/foreseerr \
    lib/ui/screens/settings/panel/foreseerr_settings_screens.dart) || {
  echo "the overlay doesn't compile against $new; pin left at $old" >&2
  exit 1
}

echo "$new" > "$root/moonfin.rev"
echo "$target" > "$root/moonfin.version"
"$root/scripts/sync.sh"
echo "pinned Moonfin $target; build with scripts/build.sh"
