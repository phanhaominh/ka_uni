import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../notifications/mei_notifications.dart';
import '../timetable/models/webcal.dart';
import 'support_bundle.dart';

/// Fallback app version, mirroring pubspec.yaml `version:`. The bundle
/// resolves the real installed version from PackageInfo at build time (F9:
/// a +64 install printed this const's 0.8.9+63); kAppVersion only covers
/// unit tests and platforms where the plugin cannot answer - a stale-but-
/// shaped version still beats an empty field in a support thread. MUST be
/// bumped together with the pubspec.
const kAppVersion = "0.8.9+63";

/// The one CrashTail every error hook records into, plus its prefs mirror.
///
/// PREF_crashTail deliberately survives logout (PREF family = device
/// facts, same precedent as PREF_exactAlarmAsked): lines are one-line
/// `runtimeType: message` records that passed [scrubDiag] before storage,
/// and the crash a support thread needs most is usually the one from the
/// session that just died - losing it at app exit would defeat the tail.
/// main.dart's zone + FlutterError hooks own [record]; the settings export
/// reads [tail] and rebuilds the whole bundle.
class SupportState {
  SupportState._();

  static final CrashTail tail = CrashTail();
  static const _prefsKey = "PREF_crashTail";

  /// Boot: re-hydrate the tail of the previous session. Contained — a
  /// poisoned prefs string must not dim the splash.
  static Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      for (final line in prefs.getStringList(_prefsKey) ?? const <String>[]) {
        tail.seed(line);
      }
    } on Object catch (_) {}
  }

  static Future<void> record(Object error, [String? route]) async {
    try {
      tail.record(error, route);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_prefsKey, tail.lines);
    } on Object catch (_) {
      // an error hook must never become the error
    }
  }

  /// Assemble the pasteable bundle: every feed diag one-liner the prefs
  /// still hold + crash tail + exact-alarm state. The values pass the
  /// bundle's own scrubber again (idempotent) - nothing here may carry a
  /// token URL, an email, or a key.
  static Future<String> buildBundle() async {
    final prefs = await SharedPreferences.getInstance();
    final diags = <String, String>{
      for (final key in const [WebcalKeys.diag, "MENSA_diag"])
        if ((prefs.getString(key) ?? "").isNotEmpty) key: prefs.getString(key)!,
    };
    // Runtime version first; PackageInfo caches its answer process-wide, so
    // this stays one channel call per session. Missing plugin (tests, odd
    // platforms) or empty fields fall back to the const, never a blank.
    var appVersion = kAppVersion;
    try {
      final info = await PackageInfo.fromPlatform();
      if (info.version.isNotEmpty && info.buildNumber.isNotEmpty) {
        appVersion = "${info.version}+${info.buildNumber}";
      }
    } on Object catch (_) {}
    return buildSupportBundle(
      appVersion: appVersion,
      diagnostics: diags,
      crashTail: tail.lines,
      notificationsPermission: MeiNotifications.canScheduleExact,
    );
  }
}
