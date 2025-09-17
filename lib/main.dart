import 'dart:convert';
import 'dart:io' as io; // use the io.* alias for all dart:io types
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:file_selector/file_selector.dart';
import 'package:path_provider/path_provider.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

WebViewEnvironment? webViewEnvironment;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  if (!kIsWeb) {
    if (defaultTargetPlatform == TargetPlatform.windows) {
      final availableVersion = await WebViewEnvironment.getAvailableVersion();
      assert(availableVersion != null, 'WebView2 not found on Windows.');
      webViewEnvironment = await WebViewEnvironment.create(
        settings: WebViewEnvironmentSettings(userDataFolder: 'custom_path'),
      );
    }
    if (defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS) {
      await InAppWebViewController.setWebContentsDebuggingEnabled(kDebugMode);
    }
  }

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Medcon Storage',
      home: WebviewPage(),
    );
  }
}

class WebviewPage extends StatefulWidget {
  const WebviewPage({super.key});
  @override
  State<WebviewPage> createState() => _WebviewPageState();
}

class _WebviewPageState extends State<WebviewPage> {
  InAppWebViewController? webViewController;
final _secure = const FlutterSecureStorage();
static const _kUser = 'syno_user';
static const _kPass = 'syno_pass';
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: InAppWebView(
          webViewEnvironment: defaultTargetPlatform == TargetPlatform.windows
              ? webViewEnvironment
              : null,
          initialSettings: InAppWebViewSettings(
            isInspectable: kDebugMode,
            useOnDownloadStart: true, // native download callback
            useShouldOverrideUrlLoading:
                true, // intercept subframe/JS downloads
            allowsBackForwardNavigationGestures: true,
          ),
          initialUrlRequest: URLRequest(
            url: WebUri(
              "https://192-168-70-6.medconme.direct.quickconnect.to:5001/#/signin",
            ),
          ),
          onWebViewCreated: (c) => webViewController = c,

          // accept self-signed cert
          onReceivedServerTrustAuthRequest: (controller, challenge) async =>
              ServerTrustAuthResponse(
                  action: ServerTrustAuthResponseAction.PROCEED),

          // prevent drag-out “application/octet-stream-Out” placeholders
          onLoadStop: (controller, url) async {
            await controller.evaluateJavascript(source: """
              document.addEventListener('dragstart', e => e.preventDefault(), true);
            """);

            final u = await controller.getUrl();
  if (u != null && u.toString().contains('/#/signin')) {
    await _installCredentialHooks(controller);
    await _autofillIfSaved(controller);
  }
          },

          // Fires for many downloads
          onDownloadStartRequest: (controller, req) async {
            debugPrint('[DL] onDownloadStartRequest ${req.url}');
            await _downloadFromUrl(req.url,
                suggestedName: req.suggestedFilename);
          },
          // Catch subframe / JS-triggered download URLs
          shouldOverrideUrlLoading: (controller, nav) async {
            final wu = nav.request.url;
            if (wu == null) return NavigationActionPolicy.ALLOW;
            debugPrint(
                '[NAV] ${wu.toString()} (isMainFrame: ${nav.isForMainFrame})');

            final u = wu.uriValue;
            if (_looksLikeDownloadUrl(u)) {
              final dl = _dlNameFromQuery(u);
              await _downloadFromUrl(wu, suggestedName: dl);
              return NavigationActionPolicy.CANCEL;
            }

            // Fallback: obvious file extensions
            const exts = [
              '.pdf',
              '.zip',
              '.rar',
              '.7z',
              '.csv',
              '.xls',
              '.xlsx',
              '.doc',
              '.docx',
              '.ppt',
              '.pptx',
              '.jpg',
              '.jpeg',
              '.png'
            ];
            final s = u.toString().toLowerCase();
            if (exts.any((e) => s.endsWith(e) || s.contains('$e?'))) {
              await _downloadFromUrl(wu);
              return NavigationActionPolicy.CANCEL;
            }

            return NavigationActionPolicy.ALLOW;
          },

          // Some sites use window.open for downloads
          onCreateWindow: (controller, create) async {
            final wu = create.request.url;
            debugPrint('[WIN] ${wu?.toString()}');

            if (wu != null && _looksLikeDownloadUrl(wu.uriValue)) {
              final dl = _dlNameFromQuery(wu.uriValue);
              await _downloadFromUrl(wu, suggestedName: dl);
              return true; // handled
            }
            controller.loadUrl(urlRequest: create.request);
            return true;
          },
        ),
      ),
    );
  }

  // ---------- helpers ----------

  bool _looksLikeDownloadUrl(Uri u) {
    final p = u.path.toLowerCase();
    if (p.contains('/fbdownload') ||
        p.contains('/filestation') ||
        p.contains('/webapi')) {
      return true;
    }
    final qp = u.queryParameters
        .map((k, v) => MapEntry(k.toLowerCase(), v.toLowerCase()));
    if (qp['mode'] == 'download') return true;
    if ((qp['method'] ?? '').contains('download')) return true;
    if (qp.containsKey('dlname') || qp.containsKey('dlink')) return true;
    return false;
  }

  String? _dlNameFromQuery(Uri u) {
    final raw = u.queryParameters['dlname'];
    if (raw == null || raw.isEmpty) return null;
    var s = Uri.decodeComponent(raw);
    if (s.contains('%'))
      s = Uri.decodeComponent(s); // Synology often double-encodes
    return s;
  }

  Future<void> _downloadFromUrl(WebUri url, {String? suggestedName}) async {
    final uri = url.uriValue;
    debugPrint('[DL] start $uri');

    // 1) Copy cookies from WebView (Synology auth)
    final cookieList = await CookieManager.instance().getCookies(url: url);
    final cookieHeader =
        cookieList.map((c) => '${c.name}=${c.value}').join('; ');
    debugPrint('[DL] cookies: ${cookieList.length}');

    // 2) Make the request (accept self-signed cert)
    final client = io.HttpClient();
    client.badCertificateCallback =
        (io.X509Certificate cert, String host, int port) => true;

    final req = await client.getUrl(uri);
    req.followRedirects = true;
    req.maxRedirects = 5;

    // Propagate cookies + typical headers Synology may check
    if (cookieHeader.isNotEmpty) {
      req.headers.set(io.HttpHeaders.cookieHeader, cookieHeader);
    }
    final referer = (await webViewController?.getUrl())?.toString();
    if (referer != null && referer.isNotEmpty) {
      req.headers.set(io.HttpHeaders.refererHeader, referer);
    }
    final ua = await _userAgent();
    if (ua != null && ua.isNotEmpty) {
      req.headers.set(io.HttpHeaders.userAgentHeader, ua);
    }
    req.headers.set(io.HttpHeaders.acceptHeader, '*/*');

    final res = await req.close();
    final ct = res.headers.contentType?.mimeType ??
        res.headers.value('content-type') ??
        'unknown';
    debugPrint('[DL] status=${res.statusCode} content-type=$ct');

    if (res.statusCode != 200) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Download failed (${res.statusCode})')),
      );
      return;
    }

    // Guard: if Synology sent an HTML page (expired token), bail with a hint
    if (ct.startsWith('text/html')) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('Login/session expired. Please sign in again.')),
      );
      return;
    }
// 3) Filename
    String filename = suggestedName ?? _filenameFromHeadersOrUrl(res, uri);
    debugPrint('[DL] filename=$filename');

// 4) Prefer real user ~/Downloads only if it’s NOT container-scoped
    String? savePath;
    if (io.Platform.isMacOS) {
      try {
        final downloadsDir =
            await getDownloadsDirectory(); // needs Downloads entitlement
        final downloadsPath = downloadsDir?.path;
        debugPrint('[DL] downloadsPath=$downloadsPath');

        final looksContainer = downloadsPath == null ||
            downloadsPath.isEmpty ||
            downloadsPath.contains('/Library/Containers/');

        if (!looksContainer) {
          savePath = '$downloadsPath/$filename';
          debugPrint('[DL] auto save to $savePath');
        } else {
          debugPrint(
              '[DL] downloadsPath is container-scoped; using Save dialog');
        }
      } catch (e) {
        debugPrint('[DL] getDownloadsDirectory error: $e');
      }
    }

// Fallback: Save dialog (always works; grants user-selected permission)
    if (savePath == null) {
      final saveLoc = await getSaveLocation(suggestedName: filename);
      debugPrint('[DL] saveLoc: ${saveLoc?.path}');
      if (saveLoc == null) {
        debugPrint('[DL] user cancelled save dialog');
        return;
      }
      savePath = saveLoc.path;
    }

// 5) Write file
    try {
      final file = io.File(savePath);
      await file.parent.create(recursive: true);
      final sink = file.openWrite();
      await res.forEach(sink.add);
      await sink.close();

      debugPrint('[DL] saved -> $savePath');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Saved: $savePath')),
      );
      if (io.Platform.isMacOS) {
        try {
          await io.Process.run('open', ['-R', savePath]);
        } catch (_) {}
      }
    } on io.FileSystemException catch (e) {
      debugPrint('[DL] write error: $e — fallback to Save dialog');
      final saveLoc = await getSaveLocation(suggestedName: filename);
      if (saveLoc == null) return;
      final altFile = io.File(saveLoc.path);
      await altFile.parent.create(recursive: true);
      final sink = altFile.openWrite();
      await res.forEach(sink.add);
      await sink.close();

      debugPrint('[DL] saved (fallback) -> ${altFile.path}');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Saved: ${altFile.path}')),
      );
    }
  }

  String _filenameFromHeadersOrUrl(io.HttpClientResponse res, Uri uri) {
    final cd = res.headers.value('content-disposition') ?? '';

    final matchStar =
        RegExp(r"filename\*\s*=\s*UTF-8''([^;]+)", caseSensitive: false)
            .firstMatch(cd);
    if (matchStar != null) {
      return Uri.decodeComponent(matchStar.group(1)!).trim();
    }

    final matchQuoted =
        RegExp(r'filename\s*=\s*"([^"]+)"', caseSensitive: false)
            .firstMatch(cd);
    if (matchQuoted != null) {
      return matchQuoted.group(1)!.trim();
    }

    final matchBare =
        RegExp(r'filename\s*=\s*([^;]+)', caseSensitive: false).firstMatch(cd);
    if (matchBare != null) {
      return matchBare.group(1)!.trim();
    }

    final dlname = uri.queryParameters['dlname'];
    if (dlname != null && dlname.isNotEmpty) {
      try {
        var decoded = Uri.decodeComponent(dlname);
        if (decoded.contains('%')) decoded = Uri.decodeComponent(decoded);
        return decoded;
      } catch (_) {}
    }

    String last =
        uri.pathSegments.isNotEmpty ? uri.pathSegments.last : 'download';
    last = Uri.decodeComponent(last);
    if (last.contains('%')) last = Uri.decodeComponent(last);
    return last;
  }

  Future<String?> _userAgent() async {
    try {
      final ua = await webViewController?.evaluateJavascript(
          source: 'navigator.userAgent');
      if (ua is String && ua.isNotEmpty) return ua;
    } catch (_) {}
    return null;
  }

  Future<String?> _getUserDownloadsPath() async {
    try {
      final dir = await getDownloadsDirectory(); // macOS: real ~/Downloads
      return dir?.path;
    } catch (_) {
      return null;
    }
  }
  Future<void> _autofillIfSaved(InAppWebViewController c) async {
  final username = await _secure.read(key: _kUser);
  final password = await _secure.read(key: _kPass);
  if (username == null || password == null) return;

  // Try common selectors (Synology DSM often uses username/password ids)
  final js = """
  (function(){
    function sel(qs){ return document.querySelector(qs); }
    const u = sel('input[name="username"]') || sel('#username') ||
              sel('input[type="text"][name*="user" i]') || sel('input[type="text"][id*="user" i]');
    const p = sel('input[name="password"]') || sel('#password') ||
              sel('input[type="password"][name*="pass" i]') || sel('input[type="password"][id*="pass" i]');
    if (u) { u.value = ${jsonEncode(username)}; u.dispatchEvent(new Event('input',{bubbles:true})); }
    if (p) { p.value = ${jsonEncode(password)}; p.dispatchEvent(new Event('input',{bubbles:true})); }
    // Tick any "remember me" checkbox if present
    const r = sel('input[type="checkbox"][name*="remember" i]') || sel('input[type="checkbox"][id*="remember" i]');
    if (r && !r.checked) r.click();
  })();
  """;
  await c.evaluateJavascript(source: js);
}

Future<void> _installCredentialHooks(InAppWebViewController c) async {
  // Receive creds from the page before it navigates away
  c.addJavaScriptHandler(
    handlerName: 'storeCreds',
    callback: (args) async {
      final user = (args.isNotEmpty && args[0] is String) ? args[0] as String : null;
      final pass = (args.length > 1 && args[1] is String) ? args[1] as String : null;
      if (user != null && user.isNotEmpty && pass != null && pass.isNotEmpty) {
        await _secure.write(key: _kUser, value: user);
        await _secure.write(key: _kPass, value: pass);
      }
      return true;
    },
  );

  // Hook login form submit and send creds to Flutter
  await c.evaluateJavascript(source: """
  (function(){
    if (window.__credHooked) return; window.__credHooked = true;

    function findFields(){
      const u = document.querySelector('input[name="username"], #username, input[type="text"][name*="user" i], input[type="text"][id*="user" i]');
      const p = document.querySelector('input[name="password"], #password, input[type="password"][name*="pass" i], input[type="password"][id*="pass" i]');
      const form = (p && p.form) || (u && u.form) || document.querySelector('form');
      return {u, p, form};
    }

    function hook(){
      const {u, p, form} = findFields();
      if (!form || !u || !p) return;
      form.addEventListener('submit', function(){
        try { window.flutter_inappwebview.callHandler('storeCreds', u.value || '', p.value || ''); } catch(e){}
      }, {capture:true});
    }

    hook();
    // SPA safety: re-hook if DOM changes
    const mo = new MutationObserver(hook);
    mo.observe(document.documentElement, {childList:true, subtree:true});
  })();
  """);
}
}
