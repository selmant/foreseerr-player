#!/usr/bin/env bash
# Builds the Linux app from upstream/'s foreseerr-player branch (commits
# only) plus overlay/, in a build tree of its own, at low priority, into
# dist/bundle, also while the app runs (see the swap at the end).
#
#   FLUTTER=/path/to/flutter scripts/build.sh
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
flutter=${FLUTTER:-flutter}
tree="${XDG_CACHE_HOME:-$HOME/.cache}/foreseerr-player/build-tree"

if [ -e "$tree/.git" ]; then
  git -C "$tree" checkout -q -f --detach foreseerr-player
else
  mkdir -p "$(dirname "$tree")"
  git -C "$root/upstream" worktree prune
  git -C "$root/upstream" worktree add -q --detach "$tree" foreseerr-player
fi
git -C "$tree" clean -q -fd -e build/
"$root/scripts/link-overlay.sh" "$tree"

# Low priority on a desktop, so a build doesn't stutter what's on screen.
low=()
if [ -z "${CI:-}" ]; then
  low=(nice -n 19 ionice -c 3)
  if command -v systemd-run >/dev/null; then
    low=(systemd-run --user --scope --quiet -p CPUWeight=1 "${low[@]}")
  fi
fi
(cd "$tree" && ${low[@]+"${low[@]}"} "$flutter" build linux --release \
  -t lib/foreseerr/main.dart --dart-define=DISTRIBUTION_CHANNEL=linux)

built="$tree/build/linux/x64/release/bundle"
dist="$root/dist"
mkdir -p "$dist"
# Copied next to it, then swapped in by renames: a running app keeps the
# files it has open and gets the new build when it next starts.
rm -rf "$dist/.bundle.next" "$dist/.bundle.gone"
cp -a "$built" "$dist/.bundle.next"
cp "$root/assets/foreseerr.png" "$dist/.bundle.next/"
[ -e "$dist/bundle" ] && mv "$dist/bundle" "$dist/.bundle.gone"
mv "$dist/.bundle.next" "$dist/bundle"
rm -rf "$dist/.bundle.gone"
echo "built $dist/bundle"
