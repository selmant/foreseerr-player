import 'dart:convert';

/// The app's own pages, shown in the web view where Foreseerr would be:
/// setup and load errors. Their buttons navigate to `foreseerr-app:` links,
/// which the runner hands to [ForeseerrShell] instead of loading.
abstract final class ForeseerrPages {
  static const _escape = HtmlEscape();

  /// Asks for the Foreseerr address. [error] says why the last one failed.
  static String setup({String address = '', String? error}) => _page(
    title: 'Foreseerr',
    body:
        '''
<p>Your Foreseerr server's address</p>
<form id="setup">
  <input id="address" type="url" inputmode="url" autocomplete="url"
    placeholder="https://foreseerr.example.com"
    value="${_escape.convert(address)}" required autofocus>
  ${error == null ? '' : '<p class="error">${_escape.convert(error)}</p>'}
  <button type="submit">Connect</button>
</form>
<script>
  const form = document.getElementById('setup');
  form.addEventListener('submit', (event) => {
    event.preventDefault();
    const button = form.querySelector('button');
    button.disabled = true;
    button.textContent = 'Connecting…';
    location.href = 'foreseerr-app:connect?address=' +
      encodeURIComponent(document.getElementById('address').value);
  });
</script>''',
  );

  /// Foreseerr at [url] didn't load.
  static String loadError(String url, String error) => _page(
    title: 'Could not open Foreseerr',
    body:
        '''
<p>${_escape.convert(url)}<br>${_escape.convert(error)}</p>
<div class="actions">
  <a class="button" href="foreseerr-app:retry" autofocus>Retry</a>
  <a class="button secondary" href="foreseerr-app:change">Change address</a>
</div>''',
  );

  static String _page({required String title, required String body}) =>
      '''
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>${_escape.convert(title)}</title>
<style>
  :root { color-scheme: dark; }
  html, body { height: 100%; margin: 0; }
  body {
    display: grid; place-items: center;
    background: #111827; color: #d1d5db;
    font: 15px/1.5 system-ui, sans-serif;
  }
  main { width: min(420px, calc(100vw - 48px)); text-align: center; }
  h1 { margin: 0 0 8px; color: #fff; font-size: 24px; font-weight: 600; }
  p { margin: 0 0 20px; overflow-wrap: anywhere; }
  form { display: grid; gap: 16px; }
  form p { margin: 0; }
  input {
    box-sizing: border-box; width: 100%; padding: 10px 12px;
    border: 1px solid #4b5563; border-radius: 6px;
    background: #1f2937; color: #fff; font: inherit;
  }
  input:focus { outline: 2px solid #6366f1; border-color: transparent; }
  .error { color: #fca5a5; }
  .actions { display: flex; gap: 12px; justify-content: center; }
  button, .button {
    padding: 10px 18px; border: 0; border-radius: 6px;
    background: #4f46e5; color: #fff; font: inherit; font-weight: 500;
    text-decoration: none; cursor: pointer;
  }
  button:disabled { opacity: 0.6; cursor: default; }
  .secondary { background: #374151; }
</style>
</head>
<body>
<main>
<h1>${_escape.convert(title)}</h1>
$body
</main>
</body>
</html>''';
}
