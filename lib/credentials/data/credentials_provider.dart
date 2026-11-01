import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:kit_mobile/credentials/models/auth_result.dart';
import 'package:kit_mobile/credentials/models/kit_credentials.dart';
import 'package:kit_mobile/state_management/kit_provider.dart';

import '../../local_files_storage/local_file_storage_manager.dart';
import '../../main.dart';
import '../../notifications/mei_notifications.dart';
import '../../tutorials/data/tutorial_manager.dart';

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

      if (!vm.profileReady) {
        credentials.valid = false;
        return AuthResult.fail;
      }
    } finally {
      // Never leave the login form disabled: every exit path (incl. throws)
      // re-enables input. Root cause of the frozen-form dead end.
      loggingIn = false;
      notifyListeners();
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
    // never skip the DATA_*/webcal-token sweep on a shared device
    try {
      await _clearCredentials();
    } on Object catch (e) {
      if (kDebugMode) print("credential wipe failed, sweeping anyway: $e");
    }
    // IdP/cascampus/ILIAS SSO cookies must die with the logout, not linger
    await vm.clearCookiesAndCache();
    vm.campusManager.wipeAccountMemory();
    tutorialManager.clearAll();
    vm.signMeUpManager.procedures = [];
    vm.signMeUpManager.mine = [];
    vm.signMeUpManager.termStart = null;
    vm.signMeUpManager.loaded = false;
    vm.signMeUpManager.loadedMine = false;
    vm.campusManager.ready = false;
    vm.campusManager.scheduleFetchingTimer?.cancel();
    vm.campusManager.resetRelevantModules();
    await vm.campusManager.clearStudentData();
    await vm.campusManager.clearCachedTimetableData();
    await vm.iliasManager.logout();
    // Full data sweep: DATA_* holds the webcal TOKEN url, the scraped
    // schedule, pinned ILIAS files and change logs - none may survive a
    // logout on a shared device or bleed into the next account's session.
    final prefs = await SharedPreferences.getInstance();
    for (final key in prefs
        .getKeys()
        .where((k) =>
            k.startsWith("DATA_") ||
            k.startsWith("RMR ") ||
            k.startsWith("module_cache_") ||
            k.startsWith("MIL "))
        .toList()) {
      await prefs.remove(key);
    }
    await MeiNotifications.cancelAllScheduled();
    // downloaded ILIAS file BYTES live outside prefs: purging only the
    // index left every file browsable by the next account until uninstall
    try {
      final cacheDir = Directory(await LocalFileStorageManager.baseDirPath);
      if (cacheDir.existsSync()) {
        await cacheDir.delete(recursive: true);
      }
    } on Object catch (e) {
      if (kDebugMode) print("file cache wipe failed: $e");
    }
    vm.setCredentials(credentials);
    notifyListeners();
    vm.notifyListeners();
  }

  IOSOptions get _iOSOptions => const IOSOptions(accountName: "kit-student");

  // encryptedSharedPreferences deliberately gone: deprecated upstream,
  // ignored by the plugin, which migrates storage to custom ciphers on
  // first access by itself
  AndroidOptions get _androidOptions => const AndroidOptions();
}
