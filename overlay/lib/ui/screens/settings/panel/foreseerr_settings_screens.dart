part of '../settings_side_panel.dart';

/// The screens under [category] (a top-level category title, such as
/// `l10n.playback`), in settings search order, each with its breadcrumb
/// below the category. Read from the settings search index, so a screen
/// Moonfin adds there shows up here too.
List<({List<String> path, Widget screen})> settingsScreensUnder(
  AppLocalizations l10n,
  String category,
) {
  Widget? opened;
  final index = _buildSettingsSearchIndex(
    l10n: l10n,
    showAdmin: false,
    showThemeEditor: false,
    push: (screen) => opened = screen,
    openAdmin: () {},
    openThemeEditor: () {},
  );
  final seen = <String>{};
  final screens = <({List<String> path, Widget screen})>[];
  for (final entry in index) {
    if (entry.path.isEmpty || entry.path.first != category) continue;
    if (!seen.add(entry.path.join('\u0000'))) continue;
    opened = null;
    entry.onOpen();
    final screen = opened;
    if (screen != null) {
      screens.add((path: entry.path.sublist(1), screen: screen));
    }
  }
  return screens;
}
