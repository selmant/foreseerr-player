import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:get_it/get_it.dart';
import 'package:moonfin/auth/repositories/session_repository.dart';
import 'package:moonfin/data/models/aggregated_item.dart';
import 'package:moonfin/data/services/media_server_client_factory.dart';
import 'package:moonfin/ui/navigation/app_router.dart'
    show PlayerRouteObserver, appRouter;
import 'package:moonfin/ui/navigation/destinations.dart';
import 'package:moonfin/ui/screens/setup/setup_wizard_gate.dart';
import 'package:moonfin/util/fullscreen_helper.dart';
import 'package:playback_core/playback_core.dart' show PlaybackManager;
import 'package:shared_preferences/shared_preferences.dart';

import 'shell.dart';

/// Moonfin's player in Foreseerr's window, and nothing else of Moonfin's.
///
/// - Plays an item the way Moonfin's remote control does: opens its player
///   route and hands the item to its playback manager.
/// - Picks what the window shows (see [ForeseerrShell.setMode]): the player
///   while a player route is open, black while one is on its way or between
///   two, Foreseerr otherwise.
/// - Keeps Moonfin's own screens from running behind Foreseerr: Home (with
///   its trailers) is swapped for an empty route, and the first-run wizard
///   is put off.
/// - Hands the window back windowed when the player made it fullscreen.
class ForeseerrPlayer {
  ForeseerrPlayer._();

  static final instance = ForeseerrPlayer._();

  /// Where Moonfin waits between plays: its static web diagnostics page,
  /// which loads nothing and needs no sign-in. (A path with no route at all
  /// would be quieter, but go_router can't push the player over it.)
  static const parkPath = Destinations.webDiagnostics;

  static const _restoreWindowedKey = 'foreseerr.restoreWindowed';

  /// How long "no player" has to last before Foreseerr comes back: one
  /// player replacing another (next episode) passes through it.
  static const _settleTime = Duration(milliseconds: 800);

  /// A play that never opens a player must not leave the window black.
  static const _startTimeout = Duration(seconds: 20);

  final _players = PlayerRouteObserver.instance.isPlayerActive;

  bool _starting = false;
  Timer? _startTimer;
  bool _settling = false;
  Timer? _settleTimer;
  bool _inPlay = false;
  bool _restoreWindowed = false;
  String? _mode;
  final List<DateTime> _parks = [];

  Future<void> start() async {
    if (GetIt.instance.isRegistered<SetupWizardGate>()) {
      GetIt.instance<SetupWizardGate>().deferThisLaunch();
    }
    _players.addListener(_onPlayerChanged);
    ForeseerrShell.instance.hasPage.addListener(_sync);
    appRouter.routerDelegate.addListener(_onRoute);
    _onRoute();
    await _leaveFullscreenFromLastRun();
    _sync();
  }

  /// Plays [itemId] for the active user. Without [startTicks] it resumes
  /// where the user left it.
  Future<void> play(String itemId, {int? startTicks}) async {
    final serverId = GetIt.instance<SessionRepository>().activeServerId;
    final client = serverId == null
        ? null
        : GetIt.instance<MediaServerClientFactory>().getClientIfExists(
            serverId,
          );
    if (serverId == null || client == null) {
      throw StateError('The player is not signed in');
    }
    final data = await client.itemsApi.getItem(itemId);
    final userData = data['UserData'];
    final ticks =
        startTicks ??
        (userData is Map
            ? (userData['PlaybackPositionTicks'] as num?)?.toInt()
            : null) ??
        0;
    final item = AggregatedItem(id: itemId, serverId: serverId, rawData: data);
    final isAudio = data['MediaType'] == 'Audio' || data['Type'] == 'Audio';

    await _beginStart();
    try {
      if (!_players.value) {
        unawaited(
          appRouter.push(
            isAudio ? Destinations.audioPlayer : Destinations.videoPlayer,
          ),
        );
      }
      await GetIt.instance<PlaybackManager>().playItems([
        item,
      ], startPosition: Duration(microseconds: ticks ~/ 10));
    } catch (_) {
      _endStart();
      unawaited(GetIt.instance<PlaybackManager>().stop(userInitiated: false));
      await _leavePlay();
      _sync();
      rethrow;
    }
  }

  /// Puts Moonfin on [parkPath], unless a player is up.
  void park() {
    if (_players.value || _path == parkPath) return;
    // A Moonfin that sends the park path back home would bounce forever.
    final now = DateTime.now();
    _parks.removeWhere((t) => now.difference(t) > const Duration(seconds: 5));
    if (_parks.length >= 3) {
      debugPrint('[Foreseerr] Moonfin keeps leaving $parkPath; staying put');
      return;
    }
    _parks.add(now);
    debugPrint('[Foreseerr] parking Moonfin on $parkPath (was $_path)');
    appRouter.go(parkPath);
  }

  String get _path => appRouter.routerDelegate.currentConfiguration.uri.path;

  void _onRoute() {
    if (_path == Destinations.home) scheduleMicrotask(park);
  }

  Future<void> _beginStart() async {
    await _enterPlay();
    _starting = true;
    _startTimer?.cancel();
    _startTimer = Timer(_startTimeout, () {
      if (_players.value) return;
      _endStart();
      // Whatever did start must not play on behind Foreseerr.
      unawaited(GetIt.instance<PlaybackManager>().stop(userInitiated: false));
      unawaited(_leavePlay());
      _sync();
      ForeseerrShell.instance.notice(
        'The player did not start.',
        clearAfter: const Duration(seconds: 8),
      );
    });
    _sync();
  }

  void _endStart() {
    _starting = false;
    _startTimer?.cancel();
  }

  void _onPlayerChanged() {
    _settleTimer?.cancel();
    if (_players.value) {
      _settling = false;
      _endStart();
      // A player Moonfin opened on its own, for a Jellyfin remote play.
      unawaited(_enterPlay());
      _sync();
      return;
    }
    _settling = true;
    _sync();
    _settleTimer = Timer(_settleTime, () async {
      if (_players.value) return;
      await _leavePlay();
      _settling = false;
      _sync();
      _onRoute();
    });
  }

  /// Remembers whether Foreseerr was windowed, to hand the window back the
  /// same way.
  Future<void> _enterPlay() async {
    if (_inPlay) return;
    _inPlay = true;
    _restoreWindowed = !await _isFullscreen();
    if (_restoreWindowed) {
      await (await SharedPreferences.getInstance()).setBool(
        _restoreWindowedKey,
        true,
      );
    }
  }

  Future<void> _leavePlay() async {
    if (!_inPlay) return;
    _inPlay = false;
    if (_restoreWindowed && await _isFullscreen()) {
      await _setFullscreen(false);
    }
    await (await SharedPreferences.getInstance()).remove(_restoreWindowedKey);
  }

  /// Quit during a play the player made fullscreen, Moonfin saved the window
  /// as fullscreen and brings it back that way, after the first frame.
  /// Foreseerr was windowed, so it goes back to that right after.
  Future<void> _leaveFullscreenFromLastRun() async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(_restoreWindowedKey) != true) return;
    await prefs.remove(_restoreWindowedKey);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_setFullscreen(false));
    });
  }

  void _sync() {
    final mode = _players.value
        ? 'player'
        : _starting || _settling || !ForeseerrShell.instance.hasPage.value
        ? 'blank'
        : 'web';
    if (mode == _mode) return;
    _mode = mode;
    debugPrint('[Foreseerr] window: $mode');
    unawaited(ForeseerrShell.instance.setMode(mode));
  }

  static Future<bool> _isFullscreen() async {
    try {
      return await FullscreenHelper.isFullscreen();
    } catch (_) {
      return false;
    }
  }

  static Future<void> _setFullscreen(bool value) async {
    try {
      await FullscreenHelper.setFullscreen(value);
    } catch (e) {
      debugPrint('[Foreseerr] fullscreen $value failed: $e');
    }
  }
}
