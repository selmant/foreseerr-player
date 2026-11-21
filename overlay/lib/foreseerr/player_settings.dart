import 'dart:async';

import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';
import 'package:moonfin/auth/repositories/session_repository.dart';
import 'package:moonfin/data/services/plugin_sync_service.dart';
import 'package:moonfin/l10n/app_localizations.dart';
import 'package:moonfin/preference/user_preferences.dart';
import 'package:moonfin/ui/navigation/app_router.dart' show appRouter;
import 'package:moonfin/ui/screens/settings/settings_side_panel.dart'
    show settingsScreensUnder;
import 'package:moonfin/ui/widgets/settings/preference_tiles.dart';
import 'package:moonfin/ui/widgets/settings/settings_section_header.dart';
import 'package:server_core/server_core.dart' show MediaServerClient;

/// Moonfin's player settings as data, for Foreseerr to show in its own UI.
///
/// Nothing here lists settings by hand. The screens come from Moonfin's
/// settings search index (everything under Playback), each is built
/// off-screen for a frame, and every standard preference tile on it is read
/// back: its preference, title, description, options and labels. Platform
/// checks, translations and settings that only show when another is on all
/// come out as Moonfin's own screens have them. Custom widgets that aren't
/// one of the standard tiles are left out.
///
/// Schema (version 1):
///
/// ```json
/// {"version": 1, "pages": [{"path": ["Player"], "sections": [
///   {"title": "…" | null, "settings": [
///     {"key", "type": "switch", "title", "description", "value": bool,
///      "enabled"},
///     {"key", "type": "choice", …, "value", "options": [{"value", "label"}]},
///     {"key", "type": "multi", …, "value": [..], "options", "max",
///      "emptyLabel"},
///     {"key", "type": "slider", …, "value": int, "min", "max", "step",
///      "label", "labels": {"<value>": "<label>"}}
///   ]}
/// ]}]}
/// ```
class PlayerSettings {
  PlayerSettings._();

  static final instance = PlayerSettings._();

  /// The tiles of the last export, by preference key, for [set].
  final Map<String, Widget> _tiles = {};
  Future<void> _queue = Future.value();

  /// The current schema, values included.
  Future<Map<String, Object?>> export() => _serialized(_export);

  /// Sets one setting the way its tile would, then exports again: other
  /// settings may appear, disappear or change with it.
  Future<Map<String, Object?>> set(String key, Object? value) =>
      _serialized(() async {
        await _apply(key, value);
        return _export();
      });

  Future<T> _serialized<T>(Future<T> Function() task) {
    final result = _queue.then((_) => task());
    _queue = result.then((_) {}, onError: (_) {});
    return result;
  }

  /// Why there are no settings yet: the player has never signed in to
  /// Jellyfin, which Moonfin's settings assume. Pairing fixes it.
  static const notPaired = 'not_paired';

  Future<Map<String, Object?>> _export() async {
    // Right after start the last session is still being restored.
    for (var i = 0; i < 60 && !_signedIn; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    if (!_signedIn) throw StateError(notPaired);
    // Sign-in then applies the settings Moonfin keeps on the server, which
    // would overwrite a change made before it is done.
    final sync = GetIt.instance<PluginSyncService>();
    final serverId = GetIt.instance<SessionRepository>().activeServerId;
    for (var i = 0; i < 60; i++) {
      if (sync.hasReadSignInSettings(
        GetIt.instance<MediaServerClient>(),
        serverId: serverId,
      )) {
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    final overlay = appRouter.routerDelegate.navigatorKey.currentState?.overlay;
    if (overlay == null || !overlay.mounted) {
      throw StateError('the app is still starting');
    }
    // Read after the wait, from the overlay as it is now.
    // ignore: use_build_context_synchronously
    final l10n = AppLocalizations.of(overlay.context);
    final screens = settingsScreensUnder(l10n, l10n.playback);
    final keys = [for (final _ in screens) GlobalKey()];
    // Built for real but never shown: tall enough that every list builds all
    // of its rows.
    final entry = OverlayEntry(
      builder: (_) => IgnorePointer(
        child: Offstage(
          child: Stack(
            children: [
              for (var i = 0; i < screens.length; i++)
                Positioned(
                  left: 0,
                  top: 0,
                  width: 900,
                  height: 30000,
                  child: KeyedSubtree(key: keys[i], child: screens[i].screen),
                ),
            ],
          ),
        ),
      ),
    );
    overlay.insert(entry);
    try {
      await _frame();
      // Screens that look something up first build their tiles a moment
      // later.
      await Future<void>.delayed(const Duration(milliseconds: 150));
      await _frame();
      _tiles.clear();
      final pages = <Map<String, Object?>>[];
      for (var i = 0; i < screens.length; i++) {
        final root = keys[i].currentContext;
        if (root == null || !root.mounted) continue;
        final sections = _read(root as Element);
        if (sections.isEmpty) continue;
        pages.add({'path': screens[i].path, 'sections': sections});
      }
      return {'version': 1, 'pages': pages};
    } finally {
      entry.remove();
    }
  }

  static bool get _signedIn => GetIt.instance.isRegistered<MediaServerClient>();

  static Future<void> _frame() async {
    WidgetsBinding.instance.scheduleFrame();
    await Future.any([
      WidgetsBinding.instance.endOfFrame,
      Future<void>.delayed(const Duration(seconds: 2)),
    ]);
  }

  List<Map<String, Object?>> _read(Element root) {
    final sections = <Map<String, Object?>>[];
    String? title;
    var settings = <Map<String, Object?>>[];
    void close() {
      if (settings.isNotEmpty) {
        sections.add({'title': title, 'settings': settings});
      }
      settings = [];
    }

    void visit(Element element) {
      final widget = element.widget;
      if (widget is SettingsSectionHeader) {
        close();
        title = widget.text;
        return;
      }
      final setting = _describe(widget);
      if (setting != null) {
        _tiles.putIfAbsent(setting['key']! as String, () => widget);
        settings.add(setting);
        return;
      }
      element.visitChildren(visit);
    }

    root.visitChildren(visit);
    close();
    return sections;
  }

  static UserPreferences get _prefs => GetIt.instance<UserPreferences>();

  // Enum tiles are read through `dynamic`: their label functions take the
  // tile's own enum type, which a typed read as `Enum` would reject.
  static Map<String, Object?>? _describe(Widget widget) {
    switch (widget) {
      case SwitchPreferenceTile tile:
        final stored = _prefs.get(tile.preference);
        return {
          'key': tile.preference.key,
          'type': 'switch',
          'title': tile.title,
          'description': tile.subtitle,
          'value': tile.inverted ? !stored : stored,
          'enabled': tile.enabled,
        };
      case EnumPreferenceTile():
        final dynamic tile = widget;
        final List<Enum> values =
            (tile.values as List<Object?>?)?.cast<Enum>() ??
            (tile.preference.values as List<Object?>).cast<Enum>();
        final Object? current = _prefs.get<dynamic>(tile.preference);
        return {
          'key': tile.preference.key as String,
          'type': 'choice',
          'title': tile.title as String,
          'description': tile.description as String?,
          'value': (current as Enum?)?.name,
          'options': [
            for (final v in values)
              {'value': v.name, 'label': tile.labelOf(v) as String},
          ],
          'enabled': tile.enabled as bool,
        };
      case StringPickerPreferenceTile tile:
        return {
          'key': tile.preference.key,
          'type': 'choice',
          'title': tile.title,
          'description': tile.description,
          'value': _prefs.get(tile.preference),
          'options': [
            for (final o in tile.options.entries)
              {'value': o.key, 'label': o.value},
          ],
          'enabled': true,
        };
      case IntPickerPreferenceTile tile:
        return {
          'key': tile.preference.key,
          'type': 'choice',
          'title': tile.title,
          'description': tile.description,
          'value': _prefs.get(tile.preference),
          'options': [
            for (final o in tile.options.entries)
              {'value': o.key, 'label': o.value},
          ],
          'enabled': true,
        };
      case MultiSelectPreferenceTile tile:
        final stored = _prefs.get(tile.preference);
        return {
          'key': tile.preference.key,
          'type': 'multi',
          'title': tile.title,
          'description': tile.description,
          'value': [
            for (final v in stored.split(','))
              if (v.isNotEmpty && tile.options.containsKey(v)) v,
          ],
          'options': [
            for (final o in tile.options.entries)
              {'value': o.key, 'label': o.value},
          ],
          'max': tile.maxSelected,
          'emptyLabel': tile.emptyLabel,
          'enabled': true,
        };
      case SliderPreferenceTile tile:
        final value = _prefs.get(tile.preference);
        final min = tile.min.round();
        final max = tile.max.round();
        final divisions = tile.divisions;
        final step = divisions == null || divisions <= 0
            ? 1
            : ((max - min) / divisions).round().clamp(1, 1 << 30);
        final labelOf = tile.labelOf ?? (int v) => '$v';
        final count = (max - min) ~/ step + 1;
        return {
          'key': tile.preference.key,
          'type': 'slider',
          'title': tile.title,
          'description': tile.description,
          'value': value,
          'min': min,
          'max': max,
          'step': step,
          'label': labelOf(value),
          if (count <= 401)
            'labels': {for (var v = min; v <= max; v += step) '$v': labelOf(v)},
          'enabled': tile.enabled,
        };
    }
    return null;
  }

  Future<void> _apply(String key, Object? value) async {
    final widget = _tiles[key];
    if (widget == null) throw ArgumentError('unknown setting $key');
    switch (widget) {
      case SwitchPreferenceTile tile:
        if (value is! bool) throw ArgumentError('$key takes true or false');
        final stored = tile.inverted ? !value : value;
        await _prefs.set(tile.preference, stored);
        tile.onChanged?.call();
        tile.onChangedValue?.call(stored);
      case EnumPreferenceTile():
        final dynamic tile = widget;
        final List<Enum> values =
            (tile.values as List<Object?>?)?.cast<Enum>() ??
            (tile.preference.values as List<Object?>).cast<Enum>();
        final picked = values.where((v) => v.name == value).firstOrNull;
        if (picked == null) throw ArgumentError('$key has no option $value');
        await _prefs.set<dynamic>(tile.preference, picked);
        tile.onChanged?.call();
        tile.onChangedValue?.call(picked);
      case StringPickerPreferenceTile tile:
        if (value is! String || !tile.options.containsKey(value)) {
          throw ArgumentError('$key has no option $value');
        }
        await _prefs.set(tile.preference, value);
        tile.onChanged?.call();
      case IntPickerPreferenceTile tile:
        if (value is! int || !tile.options.containsKey(value)) {
          throw ArgumentError('$key has no option $value');
        }
        await _prefs.set(tile.preference, value);
        tile.onChanged?.call();
      case MultiSelectPreferenceTile tile:
        if (value is! List) throw ArgumentError('$key takes a list');
        final picked = value.whereType<String>().toSet();
        final ordered = [
          for (final k in tile.options.keys)
            if (picked.contains(k)) k,
        ];
        final max = tile.maxSelected;
        if (max != null && ordered.length > max) {
          throw ArgumentError('$key takes at most $max');
        }
        await _prefs.set(tile.preference, ordered.join(','));
      case SliderPreferenceTile tile:
        if (value is! int || value < tile.min || value > tile.max) {
          throw ArgumentError('$key takes ${tile.min}–${tile.max}');
        }
        await _prefs.set(tile.preference, value);
        tile.onChangeEnd?.call();
      default:
        throw ArgumentError('unknown setting $key');
    }
  }
}
