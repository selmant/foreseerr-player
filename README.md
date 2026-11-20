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

## Patches

| Patch | What |
| --- | --- |
| 0001 | Receiver mode, built in with `--dart-define=RECEIVER_MODE=true` |
| 0002 | Pairing through Foreseerr |
| 0003 | Linux rebrand: `org.foreseerr.player`, `foreseerr-player://` |
| 0004 | Show the window as soon as a play command arrives |

### Receiver mode

- A Jellyfin remote `PlayNow`, or a `foreseerr-player://play?id=…[&userId=…]`
  `[&startTicks=…]` link, opens the player straight away. Play links resume
  from the user's saved position when `startTicks` is absent.
- Every route other than the players goes to a small idle page.
- Desktop: the window comes up fullscreen when a play command arrives and
  hides once no player is open. Closing the window leaves the player and
  hides it; the idle page's Quit really exits.

### Pairing

`foreseerr-player://pair?foreseerr=<url>&ticket=<ticket>[&id=<itemId>]`

Foreseerr issues the single-use ticket (`POST /api/v1/player/pair-tickets`).
The player reads the Jellyfin server and user from `/info`, starts Quick
Connect, and sends the code to `/quickconnect`, where Foreseerr approves it
with the user's linked Jellyfin token. The player gets a Jellyfin device and
session of its own; Foreseerr's token never leaves Foreseerr. Needs Quick
Connect enabled on the Jellyfin server.

Handing the player Foreseerr's own token was tried and dropped: Jellyfin ties
a device to a token, so the two apps overwrote each other's device, remote
control turned off for both, and a player sign-out ended Foreseerr's link.

## Build (Linux)

```sh
./scripts/sync.sh
cd upstream
flutter build linux --release --dart-define=DISTRIBUTION_CHANNEL=linux \
  --dart-define=RECEIVER_MODE=true
```

## Planned

- Android: go to the background instead of hiding a window.
- Rebrand the client name Jellyfin shows ("Moonfin for Linux") and the icon.

## License

GPL-3.0-or-later. Moonfin-Core is GPL-2.0-or-later and includes GPL-3
components, so builds are GPL-3. Foreseerr stays MIT: it only talks to the
player over URLs and Jellyfin's API.
