import 'package:flutter_test/flutter_test.dart';
import 'package:kit_mobile/exams/logic/exam_countdown.dart';
import 'package:kit_mobile/exams/models/exam_list.dart';

/// R29: countdown selection over parsed term rows — the fences the card
/// relies on: calendar-day granularity, "entfällt" honesty, pool rooms.
void main() {
  final now = DateTime(2026, 11, 12, 9); // Thursday

  ExamTerm term(String day, String time, String room) =>
      ExamTerm(day, time, room);

  ExamEntry exam(String title,
      {bool registered = true, List<ExamTerm> terms = const []}) {
    final e = ExamEntry(
        examNumber: "01-XX",
        title: title,
        examiners: "",
        examType: "",
        registered: registered,
        windowStatus: ExamWindowStatus.unknown);
    e.terms.addAll(terms);
    return e;
  }

  test("nearest sitting per exam; date order, title breaks ties", () {
    final list = examCountdowns([
      exam("Zellbiologie",
          terms: [term("Fr, 20.11.2026", "10:00 - 12:00", "30.20")]),
      exam("Thermodynamik",
          terms: [term("Mo, 16.11.2026", "08:00 - 10:00", "50.21")]),
      exam("Angewandte Informatik",
          terms: [term("Mo, 16.11.2026", "08:00 - 10:00", "50.22")]),
    ], now);
    expect(list.map((c) => c.exam.title).toList(),
        ["Angewandte Informatik", "Thermodynamik", "Zellbiologie"]);
    expect(list.map((c) => c.days).toList(), [4, 4, 8]);
    expect(list.map((c) => c.room).toList(), ["50.22", "50.21", "30.20"]);
  });

  test("today counts with 0 days; yesterday is over regardless of clock",
      () {
    final late = DateTime(2026, 11, 12, 23);
    final list = examCountdowns([
      // 8:00 already passed on the clock — but it is still TODAY's exam
      exam("Heute 8 Uhr",
          terms: [term("Do, 12.11.2026", "08:00 - 10:00", "30.40")]),
      exam("Gestern 23 Uhr",
          terms: [term("Mi, 11.11.2026", "23:00 - 23:59", "30.41")]),
    ], late);
    expect(list.map((c) => c.exam.title).toList(), ["Heute 8 Uhr"]);
    expect(list.single.days, 0);
  });

  test("entfällt never counts down: dropped alone, anchor-skipped with twin",
      () {
    final list = examCountdowns([
      exam("Ausgefallen", terms: [term("Mo, 16.11.2026", "entfällt", "")]),
      exam("Ersatztermin", terms: [
        term("Mo, 16.11.2026", "entfällt", "30.40"),
        term("Fr, 20.11.2026", "10:00 - 12:00", "30.41"),
      ]),
    ], now);
    expect(list.map((c) => c.exam.title).toList(), ["Ersatztermin"]);
    // the cancelled 16.11 must not steal the anchor nor its room
    expect(list.single.at, DateTime(2026, 11, 20, 10));
    expect(list.single.days, 8);
    expect(list.single.room, "30.41");
  });

  test("pool sittings sharing a start never misattribute a room", () {
    final list = examCountdowns([
      exam("Poolklausur", terms: [
        term("Fr, 20.11.2026", "10:00 - 12:00", "30.20"),
        term("Fr, 20.11.2026", "10:00 - 12:00", "30.41"),
      ]),
      exam("Einzeltermin",
          terms: [term("Fr, 20.11.2026", "10:00 - 12:00", "30.20")]),
    ], now);
    expect(list.map((c) => c.exam.title).toList(),
        ["Einzeltermin", "Poolklausur"]);
    expect(list[0].room, "30.20");
    // the pool still counts down — only the room goes silent
    expect(list[1].at, DateTime(2026, 11, 20, 10));
    expect(list[1].room, isNull);
  });

  test("placeholder rooms are no room; ILIAS stays as the online place", () {
    final list = examCountdowns([
      exam("Ohne Raum",
          terms: [term("Fr, 20.11.2026", "10:00 - 12:00", "-")]),
      exam("Onlineklausur",
          terms: [term("Fr, 20.11.2026", "10:00 - 12:00", "ILIAS")]),
    ], now);
    expect(list.firstWhere((c) => c.exam.title == "Ohne Raum").room, isNull);
    expect(list.firstWhere((c) => c.exam.title == "Onlineklausur").room,
        "ILIAS");
  });

  test("unregistered exams never count down", () {
    final list = examCountdowns([
      exam("Nicht angemeldet",
          registered: false,
          terms: [term("Mo, 16.11.2026", "08:00 - 10:00", "30.40")]),
    ], now);
    expect(list, isEmpty);
  });

  test("horizon cuts the tail; sitting exactly on it stays", () {
    final list = examCountdowns([
      exam("Am Horizont",
          terms: [term("Sa, 12.12.2026", "08:00 - 10:00", "30.40")]),
      exam("Knapp darüber",
          terms: [term("So, 13.12.2026", "08:00 - 10:00", "30.41")]),
    ], now, horizonDays: 30);
    expect(list.map((c) => c.exam.title).toList(), ["Am Horizont"]);
    expect(list.single.days, 30);
  });

  test("limit keeps the nearest sittings", () {
    final list = examCountdowns([
      exam("Ferne 2", terms: [term("Mo, 16.11.2026", "08:00 - 10:00", "A")]),
      exam("Nah 1", terms: [term("Fr, 13.11.2026", "08:00 - 10:00", "A")]),
      exam("Ferne 1", terms: [term("So, 15.11.2026", "08:00 - 10:00", "A")]),
      exam("Nah 2", terms: [term("Sa, 14.11.2026", "08:00 - 10:00", "A")]),
    ], now, limit: 2);
    expect(list.map((c) => c.exam.title).toList(), ["Nah 1", "Nah 2"]);
  });

  test("one countdown per exam, anchored on the earliest sitting", () {
    final list = examCountdowns([
      exam("Mehrfach", terms: [
        term("Fr, 20.11.2026", "10:00 - 12:00", "30.41"),
        term("Mo, 16.11.2026", "08:00 - 10:00", "30.40"),
      ]),
    ], now);
    expect(list.length, 1);
    expect(list.single.at, DateTime(2026, 11, 16, 8));
    expect(list.single.room, "30.40"); // the later term's room never leaks
  });

  test("range spans and time-less labels are unknown: no countdown", () {
    final list = examCountdowns([
      exam("Zeitraum",
          terms: [term("Sa, 21.11.-04.12.2026", "10:00 - 12:00", "30.40")]),
      exam("Ohne Uhrzeit", terms: [term("Mo, 16.11.2026", "", "30.41")]),
    ], now);
    expect(list, isEmpty);
  });
}
