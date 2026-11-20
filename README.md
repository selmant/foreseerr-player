# Foreseerr Player

The Foreseerr app: Foreseerr's own web UI, with Moonfin's player and
on-screen controls taking the window while something plays. Users only ever
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
| 0005 | One open link per play; shown only while playing |
| 0006 | App mode (Linux): Foreseerr's web UI in the window between plays |

### App mode (Linux)

- The window shows Foreseerr, loaded from its server (asked for on first
  run). A WebKitGTK view sits over the Flutter view in the GTK runner
  (`linux/runner/foreseerr_web.cc`) and is hidden while the player is up.
- Play buttons in the page hand their `foreseerr-player://open` link to the
  player directly, with no browser prompt. Only links from the page's own
  origin, for that same Foreseerr, are taken.
- The page keeps its own cookies and storage under
  `~/.local/share/org.foreseerr.player/web`, so Foreseerr stays signed in.
- Links out of Foreseerr (TMDB, IMDb, …) open in the browser. Alt+Left/Right
  or the mouse's side buttons go back and forward, F5 reloads, F11 toggles
  fullscreen. `FORESEERR_WEB_DEVTOOLS=1` turns on the web inspector.
- Playback goes fullscreen; afterwards Foreseerr comes back, windowed again
  if it was. Closing the window quits.

### Receiver mode

- A Jellyfin remote `PlayNow`, or a `foreseerr-player://play?id=…[&userId=…]`
  `[&startTicks=…]` link, opens the player straight away. Play links resume
  from the user's saved position when `startTicks` is absent.
- Every route other than the players goes to a small idle page.
- Desktop: the window comes up fullscreen when a play command arrives and
  hides once no player is open. Closing the window leaves the player and
  hides it; the idle page's Quit really exits.

### Open links and pairing

`foreseerr-player://open?foreseerr=<url>&ticket=<ticket>&id=<itemId>`

Foreseerr sends one of these on every play, with a fresh single-use ticket
(`POST /api/v1/player/pair-tickets`). The player reads the Jellyfin server
and user from `/info`. Already signed in as that user, it just plays; if not,
it starts Quick Connect and sends the code to `/quickconnect`, where Foreseerr
approves it with the user's linked Jellyfin token. The player gets a Jellyfin
device and session of its own; Foreseerr's token never leaves Foreseerr.
Needs Quick Connect enabled on the Jellyfin server.

A link that starts the player goes fullscreen and black until playback
begins. A link for a running, hidden player plays without showing anything
else. Opened by hand, the player shows its idle page.

Handing the player Foreseerr's own token was tried and dropped: Jellyfin ties
a device to a token, so the two apps overwrote each other's device, remote
control turned off for both, and a player sign-out ended Foreseerr's link.

## Build and install (Linux)

```sh
./scripts/sync.sh
cd upstream
flutter build linux --release --dart-define=DISTRIBUTION_CHANNEL=linux \
  --dart-define=RECEIVER_MODE=true
cd ..
./scripts/install-linux.sh   # menu entry + foreseerr-player:// handler
```

Inside the app the handoff is always on. To hand plays over from an
ordinary browser tab instead, turn it on in that browser's console:
`localStorage.setItem('foreseerrPlayer.enabled', 'true')`. The browser asks
once before opening the app.

## Planned

- Android: app mode with an Android WebView.
- Plex sign-in: its popup opens in the browser, so it can't finish in-app.
- Rebrand the client name Jellyfin shows ("Moonfin for Linux") and the icon.

## License

GPL-3.0-or-later. Moonfin-Core is GPL-2.0-or-later and includes GPL-3
components, so builds are GPL-3. Foreseerr stays MIT: it only talks to the
player over URLs and Jellyfin's API.
