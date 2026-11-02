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
      _lastUpdate = DateTime.now();
    }

    return _phpsessid;
  }

  Future<void>? _authInFlight;

  /// Single-flight: startup, dead-session recovery and the manual refresh
  /// all hammer this; two concurrent chains would wipe each other's
  /// JSESSIONID out of the shared jar mid-SSO (clearCookiesAndCache below).
  Future<void> authorize(
      {retryIfFailed = true,
      secondRetryIfFailed = true,
      refreshSession = true}) {
    final inFlight = _authInFlight;
    if (inFlight != null) return inFlight;
    final future =
        _authorize(retryIfFailed: retryIfFailed, refreshSession: refreshSession);
    _authInFlight = future;
    return future.whenComplete(() => _authInFlight = null);
  }

  Future<void> _authorize(
      {required bool retryIfFailed, required bool refreshSession}) async {
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
    if (url.contains("login.php") ||
        url.contains("cmd=force_login") ||
        url.contains("SingleSignOn") ||
        url.contains("sso.kit.edu") ||
        url.contains("oauth2/authorize")) {
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

  Future<PinnedFile> downloadFile(String srcUrl, File targetFile) async {
    if (kDebugMode) {
      print("Downloading file to ${targetFile.path} from $srcUrl");
    }

    // lecture PDFs can be tens of MB on campus wifi - the API timeout is too tight
    //
    // routed through the same dead-session wrapper every scraper call uses:
    // a session that died between page load and tap silently re-authorizes
    // instead of 302-ing the login page into the magic-byte gate below
    // (which only knows how to fail, not to recover)
    final response = await withSessionResponse(() => netGet(Uri.parse(srcUrl),
        timeout: const Duration(minutes: 2)));
    var bytes = response.bodyBytes;

    // a dead PHPSESSID makes ILIAS 302 to force_login which resolves to a
    // 200 HTML page; without this gate the login form got cached as a
    // permanently broken ".pdf" (downloads are only retried when the file
    // is absent)
    final isPdf = bytes.length > 4 &&
        bytes[0] == 0x25 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x44 &&
        bytes[3] == 0x46; // "%PDF"
    if (response.statusCode != 200 || !isPdf) {
      throw Exception(
          "ILIAS download not a PDF (status ${response.statusCode}, "
          "${bytes.lengthInBytes} bytes) - session likely expired");
    }

    await targetFile.writeAsBytes(bytes);

    return PinnedFile(
        semesterString: KITProvider.currentSemesterString,
        urlString: srcUrl,
        moduleTitle: "",
        addedAt: DateTime.now().toUtc(),
        customName: "",
        fileSystemPath: targetFile.path);
  }

  Future<void> logout() async {
    _phpsessid = "";
    // the agenda card cache holds this student's course titles and message
    // previews; the login screen renders before any refetch, so a shared
    // device must not show them to the next account
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove("DATA_iliasCardCache");
  }
}
