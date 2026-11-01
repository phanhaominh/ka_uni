import 'package:flutter_test/flutter_test.dart';
import 'package:kit_mobile/l10n/l10n.dart';
import 'package:kit_mobile/notifications/mei_notifications.dart';
import 'package:kit_mobile/timetable/models/webcal.dart';
import 'package:shared_preferences/shared_preferences.dart';

IcsOccurrence _occ(String title, int hour, {bool guessed = false}) =>
    IcsOccurrence(
        start: DateTime(2026, 11, 3, hour, 0),
        end: DateTime(2026, 11, 3, hour, 0).add(const Duration(minutes: 90)),
        title: title,
        room: "AVI 105",
        uid: title,
        endGuessed: guessed);

/// Notification bodies around exam sittings (F9 + the digest decision):
/// times the ICS never stated must never be announced as facts.
void main() {
  test("reminder prints start-only 'ab HH:MM' for a guessed end", () {
    final honest = MeiNotifications.reminderBody(_occ("Analysis I", 8));
    expect(honest, startsWith("08:00–09:30"));
    expect(honest, contains("AVI 105"));

    final guessed =
        MeiNotifications.reminderBody(_occ("Klausur: Analysis I", 8,
            guessed: true));
    expect(guessed, startsWith("ab 08:00"));
    expect(guessed, isNot(contains("–"))); // no fabricated end span
    expect(guessed, contains("AVI 105"));
  });

  test("english reminder drops the fabricated end too", () async {
    SharedPreferences.setMockInitialValues({L10n.languagePrefKey: "en"});
    await L10n.reload();
    addTearDown(() async {
      SharedPreferences.setMockInitialValues({});
      await L10n.reload();
    });
    expect(
        MeiNotifications.reminderBody(
            _occ("Klausur: Thermodynamik", 9, guessed: true)),
        startsWith("from 09:00"));
  });

  test("exam-only digest day says 'Klausur um HH:MM', not the count", () {
    final (title, body) = MeiNotifications.digestTexts(
        [_occ("Klausur: EM I", 9), _occ("Klausur: EM II", 14)],
        changesFresh: false);
    expect(title, "Heute: Klausur");
    expect(body, contains("Klausur um 09:00"));
    expect(body, isNot(contains("Veranstaltungen")));
  });

  test("mixed day keeps the classic count body", () {
    final (title, body) = MeiNotifications.digestTexts(
        [_occ("Klausur: EM I", 9), _occ("Analysis I (V)", 12)],
        changesFresh: true);
    expect(title, "Heute: 2 Veranstaltungen");
    expect(body, contains("Erste um 09:00"));
    expect(body, contains("Stundenplan geändert"));
  });
}
