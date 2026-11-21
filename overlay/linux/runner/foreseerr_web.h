#ifndef RUNNER_FORESEERR_WEB_H_
#define RUNNER_FORESEERR_WEB_H_

#include <gio/gio.h>

// Foreseerr's web UI over Moonfin's player.
//
// Call once from main(), before the application runs. Sets what WebKit needs
// from the environment, then, when the application window gets its Flutter
// view, puts the view in an overlay with a black curtain and the web view
// over it, and registers the foreseerr/web channel the Dart side drives
// (lib/foreseerr/shell.dart). Moonfin's own runner code stays as it is.
void foreseerr_web_install(GApplication* application);

#endif  // RUNNER_FORESEERR_WEB_H_
