import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:kit_mobile/common_ui/kit_progress_indicator.dart';
import 'package:kit_mobile/l10n/l10n.dart';
import 'package:kit_mobile/module/models/module.dart';
import 'package:kit_mobile/state_management/kit_provider.dart';
import 'package:kit_mobile/toasts/models/toasts_provider.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:provider/provider.dart';
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
String? iliasSendfilePath(String directory, String url,
    {String title = ""}) {
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
  final KITModule module;
  final Future<String> PHPSESSID_Future;
  final bool isFileView;

  const IliasPageView(this.module,
      {super.key, required this.PHPSESSID_Future, this.isFileView = false});

  @override
  State<StatefulWidget> createState() {
    return _IliasPageViewWState();
  }
}

class _IliasPageViewWState extends State<IliasPageView> {
  late final WebViewController _controller;
  String _phpsessid = "";

  bool isBusy = false;

  int pagesStackSize = 0;
  Future<bool?> canGoBackFuture = Future.value(false),
      canGoForwardFuture = Future.value(false);

  @override
  void initState() {
    super.initState();

    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted);

    _controller.setNavigationDelegate(NavigationDelegate(
        onUrlChange: _navigationDelegateOnUrlChange,
        onNavigationRequest: (NavigationRequest req) {
          if (isIliasSendfileUrl(req.url)) {
            _saveAsFile(req.url);
            return NavigationDecision.prevent;
          }

          return NavigationDecision.navigate;
        }));

    widget.PHPSESSID_Future.then((value) async {
      // SSO future resolves after an arbitrary delay; the page is often
      // popped (back button) before it lands
      if (!mounted) return;
      final settingsVM = Provider.of<SettingsProvider>(context, listen: false);
      _phpsessid = value;

      if (widget.isFileView && widget.module.iliasLink != null) {
        await _saveAsFile(widget.module.iliasLink!);
      } else {
        await _launchPage(settingsVM.defaultIliasPage.value);
      }
    });
  }

  void _navigationDelegateOnUrlChange(UrlChange urlChange) {
    if (!mounted) return;
    pagesStackSize++;
    setState(() {
      canGoBackFuture = _controller.canGoBack();
      canGoForwardFuture = _controller.canGoForward();
    });

    if (kDebugMode) {
      print("Changed: ${urlChange.url}");
    }
  }

  /// Concurrent taps on the same link share one download (double-taps
  /// used to race two writeAsBytes on one path and stack two viewers).
  static final Map<String, Future<void>> _downloadsInFlight = {};

  Future<String?> _saveAsFile(String url) {
    final interceptable =
        sendfileFileName(url, title: widget.module.title) != null;
    if (!interceptable) {
      // TODO: callback!
      return Future.value();
    }
    final inFlight = _downloadsInFlight[url];
    if (inFlight != null) return inFlight.then((_) => _pathFor(url));
    final future = _doSaveAsFile(url);
    _downloadsInFlight[url] = future;
    future.whenComplete(() => _downloadsInFlight.remove(url));
    return future;
  }

  Future<String?> _pathFor(String url) async {
    final iliasFileManager =
        Provider.of<IliasFilesProvider>(context, listen: false);
    final directory = await iliasFileManager.localFileStorageManager
        .ensureAndGetCurrentSemesterDirectory();
    return iliasSendfilePath(directory, url, title: widget.module.title);
  }

  Future<String?> _doSaveAsFile(String url) async {
    final vm = Provider.of<KITProvider>(context, listen: false);
    final iliasFileManager =
        Provider.of<IliasFilesProvider>(context, listen: false);
    final toastsProvider = Provider.of<ToastsProvider>(context, listen: false);

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
    if (reusable) {
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

    if (!reusable) {
      if (mounted) setState(() => isBusy = true);
      toastsProvider.showTextToast(L10n.t("ilias.downloading"));
      try {
        final iliasFile = await vm.iliasManager.downloadFile(url, file);
        if (mounted) setState(() => isBusy = false);
        _launchFileView(iliasFile);
      } on Object catch (e) {
        if (mounted) setState(() => isBusy = false);
        // a wedged busy overlay makes the whole tab unusable until restart
        toastsProvider.showTextToast(L10n.t("ilias.downloadFailed"));
        if (kDebugMode) print("ILIAS download failed: $e");
      }
      return filepath;
    }

    PinnedFile? iliasFile;

    var existingFiles = await vm.iliasFileManager.getFilesForCurrentSemester();
    for (var element in existingFiles) {
      if (element.urlString == url) {
        iliasFile = element;
        break;
      }
    }

    _launchFileView(iliasFile ??
        PinnedFile(
            semesterString: KITProvider.currentSemesterString,
            urlString: url,
            moduleTitle: "",
            addedAt: DateTime.now().toUtc(),
            customName: "",
            fileSystemPath: filepath));

    return filepath;
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
    _controller.loadRequest(Uri.parse(link));
  }

  @override
  Widget build(BuildContext context) {
    final vm = Provider.of<KITProvider>(context);
    final toastsProvider = Provider.of<ToastsProvider>(context);
    final theme = Theme.of(context);

    return FutureBuilder(
        future: widget.PHPSESSID_Future,
        builder: (context, snapshot) {
          if (!snapshot.hasData || _phpsessid.isEmpty) {
            return Scaffold(
                body: Center(
              child: KITProgressIndicator(),
            ));
          }

          Future<void> refreshSession() async {
            setState(() {
              _phpsessid = "";
            });

            await vm.iliasManager.authorize(refreshSession: true);
            final newPHPSESSIONID = await vm.iliasManager.getPHPSESSID();

            if (newPHPSESSIONID.isEmpty) {
              toastsProvider.showTextToast(L10n.t("ilias.refreshError"));
            }

            setState(() {
              _phpsessid = newPHPSESSIONID;
            });
          }

          // Immersive: ILIAS renders its own header inside the page, so any
          // app bar on top doubles it and the hand-computed webview height
          // (screen - 100 - appBar) letterboxed it. The page goes edge to
          // edge and every control floats on glass instead.
          return Scaffold(
              body: Stack(
            children: [
              Positioned.fill(child: WebViewWidget(controller: _controller)),
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
              // readability for the floating chips over white ILIAS headers
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                height: 72,
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          theme.scaffoldBackgroundColor
                              .withValues(alpha: 0.6),
                          theme.scaffoldBackgroundColor
                              .withValues(alpha: 0.0),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              if (Navigator.of(context).canPop())
                Positioned(
                    top: 6,
                    left: 8,
                    child: SafeArea(
                      child: _glassChip(CupertinoIcons.chevron_left,
                          () => Navigator.of(context).pop()),
                    )),
              Positioned(
                  top: 6,
                  right: 8,
                  child: SafeArea(
                      child: _glassChip(CupertinoIcons.refresh, refreshSession)),
                  ),
              if (!widget.isFileView)
                Positioned(
                  right: 8,
                  bottom: 12,
                  child: SafeArea(
                    child: _FloatingNavChips(
                      canGoBack: canGoBackFuture,
                      canGoForward: canGoForwardFuture,
                      onBack: () => _controller.goBack(),
                      onForward: () => _controller.goForward(),
                    ),
                  ),
                ),
            ],
          ));
        });
  }
}

Widget _glassChip(IconData icon, VoidCallback? onPressed) {
  return Opacity(
    opacity: onPressed == null ? 0.35 : 1,
    child: GlassContainer(
      useOwnLayer: true,
      child: CupertinoButton(
        padding: EdgeInsets.zero,
        minimumSize: const Size(40, 40),
        onPressed: onPressed,
        child: SizedBox(
          width: 40,
          height: 40,
          child: Center(
            child: Icon(icon, size: 20),
          ),
        ),
      ),
    ),
  );
}

/// Webview history controls floating over the page's bottom-right corner:
/// present but never paying rent in vertical space.
class _FloatingNavChips extends StatelessWidget {
  final Future<bool?> canGoBack;
  final Future<bool?> canGoForward;
  final VoidCallback onBack;
  final VoidCallback onForward;

  const _FloatingNavChips(
      {required this.canGoBack,
      required this.canGoForward,
      required this.onBack,
      required this.onForward});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        FutureBuilder(
            future: canGoBack,
            builder: (context, snapshot) {
              final enabled = snapshot.hasData && snapshot.data!;
              return _glassChip(CupertinoIcons.chevron_left,
                  enabled ? onBack : null);
            }),
        const SizedBox(height: 8),
        FutureBuilder(
            future: canGoForward,
            builder: (context, snapshot) {
              final enabled = snapshot.hasData && snapshot.data!;
              return _glassChip(CupertinoIcons.chevron_right,
                  enabled ? onForward : null);
            }),
      ],
    );
  }
}
