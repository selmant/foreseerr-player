# Foreseerr Player

Moonfin's player and on-screen controls, driven by Foreseerr. Users only ever
see Foreseerr and the player: no Moonfin home, item pages or sign-in screens.

This repo is a pin plus a patch series on top of
[Moonfin-Core](https://github.com/Moonfin-Client/Moonfin-Core). Moonfin itself
is not modified or forked on GitHub.

## Layout

| Path | What |
| --- | --- |
| `moonfin.rev` | Pinned Moonfin-Core commit |
| `patches/` | `git format-patch` series applied on the pin |
| `upstream/` | Working checkout (ignored) |
| `scripts/sync.sh` | Check out the pin into `upstream/` and apply `patches/` |
| `scripts/export-patches.sh` | Write `upstream/`'s `foreseerr-player` commits back to `patches/` |

Work happens in `upstream/` on the `foreseerr-player` branch; export after
committing.

## Receiver mode (patch 0001)

Built in with `--dart-define=RECEIVER_MODE=true`; off otherwise.

- A Jellyfin remote `PlayNow`, or a `moonfin://play?id=…[&startTicks=…]`
  link, opens the player straight away. Play links resume from the user's
  saved position when `startTicks` is absent.
- Every route other than the players goes to a small idle page.
- Desktop: the window is shown (fullscreen) while a player is open and
  hidden once none is. Closing the window leaves the player and hides it;
  the idle page's Quit really exits.

## Planned

1. Hidden pairing: Foreseerr opens a pair link carrying a short-lived,
   single-use ticket. The player starts Jellyfin Quick Connect itself,
   hands the code to Foreseerr with the ticket, and Foreseerr approves it
   with the user's linked Jellyfin token. The player gets its own Jellyfin
   session; Foreseerr's token never leaves Foreseerr.
2. Rebrand (name, app ID, `foreseerr-player://` scheme, icon) so it can sit
   next to an installed Moonfin.
3. Android: go to the background instead of hiding a window.

## License

GPL-3.0-or-later. Moonfin-Core is GPL-2.0-or-later and includes GPL-3
components, so builds are GPL-3. Foreseerr stays MIT: it only talks to the
player over URLs and Jellyfin's API.
