import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:kit_mobile/credentials/models/auth_result.dart';
import 'package:kit_mobile/credentials/models/kit_credentials.dart';
import 'package:kit_mobile/state_management/kit_provider.dart';
import 'package:workmanager/workmanager.dart';

import '../../docwatch/docwatch.dart';
import '../../local_files_storage/local_file_storage_manager.dart';
import '../../main.dart';
import '../../notifications/mei_notifications.dart';
import 'package:kit_mobile/notifications/library_notifications.dart';
import '../../tutorials/data/tutorial_manager.dart';

/// Thrown by [logout] AFTER the local session was torn down (the UI is
/// already on the login form): at least one vendor/prefs/network step
/// failed, which is a shared-device residue warning - NOT a "logout
/// failed, try again" state, because there is nothing left to retry here.
class PartialLogoutException implements Exception {
  final List<String> failures;
  PartialLogoutException(this.failures);
  @override
  String toString() => "PartialLogoutException(${failures.join("; ")})";
}

class CredentialsProvider extends ChangeNotifier {
  final FlutterSecureStorage _storage = FlutterSecureStorage();

  CredentialsProvider() {
    loadCredentials();
  }

  KITCredentials credentials = KITCredentials();
  bool credentialsLoaded = false;
  bool loggingIn = false;

  String displayName = "";

  Future<bool> loadCredentials({Function? callback, notify = true}) async {
    Map<String, String> all;
    try {
      all = await _storage.readAll(
          iOptions: _iOSOptions, aOptions: _androidOptions);
    } on Object catch (e) {
      // a backup-restored install has ciphertext without its keystore key:
      // drop it so the user just logs in again instead of a dead login gate
      if (kDebugMode) print("secure storage unreadable, resetting: $e");
      try {
        await _storage.deleteAll(
            iOptions: _iOSOptions, aOptions: _androidOptions);
      } on Object {
        // nothing else to do; reads below stay empty
      }
      all = const {};
    }

    credentials.valid = all.containsKey("username") &&
        all.containsKey("password") &&
        all.containsKey("isLoggedIn") &&
        ((all["isLoggedIn"]?.length ?? 0) > 0);

    if (credentials.valid) {
      credentials.username = all["username"]!;
      credentials.password = all["password"]!;
      displayName = all["userDisplayName"] ?? credentials.username;
    }

    credentialsLoaded = true;
    loggingIn = false;

    if (notify) notifyListeners();

    callback?.call(this);

    return credentials.valid;
  }

  Future<void> _writeCredentials() async {
    final username = credentials.username;
    final password = credentials.password;
    final isValid = credentials.valid;

    if (displayName.isEmpty) {
      displayName = credentials.username;
    }

    if (kDebugMode) {
      print("Validating validity of credentials: ${credentials.valid}");
    }

    await _storage.write(
        key: "username",
        value: username,
        iOptions: _iOSOptions,
        aOptions: _androidOptions);
    await _storage.write(
        key: "password",
        value: password,
        iOptions: _iOSOptions,
        aOptions: _androidOptions);
    await _storage.write(
        key: "isLoggedIn",
        value: isValid ? "1" : "",
        iOptions: _iOSOptions,
        aOptions: _androidOptions);
    await _storage.write(
        key: "userDisplayName",
        value: displayName,
        iOptions: _iOSOptions,
        aOptions: _androidOptions);

    if (isAlpha) {
      await _storage.write(
          key: "alpha",
          value: "hero",
          iOptions: _iOSOptions,
          aOptions: _androidOptions);
    }

    if (kDebugMode) {
      print("VALID one more time: ${credentials.valid}");
    }

    // displayName = credentials.username;
    notifyListeners();
  }

  Future<void> _clearCredentials() async {
    if (kDebugMode) {
      print("Clearing credentials...");
    }
    credentials = KITCredentials();
    displayName = ""; // else _writeCredentials re-persists the stale name
    await _writeCredentials();
  }

  Future<void> setDisplayName(String val) async {
    displayName = val;
    await _storage.write(
        key: "userDisplayName",
        value: val,
        iOptions: _iOSOptions,
        aOptions: _androidOptions);
  }

  Future<AuthResult> submit(
      String typedUsername, String typedPassword, KITProvider vm) async {
    if (displayName.isEmpty) {
      displayName = typedUsername;
      notifyListeners();
    }

    KITCredentials newCredentials =
        KITCredentials(username: typedUsername, password: typedPassword);

    if (!newCredentials.isFormatValid) {
      if (kDebugMode) {
        print("The username format is invalid!");
      }
      return AuthResult.wrongUsernameFormat;
    }

    credentials = newCredentials;

    return await login(vm, clearCookiesAndCache: true);
  }

  Future<AuthResult> login(KITProvider vm,
      {clearCookiesAndCache = true}) async {
    loggingIn = true;
    notifyListeners();
    // R22: the tail below (valid=true, real-name displayName,
    // _writeCredentials) used to run even if a logout tore the session
    // down while these awaits slept - re-persisting the PREVIOUS
    // student's name plus a phantom isLoggedIn over the fresh wipe,
    // which loadCredentials then reported as a VALID empty session
    final int epoch = vm.campusManager.teardownEpoch;
    try {
      if (clearCookiesAndCache) {
        await vm.clearCookiesAndCache();
      }

      if (!credentials.isFormatValid) {
        return AuthResult.wrongUsernameFormat;
      }

      vm.setCredentials(credentials);
      // await vm.iliasManager.authorize();
      await vm.fetchSchedule(secondRetryIfFailed: false);

      // On the boot re-login path tryPreloadCache set campusManager.ready
      // =true unconditionally BEFORE this call, so profileReady is true no
      // matter how dead the session is - the per-fetch abort flag is the
      // only honest arbiter (stage0<0 = invalid credentials, stage3 = dead
      // session; offline boots throw out of netGet and keep the cached
      // home, they never reach this line). Without it a rotated password
      // pinned the user to the dead session's cached home forever.
      if (!vm.profileReady || vm.campusManager.scheduleFetchFailed) {
        credentials.valid = false;
        return AuthResult.fail;
      }
    } finally {
      // Never leave the login form disabled: every exit path (incl. throws)
      // re-enables input. Root cause of the frozen-form dead end.
      loggingIn = false;
      notifyListeners();
    }

    if (vm.campusManager.teardownEpoch != epoch) {
      return AuthResult.fail; // see R22 note above: logout raced the tail
    }

    credentials.valid = true;
    setDisplayName(vm.student.name.repr);
    if (kDebugMode) {
      print(
          "Successfully logged in and writing credentials which are valid: ${credentials.valid}");
    }
    await _writeCredentials();

    loggingIn = false;
    notifyListeners();

    return AuthResult.ok;
  }

  /// Everything the UI must kick off once authentication succeeded; errors
  /// are contained here so no caller (login form, main.dart) can wedge.
  Future<void> loginPostSteps(KITProvider vm) async {
    try {
      vm.iliasAuth = vm.iliasManager.authorize().catchError((_) {});
      await vm.campusManager.fetchTimetable();
      // via the provider so `vm.examsDone` is armed for the agenda
      await vm.fetchExams();
      await vm.campusManager.fetchAllModules();
    } on Object catch (e) {
      if (kDebugMode) print("post-login fetch failed: $e");
    }
  }

  Future<void> logout(KITProvider vm, TutorialManager tutorialManager) async {
    // purge-first ordering: a keystore hiccup during credential wipe must
    // never skip the DATA_*/webcal-token sweep on a shared device - hence
    // every teardown step is individually try/caught, its failure merely
    // accumulated and rethrown at the end: the UI's toast then tells a
    // full sweep apart from a partial one instead of lying either way
    final failures = <String>[];
    try {
      await _clearCredentials();
    } on Object catch (e) {
      failures.add("credential wipe: $e");
    }
    try {
      // IdP/cascampus/ILIAS SSO cookies must die with the logout, not linger
      await vm.clearCookiesAndCache();
    } on Object catch (e) {
      failures.add("cookie/cache purge: $e");
    }
    try {
      // The webview engine jar is the SECOND cookie store: completing the
      // IdP wall inside the ILIAS webview leaves A's SSO cookies there, and
      // a rejected PHPSESSID then silently SSO-issues A's account into the
      // next user's webview. The engine only clears ALL domains at once,
      // which is why periodic re-auth skips it - logout must not. (Every
      // webview load re-injects a fresh PHPSESSID beforehand anyway.)
      await WebViewCookieManager().clearCookies();
    } on Object catch (e) {
      failures.add("webview cookie jar: $e");
    }
    vm.campusManager.wipeAccountMemory();
    tutorialManager.clearAll();
    vm.dropInflightFetches(); // A's in-flight memos must not be joined
    vm.signMeUpManager.procedures = [];
    vm.signMeUpManager.mine = [];
    vm.signMeUpManager.termStart = null;
    vm.signMeUpManager.loaded = false;
    vm.signMeUpManager.loadedMine = false;
    vm.campusManager.ready = false;
    vm.campusManager.scheduleFetchingTimer?.cancel();
    try {
      // awaited: it is async and its prefs.remove used to run unawaited,
      // i.e. outside every guard below
      await vm.campusManager.resetRelevantModules();
    } on Object catch (e) {
      failures.add("relevant modules: $e");
    }
    try {
      await vm.campusManager.clearStudentData();
    } on Object catch (e) {
      failures.add("student data wipe: $e");
    }
    try {
      await vm.campusManager.clearCachedTimetableData();
    } on Object catch (e) {
      failures.add("timetable cache wipe: $e");
    }
    try {
      await vm.iliasManager.logout();
    } on Object catch (e) {
      failures.add("ilias logout: $e");
    }
    // The library (Anny) session is the ONE login this app holds besides
    // the KIT campus account: without this, logout left ANN_jwt/email +
    // the ANNY_pass keychain copy behind, and the next authed call would
    // silently re-mint a JWT for the LOGGED-OUT account on a shared device
    // (audit R21, critical). signOut() itself clears triple+keychain+pings.
    try {
      await vm.anny.signOut();
    } on Object catch (e) {
      failures.add("library sign-out: $e");
    }
    // Kill the background ICS poll BEFORE the sweep so no further run
    // starts against the dying token; the already-running poll lives in a
    // separate isolate and cannot be awaited from here - its own
    // logged-out re-check is the fence for that last in-flight run.
    try {
      await Workmanager().cancelByUniqueName("mei-webcal-poll");
      // the seam-registered one-off shares the data fence but still
      // outlives the account boundary unless cancelled here too
      await Workmanager().cancelByUniqueName("mei-webcal-poll-test");
    } on Object catch (e) {
      failures.add("bg poll cancel: $e");
    }
    // Full data sweep: DATA_* holds the webcal TOKEN url, the scraped
    // schedule, pinned ILIAS files and change logs - none may survive a
    // logout on a shared device or bleed into the next account's session.
    try {
      // enumerate + delete through the LIVE store: the legacy
      // SharedPreferences.getInstance() snapshot is a per-isolate cache,
      // and keys first created by the WorkManager poll isolate this
      // session (DATA_webcalFeedSource = full token URL, fingerprint,
      // changes, iliasWatchSeen) were invisible to its getKeys() - they
      // survived logout on exactly such a shared device
      final prefs = SharedPreferencesAsync();
      for (final key in (await prefs.getKeys())
          .where((k) =>
              k.startsWith("DATA_") ||
              k.startsWith("RMR ") ||
              k.startsWith("module_cache_") ||
              k.startsWith("MIL ") ||
              // belt-and-braces for the library session (signOut above is
              // the real teardown): no ANN_* may survive the sweep
              k.startsWith("ANN_"))
          .toList()) {
        await prefs.remove(key);
      }
    } on Object catch (e) {
      failures.add("prefs sweep: $e");
    }
    try {
      // Second pass through the LEGACY instance: getInstance() answers from
      // a per-isolate snapshot the Async removals never invalidate, so every
      // reader still on the legacy API (_ensureWebcalUrl, personalIcs load,
      // the ICS-cache synth paths, manual-ILIAS reload) would hand the DEAD
      // account's cached values - including the live webcal token URL - to
      // the next student in the same process. Legacy remove() evicts the
      // snapshot entry itself, killing the whole stale-read class at the
      // root instead of per-call-site.
      final legacy = await SharedPreferences.getInstance();
      for (final key in legacy
          .getKeys()
          .where((k) =>
              k.startsWith("DATA_") ||
              k.startsWith("RMR ") ||
              k.startsWith("module_cache_") ||
              k.startsWith("MIL ") ||
              k.startsWith("ANN_"))
          .toList()) {
        await legacy.remove(key);
      }
    } on Object catch (e) {
      failures.add("legacy prefs sweep: $e");
    }
    try {
      // R34.6: the keychain is not only the KIT credentials — the document
      // expiry watch stores every user-noted DOC_* entry in the same
      // FlutterSecureStorage. Same doctrine as the prefs sweeps: enumerate
      // the LIVE store and delete exactly the family's keys (never
      // deleteAll: username/password and the library copy have their own
      // owners above). A keychain hiccup lands in `failures` below — the
      // user sees "partial wipe", it is never swallowed here.
      await DocWatchStore.purgeAll(_storage);
    } on Object catch (e) {
      failures.add("document keychain sweep: $e");
    }
    try {
      // library family first: explicit per-id cancel, so a partial
      // plugin failure inside cancelAll can never strand a check-in ping
      await LibraryNotifications.cancelAll();
      await MeiNotifications.cancelAllScheduled();
    } on Object catch (e) {
      failures.add("notification teardown: $e");
    }
    // downloaded ILIAS file BYTES live outside prefs: purging only the
    // index left every file browsable by the next account until uninstall
    try {
      final cacheDir = Directory(await LocalFileStorageManager.baseDirPath);
      if (cacheDir.existsSync()) {
        await cacheDir.delete(recursive: true);
      }
    } on Object catch (e) {
      failures.add("file cache wipe: $e");
    }
    // local UI reset runs and must never rethrow into the caller chain: a
    // throwing listener would toast "logout failed" although everything
    // is swept
    try {
      vm.setCredentials(credentials);
      notifyListeners();
      vm.notifyListeners();
    } on Object catch (e) {
      if (kDebugMode) print("local logout reset failed: $e");
    }
    // never leak raw exception text into the toast (settings_page prints
    // this in debug and shows its own text); a PARTIAL wipe is its own
    // case: the user IS logged out, only the residue differs
    if (failures.isNotEmpty) {
      throw PartialLogoutException(failures);
    }
  }

  IOSOptions get _iOSOptions => const IOSOptions(accountName: "kit-student");

  // encryptedSharedPreferences deliberately gone: deprecated upstream,
  // ignored by the plugin, which migrates storage to custom ciphers on
  // first access by itself
  AndroidOptions get _androidOptions => const AndroidOptions();
}
