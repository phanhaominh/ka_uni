import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:kit_mobile/state_management/kit_login_manager.dart';
import 'package:kit_mobile/state_management/kit_provider.dart';

import '../../local_files_storage/models/pinned_file.dart';

class IliasManager extends KITLoginManager {
  String _phpsessid = "";
  bool isBusy = false;

  DateTime _lastUpdate = DateTime(2004);

  /// ILIAS proxies emit a duplicated `Content-Type: text/html, text/html; charset=UTF-8`
  /// which http_parser rejects; ILIAS responses are always UTF-8 HTML anyway.
  String bodyOf(http.Response response) {
    try {
      return response.body;
    } on FormatException {
      return utf8.decode(response.bodyBytes);
    }
  }

  Future<String> getPHPSESSID() async {
    // bounded wait: one wedged SSO must not recurse on a 500ms timer forever
    for (var i = 0; i < 120 && isBusy; i++) {
      await Future.delayed(const Duration(milliseconds: 500));
    }

    if (isBusy) {
      // the bounded wait expired with an authorize() chain still running:
      // handing out "" or the stale pre-refresh cookie is a silent login
      // wall for the webview, so join the in-flight chain instead -
      // bounded, so a permanently wedged SSO does not grow a new dead end.
      // A join that TIMES OUT or THROWS must not escape either: callers
      // chain this future without error handlers, and falling through to
      // the stale/authorize path below is strictly better than an
      // unhandled zone error leaving the webview blank.
      try {
        await _authInFlight?.timeout(const Duration(minutes: 2));
      } on Object catch (e) {
        if (kDebugMode) {
          print("ILIAS auth join gave up: $e");
        }
      }
    }

    if (DateTime.now().isAfter(_lastUpdate.add(const Duration(minutes: 30)))) {
      if (kDebugMode) {
        print("Refetching ilias session...");
      }
      await authorize();
      // R22: stamp ONLY on success (mirrors _authorize's own discipline):
      // the unconditional stamp made one transient SSO failure deadlock
      // every ILIAS open on the auth-failed wall for a full 30 minutes,
      // although an immediate re-auth would have succeeded
      if (_phpsessid.isNotEmpty) _lastUpdate = DateTime.now();
    }

    return _phpsessid;
  }

  int _authGen = 0;

  Future<void>? _authInFlight;

  /// R22 (KITProvider.dropInflightFetches at logout): drop the
  /// account-bound SSO chain. Its memo used to survive logout, so the
  /// NEXT account's getPHPSESSID/authorize JOINED the previous user's
  /// in-flight chain and received THEIR PHPSESSID - A's ILIAS board
  /// scraped straight into B's agenda card - while A's <30-min freshness
  /// stamp suppressed B's own re-authorize.
  void dropAuthInFlight() {
    _authGen++;
    _authInFlight = null;
    _phpsessid = "";
    _lastUpdate = DateTime(2004);
  }

  /// Single-flight: startup, dead-session recovery and the manual refresh
  /// all hammer this; two concurrent chains would wipe each other's
  /// JSESSIONID out of the shared jar mid-SSO (clearCookiesAndCache below).
  Future<void> authorize(
      {retryIfFailed = true,
      secondRetryIfFailed = true,
      refreshSession = true}) {
    final inFlight = _authInFlight;
    if (inFlight != null) return inFlight;
    final future = _authorize(
        retryIfFailed: retryIfFailed, refreshSession: refreshSession);
    _authInFlight = future;
    return future.whenComplete(() => _authInFlight = null);
  }

  Future<void> _authorize(
      {required bool retryIfFailed, required bool refreshSession}) async {
    final gen = _authGen; // R22: logout bumps it - never stamp a torn-down
    // session's PHPSESSID/freshness back in after the chain settles
    isBusy = true;
    try {
      if (refreshSession) {
        await clearCookiesAndCache();
        _phpsessid = "";
      }

      await fetchJSession();

      await fetchStage0_Init();
      final stage1Response = await fetchStage1_TryToOpenLoginPage(
          "https://ilias.studium.kit.edu/shib_login.php");

      final stage2Response = await fetchStage2_(stage1Response);
      if (stage2Response == null && kDebugMode) {
        print("Stage 2 failed!");
      }

      if (retryIfFailed && !sessionContainsCookieNamed("PHPSESSID")) {
        // retry INSIDE the chain must bypass the single-flight entry:
        // _authInFlight still holds THIS future, so authorize(...) would
        // hand back the outer future and await itself forever. The memo
        // guards against concurrent external chains only; this recursion
        // is the tail of the chain it already joined.
        await _authorize(retryIfFailed: false, refreshSession: false);
        return;
      }

      // exact cookie lookup; substring surgery on cookiesString throws when
      // PHPSESSID is the last (or missing) jar entry
      if (gen != _authGen) return; // logged out mid-SSO: stay dropped
      _phpsessid = "";
      for (final c in session.cookieStore.cookies) {
        if (c.name == "PHPSESSID") _phpsessid = c.value;
      }
      if (_phpsessid.isEmpty) {
        if (kDebugMode) print("ILIAS authorize finished WITHOUT PHPSESSID");
      } else {
        _lastUpdate = DateTime.now();
      }
    } on Object catch (e) {
      if (kDebugMode) print("ILIAS authorize failed: $e");
    } finally {
      isBusy = false;
    }
  }

  /// Logged-out detection from the RESPONSE, not the cookie jar: PHPSESSID
  /// is a session cookie that survives server-side expiry inside the jar,
  /// and several landing pages carry no "Lokale ILIAS-Anmeldung" marker -
  /// a dead session used to scrape as "0 courses / no news" success.
  /// Dead sessions always land on a login page after redirects.
  bool _looksLoggedOut(http.Response response,
      {required String Function() body}) {
    // final URL after redirects (request.url is the original);
    // BaseResponseWithUrl is matched via an Object receiver so the
    // promotion sees the interface getter, not Response's absent one
    final Object asObject = response;
    final url = asObject is http.BaseResponseWithUrl
        ? asObject.url.toString()
        : (response.request?.url.toString() ?? "");
    if (looksLikeLoginWall(url)) {
      return true;
    }
    // marker hunt on HTML only: PDF downloads run through the same
    // session wrapper and must not pay for (or choke on) a body decode;
    // a missing content-type counts as HTML - scrapers rely on the marker
    if (!(response.headers["content-type"] ?? "text/html").contains("html")) {
      return false;
    }
    return body().contains("Lokale ILIAS-Anmeldung");
  }

  /// Login-wall URL signatures, shared by the HTTP-level check in
  /// [_looksLoggedOut] and the webview's mid-session SSO-wall recovery
  /// (ilias_page_view): the two detectors must never drift apart.
  static bool looksLikeLoginWall(String url) {
    return url.contains("login.php") ||
        url.contains("cmd=force_login") ||
        url.contains("SingleSignOn") ||
        url.contains("sso.kit.edu") ||
        url.contains("oauth2/authorize");
  }

  /// Re-runs SSO when the ILIAS session died, then retries once; if the
  /// retried page still shows a login wall the session is NOT revived -
  /// throwing beats parsing login HTML as empty data or caching it as a
  /// ".pdf". Every ILIAS GET shares this recovery: the scraping
  /// extension's _withSessionBody and [downloadFile].
  Future<http.Response> withSessionResponse(
      Future<http.Response> Function() action) async {
    var response = await action();
    if (!_looksLoggedOut(response, body: () => bodyOf(response))) {
      return response;
    }
    if (kDebugMode) print("ILIAS session dead -> re-authorize");
    await authorize(refreshSession: true);
    response = await action();
    if (_looksLoggedOut(response, body: () => bodyOf(response))) {
      throw Exception("ILIAS session could not be revived");
    }
    return response;
  }

  /// Content-Type → file extension for proved-session, non-PDF ILIAS
  /// downloads: the lecture-material formats KIT lecturers actually upload
  /// (Office 97-2003 + OOXML + ODF + archives + media). Deliberately
  /// contains no html/xml/executable entries, and generic octet-stream is
  /// NOT mapped - unknown types fall back to the Content-Disposition
  /// filename extension in [extensionForDownloadBody] instead.
  static const _contentTypeExtensions = <String, String>{
    // no "application/pdf" entry: PDFs are decided by magic bytes alone,
    // a non-PDF body must never receive a ".pdf" name back from this gate
    "application/zip": ".zip",
    "application/x-zip-compressed": ".zip",
    "application/x-7z-compressed": ".7z",
    "application/x-rar-compressed": ".rar",
    "application/vnd.rar": ".rar",
    "application/gzip": ".gz",
    "application/x-gzip": ".gz",
    "application/x-tar": ".tar",
    "application/epub+zip": ".epub",
    "application/msword": ".doc",
    "application/vnd.ms-powerpoint": ".ppt",
    "application/vnd.ms-excel": ".xls",
    "application/vnd.openxmlformats-officedocument.wordprocessingml.document":
        ".docx",
    "application/vnd.openxmlformats-officedocument.presentationml.presentation":
        ".pptx",
    "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet":
        ".xlsx",
    "application/vnd.oasis.opendocument.text": ".odt",
    "application/vnd.oasis.opendocument.presentation": ".odp",
    "application/vnd.oasis.opendocument.spreadsheet": ".ods",
    "application/rtf": ".rtf",
    "text/rtf": ".rtf",
    "text/plain": ".txt",
    "text/csv": ".csv",
    "text/markdown": ".md",
    "image/png": ".png",
    "image/jpeg": ".jpg",
    "image/gif": ".gif",
    "image/webp": ".webp",
    "video/mp4": ".mp4",
    "video/quicktime": ".mov",
    "video/webm": ".webm",
    "audio/mpeg": ".mp3",
    "audio/mp4": ".m4a",
    "audio/x-wav": ".wav",
    "audio/wav": ".wav",
  };

  /// The download gate, pure so it is unit-testable. Magic bytes decide
  /// PDFs; a PROVED session (withSessionResponse has already re-authorized
  /// past any wall before this runs) that yields a genuine non-PDF body
  /// gets the extension its Content-Type proves - or, for unmapped types
  /// like generic octet-stream, the extension of the original filename in
  /// Content-Disposition. Naming every body ".pdf" and rejecting the rest
  /// made real zip/pptx/docx course material an undownloadable dead end.
  /// Null means "never save this": non-200, or an HTML/unidentifiable body
  /// - a login wall or interstitial must not be cached as course material.
  @visibleForTesting
  static String? extensionForDownloadBody(
      {required bool isPdf,
      required int statusCode,
      String? contentType,
      String? contentDisposition}) {
    if (statusCode != 200) return null;
    if (isPdf) return ".pdf";
    final type = (contentType ?? "").split(";").first.trim().toLowerCase();
    // a dead session lands on a 200 login page after the redirect chain;
    // caching HTML under ANY extension would recreate the login-form-
    // cached-as-a-lecture-file bug the original PDF gate existed to stop
    if (type.contains("html")) return null;
    final mapped = _contentTypeExtensions[type];
    if (mapped != null) return mapped;
    // unknown non-HTML type: the attachment disposition still carries the
    // real filename - keep its extension when it is a plain one; web-page
    // name extensions stay refused (server-configured .html attachments
    // are walls in disguise)
    final m =
        RegExp("filename\\*?=(?:UTF-8'')?\"?([^\";]+)\"?", caseSensitive: false)
            .firstMatch(contentDisposition ?? "");
    final name = m?.group(1)?.trim();
    final dot = name?.lastIndexOf(".") ?? -1;
    if (name != null && dot > 0 && dot < name.length - 1) {
      final ext = name.substring(dot + 1).toLowerCase();
      if (RegExp(r"^[a-z0-9]{1,8}$").hasMatch(ext) &&
          // "pdf" included: a real PDF was already certified by the magic
          // bytes above, so a ".pdf" name on anything else is a lie
          !const {"pdf", "html", "htm", "xhtml", "php", "jsp", "asp", "aspx"}
              .contains(ext)) {
        return ".$ext";
      }
    }
    return null;
  }

  Future<PinnedFile> downloadFile(String srcUrl, File targetFile) async {
    if (kDebugMode) {
      print("Downloading file to ${targetFile.path} from $srcUrl");
    }

    // lecture PDFs can be tens of MB on campus wifi - the API timeout is too tight
    //
    // routed through the same dead-session wrapper every scraper call uses:
    // a session that died between page load and tap silently re-authorizes
    // instead of 302-ing the login page into the gate below
    // (which only knows how to fail, not to recover)
    final response = await withSessionResponse(
        () => netGet(Uri.parse(srcUrl), timeout: const Duration(minutes: 2)));
    var bytes = response.bodyBytes;

    // a dead PHPSESSID makes ILIAS 302 to force_login which resolves to a
    // 200 HTML page; the gate refuses HTML bodies and non-200s, so the
    // login form can never again be cached as a permanently broken file
    // (downloads are only retried when the file is absent)
    final isPdf = bytes.length > 4 &&
        bytes[0] == 0x25 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x44 &&
        bytes[3] == 0x46; // "%PDF"
    final extension = extensionForDownloadBody(
        isPdf: isPdf,
        statusCode: response.statusCode,
        contentType: response.headers["content-type"],
        contentDisposition: response.headers["content-disposition"]);
    if (extension == null) {
      throw Exception("ILIAS download refused (status ${response.statusCode}, "
          "${bytes.lengthInBytes} bytes) - session likely expired");
    }

    // PDFs land on the caller-suggested path; a proved-session non-PDF body
    // swaps the guessed ".pdf" for the extension its headers proved
    var path = targetFile.path;
    if (extension != ".pdf") {
      final stem =
          path.endsWith(".pdf") ? path.substring(0, path.length - 4) : path;
      path = "$stem$extension";
    }
    await File(path).writeAsBytes(bytes);

    return PinnedFile(
        semesterString: KITProvider.currentSemesterString,
        urlString: srcUrl,
        moduleTitle: "",
        addedAt: DateTime.now().toUtc(),
        customName: "",
        fileSystemPath: path);
  }

  Future<void> logout() async {
    dropAuthInFlight(); // R22: memo + freshness stamp are account data too
    _phpsessid = "";
    // the agenda card cache holds this student's course titles and message
    // previews; the login screen renders before any refetch, so a shared
    // device must not show them to the next account
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove("DATA_iliasCardCache");
  }
}
