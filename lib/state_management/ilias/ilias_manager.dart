import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
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
        // recursion goes through the SINGLE-FLIGHT entry; awaiting
        // _authorize() directly would deadlock on _authInFlight
        await authorize(retryIfFailed: false, refreshSession: false);
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

  Future<PinnedFile> downloadFile(String srcUrl, File targetFile) async {
    if (kDebugMode) {
      print("Downloading file to ${targetFile.path} from $srcUrl");
    }

    // lecture PDFs can be tens of MB on campus wifi - the API timeout is too tight
    final response = await netGet(Uri.parse(srcUrl),
        timeout: const Duration(minutes: 2));
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
  }
}
