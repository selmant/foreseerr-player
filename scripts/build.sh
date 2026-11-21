#!/usr/bin/env bash
# Builds the Linux app from upstream/'s foreseerr-player branch (commits
# only) plus overlay/, in a build tree of its own, at low priority, into
# dist/bundle. A running app keeps its bundle (Flutter reads its assets
# from it while it runs): the new one goes to dist/bundle.new instead.
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
if pgrep -f "^$dist/bundle/foreseerr-player" >/dev/null; then
  rm -rf "$dist/bundle.new"
  cp -a "$built" "$dist/bundle.new"
  echo "the app is running: built into $dist/bundle.new"
  echo "after quitting it: rm -rf $dist/bundle && mv $dist/bundle.new $dist/bundle"
else
  rm -rf "$dist/bundle" "$dist/bundle.new"
  cp -a "$built" "$dist/bundle"
  echo "built $dist/bundle"
fi
