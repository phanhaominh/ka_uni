import 'package:flutter_test/flutter_test.dart';
import 'package:kit_mobile/exams/models/exam_list.dart';
import 'package:kit_mobile/l10n/l10n.dart';
import 'package:kit_mobile/navigation/notification_deep_links.dart';
import 'package:kit_mobile/notifications/mei_notifications.dart';
import 'package:kit_mobile/notifications/notification_payload.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// R32.3: the 1300-1319 one-shot deregistration band - pure selection
/// math and the wording pair, pinned exactly like the 500-band window
/// family it rebuilds with.
void main() {
  final now = DateTime(2026, 11, 15, 12);

  ExamEntry exam(String title,
          {bool registered = true, DateTime? deregEnd}) =>
      ExamEntry(
          examNumber: "01-X-$title",
          title: title,
          examiners: "",
          examType: "",
          registered: registered,
          windowStatus: ExamWindowStatus.unknown,
          deregEnd: deregEnd);

  test("a registered exam with a future deregEnd arms exactly T-24h", () {
    final end = now.add(const Duration(days: 3));
    final sel = MeiNotifications.deregSelection([exam("Wind", deregEnd: end)], now);
    expect(sel.single.remindAt, now.add(const Duration(days: 2)));
    expect(sel.single.exam.title, "Wind");
  });

  test("unregistered and dereg-less exams never arm", () {
    final end = now.add(const Duration(days: 5));
    final sel = MeiNotifications.deregSelection(
        [exam("Not signed in", registered: false, deregEnd: end), exam("No date")],
        now);
    expect(sel, isEmpty,
        reason: "a dereg ping for an exam you are not registered in is "
            "noise: there is nothing to deregister from");
  });

  test("one-shot: an alarm whose moment passed is never re-armed", () {
    // deadline in 10 h: the T-24h ping either fired already or was
    // skipped while asleep - re-arming NOW would nag at the wrong time
    expect(
        MeiNotifications.deregSelection(
            [exam("Close", deregEnd: now.add(const Duration(hours: 10)))],
            now),
        isEmpty);
    // deadline already over: history
    expect(
        MeiNotifications.deregSelection(
            [exam("Over", deregEnd: now.subtract(const Duration(hours: 1)))],
            now),
        isEmpty);
    // exactly at the T-24h mark: not "after" now -> dropped (dense band
    // slots would otherwise drift a stale alarm in on every rebuild)
    expect(
        MeiNotifications.deregSelection(
            [exam("Boundary", deregEnd: now.add(const Duration(days: 1)))],
            now),
        isEmpty);
  });

  test("band cap: at most 20 pings, dense from the front", () {
    final many = [
      for (var d = 1; d <= 25; d++)
        exam("E$d", deregEnd: now.add(Duration(days: 2 + d)))
    ];
    final sel = MeiNotifications.deregSelection(many, now);
    expect(sel.length, 20, reason: "ids 1300-1319, no overflow");
  });

  test("DE body names module and full deadline", () {
    final (title, body) = MeiNotifications.deregTexts(
        exam("Wind Energy", deregEnd: DateTime(2027, 2, 19, 23, 59)));
    expect(title, contains("Abmeldung"));
    expect(body, contains("Wind Energy"));
    expect(body, contains("19.02.2027 23:59"),
        reason: "a T-24h ping crosses days: hour alone would be ambiguous");
  });

  test("EN body names module and full deadline", () async {
    SharedPreferences.setMockInitialValues({L10n.languagePrefKey: "en"});
    await L10n.reload();
    addTearDown(() async {
      SharedPreferences.setMockInitialValues({});
      await L10n.reload();
    });
    final (title, body) = MeiNotifications.deregTexts(
        exam("Wind Energy", deregEnd: DateTime(2027, 2, 19, 23, 59)));
    expect(title, contains("deregistration"));
    expect(body, contains("Wind Energy"));
    expect(body, contains("unregister until 19.02.2027 23:59"));
  });

  test("tap routes to the exams page via the EXISTING route token", () {
    // the dereg ping reuses NotificationPayload.exams (the chip it names
    // renders on the exam card) - notification_deep_links.dart is NOT
    // edited, this pins that the reused token really resolves
    expect(deepLinkForPayload(NotificationPayload.exams),
        NotificationDeepLink.exams);
  });
}
