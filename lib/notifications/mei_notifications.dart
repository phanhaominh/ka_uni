import 'dart:convert';
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
import 'notification_payload.dart';
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
  /// silently dropped and the 30 min poll could never register - while every
  /// entry point kept writing schedules as if they worked. Gating honestly
  /// beats pretending; the desktop build stays fully functional offline.
  static bool get supported => Platform.isAndroid;

  /// Bumped on every logout. Schedulers that started BEFORE the teardown
  /// (fire-and-forget fetch callbacks still in flight) check this between
  /// awaits and bail, so a fetch completing after logout can never
  /// resurrect the old account's reminders.
  static int teardownEpoch = 0;

  /// Notification tap -> deep-link routing hook. Wired once by main();
  /// stays null in the WorkManager isolate, where there is no UI to
  /// navigate to and a dispatch must be a no-op.
  static void Function(String? payload)? onTapPayload;

  /// C66: inputs of the last [scheduleExamReminders] rebuild; replayed by
  /// [resyncOnStartup] so the deadline family tracks last-known state.
  static const _examSnapshotKey = "DATA_examReminderSnapshot";

  static bool _canScheduleExact = true;

  static Future<void> init({bool requestPermissions = true}) async {
    if (_ready || !supported) return;
    tzdata.initializeTimeZones();
    await _plugin.initialize(
        const InitializationSettings(
            android: AndroidInitializationSettings("@mipmap/ic_launcher")),
        // taps dispatch through the routing hook; set at registration
        // time already, so main()'s wiring can never be too late
        onDidReceiveNotificationResponse: (response) =>
            onTapPayload?.call(response.payload));
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

  /// Cold start: a notification that LAUNCHED the app does not fire the
  /// tap callback; the launch details carry its payload instead. Read once
  /// at startup, before the main shell can exist -> the router queues it.
  static Future<String?> takeLaunchNotificationPayload() async {
    if (!supported || !_ready) return null;
    final details = await _plugin.getNotificationAppLaunchDetails();
    if (details == null || !details.didNotificationLaunchApp) return null;
    return details.notificationResponse?.payload;
  }

  /// Id 0 => rotating slot in the 1000-1019 band: consecutive changes must
  /// not replace each other in the shade, and the band is cancelled on
  /// logout. Seeded from the wall clock on first use (C63): every WorkManager
  /// poll runs in a FRESH isolate, where a 0-start counter would reuse id
  /// 1000 and silently replace the previous run's still-unopened heads-up.
  static int _changeSeq = -1;

  /// Immediate heads-up (used by the background diff job). [payload] routes
  /// the tap: callers whose content has no CHANGED band to point at (ILIAS
  /// news) pass their own destination instead of the timetable default.
  static Future<void> notifyChange(String title, String body,
      {String? payload}) async {
    if (!MeiNotifications.supported) return;
    if (!_ready) await init(requestPermissions: false);
    if (_changeSeq < 0) {
      // C63: seed per process so a FRESH WorkManager isolate's first
      // push never reuses a still-shaded id. The 30-min bucket seed
      // collided when the poll isolate and the main isolate both pushed
      // inside the same bucket (identical seeds -> the later show()
      // silently replaced the earlier heads-up); epoch-milliseconds
      // differ per process to practical certainty, and the per-push ++
      // rotation is untouched
      _changeSeq = DateTime.now().microsecondsSinceEpoch ~/ 1000;
    }
    await _plugin.show(
        1000 + (_changeSeq++ % 20),
        title,
        body,
        NotificationDetails(
            android: AndroidNotificationDetails(
                channelIdChanges, L10n.t("notifs.channelChanges"),
                importance: Importance.max)),
        // v19 carries the payload on the show/schedule call itself, it comes
        // back verbatim in the tap's NotificationResponse
        payload: payload ?? NotificationPayload.agendaChanges);
  }

  static Future<void> _zoned(
      int id, String channel, String title, String body, DateTime whenLocal,
      {required bool deadlines, required String payload}) async {
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
              : AndroidScheduleMode.inexact,
          // v19 carries the payload on the zonedSchedule call itself; it
          // comes back verbatim in the tap's NotificationResponse
          payload: payload);
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

  /// The imported personal ICS routinely MIRRORS CAS lectures: same visible
  /// title, same start, different VEVENT. Cards dedupe on display, but
  /// per-occurrence alarm scheduling turned one mirrored lecture into 3-4
  /// identical alerts (dumpsys-observed) - collapse to one reminder per
  /// (displayTitle, start), first occurrence wins.
  @visibleForTesting
  static List<IcsOccurrence> dedupOccurrences(
      List<IcsOccurrence> occurrences) {
    final seen = <String>{};
    return occurrences
        .where((o) =>
            seen.add("${o.displayTitle}|${o.start.toIso8601String()}"))
        .toList();
  }

  /// C62: two fetch paths firing within one cancel-await window used to
  /// interleave - run B's _cancelRange landing between run A's cancel and
  /// its schedules left a partial alarm set. Single-flight memo (same
  /// pattern as the exams fetch): a second caller joins the running rebuild
  /// instead of interleaving.
  static Future<void>? _lectureRemindersInFlight;

  static Future<void> scheduleLectureReminders(WebcalFeed feed) {
    final running = _lectureRemindersInFlight;
    if (running != null) return running;
    final future = _scheduleLectureRemindersInner(feed);
    _lectureRemindersInFlight = future;
    return future.whenComplete(() => _lectureRemindersInFlight = null);
  }

  static Future<void> _scheduleLectureRemindersInner(WebcalFeed feed) async {
    if (!MeiNotifications.supported) return;
    // C61: every call site is fire-and-forget unawaited(); Contain EVERY
    // failure (init throw, _cancelRange platform error) here so a scheduler
    // can never surface as an unhandled zone error at the call sites.
    try {
      if (!_ready) await init();
      final epoch = teardownEpoch;
      await _cancelRange(10, 400);
      final now = DateTime.now();
      var id = 10;
      for (final occ in dedupOccurrences(feed.occurrences)) {
        if (id > 400) break;
        final remindAt = occ.start.subtract(const Duration(minutes: 30));
        if (remindAt.isAfter(now) &&
            remindAt.isBefore(now.add(const Duration(days: 2)))) {
          if (epoch != teardownEpoch) return; // logout mid-flight
          await _zoned(id++, channelIdDaily, occ.displayTitle,
              reminderBody(occ), remindAt,
              deadlines: false,
              payload: NotificationPayload.agendaToday);
        }
      }
    } on Object catch (e) {
      if (kDebugMode) print("lecture reminders failed: $e");
    }
  }

  /// Reminder body: real start–end span, or - when the occurrence's end is
  /// only the parser's +90 default (exam sittings export WITHOUT DTEND,
  /// see IcsOccurrence.endGuessed) - a start-only "ab HH:MM": an invented
  /// end time must never be announced as a fact.
  @visibleForTesting
  static String reminderBody(IcsOccurrence occ) => occ.endGuessed
      ? "${L10n.t("notifs.reminderFrom", [_hm(occ.start)])}  ${occ.displayRoom}"
      : "${_hm(occ.start)}–${_hm(occ.end)}  ${occ.displayRoom}";

  /// Alert 24 h before an exam-registration window closes while the entry is
  /// still unregistered (missed Anmeldung = failed attempt trap). C66: every
  /// rebuild snapshots its inputs; [resyncOnStartup] replays them, so the
  /// family tracks last-known state (survives a start that never reaches the
  /// network) instead of relying on the next possibleexams fetch alone.
  static Future<void> scheduleExamReminders(List<ExamEntry> exams,
      {bool fromReplay = false}) async {
    if (!MeiNotifications.supported) return;
    // C61: contained fire-and-forget scheduler (see the lecture family).
    try {
      if (!_ready) await init();
      // The unawaited fetch-chain caller may land AFTER a logout sweep
      // (the sqassign fetch above it takes seconds): without this gate
      // the scheduler re-armed 500-band alarms and re-persisted the
      // snapshot past the purge, and the new resyncOnStartup replayed
      // the OLD account's deadlines on a later cold start. The snapshot
      // replay itself (fromReplay) is exempt: resyncOnStartup carries
      // its own logged-out guard.
      if (!fromReplay &&
          (await SharedPreferencesAsync().getString(WebcalKeys.url) ?? "")
              .isEmpty) {
        return;
      }
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
              deadlines: true,
              payload: NotificationPayload.exams);
        }
      }
      // snapshot only ever describes a LIVE account: fence the write
      // exactly like the alarms above (C78's live-url probe pattern)
      if (epoch != teardownEpoch ||
          (await SharedPreferencesAsync().getString(WebcalKeys.url) ?? "")
              .isEmpty) {
        return;
      }
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
          _examSnapshotKey,
          jsonEncode([
            for (final e in exams)
              {
                "t": e.title,
                "r": e.registered,
                "s": e.windowStart?.toIso8601String(),
                "e": e.windowEnd?.toIso8601String(),
                "w": e.windowStatus.name,
              }
          ]));
    } on Object catch (e) {
      if (kDebugMode) print("exam reminders failed: $e");
    }
  }

  /// 24 h before a SignMeUp registration window closes while the student
  /// still has not signed up (missed Übungsgruppen slot = semester stall).
  static Future<void> scheduleSignMeUpReminders(
      List<SignMeUpProcedure> procedures,
      {Set<int> registered = const {}}) async {
    final epoch = teardownEpoch;
    if (!MeiNotifications.supported) return;
    // C61: unawaited call site inside a finally block - contain the throw.
    try {
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
            deadlines: true,
            // the open procedures the reminder names render ONLY in the
            // agenda's SignMeUp card — /exams shows zero SignMeUp content,
            // so this tap must land on the agenda, not the exams page
            payload: NotificationPayload.agenda);
      }
    } on Object catch (e) {
      if (kDebugMode) print("signmeup reminders failed: $e");
    }
  }

  /// Registration state unknown -> standing deadline nags may be stale
  /// lies ("not signed up" while the student is signed up): drop them.
  static Future<void> cancelSignMeUpReminders() async {
    if (!MeiNotifications.supported) return;
    try {
      if (!_ready) await init(requestPermissions: false);
      await _cancelRange(700, 799);
    } on Object catch (e) {
      if (kDebugMode) print("signmeup cancel failed: $e"); // C61
    }
  }

  /// Morning digest: one calm summary per upcoming lecture-day, scheduled
  /// at 07:30 local for the next two days (id keyed by weekday-of-target
  /// so daily reschedules overwrite, never stack).
  static Future<void> scheduleMorningDigest(WebcalFeed feed) async {
    if (!MeiNotifications.supported) return;
    // C61: contained fire-and-forget scheduler (see the lecture family).
    try {
      if (!_ready) await init();
      await _cancelRange(900, 999);
      final epoch = teardownEpoch;
      final now = DateTime.now();
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
        final (title, body) = digestTexts(occ);
        if (epoch != teardownEpoch) return; // logout mid-flight
        await _zoned(id, channelIdDaily, title, body, at,
            deadlines: false,
            payload: NotificationPayload.agenda);
      }
    } on Object catch (e) {
      if (kDebugMode) print("morning digest failed: $e");
    }
  }

  /// Title/body pair for one digest day (pure, testable). A day whose
  /// calendar consists ONLY of registered exam sittings is not "N
  /// Veranstaltungen" - say Klausur, give the time, be done. C65: no
  /// "changed" hint - it was baked in up to 24 h ahead at schedule time
  /// and then fired as a stale claim long after the band had been
  /// dismissed; the CHANGED band + badge carry that signal at open time.
  @visibleForTesting
  static (String, String) digestTexts(List<IcsOccurrence> occ) {
    final examOnly = occ.isNotEmpty &&
        occ.every((o) => o.title.startsWith("Klausur: "));
    final first = _hm(occ.first.start);
    return examOnly
        ? (
            L10n.t("notifs.digestTitleExam"),
            L10n.t("notifs.digestBodyExam", [first, ""]),
          )
        : (
            L10n.t("notifs.digestTitle", [occ.length]),
            L10n.t("notifs.digestBody", [first, ""]),
          );
  }

  /// Full reminder + background-job teardown for logout.
  static Future<void> cancelAllScheduled() async {
    teardownEpoch++;
    if (!MeiNotifications.supported) return;
    // C61: awaited inside the logout sweep; a platform throw must not
    // abort the teardown chain.
    try {
      // the ICS poll used to outlive logout forever; an in-flight run is
      // additionally fenced by the token re-check inside the callback
      await Workmanager().cancelByUniqueName("mei-webcal-poll");
    } on Object catch (e) {
      if (kDebugMode) print("bg poll cancel failed: $e");
    }
    try {
      if (!_ready) await init(requestPermissions: false);
      await _plugin.cancelAll();
    } on Object catch (e) {
      if (kDebugMode) print("cancelAll failed: $e");
    }
  }

  /// Cold start (R100): pending zoned schedules SURVIVE app updates and
  /// restores - an older build's alarms kept firing into Feb 2027. Cancel
  /// every pending notification first, then rebuild the timetable families
  /// from the cached ICS and the exam family from its last schedule
  /// snapshot (C66); the SignMeUp family refills via its next fetch. Safe
  /// against double-scheduling: every family cancels its own id range
  /// before re-arming, so the fetch-driven reschedules that follow can
  /// never stack onto these alarms.
  static Future<void> resyncOnStartup() async {
    if (!MeiNotifications.supported) return;
    if (!_ready) await init(requestPermissions: false);
    await _plugin.cancelAll();
    // cold start into a logged-out state (post-logout, or a restore onto
    // a fresh install): rebuilding from leaked/raced leftovers would
    // resurrect the previous account's alarms; cancelling ghosts is all
    // a logged-out device should do
    if ((await SharedPreferencesAsync().getString(WebcalKeys.url) ?? "")
        .isEmpty) {
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    final feed =
        WebcalFeed.parse(prefs.getString("DATA_webcalIcsCache") ?? "");
    if (feed != null) {
      await scheduleLectureReminders(feed);
      await scheduleMorningDigest(feed);
    }
    await _replayExamReminders(prefs);
  }

  static String _hm(DateTime d) =>
      "${d.hour.toString().padLeft(2, "0")}:${d.minute.toString().padLeft(2, "0")}";

  /// C66: rebuild the exam deadline family from the last snapshot. Stale
  /// windows drop out via the very predicates [scheduleExamReminders]
  /// applies, so a replay can never re-arm a closed window; logout purges
  /// DATA_* and with it the snapshot.
  static Future<void> _replayExamReminders(SharedPreferences prefs) async {
    final raw = prefs.getString(_examSnapshotKey);
    if (raw == null || raw.isEmpty) return;
    final List<dynamic> entries;
    try {
      entries = jsonDecode(raw) as List<dynamic>;
    } on Object catch (e) {
      if (kDebugMode) print("exam snapshot unreadable: $e");
      return;
    }
    await scheduleExamReminders([
      for (final e in entries)
        if (e is Map<String, dynamic>)
          ExamEntry(
              // only the scheduling fields rehydrate; terms belong to the
              // next real fetch, the deadline alarm never reads them
              examNumber: "snapshot",
              title: e["t"] as String? ?? "",
              examiners: "",
              examType: "",
              registered: e["r"] as bool? ?? false,
              windowStatus: ExamWindowStatus.values
                  .byName(e["w"] as String? ?? "unknown"),
              windowStart: DateTime.tryParse(e["s"] as String? ?? ""),
              windowEnd: DateTime.tryParse(e["e"] as String? ?? ""))
    ]);
  }
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
        // C68: main() registers the poll on EVERY start incl. logged-out
        // ones, where it can never do anything - unregister on the first
        // fruitless fire; the next start (logged in again) re-registers.
        await Workmanager().cancelByUniqueName("mei-webcal-poll");
        return true; // not provisioned yet
      }
      final response = await http.get(Uri.parse(url), headers: const {
        "User-Agent": "MEI-Cockpit/0.6"
      }).timeout(const Duration(seconds: 45));
      if (response.statusCode != 200 ||
          !response.body.contains("BEGIN:VCALENDAR")) {
        return true; // transient; next window retries
      }
      // external bytes first, splices later: strip smuggled sentinel
      // lines so they can never move a strip/extract cut on the body
      // this isolate persists (see CampusManager.sanitizeSentinels)
      final body = CampusManager.sanitizeSentinels(response.body);
      final feed = WebcalFeed.parse(body);
      if (feed == null) {
        return true;
      }

      // C81: the legacy SharedPreferences snapshot is per isolate and the
      // logout sweep only clears the platform store - the url read above
      // can still answer with the OLD account after DATA_* died, and the
      // fingerprint/feedSource/changes writes used to re-seed the purged
      // account's course titles past logout. Re-read the url from the
      // platform (async API bypasses the snapshot) before ANY write.
      final urlLive =
          await SharedPreferencesAsync().getString("DATA_webcalUrl");
      if ((urlLive ?? "").isEmpty || (testUrl.isEmpty && urlLive != url)) {
        return true; // logged out or re-provisioned mid-poll
      }
      // Diff/compare STRIPPED snapshots or every accepted tutorial /
      // imported lecture shows up as a phantom "cancelled" lecture.
      // C10: full atomicity across isolates is impossible with
      // SharedPreferences, so the (cache, fingerprint) pair is fenced
      // instead: both baselines are read LIVE (the legacy snapshot this
      // isolate loaded can predate a foreground write), the fingerprint is
      // re-checked before notifying, and the body is written BEFORE the
      // fingerprint — a crash between the two re-surfaces a change once
      // instead of losing it forever.
      final prefsLive = SharedPreferencesAsync();
      final cacheLive = await prefsLive.getString("DATA_webcalIcsCache");
      final strippedOld = WebcalFeed.parse(CampusManager.stripPersonalIcs(
          CampusManager.stripSignMeUpSynth(CampusManager.stripExamSynth(
              cacheLive ?? ""))));
      // feed-source guard mirrors the foreground fetch: never diff a
      // baseline that belongs to a different calendar URL
      final previousSource = prefs.getString("DATA_webcalFeedSource");
      if (previousSource != null && previousSource != url) {
        await prefs.remove("DATA_webcalFingerprint");
      }
      await prefs.setString("DATA_webcalFeedSource", url);
      final previous = await prefsLive.getString("DATA_webcalFingerprint");
      final current = feed.fingerprint();
      var advanceFingerprint = previous == null || previous != current;
      if (previous != null && previous != current) {
        final changes = strippedOld == null
            ? <IcsChange>[]
            : feed.changesSince(strippedOld);
        // epoch re-check: a foreground fetch that advanced the baseline
        // mid-diff owns the transition — its alert (if any) already
        // described it; notifying ours would double-count or phantom
        final stillOurs =
            await prefsLive.getString("DATA_webcalFingerprint") == previous;
        if (changes.isNotEmpty && stillOurs) {
          await prefs.setString(
              "DATA_webcalChanges",
              IcsChange.encode(mergeIcsChanges(
                  IcsChange.decode(prefs.getString("DATA_webcalChanges") ?? ""),
                  changes)));
          final summary = changes.take(3).map((c) => c.describe()).join("\n");
          await MeiNotifications.notifyChange(
              L10n.t("agenda.timetableChangedN", [changes.length]), summary);
        }
      }
      final urlLive2 =
          await SharedPreferencesAsync().getString("DATA_webcalUrl");
      if ((urlLive2 ?? "").isEmpty) {
        return true; // logged out mid-fetch: a purged account's timetable
        // must not be re-seeded into prefs behind the logout sweep's back
      }
      // keep the synthetic tutorials, exam sittings AND the imported
      // personal ICS in the cache: the agenda renders today/tomorrow
      // straight from it and a cold start may fail to re-inject (expired
      // plus session)
      final staleCache =
          (await prefsLive.getString("DATA_webcalIcsCache")) ?? "";
      final mergedRaw = CampusManager.injectPersonalIcs(
          CampusManager.injectSignMeUpSynth(
              CampusManager.injectExamSynth(
                  body, CampusManager.extractExamSynth(staleCache)),
              CampusManager.extractSignMeUpSynth(staleCache)),
          CampusManager.extractPersonalIcs(staleCache));
      await prefs.setString("DATA_webcalIcsCache", mergedRaw);
      await prefs.setString(
          "DATA_webcalFetchedAt", DateTime.now().toIso8601String());
      // body first, fingerprint second (C10): the pair must never present
      // a new baseline over an old body; worst case a change resurfaces
      if (advanceFingerprint) {
        await prefs.setString("DATA_webcalFingerprint", current);
      }
      // the 30 min poll is the only thing that runs while the app stays closed:
      // without re-scheduling, the 2-day reminder/digest horizon silently
      // expired after any weekend gap and reminders just stopped.
      // R101's initialDelay-zero poll races the MAIN isolate's
      // resyncOnStartup on every cold start (both rebuild the same id
      // bands from per-isolate memos; interleaved cancel/schedule tails
      // survive as stale alarms). The band is the main isolate's
      // responsibility at cold start — give it a head start instead of
      // interleaving.
      await Future.delayed(const Duration(seconds: 12));
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
    // 30 min floor: KIT sometimes publishes room swaps under 2 h before a
    // lecture; Android treats this as a hint and may batch, battery cost is
    // one conditional GET per window
    frequency: const Duration(minutes: 30),
    constraints: Constraints(
      networkType: NetworkType.connected,
      requiresBatteryNotLow: false,
    ),
    // R101: re-registered on EVERY app start with update - Android 9 parks
    // delayed periodic work ("Delaying execution before schedule") and
    // force-runs shift the window out; keep would trust that stale state
    // until uninstall, update refreshes the schedule each cold start and
    // re-arms an immediate first run.
    initialDelay: Duration.zero,
    existingWorkPolicy: ExistingPeriodicWorkPolicy.update,
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
