#include "foreseerr_web.h"

#include <fcntl.h>
#include <flutter_linux/flutter_linux.h>
#include <gdk/gdkkeysyms.h>
#include <gtk/gtk.h>
#include <unistd.h>
#include <webkit2/webkit2.h>

#include <cstdio>

// The WebKitGTK 4.1 API this uses (website data manager, persistent cookie
// storage) is deprecated in newer releases, but still the only way there.
#pragma GCC diagnostic ignored "-Wdeprecated-declarations"

namespace {

// Foreseerr's play links, from its pages.
constexpr char kPlayScheme[] = "foreseerr-player:";
// The app's own pages (setup, load errors) ask for things with these.
constexpr char kPageScheme[] = "foreseerr-app:";

constexpr char kMessageHandler[] = "foreseerrPlayer";

// Runs in Foreseerr's pages only. Marks the page as the app's
// (`html.native-shell`), which keeps Foreseerr's in-app chrome and its
// animation hints, and gives it `foreseerrPlayer.request(message)`: a JSON
// message to the app, answered with a promise (see lib/foreseerr/shell.dart).
constexpr char kBridgeScript[] = R"js((() => {
  const handler = window.webkit?.messageHandlers?.foreseerrPlayer;
  if (handler) {
    window.foreseerrPlayer = Object.freeze({
      version: 1,
      request: (message) =>
        handler.postMessage(JSON.stringify(message)).then((reply) => {
          const data = JSON.parse(reply);
          if (data.error) throw new Error(data.error);
          return data.result;
        }),
    });
  }
  const mark = () => {
    const root = document.documentElement;
    if (root && !root.classList.contains('native-shell')) {
      root.classList.add('native-shell');
    }
  };
  mark();
  const root = document.documentElement;
  if (root) {
    new MutationObserver(mark).observe(root, {
      attributes: true,
      attributeFilter: ['class'],
    });
  }
})();)js";

FlView* flutter_view = nullptr;
GtkWidget* overlay = nullptr;
GtkWidget* curtain = nullptr;
WebKitWebView* web = nullptr;
WebKitUserContentManager* content = nullptr;
FlMethodChannel* channel = nullptr;
gchar* home_origin = nullptr;
// Whether the web view shows one of the app's own pages, and which.
bool own_page = false;
gchar* own_html = nullptr;
// "web", "blank" or "player"; see SetMode.
gchar* mode = nullptr;

// scheme://host[:port], without default ports; null for non-network URIs.
gchar* OriginOf(const gchar* uri) {
  g_autoptr(GUri) parsed = g_uri_parse(uri, G_URI_FLAGS_NONE, nullptr);
  if (parsed == nullptr) return nullptr;
  const gchar* scheme = g_uri_get_scheme(parsed);
  const gchar* host = g_uri_get_host(parsed);
  if (scheme == nullptr || host == nullptr || *host == '\0') return nullptr;
  g_autofree gchar* lower_scheme = g_ascii_strdown(scheme, -1);
  g_autofree gchar* lower_host = g_ascii_strdown(host, -1);
  int port = g_uri_get_port(parsed);
  bool default_port = port == -1 ||
                      (port == 80 && g_str_equal(lower_scheme, "http")) ||
                      (port == 443 && g_str_equal(lower_scheme, "https"));
  if (default_port) return g_strdup_printf("%s://%s", lower_scheme, lower_host);
  return g_strdup_printf("%s://%s:%d", lower_scheme, lower_host, port);
}

bool IsHome(const gchar* uri) {
  if (home_origin == nullptr || uri == nullptr) return false;
  g_autofree gchar* origin = OriginOf(uri);
  return origin != nullptr && g_str_equal(origin, home_origin);
}

bool IsWebUri(const gchar* uri) {
  return g_str_has_prefix(uri, "https://") || g_str_has_prefix(uri, "http://");
}

void Notify(const gchar* method, const gchar* argument) {
  if (channel == nullptr) return;
  g_autoptr(FlValue) value = fl_value_new_string(argument);
  fl_method_channel_invoke_method(channel, method, value, nullptr, nullptr,
                                  nullptr);
}

void OpenExternally(const gchar* uri) {
  g_autoptr(GError) error = nullptr;
  if (!g_app_info_launch_default_for_uri(uri, nullptr, &error)) {
    g_warning("Could not open %s: %s", uri, error->message);
  }
}

gboolean OnDecidePolicy(WebKitWebView* view, WebKitPolicyDecision* decision,
                        WebKitPolicyDecisionType type, gpointer) {
  if (type == WEBKIT_POLICY_DECISION_TYPE_RESPONSE) return FALSE;
  WebKitNavigationAction* action =
      webkit_navigation_policy_decision_get_navigation_action(
          WEBKIT_NAVIGATION_POLICY_DECISION(decision));
  const gchar* uri =
      webkit_uri_request_get_uri(webkit_navigation_action_get_request(action));
  if (uri == nullptr) return FALSE;

  // Foreseerr's play handoff: the player takes it from here.
  if (g_str_has_prefix(uri, kPlayScheme)) {
    webkit_policy_decision_ignore(decision);
    if (!own_page && IsHome(webkit_web_view_get_uri(view))) {
      Notify("open", uri);
    }
    return TRUE;
  }
  // A button on the app's own page.
  if (g_str_has_prefix(uri, kPageScheme)) {
    webkit_policy_decision_ignore(decision);
    if (own_page) Notify("page", uri);
    return TRUE;
  }

  bool new_window = type == WEBKIT_POLICY_DECISION_TYPE_NEW_WINDOW_ACTION;
  if (new_window && IsHome(uri)) {
    // There is one window: Foreseerr's own pages open in it.
    webkit_policy_decision_ignore(decision);
    webkit_web_view_load_uri(view, uri);
    return TRUE;
  }
  // Links out of Foreseerr (TMDB, IMDb, trailers) go to the browser.
  bool clicked_out =
      !IsHome(uri) && webkit_navigation_action_is_user_gesture(action);
  if ((new_window || clicked_out) && IsWebUri(uri)) {
    webkit_policy_decision_ignore(decision);
    OpenExternally(uri);
    return TRUE;
  }
  return FALSE;
}

gboolean OnLoadFailed(WebKitWebView*, WebKitLoadEvent, gchar*, GError* error,
                      gpointer) {
  if (g_error_matches(error, WEBKIT_NETWORK_ERROR,
                      WEBKIT_NETWORK_ERROR_CANCELLED) ||
      g_error_matches(error, WEBKIT_POLICY_ERROR,
                      WEBKIT_POLICY_ERROR_FRAME_LOAD_INTERRUPTED_BY_POLICY_CHANGE)) {
    return FALSE;
  }
  Notify("loadFailed", error->message);
  // The app shows its own page with a retry instead of WebKit's.
  return TRUE;
}

struct PendingReply {
  WebKitScriptMessageReply* reply;
  JSCContext* context;
};

void OnMessageAnswered(GObject* object, GAsyncResult* result,
                       gpointer user_data) {
  auto* pending = static_cast<PendingReply*>(user_data);
  g_autoptr(GError) error = nullptr;
  g_autoptr(FlMethodResponse) response = fl_method_channel_invoke_method_finish(
      FL_METHOD_CHANNEL(object), result, &error);
  FlValue* value =
      response != nullptr ? fl_method_response_get_result(response, &error)
                          : nullptr;
  if (value != nullptr && fl_value_get_type(value) == FL_VALUE_TYPE_STRING) {
    g_autoptr(JSCValue) answer =
        jsc_value_new_string(pending->context, fl_value_get_string(value));
    webkit_script_message_reply_return_value(pending->reply, answer);
  } else {
    webkit_script_message_reply_return_error_message(
        pending->reply, error != nullptr ? error->message : "no answer");
  }
  webkit_script_message_reply_unref(pending->reply);
  g_object_unref(pending->context);
  g_free(pending);
}

// A request from the page; the app answers it through the channel.
gboolean OnScriptMessage(WebKitUserContentManager*, JSCValue* value,
                         WebKitScriptMessageReply* reply, gpointer) {
  if (channel == nullptr || own_page ||
      !IsHome(webkit_web_view_get_uri(web)) || !jsc_value_is_string(value)) {
    webkit_script_message_reply_return_error_message(reply, "not allowed");
    return TRUE;
  }
  g_autofree gchar* text = jsc_value_to_string(value);
  auto* pending = g_new0(PendingReply, 1);
  pending->reply = webkit_script_message_reply_ref(reply);
  pending->context = JSC_CONTEXT(g_object_ref(jsc_value_get_context(value)));
  g_autoptr(FlValue) argument = fl_value_new_string(text);
  fl_method_channel_invoke_method(channel, "message", argument, nullptr,
                                  OnMessageAnswered, pending);
  return TRUE;
}

void OnWebProcessTerminated(WebKitWebView* view,
                            WebKitWebProcessTerminationReason, gpointer) {
  if (own_page && own_html != nullptr) {
    webkit_web_view_load_html(view, own_html, "about:blank");
  } else {
    webkit_web_view_reload(view);
  }
}

void ToggleFullscreen() {
  GtkWidget* toplevel = gtk_widget_get_toplevel(GTK_WIDGET(web));
  GdkWindow* window = gtk_widget_get_window(toplevel);
  if (window == nullptr) return;
  if (gdk_window_get_state(window) & GDK_WINDOW_STATE_FULLSCREEN) {
    gtk_window_unfullscreen(GTK_WINDOW(toplevel));
  } else {
    gtk_window_fullscreen(GTK_WINDOW(toplevel));
  }
}

// Page zoom, as in a browser, kept across runs.
constexpr double kZoomSteps[] = {0.5, 0.67, 0.75, 0.8,  0.9, 1.0, 1.1,
                                 1.25, 1.5, 1.75, 2.0, 2.5, 3.0};
// Smooth (touchpad) scrolling with Ctrl, not yet a whole step.
double scroll_zoom = 0;

gchar* ZoomFile() {
  return g_build_filename(g_get_user_data_dir(), APPLICATION_ID, "web-zoom",
                          nullptr);
}

double SavedZoom() {
  g_autofree gchar* file = ZoomFile();
  g_autofree gchar* text = nullptr;
  if (!g_file_get_contents(file, &text, nullptr, nullptr)) return 1.0;
  double level = g_ascii_strtod(text, nullptr);
  double low = kZoomSteps[0];
  double high = kZoomSteps[G_N_ELEMENTS(kZoomSteps) - 1];
  return level >= low && level <= high ? level : 1.0;
}

// Shows the new zoom for a moment at the top of the page.
void ShowZoom(double level) {
  g_autofree gchar* script = g_strdup_printf(
      R"js((() => {
  const id = 'foreseerr-player-zoom';
  let badge = document.getElementById(id);
  if (!badge) {
    badge = document.createElement('div');
    badge.id = id;
    badge.setAttribute('role', 'status');
    Object.assign(badge.style, {
      position: 'fixed', top: '16px', left: '50%%', zIndex: '2147483647',
      transform: 'translateX(-50%%)', padding: '6px 14px',
      borderRadius: '8px', background: 'rgba(17, 24, 39, 0.95)',
      color: '#f3f4f6', border: '1px solid #4b5563',
      boxShadow: '0 10px 25px rgba(0, 0, 0, 0.5)',
      font: '14px/1.4 system-ui, sans-serif', pointerEvents: 'none',
    });
    document.body.append(badge);
  }
  badge.textContent = '%d%%';
  clearTimeout(badge.foreseerrTimer);
  badge.foreseerrTimer = setTimeout(() => badge.remove(), 1200);
})();)js",
      static_cast<int>(level * 100 + 0.5));
  webkit_web_view_evaluate_javascript(web, script, -1, nullptr, nullptr,
                                      nullptr, nullptr, nullptr);
}

void SetZoom(double level) {
  if (level == webkit_web_view_get_zoom_level(web)) return;
  webkit_web_view_set_zoom_level(web, level);
  g_autofree gchar* file = ZoomFile();
  gchar text[G_ASCII_DTOSTR_BUF_SIZE];
  g_ascii_dtostr(text, sizeof text, level);
  g_file_set_contents(file, text, -1, nullptr);
  ShowZoom(level);
}

// One step in or out (+1 or -1) from the current zoom.
void StepZoom(int direction) {
  double current = webkit_web_view_get_zoom_level(web);
  int count = G_N_ELEMENTS(kZoomSteps);
  for (int i = 0; i < count; i++) {
    double step = kZoomSteps[direction > 0 ? i : count - 1 - i];
    if (direction > 0 ? step > current + 0.001 : step < current - 0.001) {
      SetZoom(step);
      return;
    }
  }
}

gboolean OnScroll(GtkWidget*, GdkEventScroll* event, gpointer) {
  guint mods = event->state & gtk_accelerator_get_default_mod_mask();
  if (mods != GDK_CONTROL_MASK) {
    scroll_zoom = 0;
    return FALSE;
  }
  switch (event->direction) {
    case GDK_SCROLL_UP:
      StepZoom(1);
      break;
    case GDK_SCROLL_DOWN:
      StepZoom(-1);
      break;
    case GDK_SCROLL_SMOOTH:
      scroll_zoom += event->delta_y;
      for (; scroll_zoom <= -1; scroll_zoom += 1) StepZoom(1);
      for (; scroll_zoom >= 1; scroll_zoom -= 1) StepZoom(-1);
      break;
    default:
      break;
  }
  return TRUE;
}

// Ctrl with +, - or 0 (Shift allowed: "+" needs it on many layouts).
bool OnZoomKey(guint mods, guint key) {
  if ((mods & ~GDK_SHIFT_MASK) != GDK_CONTROL_MASK) return false;
  switch (key) {
    case GDK_KEY_plus:
    case GDK_KEY_equal:
    case GDK_KEY_KP_Add:
      StepZoom(1);
      return true;
    case GDK_KEY_minus:
    case GDK_KEY_underscore:
    case GDK_KEY_KP_Subtract:
      StepZoom(-1);
      return true;
    case GDK_KEY_0:
    case GDK_KEY_KP_0:
      SetZoom(1.0);
      return true;
    default:
      return false;
  }
}

gboolean OnKeyPress(GtkWidget*, GdkEventKey* event, gpointer) {
  guint mods = event->state & gtk_accelerator_get_default_mod_mask();
  if (OnZoomKey(mods, event->keyval)) return TRUE;
  if (mods == GDK_MOD1_MASK && event->keyval == GDK_KEY_Left) {
    webkit_web_view_go_back(web);
    return TRUE;
  }
  if (mods == GDK_MOD1_MASK && event->keyval == GDK_KEY_Right) {
    webkit_web_view_go_forward(web);
    return TRUE;
  }
  if ((mods == 0 && event->keyval == GDK_KEY_F5) ||
      (mods == GDK_CONTROL_MASK && event->keyval == GDK_KEY_r)) {
    if (!own_page) webkit_web_view_reload(web);
    return TRUE;
  }
  if (mods == 0 && event->keyval == GDK_KEY_F11) {
    ToggleFullscreen();
    return TRUE;
  }
  return FALSE;
}

gboolean OnButtonPress(GtkWidget*, GdkEventButton* event, gpointer) {
  if (event->type != GDK_BUTTON_PRESS) return FALSE;
  if (event->button == 8) {
    webkit_web_view_go_back(web);
    return TRUE;
  }
  if (event->button == 9) {
    webkit_web_view_go_forward(web);
    return TRUE;
  }
  return FALSE;
}

gboolean OnCurtainDraw(GtkWidget*, cairo_t* cr, gpointer) {
  cairo_set_source_rgb(cr, 0, 0, 0);
  cairo_paint(cr);
  return TRUE;
}

// What the window shows:
//  - "web": the web view (Foreseerr, or the app's own page),
//  - "blank": black, while the player gets ready or between two players,
//  - "player": Flutter, which is then always Moonfin's player.
// Anything else of Moonfin's stays under the curtain.
void ApplyMode() {
  bool show_web = web != nullptr && g_strcmp0(mode, "web") == 0;
  bool show_curtain = g_strcmp0(mode, "player") != 0;
  if (show_curtain) {
    gtk_widget_show(curtain);
  } else {
    gtk_widget_hide(curtain);
  }
  if (web != nullptr) {
    // A page hidden behind the player stays quiet (trailers, previews).
    webkit_web_view_set_is_muted(web, !show_web);
    if (show_web) {
      gtk_widget_show(GTK_WIDGET(web));
    } else {
      gtk_widget_hide(GTK_WIDGET(web));
    }
  }
  gtk_widget_grab_focus(show_web ? GTK_WIDGET(web) : GTK_WIDGET(flutter_view));
}

// The web view keeps its own cookies and storage under the app's data
// directory, so Foreseerr stays signed in across runs.
void EnsureWebView() {
  if (web != nullptr) return;
  g_autofree gchar* data_dir =
      g_build_filename(g_get_user_data_dir(), APPLICATION_ID, "web", nullptr);
  g_autofree gchar* cache_dir =
      g_build_filename(g_get_user_cache_dir(), APPLICATION_ID, "web", nullptr);
  g_autofree gchar* cookie_file =
      g_build_filename(data_dir, "cookies.sqlite", nullptr);
  g_mkdir_with_parents(data_dir, 0700);

  WebKitWebsiteDataManager* data = webkit_website_data_manager_new(
      "base-data-directory", data_dir, "base-cache-directory", cache_dir,
      nullptr);
  webkit_cookie_manager_set_persistent_storage(
      webkit_website_data_manager_get_cookie_manager(data), cookie_file,
      WEBKIT_COOKIE_PERSISTENT_STORAGE_SQLITE);
  WebKitWebContext* context =
      webkit_web_context_new_with_website_data_manager(data);
  g_object_unref(data);

  content = webkit_user_content_manager_new();
  webkit_user_content_manager_register_script_message_handler_with_reply(
      content, kMessageHandler, nullptr);
  g_signal_connect(content,
                   "script-message-with-reply-received::foreseerrPlayer",
                   G_CALLBACK(OnScriptMessage), nullptr);
  web = WEBKIT_WEB_VIEW(g_object_new(WEBKIT_TYPE_WEB_VIEW, "web-context",
                                     context, "user-content-manager", content,
                                     nullptr));
  g_object_unref(context);

  WebKitSettings* settings = webkit_web_view_get_settings(web);
  webkit_settings_set_user_agent_with_application_details(
      settings, "ForeseerrPlayer", nullptr);
  webkit_settings_set_enable_developer_extras(
      settings, g_getenv("FORESEERR_WEB_DEVTOOLS") != nullptr);
  GdkRGBA background = {0.067, 0.094, 0.153, 1.0};  // Foreseerr's gray-900
  webkit_web_view_set_background_color(web, &background);
  webkit_web_view_set_zoom_level(web, SavedZoom());

  g_signal_connect(web, "decide-policy", G_CALLBACK(OnDecidePolicy), nullptr);
  g_signal_connect(web, "load-failed", G_CALLBACK(OnLoadFailed), nullptr);
  g_signal_connect(web, "web-process-terminated",
                   G_CALLBACK(OnWebProcessTerminated), nullptr);
  g_signal_connect(web, "key-press-event", G_CALLBACK(OnKeyPress), nullptr);
  g_signal_connect(web, "button-press-event", G_CALLBACK(OnButtonPress),
                   nullptr);
  g_signal_connect(web, "scroll-event", G_CALLBACK(OnScroll), nullptr);

  gtk_overlay_add_overlay(GTK_OVERLAY(overlay), GTK_WIDGET(web));
  ApplyMode();
}

void Load(const gchar* url) {
  EnsureWebView();
  own_page = false;
  g_free(home_origin);
  home_origin = OriginOf(url);

  webkit_user_content_manager_remove_all_scripts(content);
  g_autoptr(GUri) home = g_uri_parse(url, G_URI_FLAGS_NONE, nullptr);
  if (home_origin != nullptr && home != nullptr) {
    // WebKit's URL patterns have no port; IsHome still checks it for
    // messages.
    g_autofree gchar* pattern = g_strdup_printf(
        "%s://%s/*", g_uri_get_scheme(home), g_uri_get_host(home));
    const gchar* allow[] = {pattern, nullptr};
    WebKitUserScript* script = webkit_user_script_new(
        kBridgeScript, WEBKIT_USER_CONTENT_INJECT_TOP_FRAME,
        WEBKIT_USER_SCRIPT_INJECT_AT_DOCUMENT_START, allow, nullptr);
    webkit_user_content_manager_add_script(content, script);
    webkit_user_script_unref(script);
  }
  webkit_web_view_load_uri(web, url);
}

// One of the app's own pages, made by the Dart side.
void LoadPage(const gchar* html) {
  EnsureWebView();
  own_page = true;
  g_free(own_html);
  own_html = g_strdup(html);
  g_clear_pointer(&home_origin, g_free);
  webkit_user_content_manager_remove_all_scripts(content);
  webkit_web_view_load_html(web, html, "about:blank");
}

const gchar* StringArg(FlValue* args, const gchar* key) {
  FlValue* value = nullptr;
  if (args != nullptr && fl_value_get_type(args) == FL_VALUE_TYPE_MAP) {
    value = fl_value_lookup_string(args, key);
  } else if (key == nullptr) {
    value = args;
  }
  return value != nullptr && fl_value_get_type(value) == FL_VALUE_TYPE_STRING
             ? fl_value_get_string(value)
             : nullptr;
}

void OnCacheCleared(GObject* manager, GAsyncResult* result, gpointer data) {
  g_autoptr(FlMethodCall) call = FL_METHOD_CALL(data);
  g_autoptr(GError) error = nullptr;
  g_autoptr(FlMethodResponse) response = nullptr;
  if (webkit_website_data_manager_clear_finish(
          WEBKIT_WEBSITE_DATA_MANAGER(manager), result, &error)) {
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
  } else {
    response = FL_METHOD_RESPONSE(fl_method_error_response_new(
        "clear_failed", error->message, nullptr));
  }
  fl_method_call_respond(call, response, nullptr);
}

// The web view's HTTP caches; cookies and storage stay.
void ClearCache(FlMethodCall* call) {
  WebKitWebsiteDataManager* manager = webkit_web_context_get_website_data_manager(
      webkit_web_view_get_context(web));
  webkit_website_data_manager_clear(
      manager,
      static_cast<WebKitWebsiteDataTypes>(WEBKIT_WEBSITE_DATA_MEMORY_CACHE |
                                          WEBKIT_WEBSITE_DATA_DISK_CACHE),
      0, nullptr, OnCacheCleared, g_object_ref(call));
}

void HandleMethod(FlMethodChannel*, FlMethodCall* call, gpointer) {
  const gchar* method = fl_method_call_get_name(call);
  FlValue* args = fl_method_call_get_args(call);
  g_autoptr(FlMethodResponse) response = nullptr;
  const gchar* argument = nullptr;

  if (g_str_equal(method, "load") && (argument = StringArg(args, "url"))) {
    Load(argument);
  } else if (g_str_equal(method, "page") &&
             (argument = StringArg(args, "html"))) {
    LoadPage(argument);
  } else if (g_str_equal(method, "mode") &&
             (argument = StringArg(args, nullptr))) {
    g_free(mode);
    mode = g_strdup(argument);
    ApplyMode();
  } else if (g_str_equal(method, "script") &&
             (argument = StringArg(args, nullptr))) {
    if (web != nullptr && !own_page) {
      webkit_web_view_evaluate_javascript(web, argument, -1, nullptr, nullptr,
                                          nullptr, nullptr, nullptr);
    }
  } else if (g_str_equal(method, "clearCache") && web != nullptr) {
    ClearCache(call);
    return;
  } else if (g_str_equal(method, "reload")) {
    if (web != nullptr) webkit_web_view_reload(web);
  } else {
    response = FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  }
  if (response == nullptr) {
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
  }
  fl_method_call_respond(call, response, nullptr);
}

// Stands in for GtkWindow's "add" on the application window: the Flutter
// view goes in an overlay with the curtain over it, and the web view later
// over both.
void OnWindowAdd(GtkContainer* window, GtkWidget* child) {
  if (overlay != nullptr || !FL_IS_VIEW(child)) {
    g_signal_chain_from_overridden_handler(window, child);
    return;
  }
  flutter_view = FL_VIEW(child);
  overlay = gtk_overlay_new();
  gtk_container_add(GTK_CONTAINER(overlay), child);
  curtain = gtk_drawing_area_new();
  g_signal_connect(curtain, "draw", G_CALLBACK(OnCurtainDraw), nullptr);
  gtk_overlay_add_overlay(GTK_OVERLAY(overlay), curtain);
  gtk_widget_show(curtain);
  gtk_widget_show(overlay);
  gtk_window_set_title(GTK_WINDOW(window), "Foreseerr");

  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  channel = fl_method_channel_new(
      fl_engine_get_binary_messenger(fl_view_get_engine(flutter_view)),
      "foreseerr/web", FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(channel, HandleMethod, nullptr,
                                            nullptr);

  g_signal_chain_from_overridden_handler(window, overlay);
}

void OnStartup(GApplication*, gpointer) {
  // Signals are only there once the class is.
  g_type_class_ref(GTK_TYPE_APPLICATION_WINDOW);
  g_signal_override_class_handler("add", GTK_TYPE_APPLICATION_WINDOW,
                                  G_CALLBACK(OnWindowAdd));
}

// Started from the desktop's menu, the app's output (ours, Moonfin's, GTK's
// and WebKit's) would go nowhere. Unless it runs in a terminal, it goes to
// a log of this run instead, with the run before kept next to it, so the
// log of a crash survives starting the app again:
// ~/.local/state/org.foreseerr.player/foreseerr-player{,.previous}.log
void LogToFile() {
  if (isatty(STDERR_FILENO)) return;
  g_autofree gchar* dir =
      g_build_filename(g_get_user_state_dir(), APPLICATION_ID, nullptr);
  g_mkdir_with_parents(dir, 0700);
  g_autofree gchar* log = g_build_filename(dir, "foreseerr-player.log", nullptr);
  g_autofree gchar* previous =
      g_build_filename(dir, "foreseerr-player.previous.log", nullptr);
  rename(log, previous);
  int fd = open(log, O_WRONLY | O_CREAT | O_TRUNC, 0600);
  if (fd < 0) return;
  fflush(stdout);
  fflush(stderr);
  dup2(fd, STDOUT_FILENO);
  dup2(fd, STDERR_FILENO);
  close(fd);
  // Line by line, so a crash loses nothing that was printed.
  setvbuf(stdout, nullptr, _IOLBF, 0);
  g_autoptr(GDateTime) now = g_date_time_new_now_local();
  g_autofree gchar* when = g_date_time_format_iso8601(now);
  printf("[Foreseerr] started %s, pid %d\n", when, getpid());
}

}  // namespace

void foreseerr_web_install(GApplication* application) {
  LogToFile();
  // WebKitGTK 2.54's Skia compositor flashes old frames during fades and
  // repaints without end on CSS backdrop-filter; the previous one draws on
  // the GPU without either.
  g_setenv("WEBKIT_USE_SKIA_FOR_COMPOSITION", "0", FALSE);
  // NVIDIA under Wayland: WebKit's frames trip over the driver's explicit
  // sync (Wayland protocol error 71). Read when the window's GL starts.
  if (g_file_test("/sys/module/nvidia", G_FILE_TEST_IS_DIR)) {
    g_setenv("__NV_DISABLE_EXPLICIT_SYNC", "1", FALSE);
  }
  g_signal_connect(application, "startup", G_CALLBACK(OnStartup), nullptr);
}
