import 'dart:async';
import 'dart:io' show Platform, stderr;

import 'package:flutter/foundation.dart';
import 'package:moonfin/main.dart' as moonfin;
import 'package:moonfin/ui/navigation/app_router.dart' show appRouter;

import 'player.dart';
import 'shell.dart';

/// The Foreseerr app's entry point (`flutter build linux -t
/// lib/foreseerr/main.dart`): Moonfin, started exactly as Moonfin starts
/// itself, with Foreseerr's web UI in the window and Moonfin's player taking
/// over while something plays.
///
/// Launched with a `foreseerr-player://open?…` link for the saved
/// Foreseerr, it plays that link once Foreseerr is up.
Future<void> main(List<String> args) async {
  final Object? started = Function.apply(moonfin.main, const []);
  if (kIsWeb || !Platform.isLinux) return;
  await _moonfinReady(started);

  await ForeseerrPlayer.instance.start();
  final shell = ForeseerrShell.instance;
  await shell.start();
  stderr.writeln('[Foreseerr] started');
  for (final arg in args) {
    if (!arg.startsWith('${ForeseerrShell.linkScheme}:')) continue;
    final link = Uri.tryParse(arg);
    if (link != null) shell.openLink(link);
  }
}

/// Moonfin's main is `void … async`; its future still says when it has
/// called runApp. Then its router needs a navigator.
Future<void> _moonfinReady(Object? started) async {
  if (started is Future<void>) {
    await started.timeout(
      const Duration(seconds: 30),
      onTimeout: () =>
          stderr.writeln("[Foreseerr] Moonfin's main is still running"),
    );
  }
  while (appRouter.routerDelegate.navigatorKey.currentState == null) {
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
}
