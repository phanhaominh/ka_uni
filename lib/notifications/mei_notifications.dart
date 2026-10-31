import 'dart:io' show Platform;
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;
import 'package:workmanager/workmanager.dart';

import '../exams/models/exam_list.dart';
import '../l10n/l10n.dart';
import '../signmeup/signmeup_manager.dart';
import '../state_management/campus/campus_manager.dart';
import '../timetable/models/webcal.dart';

const String channelIdDaily = "mei_daily";
const String channelIdDeadlines = "mei_deadlines";
const String channelIdChanges = "mei_changes";

class MeiNotifications {
  static final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  static bool _ready = false;

  /// Notifications + background jobs: Android only, deliberately. On iOS
  /// there is no DarwinInitializationSettings, no permission request and no
  /// BGTaskScheduler identifier/handler, so every notification would be
  /// silently dropped and the 2 h poll could never register - while every
  /// entry point kept writing schedules as if they worked. Gating honestly
  /// beats pretending; the desktop build stays fully functional offline.
  static bool get supported => Platform.isAndroid;

  /// Bumped on every logout. Schedulers that started BEFORE the teardown
  /// (fire-and-forget fetch callbacks still in flight) check this between
  /// awaits and bail, so a fetch completing after logout can never
  /// resurrect the old account's reminders.
  static int teardownEpoch = 0;

  static bool _canScheduleExact = true;

  static Future<void> init({bool requestPermissions = true}) async {
    if (_ready || !supported) return;
    tzdata.initializeTimeZones();
    await _plugin.initialize(const InitializationSettings(
        android: AndroidInitializationSettings("@mipmap/ic_launcher")));
    final androidPlugin = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    await androidPlugin?.createNotificationChannel(AndroidNotificationChannel(
        channelIdDaily, L10n.t("notifs.channelTimetable"),
        description: L10n.t("notifs.channelTimetableDesc"),
        importance: Importance.high));
    await androidPlugin?.createNotificationChannel(AndroidNotificationChannel(
        channelIdDeadlines, L10n.t("notifs.channelDeadlines"),
        description: L10n.t("notifs.channelDeadlinesDesc"),
        importance: Importance.high));
    await androidPlugin?.createNotificationChannel(AndroidNotificationChannel(
        channelIdChanges, L10n.t("notifs.channelChanges"),
        description: L10n.t("agenda.roomChanges"), importance: Importance.max));
    // permission REQUESTS need an attached activity: in the WorkManager
    // isolate mainActivity is null and the plugin NPEs (crash-loop every
    // poll). Only the UI process may prompt; background inits only probe.
    if (requestPermissions) {
      await androidPlugin?.requestExactAlarmsPermission();
      await androidPlugin?.requestNotificationsPermission();
    }
    _canScheduleExact =
        await androidPlugin?.canScheduleExactNotifications() ?? true;
    _ready = true;
  }

  /// Id 0 => rotating slot in the 1000-1019 band: consecutive changes must
  /// not replace each other in the shade, and the band is cancelled on logout.
  static int _changeSeq = 0;

  /// Immediate heads-up (used by the background diff job).
  static Future<void> notifyChange(String title, String body) async {
    if (!MeiNotifications.supported) return;
    if (!_ready) await init(requestPermissions: false);
    await _plugin.show(
        1000 + (_changeSeq++ % 20),
        title,
        body,
        NotificationDetails(
            android: AndroidNotificationDetails(
                channelIdChanges, L10n.t("notifs.channelChanges"),
                importance: Importance.max)));
  }

  static Future<void> _zoned(
      int id, String channel, String title, String body, DateTime whenLocal,
      {required bool deadlines}) async {
    if (!whenLocal.isAfter(DateTime.now())) {
      return;
    }
    try {
      await _plugin.zonedSchedule(
          id,
          title,
          body,
          tz.TZDateTime.from(whenLocal, tz.local),
          NotificationDetails(
              android: AndroidNotificationDetails(
                  deadlines ? channelIdDeadlines : channelIdDaily,
                  deadlines
                      ? L10n.t("notifs.channelDeadlines")
                      : L10n.t("notifs.channelTimetable"),
                  importance: Importance.high)),
          // Android 14 denies SCHEDULE_EXACT_ALARM by default; a throw here
          // used to abandon the whole family AFTER its cancelRange - zero
          // reminders left standing. Fall back to inexact instead, and keep
          // any single failure from killing the siblings.
          androidScheduleMode: _canScheduleExact
              ? AndroidScheduleMode.exactAllowWhileIdle
              : AndroidScheduleMode.inexact);
    } on Object catch (e) {
      if (kDebugMode) print("reminder $id failed: $e");
    }
  }

  /// Idempotent rescheduling: nuke the family's whole id range first, so
  /// cancelled lectures / registered exams can never fire stale alerts.
  static Future<void> _cancelRange(int from, int to) async {
    for (var id = from; id <= to; id++) {
      await _plugin.cancel(id);
    }
  }

  /// "In 30 min" reminders for lectures within the next two days, from the
  /// expanded ICS occurrence set (authoritative dates incl. holiday skips).
  static Future<void> scheduleLectureReminders(WebcalFeed feed) async {
    if (!MeiNotifications.supported) return;
    if (!_ready) await init();
    final epoch = teardownEpoch;
    await _cancelRange(10, 400);
    final now = DateTime.now();
    var id = 10;
    for (final occ in feed.occurrences) {
      if (id > 400) break;
      final remindAt = occ.start.subtract(const Duration(minutes: 30));
      if (remindAt.isAfter(now) &&
          remindAt.isBefore(now.add(const Duration(days: 2)))) {
        if (epoch != teardownEpoch) return; // logout mid-flight
        await _zoned(id++, channelIdDaily, occ.displayTitle,
            "${_hm(occ.start)}–${_hm(occ.end)}  ${occ.displayRoom}", remindAt,
            deadlines: false);
      }
    }
  }

  /// Alert 24 h before an exam-registration window closes while the entry is
  /// still unregistered (missed Anmeldung = failed attempt trap).
  static Future<void> scheduleExamReminders(List<ExamEntry> exams) async {
    if (!MeiNotifications.supported) return;
    if (!_ready) await init();
    await _cancelRange(500, 600);
    final epoch = teardownEpoch;
    final now = DateTime.now();
    var id = 500;
    for (final exam in exams) {
      if (id > 600) break;
      final end = exam.windowEnd;
      if (end == null || exam.registered) continue;
      final remindAt = end.subtract(const Duration(hours: 24));
      final relevant = exam.windowIsOpen(now) ||
          (exam.windowStart != null &&
              now.isBefore(exam.windowStart!) &&
              remindAt.isAfter(exam.windowStart!));
      if (relevant) {
        if (epoch != teardownEpoch) return; // logout mid-flight
        await _zoned(
            id++,
            channelIdDeadlines,
            L10n.t("notifs.examDeadlineTitle"),
            L10n.t("notifs.examDeadlineBody", [exam.title, _hm(end)]),
            remindAt,
            deadlines: true);
      }
    }
  }

  /// 24 h before a SignMeUp registration window closes while the student
  /// still has not signed up (missed Übungsgruppen slot = semester stall).
  static Future<void> scheduleSignMeUpReminders(
      List<SignMeUpProcedure> procedures,
      {Set<int> registered = const {}}) async {
    final epoch = teardownEpoch;
    if (!MeiNotifications.supported) return;
    if (!_ready) await init();
    await _cancelRange(700, 799);
    final now = DateTime.now();
    var id = 700;
    for (final p in procedures) {
      if (id > 799) break;
      if (!p.needsAction(now, registered)) continue;
      final remindAt = p.registrationEnd!.subtract(const Duration(hours: 24));
      if (epoch != teardownEpoch) return; // logout mid-flight
      await _zoned(
          id++,
          channelIdDeadlines,
          L10n.t("notifs.signmeupTitle"),
          L10n.t("notifs.signmeupBody", [p.name, _hm(p.registrationEnd!)]),
          remindAt,
          deadlines: true);
    }
  }

  /// Registration state unknown -> standing deadline nags may be stale
  /// lies ("not signed up" while the student is signed up): drop them.
  static Future<void> cancelSignMeUpReminders() async {
    if (!MeiNotifications.supported) return;
    if (!_ready) await init(requestPermissions: false);
    await _cancelRange(700, 799);
  }

  /// Morning digest: one calm summary per upcoming lecture-day, scheduled
  /// at 07:30 local for the next two days (id keyed by weekday-of-target
  /// so daily reschedules overwrite, never stack).
  static Future<void> scheduleMorningDigest(WebcalFeed feed) async {
    if (!MeiNotifications.supported) return;
    if (!_ready) await init();
    await _cancelRange(900, 999);
    final epoch = teardownEpoch;
    final now = DateTime.now();
    final prefs = await SharedPreferences.getInstance();
    final changesFresh =
        (prefs.getString("DATA_webcalChanges") ?? "").isNotEmpty;
    for (var ahead = 1; ahead <= 2; ahead++) {
      final day = now.add(Duration(days: ahead));
      final occ = feed.occurrences
          .where((o) =>
              o.start.year == day.year &&
              o.start.month == day.month &&
              o.start.day == day.day)
          .toList()
        ..sort((a, b) => a.start.compareTo(b.start));
      final at = DateTime(day.year, day.month, day.day, 7, 30);
      if (!at.isAfter(now)) continue;
      final id = 900 + (day.day * 2 + ahead) % 100;
      if (occ.isEmpty) continue; // no nagging on free days
      final body = L10n.t("notifs.digestBody", [
        _hm(occ.first.start),
        changesFresh ? L10n.t("notifs.digestChanges") : "",
      ]);
      if (epoch != teardownEpoch) return; // logout mid-flight
      await _zoned(id, channelIdDaily,
          L10n.t("notifs.digestTitle", [occ.length]), body, at,
          deadlines: false);
    }
  }

  /// Full reminder + background-job teardown for logout.
  static Future<void> cancelAllScheduled() async {
    teardownEpoch++;
    if (!MeiNotifications.supported) return;
    try {
      // the ICS poll used to outlive logout forever; an in-flight run is
      // additionally fenced by the token re-check inside the callback
      await Workmanager().cancelByUniqueName("mei-webcal-poll");
    } on Object catch (e) {
      if (kDebugMode) print("bg poll cancel failed: $e");
    }
    if (!_ready) await init(requestPermissions: false);
    await _plugin.cancelAll();
  }

  static String _hm(DateTime d) =>
      "${d.hour.toString().padLeft(2, "0")}:${d.minute.toString().padLeft(2, "0")}";
}

/// WorkManager entry: cookieless ICS poll + fingerprint diff -> push.
@pragma('vm:entry-point')
void meiBackgroundCallback() {
  Workmanager().executeTask((taskName, inputData) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      // fresh isolate: mirror main()'s locale bootstrap before t()
      L10n.setSystemLanguage(PlatformDispatcher.instance.locale.languageCode);
      await L10n.reload();
      // E2E test seam: same --dart-define as the foreground fetch
      final testUrl = CampusManager.testWebcalUrl;
      final url = testUrl.isNotEmpty
          ? testUrl
          : prefs.getString("DATA_webcalUrl");
      if (url == null || url.isEmpty) {
        return true; // not provisioned yet
      }
      final response = await http.get(Uri.parse(url), headers: const {
        "User-Agent": "MEI-Cockpit/0.6"
      }).timeout(const Duration(seconds: 45));
      if (response.statusCode != 200 ||
          !response.body.contains("BEGIN:VCALENDAR")) {
        return true; // transient; next window retries
      }
      final feed = WebcalFeed.parse(response.body);
      if (feed == null) {
        return true;
      }
      // the cache carries the student's synthetic SignMeUp VEVENTs and the
      // imported personal ICS; the freshly polled feed never does.
      // Diff/compare STRIPPED snapshots or every accepted tutorial /
      // imported lecture shows up as a phantom "cancelled" lecture.
      final strippedOld = WebcalFeed.parse(CampusManager.stripPersonalIcs(
          CampusManager.stripSignMeUpSynth(
              prefs.getString("DATA_webcalIcsCache") ?? "")));
      // feed-source guard mirrors the foreground fetch: never diff a
      // baseline that belongs to a different calendar URL
      final previousSource = prefs.getString("DATA_webcalFeedSource");
      if (previousSource != null && previousSource != url) {
        await prefs.remove("DATA_webcalFingerprint");
      }
      await prefs.setString("DATA_webcalFeedSource", url);
      final previous = prefs.getString("DATA_webcalFingerprint");
      final current = feed.fingerprint();
      if (previous != null && previous != current) {
        final changes = strippedOld == null
            ? <IcsChange>[]
            : feed.changesSince(strippedOld);
        if (changes.isNotEmpty) {
          await prefs.setString(
              "DATA_webcalChanges",
              IcsChange.encode(mergeIcsChanges(
                  IcsChange.decode(prefs.getString("DATA_webcalChanges") ?? ""),
                  changes)));
          final summary = changes.take(3).map((c) => c.describe()).join("\n");
          await MeiNotifications.notifyChange(
              L10n.t("agenda.timetableChangedN", [changes.length]), summary);
        }
        await prefs.setString("DATA_webcalFingerprint", current);
      } else if (previous == null) {
        // establish the baseline on first poll; without this, background
        // change alerts can never fire until a foreground fetch seeds it
        await prefs.setString("DATA_webcalFingerprint", current);
      }
      if ((prefs.getString("DATA_webcalUrl") ?? "").isEmpty) {
        return true; // logged out mid-fetch: a purged account's timetable
        // must not be re-seeded into prefs behind the logout sweep's back
      }
      // keep the synthetic tutorials AND the imported personal ICS in the
      // cache: the agenda renders today/tomorrow straight from it and a
      // cold start may fail to re-inject (expired plus session)
      final staleCache = prefs.getString("DATA_webcalIcsCache") ?? "";
      final mergedRaw = CampusManager.injectPersonalIcs(
          CampusManager.injectSignMeUpSynth(
              response.body, CampusManager.extractSignMeUpSynth(staleCache)),
          CampusManager.extractPersonalIcs(staleCache));
      await prefs.setString("DATA_webcalIcsCache", mergedRaw);
      await prefs.setString(
          "DATA_webcalFetchedAt", DateTime.now().toIso8601String());
      // the 2 h poll is the only thing that runs while the app stays closed:
      // without re-scheduling, the 2-day reminder/digest horizon silently
      // expired after any weekend gap and reminders just stopped
      final mergedFeed = WebcalFeed.parse(mergedRaw) ?? feed;
      await MeiNotifications.scheduleLectureReminders(mergedFeed);
      await MeiNotifications.scheduleMorningDigest(mergedFeed);
    } catch (e) {
      if (kDebugMode) {
        print("background poll failed: $e");
      }
    }
    return true;
  });
}

Future<void> registerBackgroundPolling() async {
  if (!MeiNotifications.supported) return;
  await Workmanager().initialize(meiBackgroundCallback);
  await Workmanager().registerPeriodicTask(
    "mei-webcal-poll",
    "webcal-diff",
    frequency: const Duration(hours: 2),
    constraints: Constraints(
      networkType: NetworkType.connected,
      requiresBatteryNotLow: false,
    ),
    existingWorkPolicy: ExistingPeriodicWorkPolicy.keep,
  );
}

/// Test-only: fires webcal-diff immediately as a one-off so an E2E run does
/// not have to wait out the periodic job's minimum interval. Registered
/// exactly when the TEST_WEBCAL_URL seam is baked into the build.
Future<void> registerTestPollOnce() async {
  if (CampusManager.testWebcalUrl.isEmpty) return;
  if (!MeiNotifications.supported) return;
  await Workmanager().initialize(meiBackgroundCallback);
  await Workmanager().registerOneOffTask(
    "mei-webcal-poll-test",
    "webcal-diff",
    constraints: Constraints(
      networkType: NetworkType.connected,
      requiresBatteryNotLow: false,
    ),
    existingWorkPolicy: ExistingWorkPolicy.replace,
  );
}

/// Merge a fresh diff into changes already surfaced in the agenda band:
/// two poll cycles that both produce deltas before the student opens the
/// app must not silently drop the first batch (the unconditional replace
/// used to keep only the newest diff). Deduped on full identity, oldest
/// first, capped so the pref cannot grow unboundedly.
List<IcsChange> mergeIcsChanges(List<IcsChange> stored, List<IcsChange> fresh) {
  String idOf(IcsChange c) =>
      "${c.kind.name}|${c.title}|${c.when.toIso8601String()}|${c.room}|${c.oldWhen?.toIso8601String() ?? ""}|${c.oldRoom ?? ""}";
  final freshIds = fresh.map(idOf).toSet();
  final carried = stored.where((c) => !freshIds.contains(idOf(c)));
  final merged = [...carried, ...fresh]
    ..sort((a, b) => a.when.compareTo(b.when));
  return merged.length <= 50 ? merged : merged.sublist(merged.length - 50);
}
