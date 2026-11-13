import 'package:flutter_test/flutter_test.dart';
import 'package:kit_mobile/l10n/l10n.dart';
import 'package:kit_mobile/notifications/mei_notifications.dart';
import 'package:kit_mobile/signmeup/signmeup_manager.dart';
import 'package:kit_mobile/timetable/models/webcal.dart';

/// Wave R33: the pocket era's pure decision math - window-opens ping
/// timing (T-0, work-hour clamp, once-per-window snapshot) and the
/// last-lecture soft-alarm pick. The plugin sides are Android-only and
/// exercised on device; every CLAIM lives here.
void main() {
  SignMeUpProcedure proc(int id, DateTime? start, DateTime? end) =>
      SignMeUpProcedure.fromJson({
        "id": id,
        "name": "P$id",
        "registrationStart": start?.toIso8601String(),
        "registrationEnd": end?.toIso8601String(),
      });

  group("smuOpenFire (R33.1)", () {
    test("future window: fires at T-0, midnight start clamped to 08:00", () {
      final now = DateTime(2026, 11, 13, 10);
      final p = proc(1, DateTime(2026, 11, 14, 0, 5),
          DateTime(2026, 11, 20)); // 00:05 opening
      expect(MeiNotifications.smuOpenFire(p, now, {}),
          DateTime(2026, 11, 14, 8));
    });

    test("future window: opening at 21:30 waits until next morning", () {
      final now = DateTime(2026, 11, 13, 10);
      final p = proc(2, DateTime(2026, 11, 13, 21, 30),
          DateTime(2026, 11, 20));
      expect(MeiNotifications.smuOpenFire(p, now, {}),
          DateTime(2026, 11, 14, 8));
    });

    test("future window: daytime start fires on the dot", () {
      final now = DateTime(2026, 11, 13, 10);
      final p = proc(3, DateTime(2026, 11, 15, 13, 15),
          DateTime(2026, 11, 20));
      expect(MeiNotifications.smuOpenFire(p, now, {}),
          DateTime(2026, 11, 15, 13, 15));
    });

    test("open window backfills now+2min within work hours", () {
      final now = DateTime(2026, 11, 13, 10);
      final p = proc(4, now.subtract(const Duration(hours: 1)),
          now.add(const Duration(days: 1)));
      expect(MeiNotifications.smuOpenFire(p, now, {}),
          now.add(const Duration(minutes: 2)));
    });

    test("open window discovered at night pings next morning, not 03:00",
        () {
      final now = DateTime(2026, 11, 13, 1, 30);
      final p = proc(5, now.subtract(const Duration(hours: 3)),
          now.add(const Duration(days: 1)));
      expect(MeiNotifications.smuOpenFire(p, now, {}),
          DateTime(2026, 11, 13, 8));
    });

    test("once per window: the armed future arm counts as announced", () {
      // R34.7: scheduleSignMeUpReminders writes fired[id] the moment it
      // ARMS a future window's T-0 alarm. The armed alarm alone was NOT
      // the once-per-window guarantee: the first run after T-0 found the
      // now-open window with no entry, took the backfill path and pinged
      // again minutes after the armed alarm had fired.
      final t0 = DateTime(2026, 11, 14, 9);
      final p = proc(6, t0, DateTime(2026, 11, 20));
      final fired = <String, String>{};
      // run 1, window still future: fire instant = T-0 ...
      expect(MeiNotifications.smuOpenFire(p, DateTime(2026, 11, 13, 10), fired),
          t0);
      // ... and the scheduler records the ARM next to the alarm (mirrors
      // scheduleSignMeUpReminders' fired[id] write on the !isBackfill arm)
      fired["6"] = t0.toIso8601String();
      // run 2 after T-0: now-open window, entry found -> pings NOTHING
      expect(
          MeiNotifications.smuOpenFire(
              p, DateTime(2026, 11, 14, 9, 5), fired),
          isNull);
      // the backfill path keeps its dedup: matching entry, no ping
      final now = DateTime(2026, 11, 13, 10);
      final p2 = proc(6, now.subtract(const Duration(hours: 1)),
          now.add(const Duration(days: 1)));
      final fired3 = {"6": p2.registrationStart!.toIso8601String()};
      expect(MeiNotifications.smuOpenFire(p2, now, fired3), isNull);
      // a NEWER window (different start) is a fresh announcement
      final fired4 = {"6": now
          .subtract(const Duration(days: 9))
          .toIso8601String()};
      expect(MeiNotifications.smuOpenFire(p2, now, fired4), isNotNull);
    });

    test("closed window and missing data never fire", () {
      final now = DateTime(2026, 11, 13, 10);
      expect(
          MeiNotifications.smuOpenFire(
              proc(7, now.subtract(const Duration(days: 2)),
                  now.subtract(const Duration(days: 1))),
              now,
              const {}),
          isNull);
      expect(
          MeiNotifications.smuOpenFire(proc(8, null, null), now, const {}),
          isNull);
    });
  });

  IcsOccurrence occ(String title, DateTime start,
          {String uid = "u", bool personal = false}) =>
      IcsOccurrence(
          start: start,
          end: start.add(const Duration(hours: 1)),
          title: title,
          room: "HS",
          uid: uid,
          seriesEnd: null,
          endGuessed: false,
          fromPersonalIcs: personal,
          url: null);

  group("lastUpcomingLecture (R33.4)", () {
    final now = DateTime(2026, 11, 13, 12);

    test("picks the latest FUTURE lecture, ignores past ones", () {
      final list = [
        occ("Old", now.subtract(const Duration(days: 30))),
        occ("Last", DateTime(2027, 2, 3, 10)),
        occ("Middle", DateTime(2027, 1, 20, 10)),
      ];
      expect(MeiNotifications.lastUpcomingLecture(list, now)!.title, "Last");
    });

    test("Due rows, exam sittings, dues and personal events are no lectures",
        () {
      final list = [
        occ("Due: Assignment", DateTime(2027, 3, 1), uid: "x"),
        occ("Abgabe: Schein", DateTime(2027, 3, 2), uid: "y"),
        occ("Klausur ML", DateTime(2027, 3, 3), uid: "kauni-exam-9"),
        occ("Due: ILIAS", DateTime(2027, 3, 4), uid: "kauni-due-9"),
        occ("Zahnarzt", DateTime(2027, 3, 5), personal: true),
      ];
      expect(MeiNotifications.lastUpcomingLecture(list, now), isNull);
    });

    test("nothing ahead -> null (never announce a PAST last lecture)", () {
      final list = [occ("Done", now.subtract(const Duration(days: 1)))];
      expect(MeiNotifications.lastUpcomingLecture(list, now), isNull);
    });

    test("digest line only on the exact day, hedged 'laut Plan'", () {
      final last = occ("Getriebe", DateTime(2027, 2, 3, 16, 15));
      final line = MeiNotifications.lastLectureDigestLine(
          [last], DateTime(2027, 2, 3), now);
      expect(line, isNotNull);
      expect(line, contains("laut Plan"));
      expect(line, contains("Getriebe"));
      expect(
          MeiNotifications.lastLectureDigestLine(
              [last], DateTime(2027, 2, 2), now),
          isNull);
    });
  });

  test("gradePublished body wording (R33.3 rides the existing ping)", () {
    expect(L10n.t("notifs.gradePublishedBody", ["Math", "1,7"]),
        "Math · 1,7");
  });
}
