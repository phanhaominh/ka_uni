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

    final guessed = MeiNotifications.reminderBody(
        _occ("Klausur: Analysis I", 8, guessed: true));
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

  // R32.1: the room placeholder wording is localized, the real room is not
  test("english digest says 'Room TBA', german 'Raum folgt'", () async {
    SharedPreferences.setMockInitialValues({L10n.languagePrefKey: "en"});
    await L10n.reload();
    addTearDown(() async {
      SharedPreferences.setMockInitialValues({});
      await L10n.reload();
    });
    final tba = MeiNotifications.digestTexts([
      IcsOccurrence(
          start: DateTime(2026, 11, 3, 8),
          end: DateTime(2026, 11, 3, 9),
          title: "Analysis I",
          room: "-",
          uid: "tba-en")
    ]);
    expect(tba.$2, contains("Room TBA"));
    final roomed = MeiNotifications.digestTexts([_occ("Analysis I", 8)]);
    expect(roomed.$2, contains("AVI 105"));
    expect(roomed.$2, isNot(contains("Room TBA")));
  });

  test("exam-only digest day says 'Klausur um HH:MM', not the count", () {
    final (title, body) = MeiNotifications.digestTexts(
        [_occ("Klausur: EM I", 9), _occ("Klausur: EM II", 14)]);
    expect(title, "Heute: Klausur");
    expect(body, contains("Klausur um 09:00"));
    expect(body, isNot(contains("Veranstaltungen")));
  });

  test("mixed day keeps the classic count body", () {
    final (title, body) = MeiNotifications.digestTexts(
        [_occ("Klausur: EM I", 9), _occ("Analysis I (V)", 12)]);
    expect(title, "Heute: 2 Veranstaltungen");
    expect(body, contains("Erste um 09:00"));
    expect(body, isNot(contains("geändert"))); // C65: stale hint dropped
  });

  test("due-only day is an assignment, not '1 classes'", () {
    final (title, body) = MeiNotifications.digestTexts(
        [_occ("Due: AM I (Blatt 3)", 18, guessed: true)]);
    expect(title, "Heute: Abgabe fällig");
    expect(body, contains("Fällig um 18:00"));
    // a real lecture sharing the day is no longer counted around the due
    final mixed = MeiNotifications.digestTexts(
        [_occ("Due: AM I (Blatt 3)", 18, guessed: true), _occ("Analysis I (V)", 10)]);
    expect(mixed.$1, "Heute: 1 Veranstaltungen");
  });

  test("mirrored lectures (same title+start) get exactly one alarm slot", () {
    final mirrored = [
      _occ("Analysis I", 8),
      _occ("Analysis I", 8), // personal-ICS mirror of the CAS event
      _occ("Analysis I (Übung)", 8),
      _occ("Analysis I", 10),
    ];
    final deduped = MeiNotifications.dedupOccurrences(mirrored);
    expect(deduped.length, 3);
    expect(deduped.map((o) => o.title),
        ["Analysis I", "Analysis I (Übung)", "Analysis I"]);
  });

  // R29 (R2): evening digest wording - the frame says "Morgen", so no
  // body may claim "Heute"; the lecture taxonomy must match the morning
  // digest exactly (Due rows are no classes, Klausur-only days say Klausur)
  test("evening digest frames tomorrow, never 'Heute'", () {
    final (title, body) = MeiNotifications.eveningTexts(
        [_occ("Analysis I", 8), _occ("Mechanik A", 10)]);
    expect(title, "Morgen");
    expect(body, contains("08:00"));
    expect(body, contains("Analysis I"));
    expect(body, contains("+1 weitere"));
    expect(body, isNot(contains("Heute")));
  });

  test("evening digest keeps morning taxonomy for due/exam/free days", () {
    final due = MeiNotifications.eveningTexts([_occ("Due: Abgabe", 12)]);
    expect(due.$1, "Morgen");
    expect(due.$2, isNot(contains("Veranstaltung")));
    expect(due.$2, contains("Fällig"));

    final exam =
        MeiNotifications.eveningTexts([_occ("Klausur: Analysis I", 9)]);
    expect(exam.$2, contains("Klausur"));

    final free = MeiNotifications.eveningTexts([]);
    expect(free.$1, "Morgen");
    expect(free.$2, contains("Keine Veranstaltungen"));
    expect(free.$2, isNot(contains("Heute")));

    final cancelled =
        MeiNotifications.eveningTexts([], const ["Thermodynamik"]);
    expect(cancelled.$2, contains("Thermodynamik"));
    expect(cancelled.$2, isNot(contains("Heute")));
  });
}
