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

import '../agenda/logic/day_decision.dart';
import '../exams/models/exam_list.dart';
import '../l10n/l10n.dart';
import '../signmeup/signmeup_manager.dart';
import '../state_management/campus/campus_manager.dart';
import '../state_management/kit_login_manager.dart';
import 'notification_payload.dart';
import '../timetable/models/webcal.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../credentials/models/kit_credentials.dart';
import '../ilias/ilias_scraper.dart';
import '../state_management/ilias/ilias_manager.dart';
import '../state_management/ilias/ilias_watcher.dart';

const String channelIdDaily = "mei_daily";
const String channelIdDeadlines = "mei_deadlines";
const String channelIdChanges = "mei_changes";
const String channelIdLibrary = "mei_library";

/// Exact map of notification id bands - every family cancels its own range
/// before re-arming, so a new family MUST take a fresh gap and join this
/// list: 10-400 lecture T−30 · 410-499 T−15 re-arm for CHANGED lectures
/// (R12) · 500-600 exam registration deadlines · 700-799 SignMeUp
/// deadlines · 800-819 library seat check-in pings (LibraryNotifications)
/// · 900-999 morning digest · 1000-1019 CHANGED heads-up rotation.
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
  // R23: once-per-install marker for the exact-alarm settings prompt
  // (plain PREF_, survives logout: it records a system-UI fact, not
  // account data)
  static const _exactAlarmAskedKey = "PREF_exactAlarmAsked";

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
    await androidPlugin?.createNotificationChannel(AndroidNotificationChannel(
        channelIdLibrary, L10n.t("notifs.channelLibrary"),
        description: L10n.t("notifs.channelLibraryDesc"),
        importance: Importance.max));
    // permission REQUESTS need an attached activity: in the WorkManager
    // isolate mainActivity is null and the plugin NPEs (crash-loop every
    // poll). Only the UI process may prompt; background inits only probe.
    if (requestPermissions) {
      // R23: requestExactAlarmsPermission() is NOT a polite dialog - on
      // S+ the plugin UNCONDITIONALLY startActivityForResult(ACTION_
      // REQUEST_SCHEDULE_EXACT_ALARM) whenever the grant is missing: a
      // user who denied exact alarms once (or whose Android 15 ROM ships
      // the toggle off) was dumped onto the system "Alarm access"
      // settings page OVER THE SPLASH on literally every app open.
      // Ask only while the grant is actually missing, and at most once
      // per install; the inexact fallback already covers the denial.
      // Each request is try-wrapped: an OEM ROM missing the settings
      // intent used to abort init() before _ready=true, killing ALL
      // notifications for the session.
      try {
        final missing =
            await androidPlugin?.canScheduleExactNotifications() == false;
        final prefs = await SharedPreferences.getInstance();
        if (missing && !prefs.containsKey(_exactAlarmAskedKey)) {
          await prefs.setBool(_exactAlarmAskedKey, true);
          await androidPlugin?.requestExactAlarmsPermission();
        }
      } on Object catch (e) {
        if (kDebugMode) print("exact-alarm prompt failed: $e");
      }
      try {
        await androidPlugin?.requestNotificationsPermission();
      } on Object catch (e) {
        if (kDebugMode) print("notification permission prompt failed: $e");
      }
    }
    try {
      _canScheduleExact =
          await androidPlugin?.canScheduleExactNotifications() ?? true;
    } on Object catch (e) {
      if (kDebugMode) print("exact-alarm probe failed: $e");
      _canScheduleExact = false; // -> inexact path, alarms still delivered
    }
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

  /// Notification id in the 1000-1019 CHANGED heads-up band, derived PER
  /// PUSH from the wall clock (see [changeSlot]); the band is cancelled
  /// wholesale on logout.
  static int _changeSlotRotation = 0;

  /// Pure slot math for [notifyChange]'s id (C63 follow-up). The old fix
  /// seeded a per-process counter from epoch-milliseconds and rotated it
  /// per push - but seed inequality is NOT id inequality: two ++-rotating
  /// sequences modulo 20 intersect whenever their seeds differ by a small
  /// residue, i.e. a FRESH WorkManager poll still silently replaced the
  /// main process's still-unopened heads-up. Deriving the slot from the
  /// wall-clock MINUTE bucket makes two isolates hit the same id only if
  /// they push nearly simultaneously (no id scheme without cross-process
  /// state can separate same-minute pushes from two isolates; a reused
  /// id then merely replaces the older unopened heads-up ~every 20 min).
  /// The per-process [rotation] spread keeps a BURST distinct: the ILIAS
  /// watcher pushes up to three announcements back-to-back and a pure
  /// bucket would collapse them into one visible notification.
  @visibleForTesting
  static int changeSlot(int millisecondsSinceEpoch, int rotation) =>
      (millisecondsSinceEpoch ~/ 60000 + rotation) % 20;

  /// One-shot exact reminder on the library channel (seat check-in pings,
  /// scheduled by LibraryNotifications). Reuses _zoned's exact/inexact and
  /// payload discipline; channel creation happens in init().
  static Future<void> scheduleLibraryPing(
      int id, String title, String body, DateTime whenLocal,
      {required String payload}) async {
    if (!supported) return;
    if (!_ready) await init(requestPermissions: false);
    await _zoned(id, channelIdLibrary, title, body, whenLocal,
        deadlines: true, payload: payload);
  }

  static Future<void> cancelLibraryPing(int id) async {
    if (!supported || !_ready) return;
    await _plugin.cancel(id);
  }

  /// Immediate (re-)post of a library check-in ping. R23: the cold-start
  /// ghost sweep (resyncOnStartup's cancelAll) also wipes the SHADE of a
  /// ping that already fired but whose 15-minute check-in window is still
  /// open - replay re-arms future pings only, so without this repost the
  /// reminder is destroyed mid-window and the booking silently expires.
  static Future<void> showLibraryPingNow(int id, String title, String body,
      {required String payload}) async {
    if (!supported) return;
    if (!_ready) await init(requestPermissions: false);
    await _plugin.show(
        id,
        title,
        body,
        NotificationDetails(
            android: AndroidNotificationDetails(
                channelIdLibrary, L10n.t("notifs.channelLibrary"),
                importance: Importance.max)),
        payload: payload);
  }

  /// Immediate heads-up (used by the background diff job). [payload] routes
  /// the tap: callers whose content has no CHANGED band to point at (ILIAS
  /// news) pass their own destination instead of the timetable default.
  static Future<void> notifyChange(String title, String body,
      {String? payload}) async {
    if (!MeiNotifications.supported) return;
    if (!_ready) await init(requestPermissions: false);
    await _plugin.show(
        1000 +
            changeSlot(
                DateTime.now().millisecondsSinceEpoch, _changeSlotRotation++),
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
                  // the CHANNEL argument wins (audit R21: it used to be
                  // ignored — library pings landed on "Deadlines" while
                  // their own channel sat empty; muting one family must
                  // never silence another)
                  channel,
                  channel == channelIdLibrary
                      ? L10n.t("notifs.channelLibrary")
                      : channel == channelIdChanges
                          ? L10n.t("notifs.channelChanges")
                          : deadlines
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
  static List<IcsOccurrence> dedupOccurrences(List<IcsOccurrence> occurrences) {
    final seen = <String>{};
    return occurrences
        .where(
            (o) => seen.add("${o.displayTitle}|${o.start.toIso8601String()}"))
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
      if (!_ready) await init(requestPermissions: false); // R22: schedulers
      // may run in the WorkManager isolate (poll tail) - prompting there
      // NPEs the plugin and kills the whole re-arm; only main() may ask.
      final epoch = teardownEpoch;
      await _cancelRange(10, 400);
      await _cancelRange(410, 499);
      final now = DateTime.now();
      var id = 10;
      var changeId = 410;
      // T−15 re-arm (R12): a lecture the still-un-dismissed CHANGED band
      // marks moved/removed/room-swapped ALSO gets an alarm 15 min before
      // its start - the T−30 one may have been armed against the PRE-change
      // timetable, so the second heads-up confirms the new state close to
      // the door. Calm lectures never get a second nag: the change index
      // gates the whole 410 band.
      final prefs = await SharedPreferences.getInstance();
      final changes =
          IcsChange.decode(prefs.getString(WebcalKeys.changes) ?? "");
      final blockKeysByDay = <DateTime, Map<int, IcsChange>>{};
      final movedByDay = <DateTime, Set<int>>{};
      bool touchedByChange(IcsOccurrence o) {
        final day = DateTime(o.start.year, o.start.month, o.start.day);
        final block = o.start.hour * 60 + o.start.minute;
        // W3 index shape: room-changed blocks carry their IcsChange,
        // moved/removed ones only their block key
        return blockKeysByDay
                .putIfAbsent(day, () => changes.blockKeys(day))
                .containsKey(block) ||
            movedByDay
                .putIfAbsent(day, () => changes.removedOrMovedBlocks(day))
                .contains(block);
      }

      for (final occ in dedupOccurrences(feed.occurrences)) {
        if (id > 400 && (changes.isEmpty || changeId > 499)) break;
        final remindAt = occ.start.subtract(const Duration(minutes: 30));
        if (id <= 400 &&
            remindAt.isAfter(now) &&
            remindAt.isBefore(now.add(const Duration(days: 2)))) {
          if (epoch != teardownEpoch) return; // logout mid-flight
          await _zoned(id++, channelIdDaily, occ.displayTitle,
              reminderBody(occ), remindAt,
              deadlines: false, payload: NotificationPayload.agendaToday);
        }
        if (changes.isEmpty || changeId > 499) continue;
        final t15 = occ.start.subtract(const Duration(minutes: 15));
        if (t15.isAfter(now) &&
            t15.isBefore(now.add(const Duration(days: 2))) &&
            touchedByChange(occ)) {
          if (epoch != teardownEpoch) return;
          await _zoned(changeId++, channelIdDaily, occ.displayTitle,
              reminderBody(occ), t15,
              deadlines: false, payload: NotificationPayload.agendaToday);
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
      if (!_ready) await init(requestPermissions: false); // R22: schedulers
      // may run in the WorkManager isolate (poll tail) - prompting there
      // NPEs the plugin and kills the whole re-arm; only main() may ask.
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
      // R22: capture the epoch BEFORE the ~100-cancel window below: a
      // logout landing inside _cancelRange would otherwise leave this
      // chain holding the POST-bump epoch, every later guard would pass,
      // and the loop would re-arm the logged-out account's 500-band
      // alarms after cancelAll ran (the lecture/SignMeUp families
      // captured before their cancels all along - these two were outliers)
      final epoch = teardownEpoch;
      await _cancelRange(500, 600);
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
      if (!_ready) await init(requestPermissions: false); // R22: schedulers
      // may run in the WorkManager isolate (poll tail) - prompting there
      // NPEs the plugin and kills the whole re-arm; only main() may ask.
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
      if (!_ready) await init(requestPermissions: false); // R22: schedulers
      // may run in the WorkManager isolate (poll tail) - prompting there
      // NPEs the plugin and kills the whole re-arm; only main() may ask.
      // R22: epoch before the cancel window (see exam family above) -
      // otherwise a logout inside _cancelRange lets the digest re-arm
      // with the old account's lecture titles post-teardown
      final epoch = teardownEpoch;
      await _cancelRange(900, 999);
      final now = DateTime.now();
      // R24 wave A: pending deltas let a free day NAME its cancellations;
      // live async read (the poll isolate writes these from the diff)
      final pendingChanges = IcsChange.decode(await SharedPreferencesAsync()
              .getString(WebcalKeys.changes) ??
          "");
      for (var ahead = 1; ahead <= 2; ahead++) {
        final day = DateTime(now.year, now.month, now.day + ahead);
        final decision = DayDecision.compute(
            feed: feed, day: day, feedFresh: true, changes: pendingChanges);
        final at = DateTime(day.year, day.month, day.day, 7, 30);
        if (!at.isAfter(now)) continue;
        final id = 900 + (day.day * 2 + ahead) % 100;
        // R24: free/cancelled days now ANSWER instead of being skipped —
        // the digest became the morning decision line ("no lectures" is
        // the most relevant possible morning fact, and re-scheduling on
        // every poll keeps it at most 30 min stale)
        if (decision.kind == DayDecisionKind.noData ||
            decision.kind == DayDecisionKind.staleFeed) {
          continue; // never assert emptiness off data we do not trust
        }
        final (title, body) =
            digestTexts(decision.lectures, decision.cancelledTitles);
        if (epoch != teardownEpoch) return; // logout mid-flight
        await _zoned(id, channelIdDaily, title, body, at,
            deadlines: false,
            // the digest names the day's first lectures - open ON them
            payload: NotificationPayload.agendaToday);
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
  /// R24 wave A: empty days are no longer skipped upstream - the wording
  /// lives in DayDecision.digestTexts (shared with the home banner).
  @visibleForTesting
  static (String, String) digestTexts(List<IcsOccurrence> occ,
          [List<String> cancelledTitles = const []]) =>
      DayDecision.digestTexts(occ, cancelledTitles);

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
    final feed = WebcalFeed.parse(prefs.getString("DATA_webcalIcsCache") ?? "");
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
        // R23: per-entry containment - byName THROWS on a stored status
        // name that a later app version renamed (the ?? "unknown" only
        // covers a MISSING key), and the `as String?` casts throw on
        // foreign types; one poisoned element used to escape through
        // resyncOnStartup into main's bootstrap try, taking
        // LibraryNotifications.replayPending() down with it: exam
        // deadline alarms AND library check-in pings lost every reboot
        // until the next successful possibleexams fetch
        () {
          try {
            if (e is! Map<String, dynamic>) return null;
            final w = e["w"] as String?;
            return ExamEntry(
                // only the scheduling fields rehydrate; terms belong to
                // the next real fetch, the deadline alarm never reads them
                examNumber: "snapshot",
                title: e["t"] as String? ?? "",
                examiners: "",
                examType: "",
                registered: e["r"] as bool? ?? false,
                windowStatus: ExamWindowStatus.values.firstWhere(
                    (s) => s.name == w,
                    orElse: () => ExamWindowStatus.unknown),
                windowStart:
                    DateTime.tryParse(e["s"] as String? ?? ""),
                windowEnd: DateTime.tryParse(e["e"] as String? ?? ""));
          } on Object {
            return null; // one unreadable snapshot row is a dropped row
          }
        }(),
    ].whereType<ExamEntry>().toList());
  }
}

/// C28: one background ILIAS announcements diff, piggy-backed on the same
/// 30-min webcal cycle so new material is pushed on days the agenda is
/// never opened (before this, the diff only ran on agenda visits).
/// A FRESH IliasManager per run: its cookie jar is per-instance in-memory,
/// so each cycle pays one full SAML chain (~4 requests) — the same cadence
/// CampusKIT's own web session keeps warm anyway. Every dead end funnels
/// to a contained early return, and every watcher write/push passes the
/// live-URL probe: the main isolate's teardownEpoch bump is invisible in
/// this isolate, platform prefs are the only cross-isolate fence.
Future<void> _iliasBackgroundDiff() async {
  if ((await SharedPreferencesAsync().getString(WebcalKeys.url) ?? "")
      .isEmpty) {
    return; // logged out (or never provisioned)
  }
  // options MUST mirror CredentialsProvider's (iOS keychain account!)
  const storage =
      FlutterSecureStorage(iOptions: IOSOptions(accountName: "kit-student"));
  final user = await storage.read(key: "username");
  final pass = await storage.read(key: "password");
  if ((user ?? "").isEmpty || (pass ?? "").isEmpty) return;
  final mgr = IliasManager();
  mgr.credentials =
      KITCredentials(username: user!, password: pass!, valid: true);
  await mgr.authorize(refreshSession: true);
  if (!mgr.sessionContainsCookieNamed("PHPSESSID")) {
    return; // bot wall or dead session: the board would come back EMPTY,
    // and seeding that as truth would swallow every future announcement
  }
  final fresh = await mgr.fetchAnnouncements();
  if (fresh.isEmpty) return; // never seed from a board we did not prove
  await IliasWatcher.diffAndNotify(fresh,
      stillOurs: () async =>
          (await SharedPreferencesAsync().getString(WebcalKeys.url) ?? "")
              .isNotEmpty);
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
      // R22: bring _ready up HERE, permission-free. Otherwise the tail's
      // scheduleLectureReminders/scheduleMorningDigest reach the plugin's
      // request*Permission methods with mainActivity == null (this
      // isolate has no activity, ever) - a PlatformException that aborts
      // init() before _ready and silently kills the whole re-arm, exactly
      // the "quiet days expire the 2-day horizon" failure the tail exists
      // to prevent. Prompting stays main()'s job.
      await MeiNotifications.init(requestPermissions: false);
      // E2E test seam: same --dart-define as the foreground fetch
      final testUrl = CampusManager.testWebcalUrl;
      final url =
          testUrl.isNotEmpty ? testUrl : prefs.getString("DATA_webcalUrl");
      if (url == null || url.isEmpty) {
        // C68: main() registers the poll on EVERY start incl. logged-out
        // ones, where it can never do anything - unregister on the first
        // fruitless fire; the next start (logged in again) re-registers.
        await Workmanager().cancelByUniqueName("mei-webcal-poll");
        return true; // not provisioned yet
      }
      // R22: the webcal endpoint sends NO charset, so a bare http.get
      // decodes UTF-8 bytes as latin1 - "Übung" turned to mojibake that
      // this isolate then persisted into DATA_webcalIcsCache (rendered
      // verbatim by the agenda on cold start) and fingerprinted against
      // the foreground's UTF-8 baseline (phantom "timetable changed"
      // heads-up on every foreground/background alternation). The
      // foreground GET runs through netGet, which applies this exact fix.
      final response = KITLoginManager.fixUtf8Body(await http.get(
              Uri.parse(url),
              headers: const {"User-Agent": "MEI-Cockpit/0.6"})
          .timeout(const Duration(seconds: 45)));
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
          CampusManager.stripSignMeUpSynth(
              CampusManager.stripExamSynth(cacheLive ?? ""))));
      // feed-source guard mirrors the foreground fetch: never diff a
      // baseline that belongs to a different calendar URL
      final previousSource = prefs.getString("DATA_webcalFeedSource");
      if (previousSource != null && previousSource != url) {
        await prefs.remove("DATA_webcalFingerprint");
      }
      final previous = await prefsLive.getString("DATA_webcalFingerprint");
      final current = feed.fingerprint();
      var advanceFingerprint = previous == null || previous != current;
      List<IcsChange> changes = const [];
      var surfaceChanges = false;
      if (previous != null && previous != current) {
        changes = strippedOld == null
            ? <IcsChange>[]
            : feed.changesSince(strippedOld);
        // epoch re-check: a foreground fetch that advanced the baseline
        // mid-diff owns the transition — its alert (if any) already
        // described it; notifying ours would double-count or phantom
        final stillOurs =
            await prefsLive.getString("DATA_webcalFingerprint") == previous;
        surfaceChanges = changes.isNotEmpty && stillOurs;
      }
      // C81's fence family extended to the transition-bearing writes:
      // between the urlLive probe up top and the writes below used to sit
      // ~6 platform awaits (cache, source, two fingerprint reads) — a
      // logout in that window re-seeded the swept feedSource/changes keys
      // with the OLD account's course titles and fired a heads-up after
      // the teardown, on a shared device. Bail here WITHOUT advancing the
      // fingerprint: the next (re-provisioned) run re-diffs against the
      // old baseline and surfaces the transition exactly once. The
      // feedSource write moved down behind the same fence.
      if ((await SharedPreferencesAsync().getString("DATA_webcalUrl") ?? "")
          .isEmpty) {
        return true; // logged out mid-diff
      }
      await prefs.setString("DATA_webcalFeedSource", url);
      if (surfaceChanges) {
        await prefs.setString(
            "DATA_webcalChanges",
            IcsChange.encode(mergeIcsChanges(
                // LIVE read: the legacy snapshot this isolate loaded can
                // predate the agenda dismissing the band — merging against
                // it would re-seed already-dismissed changes
                IcsChange.decode(
                    (await prefsLive.getString("DATA_webcalChanges")) ?? ""),
                changes)));
        final summary = changes.take(3).map((c) => c.describe()).join("\n");
        // A heads-up failure must NOT strand the ordering (the other
        // option, advancing the fingerprint before the push, trades the
        // crash window C10 keeps for the body/fingerprint pair): it used
        // to escape to the outer catch AFTER the change log persisted and
        // BEFORE the baseline advanced, so the next poll re-diffed the
        // same transition and pushed it TWICE. Swallowing it instead lets
        // the run advance the fingerprint: the persisted diff still
        // surfaces in the CHANGED band + badge, so a lost heads-up stays
        // lost (at-most-once in the shade) and never becomes a duplicate.
        try {
          await MeiNotifications.notifyChange(
              L10n.t("agenda.timetableChangedN", [changes.length]), summary);
        } on Object catch (e) {
          if (kDebugMode) print("change heads-up failed: $e");
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
              // feed-coverage dedupe of the CARRIED synth block (b48: the
              // poll re-seeded the pre-dedupe block verbatim, reviving
              // double agenda rows the foreground paths now filter):
              // judge the carried block against the FRESH feed alone
              // (same rule as CampusManager's foreground embed) - suppress
              // only feed-covered events, keep synth-only ones (AdvMath,
              // MINT tutorials)
              CampusManager.dropSignMeUpSynthCoveredByFeed(
                  body, CampusManager.extractSignMeUpSynth(staleCache))),
          CampusManager.extractPersonalIcs(staleCache));
      await prefs.setString("DATA_webcalIcsCache", mergedRaw);
      await prefs.setString(
          "DATA_webcalFetchedAt", DateTime.now().toIso8601String());
      // body first, fingerprint second (C10): the pair must never present
      // a new baseline over an old body; worst case a change resurfaces
      if (advanceFingerprint) {
        await prefs.setString("DATA_webcalFingerprint", current);
      }

      // C28: background ILIAS news diff rides the same cycle — contained
      // separately so a wedged SSO can never kill the reminder re-arm or
      // the re-registration below
      try {
        await _iliasBackgroundDiff();
      } on Object catch (e) {
        if (kDebugMode) print("ilias background diff failed: $e");
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
      // R22 cross-isolate fence for the TAIL: teardownEpoch is a
      // per-isolate 0 here (the main isolate's bump is invisible), so a
      // logout completing during the head start would otherwise re-arm
      // the DEAD account's lecture/digest alarms AFTER logout's
      // cancelAll ran - the leak with a two-day delay. Platform prefs
      // are the only valid fence in this isolate (urlLive pattern).
      if ((await SharedPreferencesAsync().getString("DATA_webcalUrl") ?? "")
          .isEmpty) {
        return true; // logged out during the head start: never re-arm
      }
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
