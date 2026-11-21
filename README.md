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
| 0007 | Player settings as data, for Foreseerr's own settings page |

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
- The page draws on the GPU with WebKit's previous compositor
  (`WEBKIT_USE_SKIA_FOR_COMPOSITION=0`): 2.54's Skia one flashes old frames
  during fades and, on CSS backdrop-filter, grows without end (fixed in
  2.54.2). On NVIDIA under Wayland the app also sets
  `__NV_DISABLE_EXPLICIT_SYNC=1` (otherwise Wayland error 71). The usual
  `WEBKIT_DISABLE_DMABUF_RENDERER=1` works but draws on the CPU, about 4 fps
  on a 4K screen. Foreseerr marks its animated elements so WebKit doesn't
  show a layer before it is painted.
- Playback stays in the window as it is: fullscreen only if the app already
  was. Made fullscreen from the player, the window goes back to windowed for
  Foreseerr afterwards, and the next start opens windowed too. Closing the
  window quits.

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

### Player settings in Foreseerr

Foreseerr shows Moonfin's player settings on its own page (Profile →
Settings → Player, inside the app only). Nothing lists them by hand:

1. The screens under Playback come from Moonfin's settings search index.
2. Each is built off-screen for a frame, and every standard preference tile
   on it (switch, choice, multi-select, slider) is read back: key, title,
   description, options with their labels, current value.
3. Foreseerr draws that schema generically and sends changes back; the app
   applies them the way the tile would, callbacks included.

So settings Moonfin adds or changes show up without work on either side.
Custom widgets that aren't standard tiles are left out. The page talks to
the app through `window.foreseerrPlayer.request(...)` (see
`lib/receiver/foreseerr_web.dart`); the app waits for Moonfin's sign-in
settings sync first, which would otherwise overwrite an early change.

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
