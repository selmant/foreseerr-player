import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:moonfin/util/app_exit.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'pages.dart';
import 'pairing.dart';
import 'player_settings.dart';

/// The window's web view (`linux/runner/foreseerr_web.cc`): Foreseerr's own
/// web UI, loaded from its server, or the app's setup and error pages.
///
/// Play buttons in Foreseerr's page navigate to a `foreseerr-player://open`
/// link, which the runner hands here instead of loading ([ForeseerrPairing]
/// plays it). The page can also ask the app for things through
/// `window.foreseerrPlayer.request(message)` (see [_answer]).
class ForeseerrShell {
  ForeseerrShell._();

  static final instance = ForeseerrShell._();

  /// The scheme of Foreseerr's play links.
  static const linkScheme = 'foreseerr-player';

  static const _channel = MethodChannel('foreseerr/web');
  static const _urlKey = 'foreseerr.url';

  /// The Foreseerr address in use, or null before setup.
  String? get url => _url;
  String? _url;

  /// Whether the web view has something to show yet.
  final ValueNotifier<bool> hasPage = ValueNotifier<bool>(false);

  Timer? _noticeTimer;

  /// Loads the saved Foreseerr, or asks for one.
  Future<void> start() async {
    _channel.setMethodCallHandler(_onCall);
    final saved = (await SharedPreferences.getInstance()).getString(_urlKey);
    if (saved == null) {
      await _page(ForeseerrPages.setup());
    } else {
      await _load(saved);
    }
  }

  /// What the window shows: `web`, `blank` or `player`.
  Future<void> setMode(String mode) => _invoke('mode', mode);

  /// Shows [text] over Foreseerr's page until it changes or [clearAfter]
  /// passes; null takes it away.
  void notice(String? text, {Duration? clearAfter}) {
    _noticeTimer?.cancel();
    unawaited(_invoke('script', _noticeScript(text)));
    if (text != null && clearAfter != null) {
      _noticeTimer = Timer(clearAfter, () => notice(null));
    }
  }

  /// Plays [link] when it is a play link for this Foreseerr: a page
  /// elsewhere can't point the player at another server.
  void openLink(Uri link) {
    if (!link.isScheme(linkScheme) || !ForeseerrPairing.isOpenLink(link)) {
      return;
    }
    final home = _origin(_url);
    if (home == null || home != _origin(link.queryParameters['foreseerr'])) {
      return;
    }
    unawaited(ForeseerrPairing.instance.open(link));
  }

  Future<void> _load(String address) async {
    _url = address;
    await _invoke('load', {'url': address});
    hasPage.value = true;
  }

  Future<void> _page(String html) async {
    await _invoke('page', {'html': html});
    hasPage.value = true;
  }

  Future<void> _invoke(String method, Object? arguments) async {
    try {
      await _channel.invokeMethod<void>(method, arguments);
    } on PlatformException catch (e) {
      debugPrint('[Foreseerr] $method failed: ${e.message ?? e.code}');
    }
  }

  /// Checks that [address] is a Foreseerr server, then saves and opens it.
  Future<void> _connect(String address) async {
    var text = address.trim().replaceFirst(RegExp(r'/+$'), '');
    if (!text.contains('://')) text = 'https://$text';
    final uri = Uri.tryParse(text);
    String? error;
    if (uri == null ||
        !(uri.isScheme('http') || uri.isScheme('https')) ||
        uri.host.isEmpty) {
      error = 'That is not a web address.';
    } else {
      try {
        final status = await Dio(
          BaseOptions(
            connectTimeout: const Duration(seconds: 10),
            receiveTimeout: const Duration(seconds: 10),
          ),
        ).get<Object?>('$text/api/v1/status');
        final data = status.data;
        if (data is! Map || data['version'] == null) {
          error = 'No Foreseerr at $text.';
        }
      } on DioException catch (e) {
        error = 'Could not reach $text: ${e.message ?? e.type.name}';
      }
    }
    if (error != null) {
      await _page(ForeseerrPages.setup(address: address, error: error));
      return;
    }
    await (await SharedPreferences.getInstance()).setString(_urlKey, text);
    await _load(text);
  }

  Future<Object?> _onCall(MethodCall call) async {
    final argument = call.arguments as String? ?? '';
    switch (call.method) {
      case 'open':
        final link = Uri.tryParse(argument);
        if (link != null) openLink(link);
      case 'page':
        await _onPageAction(Uri.tryParse(argument));
      case 'loadFailed':
        final url = _url;
        if (url != null) {
          await _page(ForeseerrPages.loadError(url, argument));
        }
      case 'message':
        return _answer(argument);
    }
    return null;
  }

  /// A button on one of [ForeseerrPages].
  Future<void> _onPageAction(Uri? action) async {
    switch (action?.path) {
      case 'connect':
        await _connect(action!.queryParameters['address'] ?? '');
      case 'retry':
        final url = _url;
        if (url != null) await _load(url);
      case 'change':
        final previous = _url;
        _url = null;
        await (await SharedPreferences.getInstance()).remove(_urlKey);
        await _page(ForeseerrPages.setup(address: previous ?? ''));
    }
  }

  /// Answers a page's `foreseerrPlayer.request(message)`:
  ///
  /// - `{"type": "settings"}`: the player settings ([PlayerSettings]).
  /// - `{"type": "setSetting", "key", "value"}`: sets one; answers with the
  ///   settings as they are after it.
  /// - `{"type": "pair", "ticket"}`: signs the player in as the ticket's
  ///   user, as a play would, when settings answered `not_paired`; answers
  ///   whether it worked.
  /// - `{"type": "quit"}`: quits the app, right after answering.
  /// - `{"type": "clearCache"}`: clears the web view's HTTP cache (not its
  ///   cookies or storage).
  /// - `{"type": "changeAddress"}`: shows the setup page, right after
  ///   answering, to open another Foreseerr.
  ///
  /// Always a JSON `{"result": …}` or `{"error": "…"}`.
  Future<String> _answer(String message) async {
    try {
      final request = jsonDecode(message);
      if (request is! Map) throw const FormatException('not an object');
      final result = switch (request['type']) {
        'settings' => await PlayerSettings.instance.export(),
        'setSetting' => await PlayerSettings.instance.set(
          request['key'] as String,
          request['value'],
        ),
        'pair' => await _pair(request['ticket'] as String),
        'quit' => _afterAnswer(AppExit.closeApp),
        'clearCache' => await _clearCache(),
        'changeAddress' => _afterAnswer(
          () => _onPageAction(Uri(path: 'change')),
        ),
        final type => throw ArgumentError('unknown request $type'),
      };
      return jsonEncode({'result': result});
    } catch (e) {
      debugPrint('[Foreseerr] request failed: $e');
      final text = switch (e) {
        ArgumentError(:final message) => '$message',
        StateError(:final message) => message,
        _ => '$e',
      };
      return jsonEncode({'error': text});
    }
  }

  /// Runs [action] once the answer is on its way: it takes the page away.
  static bool _afterAnswer(Future<void> Function() action) {
    Timer(const Duration(milliseconds: 100), () => unawaited(action()));
    return true;
  }

  Future<bool> _clearCache() async {
    await _channel.invokeMethod<void>('clearCache');
    return true;
  }

  Future<bool> _pair(String ticket) async {
    final home = _url;
    if (home == null) throw StateError('no Foreseerr address');
    try {
      await ForeseerrPairing.instance.signIn(Uri.parse(home), ticket);
      return true;
    } catch (e) {
      debugPrint('[Foreseerr] pairing failed: $e');
      return false;
    }
  }

  static String? _origin(String? address) {
    final uri = Uri.tryParse(address ?? '');
    if (uri == null || uri.host.isEmpty) return null;
    try {
      return uri.origin.toLowerCase();
    } on StateError {
      return null;
    }
  }

  /// A small status line at the bottom of Foreseerr's page.
  static String _noticeScript(String? text) =>
      '''
(() => {
  const id = 'foreseerr-player-notice';
  const text = ${jsonEncode(text)};
  let notice = document.getElementById(id);
  if (text === null) {
    notice?.remove();
    return;
  }
  if (!notice) {
    notice = document.createElement('div');
    notice.id = id;
    notice.setAttribute('role', 'status');
    Object.assign(notice.style, {
      position: 'fixed', left: '50%', bottom: '24px', zIndex: '2147483647',
      transform: 'translateX(-50%)', maxWidth: 'min(90vw, 560px)',
      padding: '12px 18px', borderRadius: '8px', whiteSpace: 'pre-line',
      background: 'rgba(17, 24, 39, 0.95)', color: '#f3f4f6',
      border: '1px solid #4b5563', boxShadow: '0 10px 25px rgba(0, 0, 0, 0.5)',
      font: '14px/1.4 system-ui, sans-serif', pointerEvents: 'none',
    });
    document.body.append(notice);
  }
  notice.textContent = text;
})();''';
}
