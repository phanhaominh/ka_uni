import 'dart:async';
import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:kit_mobile/common_ui/kit_progress_indicator.dart';
import 'package:kit_mobile/constants/view_constants.dart';
import 'package:kit_mobile/l10n/l10n.dart';
import 'package:kit_mobile/module/models/module.dart';
import 'package:kit_mobile/state_management/ilias/ilias_manager.dart';
import 'package:kit_mobile/state_management/kit_provider.dart';
import 'package:kit_mobile/toasts/models/toasts_provider.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../local_files_storage/files_manager.dart';
import '../../local_files_storage/models/pinned_file.dart';
import '../../local_files_storage/views/file_viewer.dart';
import '../../settings/providers/settings_provider.dart';

/// Only https downloads from the real ILIAS host are mirrored into the
/// local cache; everything else - plain http, lookalike hosts like
/// "kit.edu.evil.example", unrelated paths merely containing the word -
/// falls through to regular webview navigation.
const iliasHost = "ilias.studium.kit.edu";

const _maxSendfileNameLength = 120;

bool isIliasSendfileUrl(String url) {
  final uri = Uri.tryParse(url);
  return uri != null &&
      uri.scheme == "https" &&
      uri.host.toLowerCase() == iliasHost &&
      uri.path.contains("sendfile");
}

/// Destination filename (no directory) for an ILIAS sendfile URL, or null
/// when the URL is not ours to intercept or carries no usable ref_id.
/// ref_id is attacker-influenced: scrubbed exactly like the module title,
/// stripped of leading dots (hidden files, "."/".." segments) and capped
/// in length, so no path can ever be smuggled into it.
String? sendfileFileName(String url, {String title = ""}) {
  final uri = Uri.tryParse(url);
  if (uri == null ||
      uri.scheme != "https" ||
      uri.host.toLowerCase() != iliasHost ||
      !uri.path.contains("sendfile")) {
    return null;
  }
  final String? refId;
  try {
    refId = uri.queryParameters["ref_id"];
  } on FormatException {
    return null; // malformed percent-encoding is not a trusted download
  }
  if (refId == null) {
    return null;
  }
  var refPart = _scrubFileNamePart(refId);
  if (refPart.isEmpty) {
    return null;
  }
  if (refPart.length > _maxSendfileNameLength) {
    refPart = refPart.substring(0, _maxSendfileNameLength);
  }
  final titlePart = _scrubFileNamePart(title);
  final budget = (_maxSendfileNameLength - refPart.length)
      .clamp(0, titlePart.length < 60 ? titlePart.length : 60);
  return titlePart.substring(0, budget) + refPart;
}

/// Full destination path for a sendfile URL, pinned inside `directory`
/// (the semester cache dir under the app documents download directory).
/// Null means "do not write anywhere" - callers fail closed.
String? iliasSendfilePath(String directory, String url, {String title = ""}) {
  final name = sendfileFileName(url, title: title);
  if (name == null) {
    return null;
  }
  final path = "$directory/$name.pdf";
  // Belt and braces: whatever the composition above did, the destination
  // must sit under the documents download directory or it is dropped.
  return path.startsWith("$directory/") ? path : null;
}

/// The scrubber module titles always went through, plus leading-dot
/// removal; the class excludes "/" and "\", so no path separator survives.
String _scrubFileNamePart(String raw) {
  final cleaned = raw
      .replaceAll(RegExp(r'[^A-Za-z0-9._ -]'), "_")
      .replaceAll(RegExp(r"\s+"), " ")
      .trim();
  return cleaned.replaceAll(RegExp(r"^\.+"), "");
}

class IliasPageView extends StatefulWidget {
  /// Route name used by the nav container to dedupe pushes of this page.
  static const routeName = "/ilias";

  final KITModule module;
  final Future<String> PHPSESSID_Future;

  const IliasPageView(this.module, {super.key, required this.PHPSESSID_Future});

  @override
  State<StatefulWidget> createState() {
    return _IliasPageViewWState();
  }
}

class _IliasPageViewWState extends State<IliasPageView> {
  late final WebViewController _controller;
  String _phpsessid = "";

  /// ILIAS SSO occasionally hangs mid-handshake on KIT's side; an
  /// unresolved future would pin the gate on the spinner forever. The
  /// timeout resolves to the EMPTY session, which is the existing
  /// auth-failed path - one terminal state, one retry affordance.
  static const _sessionTimeout = Duration(seconds: 20);
  late final Future<String> _sessionFuture =
      widget.PHPSESSID_Future.timeout(_sessionTimeout, onTimeout: () => "");

  bool isBusy = false;

  /// A session (re-)authorization is in flight: keeps the pre-webview
  /// gate on the spinner instead of flashing the auth-failed scaffold
  /// while a retry/refresh is running
  bool _retrying = false;

  /// Forward reachability, re-read on every URL change; the unified back
  /// button queries the controller live instead.
  Future<bool?> canGoForwardFuture = Future.value(false);

  /// Main-frame load progress (0..100); drives the hairline bar under
  /// the control bar so a first load shows movement instead of a blank
  /// flash until the page paints.
  int _loadProgress = 0;

  /// One-shot per SSO-wall episode: a session that died mid-browse
  /// bounces the webview onto the login wall, and the wall re-fires
  /// onUrlChange on every hop - recovery must run once, not loop.
  /// Re-armed by any non-wall navigation (incl. the reload it causes),
  /// released by a failed recovery so the next episode can retry.
  bool _ssoWallLatched = false;

  @override
  void initState() {
    super.initState();

    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted);

    _controller.setNavigationDelegate(NavigationDelegate(
        onUrlChange: _navigationDelegateOnUrlChange,
        onProgress: (progress) {
          if (!mounted) return;
          setState(() => _loadProgress = progress);
        },
        onPageFinished: (_) {
          if (!mounted) return;
          setState(() => _loadProgress = 0);
        },
        onNavigationRequest: (NavigationRequest req) {
          if (isIliasSendfileUrl(req.url)) {
            // nothing to mirror without a usable ref_id: preventing the
            // navigation there used to swallow the tap outright, so an
            // unparseable sendfile link must load in the webview itself
            if (sendfileFileName(req.url, title: widget.module.title) == null) {
              return NavigationDecision.navigate;
            }
            _saveAsFile(req.url);
            return NavigationDecision.prevent;
          }

          return NavigationDecision.navigate;
        }));

    _sessionFuture.then((value) async {
      // SSO future resolves after an arbitrary delay; the page is often
      // popped (back button) before it lands
      if (!mounted) return;
      final settingsVM = Provider.of<SettingsProvider>(context, listen: false);
      _phpsessid = value;

      await _launchPage(settingsVM.defaultIliasPage.value);
    });
  }

  void _navigationDelegateOnUrlChange(UrlChange urlChange) {
    if (!mounted) return;
    setState(() {
      canGoForwardFuture = _controller.canGoForward();
    });

    // mid-session dead cookie: ILIAS bounces the webview onto its / the
    // KIT IdP's login wall. Recover exactly once per episode (the
    // recovery reload itself re-enters the wall), and never while a
    // re-auth is already in flight.
    if (IliasManager.looksLikeLoginWall(urlChange.url ?? "")) {
      if (!_ssoWallLatched && !_retrying) {
        _ssoWallLatched = true;
        _refreshSession();
      }
    } else {
      _ssoWallLatched = false;
    }

    if (kDebugMode) {
      print("Changed: ${urlChange.url}");
    }
  }

  /// Concurrent taps on the same link share one download (double-taps
  /// used to race two writeAsBytes on one path and stack two viewers).
  static final Map<String, Future<void>> _downloadsInFlight = {};

  Future<String?> _saveAsFile(String url) {
    final inFlight = _downloadsInFlight[url];
    if (inFlight != null) return inFlight.then((_) => _pathFor(url));
    final future = _doSaveAsFile(url);
    _downloadsInFlight[url] = future;
    future.whenComplete(() => _downloadsInFlight.remove(url));
    return future;
  }

  Future<String?> _pathFor(String url) async {
    // follow-up callers resolve after an arbitrary await; their State may
    // already be disposed - Provider.of on a defunct context would throw,
    // and this future is joined by the fire-and-forget tap path, so a
    // throw here would be an unobserved zone error
    try {
      if (!mounted) return null;
      final iliasFileManager =
          Provider.of<IliasFilesProvider>(context, listen: false);
      final directory = await iliasFileManager.localFileStorageManager
          .ensureAndGetCurrentSemesterDirectory();
      return iliasSendfilePath(directory, url, title: widget.module.title);
    } on Object catch (_) {
      return null;
    }
  }

  Future<String?> _doSaveAsFile(String url) async {
    // the ENTIRE body is guarded: the Provider lookups and the directory
    // creation sit before any download try, and onNavigationRequest
    // fire-and-forgets this future - an early throw used to die as an
    // unobserved zone error, i.e. a tap that visibly did nothing
    ToastsProvider? toastsProvider;
    try {
      final vm = Provider.of<KITProvider>(context, listen: false);
      final iliasFileManager =
          Provider.of<IliasFilesProvider>(context, listen: false);
      toastsProvider = Provider.of<ToastsProvider>(context, listen: false);

      final directory = await iliasFileManager.localFileStorageManager
          .ensureAndGetCurrentSemesterDirectory();

      // fail closed: without a destination pinned inside the documents
      // download directory nothing is written or downloaded at all
      final filepath =
          iliasSendfilePath(directory, url, title: widget.module.title);
      if (filepath == null) {
        toastsProvider.showTextToast(L10n.t("ilias.downloadFailed"));
        if (kDebugMode) {
          print("ILIAS sendfile destination rejected for $url");
        }
        return null;
      }

      File file = File(filepath);

      // an old corrupt cache entry (login-page HTML saved as .pdf before the
      // magic-byte gate existed) must not be reused forever
      var reusable = await file.exists();
      if (reusable && filepath.endsWith(".pdf")) {
        final sink = await file.open();
        try {
          final head = Uint8List(4);
          final read = await sink.readInto(head);
          reusable = read == 4 &&
              head[0] == 0x25 &&
              head[1] == 0x50 &&
              head[2] == 0x44 &&
              head[3] == 0x46;
        } finally {
          await sink.close();
        }
      }
      // R22: a proved-session non-PDF body is saved as "<stem>.<ext>" by
      // downloadFile (zip/pptx/docx…), but this probe only ever knew the
      // guessed ".pdf" name - every re-tap of a saved lecture archive
      // silently re-downloaded tens of MB, contradicting the file's own
      // "downloads are only retried when the file is absent" rule. The
      // name is deterministic (scrubbed title+ref_id), so probe the stem
      // with ANY extension; the extension written by the header-proved
      // save is the evidence - no PDF magic check there.
      if (!reusable) {
        final stem = filepath.endsWith(".pdf")
            ? filepath.substring(0, filepath.length - 4)
            : filepath;
        try {
          final dir = File(stem).parent;
          if (dir.existsSync()) {
            for (final e in dir.listSync()) {
              if (e is! File) continue;
              if (e.path.startsWith("$stem.") &&
                  e.path.length > stem.length + 1) {
                file = e;
                reusable = true;
                break;
              }
            }
          }
        } on Object catch (_) {}
      }

      if (!reusable) {
        if (mounted) setState(() => isBusy = true);
        toastsProvider.showTextToast(L10n.t("ilias.downloading"));
        // the download gate may save a proved-session non-PDF body under
        // the extension its headers prove; delivery follows the ACTUAL
        // result, not the guessed ".pdf" name
        final iliasFile = await vm.iliasManager.downloadFile(url, file);
        if (mounted) setState(() => isBusy = false);
        _deliverFile(iliasFile, toastsProvider);
        return iliasFile.fileSystemPath;
      }

      PinnedFile? iliasFile;

      var existingFiles =
          await vm.iliasFileManager.getFilesForCurrentSemester();
      for (var element in existingFiles) {
        if (element.urlString == url) {
          iliasFile = element;
          break;
        }
      }

      _deliverFile(
          iliasFile ??
              PinnedFile(
                  semesterString: KITProvider.currentSemesterString,
                  urlString: url,
                  moduleTitle: "",
                  addedAt: DateTime.now().toUtc(),
                  customName: "",
                  // the ACTUAL bytes: a reused non-PDF save lives at
                  // <stem>.<ext>, not at the guessed ".pdf" (R22)
                  fileSystemPath: file.path),
          toastsProvider);

      return file.path;
    } on Object catch (e) {
      // a wedged busy overlay makes the whole tab unusable until restart
      if (mounted) setState(() => isBusy = false);
      toastsProvider?.showTextToast(L10n.t("ilias.downloadFailed"));
      if (kDebugMode) print("ILIAS sendfile handling failed: $e");
      return null;
    }
  }

  /// Route a saved download to the user. PDFs open in the in-app viewer.
  /// Proved-session non-PDF bodies (zip/pptx/docx/…) have NO in-app viewer
  /// - PDFScreen is flutter_pdfview-only, and the pinned Files list opens
  /// every tap through PDFScreen too, so pinning one there would just move
  /// the dead end. The bytes are saved in the semester cache dir (visible
  /// in the Files cache browser) and handed to the system viewer chooser
  /// via the app's existing open-externally util - the same share_plus
  /// call as the file viewer's share button - with a toast naming the
  /// saved file for the case where the chooser is dismissed.
  void _deliverFile(PinnedFile iliasFile, ToastsProvider toastsProvider) {
    if (!mounted) return; // always called after download/listing awaits
    final path = iliasFile.fileSystemPath;
    if (path.toLowerCase().endsWith(".pdf")) {
      _launchFileView(iliasFile);
      return;
    }
    toastsProvider
        .showTextToast(L10n.t("ilias.savedToFiles", [path.split("/").last]));
    unawaited(_openExternally(path));
  }

  Future<void> _openExternally(String path) async {
    try {
      await SharePlus.instance.share(ShareParams(files: [XFile(path)]));
    } on Object catch (e) {
      // the file is already saved; an unavailable chooser must not escape
      // this fire-and-forget future as an unobserved zone error
      if (kDebugMode) print("ILIAS external open failed: $e");
    }
  }

  void _launchFileView(PinnedFile iliasFile) {
    if (!mounted) return; // always called after download/listing awaits
    if (iliasFile.fileSystemPath.isEmpty) {
      if (kDebugMode) {
        print("Failed to download file!");
      }
    }

    final filepath = iliasFile.fileSystemPath;

    if (kDebugMode) {
      print("Launching file view for $filepath");
    }

    Navigator.of(context).push(MaterialPageRoute(
        builder: (context) => PDFScreen(
              iliasFile: iliasFile,
            )));
  }

  Future<void> _launchPage(String defaultPage) async {
    final cookieManager = WebViewCookieManager();
    await cookieManager.setCookie(WebViewCookie(
        name: "PHPSESSID", value: _phpsessid, domain: "ilias.studium.kit.edu"));

    // final vm = Provider.of<KITProvider>(context);
    String link = widget.module.iliasLink ?? "";
    if (link.isEmpty) {
      link = defaultPage == "Dashboard"
          ? "https://ilias.studium.kit.edu/ilias.php?baseClass=ildashboardgui&cmd=show"
          : "https://ilias.studium.kit.edu/ilias.php?baseClass=ilmembershipoverviewgui";
    }
    // re-auth/refresh must land back on the page the user is looking
    // at; only a webview that never loaded anything - or one sitting on
    // the login wall - falls back to the configured entry page. Wall
    // recovery must NOT reload `current`: mid-session it is the SSO wall
    // URL, and its consumed SAMLRequest cannot be replayed - a wall
    // reload just shows the wall again instead of restarting the handshake
    final current = await _controller.currentUrl();
    if (current != null &&
        current.isNotEmpty &&
        !IliasManager.looksLikeLoginWall(current)) {
      _controller.loadRequest(Uri.parse(current));
    } else {
      _controller.loadRequest(Uri.parse(link));
    }
  }

  /// Re-authenticates from scratch and pushes the fresh cookie into the
  /// webview engine via [_launchPage]; the strip's refresh chip and the
  /// mid-session SSO-wall recovery share this path.
  Future<String> _refreshSession() async {
    final vm = Provider.of<KITProvider>(context, listen: false);
    final toastsProvider = Provider.of<ToastsProvider>(context, listen: false);
    setState(() {
      _phpsessid = "";
      _retrying = true;
    });

    String newPHPSESSIONID = "";
    try {
      // same ceiling as the initial gate: a re-auth that hangs
      // must end on the retry card, not a dead strip spinner
      await vm.iliasManager
          .authorize(refreshSession: true)
          .timeout(_sessionTimeout);
      newPHPSESSIONID =
          await vm.iliasManager.getPHPSESSID().timeout(_sessionTimeout);
    } on Object catch (_) {
      // fall through to the empty-session auth-failed path
    }

    if (newPHPSESSIONID.isEmpty) {
      // the webview is gone behind the auth-failed gate by now, so let a
      // later wall re-trigger recovery once the user retries
      _ssoWallLatched = false;
      toastsProvider.showTextToast(L10n.t("ilias.refreshError"));
    }

    if (mounted) {
      setState(() {
        _phpsessid = newPHPSESSIONID;
        _retrying = false;
      });
    }
    if (newPHPSESSIONID.isNotEmpty && mounted) {
      // the refresh gesture must act on the VISIBLE page: only
      // _launchPage pushes the fresh PHPSESSID into the webview
      // engine's cookie jar and reloads - without this the strip
      // spinner ends and the stale-cookie page just sits there
      await _launchPage(Provider.of<SettingsProvider>(context, listen: false)
          .defaultIliasPage
          .value);
    }
    return newPHPSESSIONID;
  }

  /// Auth-failed gate retry. The gate fires after 20s but a legitimate
  /// SSO chain can run for a minute+, and a forced full re-auth would
  /// wipe the cookies of a chain that succeeded seconds after the
  /// timeout - so join the in-flight chain first, and only re-auth from
  /// scratch when it truly yields nothing.
  Future<void> _retryFromGate() async {
    setState(() => _retrying = true);
    String session = "";
    try {
      // getPHPSESSID joins in-flight chains with internal bounds;
      // deliberately NOT capped by _sessionTimeout - waiting the chain
      // out is the whole point here
      session = await Provider.of<KITProvider>(context, listen: false)
          .iliasManager
          .getPHPSESSID();
    } on Object catch (_) {
      // the bounded join swallows its own failures; fall through to the
      // hard re-auth below
    }
    if (session.isEmpty) {
      // R22: getPHPSESSID above may join an in-flight chain for up to two
      // minutes; popping the gate during that window used to land
      // _refreshSession's Provider.of + setState on a disposed State
      // (every other entry into it is mounted-guarded)
      if (!mounted) return;
      await _refreshSession();
      return;
    }
    if (!mounted) return;
    setState(() {
      _phpsessid = session;
      _retrying = false;
    });
    await _launchPage(Provider.of<SettingsProvider>(context, listen: false)
        .defaultIliasPage
        .value);
  }

  /// Back = webview history first; the page only pops once the webview
  /// itself sits on its first entry.
  Future<void> _onBack() async {
    if (await _controller.canGoBack()) {
      // the canGoBack() round-trip outlives the pop: if the route closed
      // meanwhile the platform webview is destroyed and goBack() would
      // throw into the PopScope callback - the mounted guard below the
      // await covers exactly this gap
      if (!mounted) return;
      _controller.goBack();
    } else if (mounted && Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return FutureBuilder(
        future: _sessionFuture,
        builder: (context, snapshot) {
          if (!snapshot.hasData || _phpsessid.isEmpty) {
            // loading vs auth-failed: an EMPTY resolution means the SSO
            // chain ended without a PHPSESSID - a spinner there is a
            // dead end (the refresh chip lives inside the loaded
            // scaffold), so the gate offers its own retry
            if (!snapshot.hasData || _retrying) {
              // branded gate: the tab's icon (a paperclip) never
              // announced ILIAS, so the first frame of the session now
              // does - wordmark + what is happening + spinner
              return Scaffold(
                  body: Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      "ILIAS",
                      style: theme.textTheme.headlineMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                          letterSpacing: 2,
                          color: theme.colorScheme.primary),
                    ),
                    SizedBox(height: spaceLg),
                    Text(
                      L10n.t("ilias.connecting"),
                      style: theme.textTheme.bodyMedium
                          ?.copyWith(color: theme.colorScheme.outline),
                    ),
                    SizedBox(height: spaceXl),
                    KITProgressIndicator(),
                  ],
                ),
              ));
            }
            return Scaffold(
                body: Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(L10n.t("ilias.authFailed"),
                      style: theme.textTheme.bodyMedium),
                  SizedBox(height: 8),
                  CupertinoButton(
                    // joins any still-running SSO chain before forcing
                    // a fresh one - see _retryFromGate
                    onPressed: () => _retryFromGate(),
                    child: Text(L10n.t("ilias.retry")),
                  ),
                ],
              ),
            ));
          }

          // All controls live in ONE slim translucent strip ABOVE the
          // webview, outside the viewport. The old floating glass chips
          // sat on top of web content: back over the HINWEIS banner and
          // KIT logo, refresh over the site's overflow menu, the history
          // pair over the bottom nav - a dead zone that swallowed taps
          // meant for the 'Lernerfolge' tab on every ILIAS page. Auto-
          // fading the history chips would only shrink that zone; a strip
          // outside the viewport removes all four occlusions for ~52 dp
          // of web content instead. (The chips stayed glass - the strip
          // is translucent over the page background, and nothing ever
          // scrolls behind it.)
          // system back walks the webview history first (same rule as
          // the strip chevron); the route only pops once the webview
          // sits on its first entry. The loading/auth-failed gates
          // above keep the default pop - back must never trap the user
          // on a page that never loaded.
          return PopScope(
            canPop: false,
            onPopInvokedWithResult: (didPop, _) {
              if (!didPop) _onBack();
            },
            child: Scaffold(
              body: Column(
                children: [
                  _IliasControlBar(
                    showBack: Navigator.of(context).canPop(),
                    canGoForward: canGoForwardFuture,
                    onBack: _onBack,
                    onForward: () => _controller.goForward(),
                    onRefresh: _refreshSession,
                  ),
                  if (_loadProgress > 0 && _loadProgress < 100)
                    LinearProgressIndicator(
                        value: _loadProgress / 100, minHeight: 2),
                  Expanded(
                    child: Stack(
                      children: [
                        Positioned.fill(
                            child: WebViewWidget(controller: _controller)),
                        if (isBusy)
                          Center(
                            child: GlassContainer(
                              useOwnLayer: true,
                              child: Padding(
                                padding: EdgeInsets.all(10),
                                child: KITProgressIndicator(),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        });
  }
}

/// ≥44 dp glass hit target (WCAG touch minimum) wrapped in a tooltip, so
/// the unlabelled chevrons stay distinguishable by long-press/accessibility.
Widget _glassChip(IconData icon, VoidCallback? onPressed, String tooltip) {
  return Tooltip(
    message: tooltip,
    child: Opacity(
      opacity: onPressed == null ? 0.35 : 1,
      child: GlassContainer(
        useOwnLayer: true,
        child: CupertinoButton(
          padding: EdgeInsets.zero,
          minimumSize: const Size(44, 44),
          onPressed: onPressed,
          child: SizedBox(
            width: 44,
            height: 44,
            child: Center(
              child: Icon(icon, size: 20),
            ),
          ),
        ),
      ),
    ),
  );
}

/// The ILIAS tab's whole browser chrome: one slim translucent strip above
/// the webview so it can never overlap web content. Back folds the old
/// pop chip and the webview-history-back chip together (history first,
/// then pop); forward follows the controller; refresh re-authorizes.
class _IliasControlBar extends StatelessWidget {
  final bool showBack;
  final Future<bool?> canGoForward;
  final VoidCallback onBack;
  final VoidCallback onForward;
  final VoidCallback onRefresh;

  const _IliasControlBar(
      {required this.showBack,
      required this.canGoForward,
      required this.onBack,
      required this.onForward,
      required this.onRefresh});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      bottom: false,
      child: Container(
        color: theme.scaffoldBackgroundColor.withValues(alpha: 0.9),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Row(
          children: [
            if (showBack)
              _glassChip(CupertinoIcons.chevron_left, onBack,
                  L10n.t("ilias.backTooltip")),
            FutureBuilder(
                future: canGoForward,
                builder: (context, snapshot) {
                  final enabled = snapshot.hasData && snapshot.data!;
                  return _glassChip(
                      CupertinoIcons.chevron_right,
                      enabled ? onForward : null,
                      L10n.t("ilias.forwardTooltip"));
                }),
            const Spacer(),
            // the wordmark owns the strip's center: three glass glyphs
            // alone never said which service this browser belongs to
            Text(
              "ILIAS",
              style: theme.textTheme.titleSmall
                  ?.copyWith(fontWeight: FontWeight.bold, letterSpacing: 1.5),
            ),
            const Spacer(),
            _glassChip(CupertinoIcons.refresh, onRefresh,
                L10n.t("ilias.refreshTooltip")),
          ],
        ),
      ),
    );
  }
}
