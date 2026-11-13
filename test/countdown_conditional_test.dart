import 'package:flutter_test/flutter_test.dart';
import 'package:kit_mobile/exams/logic/exam_countdown.dart';
import 'package:kit_mobile/exams/models/exam_list.dart';

/// R31 D1: eligibility matrix for the "If you register" tier — the fences
/// the card relies on: registered rows stay in their own pool, dead and
/// unreachable windows never show a deadline, and the tier shares the
/// card's limit of 6 WITHOUT ever displacing a registered countdown.
void main() {
  final now = DateTime(2026, 11, 12, 9); // Thursday

  ExamTerm term(String day, String time, String room) =>
      ExamTerm(day, time, room);

  ExamEntry exam(String title,
      {bool registered = false,
      ExamWindowStatus status = ExamWindowStatus.open,
      DateTime? windowStart,
      DateTime? windowEnd,
      List<ExamTerm> terms = const []}) {
    final e = ExamEntry(
        examNumber: "01-XX",
        title: title,
        examiners: "",
        examType: "",
        registered: registered,
        windowStatus: status,
        windowStart: windowStart,
        windowEnd: windowEnd);
    e.terms.addAll(terms);
    return e;
  }

  // open registration, dated future sitting — the archetype
  ExamEntry eligible(String title) => exam(title,
      windowEnd: DateTime(2026, 11, 20, 23, 59),
      terms: [term("Do, 03.12.2026", "09:00 - 11:00", "30.40")]);

  test("window open + dated future sitting: conditional row with deadline",
      () {
    final list = conditionalCountdowns([eligible("IT und Data Science")], now);
    expect(list.single.conditional, isTrue);
    expect(list.single.days, 21); // 12.11 -> 03.12, calendar days
    expect(list.single.at, DateTime(2026, 12, 3, 9));
    expect(list.single.windowEnd, DateTime(2026, 11, 20, 23, 59));
    expect(list.single.room, "30.40");
  });

  test("registered exams stay in the registered pool only", () {
    final both = [
      exam("Angemeldet",
          registered: true,
          windowEnd: DateTime(2026, 11, 20, 23, 59),
          terms: [term("Do, 03.12.2026", "09:00 - 11:00", "30.40")]),
      eligible("Neu"),
    ];
    expect(conditionalCountdowns(both, now).map((c) => c.exam.title).toList(),
        ["Neu"]);
    expect(examCountdowns(both, now).map((c) => c.exam.title).toList(),
        ["Angemeldet"]);
  });

  test("impossible window excluded even with future end and sitting", () {
    final list = conditionalCountdowns([
      exam("Sperre",
          status: ExamWindowStatus.impossible,
          windowEnd: DateTime(2026, 12, 1, 23, 59),
          terms: [term("Do, 03.12.2026", "09:00 - 11:00", "30.40")]),
    ], now);
    expect(list, isEmpty);
  });

  test("window not open yet but closing within horizon included", () {
    final list = conditionalCountdowns([
      exam("Öffnet bald",
          status: ExamWindowStatus.closed,
          windowStart: DateTime(2026, 11, 15, 8),
          windowEnd: DateTime(2026, 11, 30, 23, 59),
          terms: [term("Fr, 12.02.2027", "10:00 - 12:00", "50.21")]),
      // unknown status but a concrete closing date: the date is the offer
      exam("Status unbekannt",
          status: ExamWindowStatus.unknown,
          windowEnd: DateTime(2026, 12, 5, 23, 59),
          terms: [term("Mo, 08.02.2027", "08:00 - 10:00", "50.22")]),
    ], now);
    expect(list.map((c) => c.exam.title).toList(),
        ["Status unbekannt", "Öffnet bald"]); // sorted by sitting
  });

  test("closing beyond horizon excluded; already-closed window gone", () {
    final list = conditionalCountdowns([
      exam("Zu spaeter Start",
          status: ExamWindowStatus.unknown,
          windowEnd: DateTime(2027, 3, 1, 23, 59), // beyond 90d horizon
          terms: [term("Do, 03.06.2027", "09:00 - 11:00", "30.40")]),
      // status claims open but the deadline passed — the window is gone,
      // the row must disappear with its own sub-line, not resurrect
      exam("Fenster zu",
          windowEnd: DateTime(2026, 11, 1, 23, 59),
          terms: [term("Do, 03.12.2026", "09:00 - 11:00", "30.41")]),
    ], now);
    expect(list, isEmpty);
  });

  test("dated sittings only: range spans and entfällt never qualify", () {
    final list = conditionalCountdowns([
      exam("Zeitraum",
          windowEnd: DateTime(2026, 11, 20, 23, 59),
          terms: [term("27.11.-04.12.2026", "09:00 - 11:00", "30.40")]),
      exam("Ausgefallen",
          windowEnd: DateTime(2026, 11, 20, 23, 59),
          terms: [term("Mo, 16.11.2026", "entfällt", "")]),
    ], now);
    expect(list, isEmpty);
  });

  test("open-ended window: no deadline date, prefix-only sub-line", () {
    final list = conditionalCountdowns([
      exam("Offen ohne Ende",
          status: ExamWindowStatus.closed,
          windowStart: DateTime(2026, 11, 1, 8),
          terms: [term("Do, 03.12.2026", "09:00 - 11:00", "30.40")]),
    ], now);
    expect(list.single.windowEnd, isNull);
    expect(list.single.conditional, isTrue);
  });

  test("sort by sitting, title breaks ties", () {
    final list = conditionalCountdowns([
      exam("Zweite",
          windowEnd: DateTime(2026, 11, 20, 23, 59),
          terms: [term("Fr, 12.02.2027", "10:00 - 12:00", "50.21")]),
      exam("Alpha",
          windowEnd: DateTime(2026, 11, 20, 23, 59),
          terms: [term("Fr, 12.02.2027", "10:00 - 12:00", "50.22")]),
      exam("Fruehe",
          windowEnd: DateTime(2026, 11, 20, 23, 59),
          terms: [term("Mo, 30.11.2026", "08:00 - 10:00", "50.23")]),
    ], now);
    expect(list.map((c) => c.exam.title).toList(),
        ["Fruehe", "Alpha", "Zweite"]);
  });

  test("shared limit of 6: conditionals never displace registered", () {
    final registered = [
      for (var i = 1; i <= 6; i++)
        exam("R$i",
            registered: true,
            terms: [term("Sa, 05.12.2026", "0${i % 10}:00 - 11:00", "30.40")]),
    ];
    final conditional = [
      for (var i = 1; i <= 3; i++) eligible("C$i"),
    ];
    final all = [...registered, ...conditional];
    // exactly the card's arithmetic: registered first, cond fills the rest
    final reg = examCountdowns(all, now, limit: 6);
    final cond = reg.length < 6
        ? conditionalCountdowns(all, now, limit: 6 - reg.length)
        : const <ExamCountdown>[];
    expect(reg.length, 6);
    expect(reg.every((c) => !c.conditional), isTrue);
    // full card: registered untouched, zero conditionals fit
    expect([...reg, ...cond].map((c) => c.exam.title).toList(),
        ["R1", "R2", "R3", "R4", "R5", "R6"]);
    // 2 registered: all 3 conditionals fit, appended after the registered
    final half = [registered[0], registered[1], ...conditional];
    final reg2 = examCountdowns(half, now, limit: 6);
    final cond2 = conditionalCountdowns(half, now, limit: 6 - reg2.length);
    expect([...reg2, ...cond2].map((c) => c.exam.title).toList(),
        ["R1", "R2", "C1", "C2", "C3"]);
  });
}
