import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:get_it/get_it.dart';
import 'package:moonfin/auth/models/server.dart';
import 'package:moonfin/auth/models/user.dart';
import 'package:moonfin/auth/repositories/server_repository.dart';
import 'package:moonfin/auth/repositories/session_repository.dart';
import 'package:moonfin/auth/store/authentication_preferences.dart';
import 'package:moonfin/auth/store/authentication_store.dart';
import 'package:moonfin/data/services/media_server_client_factory.dart';
import 'package:moonfin/ui/navigation/app_router.dart' show appRouter;
import 'package:moonfin/ui/navigation/destinations.dart';

import 'player.dart';
import 'shell.dart';

/// Plays an item for a Foreseerr user, from a play link in Foreseerr's page:
///
/// `foreseerr-player://open?foreseerr=<url>&ticket=<ticket>`
/// `[&id=<itemId>[&startTicks=<ticks>]]` (`pair` works the same)
///
/// Foreseerr sends a fresh single-use ticket with every play. The player
/// asks Foreseerr which Jellyfin server and user it is for, switches to that
/// user when it is already signed in, and otherwise redeems the ticket for
/// the Jellyfin session Foreseerr holds for that user and signs in with it.
/// Then it plays `id`. A ticket it didn't need just expires.
class ForeseerrPairing {
  ForeseerrPairing._();

  static final instance = ForeseerrPairing._();

  bool _busy = false;

  static bool isOpenLink(Uri uri) => uri.host == 'open' || uri.host == 'pair';

  Future<void> open(Uri link) async {
    final query = link.queryParameters;
    final foreseerr = Uri.tryParse(query['foreseerr'] ?? '');
    final ticket = query['ticket'];
    final shell = ForeseerrShell.instance;
    if (foreseerr == null ||
        !(foreseerr.isScheme('http') || foreseerr.isScheme('https')) ||
        foreseerr.host.isEmpty ||
        ticket == null ||
        ticket.isEmpty) {
      shell.notice(
        'This link from Foreseerr is incomplete.',
        clearAfter: _errorTime,
      );
      return;
    }
    if (_busy) return;
    _busy = true;
    try {
      await signIn(foreseerr, ticket);
      shell.notice(null);
      final id = query['id'];
      if (id != null && id.isNotEmpty) {
        await ForeseerrPlayer.instance.play(
          id,
          startTicks: int.tryParse(query['startTicks'] ?? ''),
        );
      }
    } catch (e, st) {
      debugPrint('[Foreseerr] open failed: $e\n$st');
      shell.notice('Could not play: ${_describe(e)}', clearAfter: _errorTime);
    } finally {
      _busy = false;
    }
  }

  static const _errorTime = Duration(seconds: 8);

  /// Makes the ticket's user the player's active session, signing in when
  /// needed.
  Future<void> signIn(Uri foreseerr, String ticket) async {
    await _startupSettled();
    final base = foreseerr.toString().replaceFirst(RegExp(r'/+$'), '');
    final api = Dio(
      BaseOptions(
        baseUrl: '$base/api/v1/player/pair-tickets',
        connectTimeout: const Duration(seconds: 10),
        receiveTimeout: const Duration(seconds: 20),
        contentType: Headers.jsonContentType,
      ),
    );
    final info = (await api.post<Map<String, dynamic>>(
      '/info',
      data: {'ticket': ticket},
    )).data!;
    final urls = (info['serverUrls'] as List).cast<String>();
    final userId = info['userId'] as String;

    final servers = GetIt.instance<ServerRepository>();
    await servers.loadStoredServers();
    final server = await _server(servers, urls);
    final session = GetIt.instance<SessionRepository>();

    if (session.activeServerId == server.id && session.activeUserId == userId) {
      return;
    }
    if (!await session.switchCurrentSession(
      serverId: server.id,
      userId: userId,
      validateToken: true,
    )) {
      ForeseerrShell.instance.notice('Signing in through Foreseerr…');
      final redeemed = (await api.post<Map<String, dynamic>>(
        '/redeem',
        data: {'ticket': ticket},
      )).data!;
      await _signInWithToken(
        server,
        userId: redeemed['userId'] as String,
        token: redeemed['accessToken'] as String,
      );
    }
    ForeseerrPlayer.instance.park();
  }

  /// Waits for startup to restore the last session, as Moonfin's own links
  /// do: switching users in the middle of that would interleave two setups.
  static Future<void> _startupSettled() async {
    for (var i = 0; i < 60; i++) {
      final path = appRouter.routerDelegate.currentConfiguration.uri.path;
      if (path != Destinations.startup) return;
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
  }

  /// Signs in with an access token Foreseerr handed over: checks it, stores
  /// the user and makes it the active session.
  static Future<void> _signInWithToken(
    Server server, {
    required String userId,
    required String token,
  }) async {
    final client = GetIt.instance<MediaServerClientFactory>().getClient(
      serverId: server.id,
      serverType: server.serverType,
      baseUrl: server.address,
    );
    client.accessToken = token;
    client.userId = userId;
    final me = await client.usersApi.getCurrentUser();
    if (me.id != userId) {
      throw StateError('The token from Foreseerr is for another user');
    }
    final user = PrivateUser(
      id: me.id,
      name: (me.name ?? '').trim().isNotEmpty ? me.name!.trim() : 'Foreseerr',
      serverId: server.id,
      accessToken: token,
      lastUsed: DateTime.now(),
      imageTag: me.primaryImageTag,
      isAdministrator: me.policy?.isAdministrator ?? false,
      canDownload: me.policy?.enableContentDownloading ?? false,
      canManageSubtitles: me.policy?.canFetchRemoteSubtitles ?? false,
      canManageCollections: me.policy?.enableCollectionManagement ?? false,
      canManageLiveTv: me.policy?.enableLiveTvManagement ?? false,
    );
    await GetIt.instance<AuthenticationStore>().putUser(user);
    final prefs = GetIt.instance<AuthenticationPreferences>();
    await prefs.setLastServerId(server.id);
    await prefs.setLastUserId(user.id);
    if (!await GetIt.instance<SessionRepository>().switchCurrentSession(
      serverId: server.id,
      userId: user.id,
    )) {
      throw StateError('Could not switch to the signed-in user');
    }
  }

  /// The stored server at one of [urls], added when there is none yet.
  static Future<Server> _server(
    ServerRepository servers,
    List<String> urls,
  ) async {
    for (final url in urls) {
      try {
        final server = await servers.addServer(url);
        if (server != null) return server;
      } catch (e) {
        debugPrint('[Foreseerr] $url unreachable: $e');
      }
    }
    throw StateError('Jellyfin is unreachable at ${urls.join(', ')}');
  }

  static String _describe(Object e) {
    if (e is DioException) {
      final data = e.response?.data;
      final code = data is Map ? data['code'] : null;
      if (code != null) return '$code';
      return e.message ?? e.type.name;
    }
    if (e is StateError) return e.message;
    return '$e';
  }
}
