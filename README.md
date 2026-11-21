# Foreseerr Player

The Foreseerr app: Foreseerr's own web UI, with Moonfin's player and
on-screen controls taking the window while something plays. Users only ever
see Foreseerr and the player: no Moonfin home, item pages or sign-in screens.

Built from [Moonfin-Core](https://github.com/Moonfin-Client/Moonfin-Core)
at a pinned release. Moonfin is not forked: our code lives in files of its
own, and only a few lines of Moonfin's files change.

## Layout

| Path | What |
| --- | --- |
| `moonfin.version`, `moonfin.rev` | Pinned Moonfin release, and its commit |
| `overlay/` | Our files, linked into the Moonfin checkout at the same paths |
| `patches/` | The few edits to Moonfin's own files (`git format-patch`) |
| `upstream/` | Working checkout (ignored): the pin, the patches as commits, overlay links |
| `dist/bundle` | The built app (ignored) |
| `scripts/sync.sh` | Check out the pin into `upstream/`, apply `patches/`, link `overlay/` |
| `scripts/build.sh` | Build `dist/bundle` (low priority, in a build tree of its own) |
| `scripts/update-moonfin.sh` | Move the pin to Moonfin's latest release (or a given one) if everything still applies and compiles |
| `scripts/latest-moonfin-release.sh` | Moonfin's newest release tag |
| `scripts/package.sh` | Pack `dist/bundle` as a release tarball |
| `scripts/export-patches.sh` | Write `upstream/`'s `foreseerr-player` commits back to `patches/` |
| `scripts/link-overlay.sh` | Link `overlay/` into a checkout (sync and build do this) |
| `scripts/install-linux.sh` | Add `dist/bundle` to the desktop's menu |

Edit overlay files anywhere (the links in `upstream/` point at them). Edits
to Moonfin's own files are commits on `upstream/`'s `foreseerr-player`
branch, exported with `export-patches.sh`; keep them few and small.

### What touches Moonfin

`patches/`, all in files Moonfin rarely changes, except the one line:

| Patch | What |
| --- | --- |
| 0001 | Linux runner: `foreseerr-player` / `org.foreseerr.player`, WebKitGTK, `foreseerr_web.cc`, one call in `main.cc` |
| 0002 | One `part` line in `settings_side_panel.dart`, so the overlay can read the settings search index |

Everything else uses Moonfin's public code, and a rename there fails the
build (or `update-moonfin.sh`) with a clear error rather than a conflict:

- `main()` from `lib/main.dart`, which our entry point calls first.
- `appRouter`, `PlayerRouteObserver`, `Destinations`: opening the player
  and knowing when one is up.
- `PlaybackManager.playItems`, `SessionRepository`, the client factory and
  the sign-in store: playing and signing in.
- `SetupWizardGate.deferThisLaunch`: no first-run wizard.
- The settings tiles (`preference_tiles.dart`): reading the player settings.

## How it works (Linux)

- `lib/foreseerr/main.dart` is the entry point (`flutter build linux -t
  lib/foreseerr/main.dart`). It runs Moonfin's `main()` unchanged, then
  starts ours.
- `foreseerr_web_install()` (`linux/runner/foreseerr_web.cc`) takes over
  GtkWindow's `add` for the application window: Moonfin's Flutter view goes
  into an overlay with a black curtain and the web view over it. The
  `foreseerr/web` channel lets Dart load pages and pick what shows: `web`,
  `blank` (black) or `player` (Flutter).
- The web view shows Foreseerr, loaded from its server, or the app's own
  setup and load-error pages (`pages.dart`) before that. It keeps its
  cookies and storage under `~/.local/share/org.foreseerr.player/web`.
- Moonfin's screens never show: Flutter is only uncovered while a player
  route is open. Behind the page, Moonfin waits on its static web
  diagnostics page (`/_diag`) instead of Home, so Home's trailers don't run
  (`player.dart`). A path with no route would be quieter, but go_router
  can't push the player over it.
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
  Foreseerr afterwards, also when the app was quit during the play.
- Casting to the player from Jellyfin works while the app is open (Moonfin's
  own remote control).

### Playing and signing in

`foreseerr-player://open?foreseerr=<url>&ticket=<ticket>&id=<itemId>`

Foreseerr's play buttons navigate to one of these, with a fresh single-use
ticket (`POST /api/v1/player/pair-tickets`); the web view hands it to the
app instead of loading it, and only from Foreseerr's own page. The app reads
the Jellyfin server and user from `/info`. Already signed in as that user,
it just plays; if not, it redeems the ticket (`/redeem`) for the Jellyfin
session Foreseerr holds for the user and signs in with it. Progress and
errors show as a small notice on Foreseerr's page.

Launched with such a link as its argument, the app plays it once
Foreseerr is up.

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
`overlay/lib/foreseerr/shell.dart`); the app waits for Moonfin's sign-in
settings sync first, which would otherwise overwrite an early change.

## Build and install (Linux)

```sh
./scripts/sync.sh
FLUTTER=/path/to/flutter ./scripts/build.sh
./scripts/install-linux.sh   # menu entry
```

## Updating Moonfin

The pin follows Moonfin's releases. Every day, the Moonfin watch workflow
looks for a newer one and opens an issue about it. If the update works (the
patches apply and our code compiles), the issue links a PR that moves the
pin, and CI builds it; check playback, then merge. If not, the issue has the
log. By hand:

```sh
FLUTTER=/path/to/flutter ./scripts/update-moonfin.sh   # or a tag
```

It tries the patches on the new release and compiles the overlay against it
in a temporary checkout, and only then moves the pin. When a patch no longer
applies, fix it on the new release in `upstream/` and export; when the
overlay no longer compiles, adapt it to Moonfin's rename.

## Releases

Push a `v<version>` tag: the Release workflow builds the Linux app with the
Flutter version Moonfin's own CI uses and attaches
`foreseerr-player-<version>-linux-x64.tar.gz`. It needs WebKitGTK 4.1 and
libmpv from the system (Moonfin's "system libs" build). Unpack, then run
`./install.sh` for a menu entry or start `./foreseerr-player`.

## Planned

- Android: the same with an Android WebView.
- Emby and Plex sign-in through Foreseerr.
- Rebrand the client name Jellyfin shows ("Moonfin for Linux") and the icon.

## License

GPL-3.0-or-later. Moonfin-Core is GPL-2.0-or-later and includes GPL-3
components, so builds are GPL-3. Foreseerr stays MIT: it only talks to the
player over URLs and Jellyfin's API.
