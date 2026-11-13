import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../notifications/mei_notifications.dart';
import '../timetable/models/webcal.dart';
import 'feed_health.dart';
import 'support_bundle.dart';

/// Fallback app version, mirroring pubspec.yaml `version:`. The bundle
/// resolves the real installed version from PackageInfo at build time (F9:
/// a +64 install printed this const's 0.8.9+63); kAppVersion only covers
/// unit tests and platforms where the plugin cannot answer - a stale-but-
/// shaped version still beats an empty field in a support thread. MUST be
/// bumped together with the pubspec.
const kAppVersion = "0.8.9+65";

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

  /// R36.1: the doctor's input map + verdicts, ready to render. Lives
  /// here (next to [buildBundle]) so both surfaces provably read the
  /// same device state; the verdict logic itself is the pure
  /// [feedHealth] in feed_health.dart. LIVE platform API (not the
  /// legacy getInstance() snapshot): the heartbeat and the webcal
  /// stamps are written by the WorkManager isolate, and the R16f
  /// lesson is that the per-isolate snapshot can predate those writes
  /// — a doctor showing yesterday's stamp as today's is the exact
  /// fabrication this whole lane exists to prevent.
  static Future<List<FeedStatus>> feedStatuses(
      {required bool credentialsStored,
      bool? notificationsPermission,
      DateTime? now}) async {
    final prefs = SharedPreferencesAsync();
    final diag = <String, String>{};
    for (final key in const [
      WebcalKeys.diag,
      WebcalKeys.fetchedAt,
      "MENSA_fetchedAt",
      "MENSA_diag",
      "DATA_iliasCardCache",
      "DATA_smuOpensFired",
      "ANN_rooms",
    ]) {
      final value = await prefs.getString(key);
      if (value != null && value.isNotEmpty) diag[key] = value;
    }
    final pollAt = await prefs.getInt(lastPollAtKey);
    if (pollAt != null) diag[lastPollAtKey] = pollAt.toString();
    // the grades stamp family is per-term (module_cache_<term>_last_fetch,
    // owner: campus_manager) — feedHealth picks the newest from the scan
    for (final key in await prefs.getKeys()) {
      if (!key.startsWith("module_cache_") || !key.endsWith("_last_fetch")) {
        continue;
      }
      final value = await prefs.getString(key);
      if (value != null && value.isNotEmpty) diag[key] = value;
    }
    return feedHealth(diag,
        // the bundle's own source by default; the UI may hand in a live
        // probe of the identical plugin call after the user returns
        // from the system page (init() short-circuits once _ready)
        notificationsPermission:
            notificationsPermission ?? MeiNotifications.canScheduleExact,
        credentialsStored: credentialsStored,
        now: now);
  }
}
