import 'package:flutter_test/flutter_test.dart';
import 'package:kit_mobile/exams/logic/exam_clash.dart';
import 'package:kit_mobile/exams/models/exam_list.dart';

/// R29: red needs proof, amber needs a day, "all clear" needs coverage.
void main() {
  final now = DateTime(2026, 11, 12, 9); // Thursday 09:00

  ExamTerm term(String date, String time) => ExamTerm("Do, $date", time, "");

  ExamEntry exam(String num,
      {bool registered = true, List<ExamTerm> terms = const []}) {
    final e = ExamEntry(
        examNumber: num,
        title: "Klausur $num",
        examiners: "",
        examType: "",
        registered: registered,
        windowStatus: ExamWindowStatus.unknown);
    e.terms.addAll(terms);
    return e;
  }

  test("strict overlap: 17:30-19:00 vs 18:30-20:00 is red with proven ends",
      () {
    final r = findExamClashes([
      exam("01-A", terms: [term("20.01.2027", "17:30 - 19:00")]),
      exam("02-B", terms: [term("20.01.2027", "18:30 - 20:00")]),
    ], now);
    expect(r.clashes.length, 1);
    expect(r.clashes.single.kind, ClashKind.overlap);
    expect(r.clashes.single.when, DateTime(2027, 1, 20, 17, 30));
    expect(r.clashes.single.exactEndA, DateTime(2027, 1, 20, 19));
    expect(r.clashes.single.exactEndB, DateTime(2027, 1, 20, 20));
    expect(r.uncomparable, 0); // both ends proven
  });

  test("back-to-back 17:30-19:00 vs 19:00-20:00 is NOT overlap", () {
    final r = findExamClashes([
      exam("01-A", terms: [term("20.01.2027", "17:30 - 19:00")]),
      exam("02-B", terms: [term("20.01.2027", "19:00 - 20:00")]),
    ], now);
    // same day still earns the amber tier, just never the red one
    expect(r.clashes.single.kind, ClashKind.sameDay);
    expect(r.uncomparable, 0);
  });

  test("unknown end demotes to sameDay even when the start sits inside", () {
    // "18:30" alone proves nothing about an end - red is NEVER inferred.
    final r = findExamClashes([
      exam("01-A", terms: [term("20.01.2027", "17:30 - 19:00")]),
      exam("02-B", terms: [term("20.01.2027", "18:30")]),
    ], now);
    expect(r.clashes.single.kind, ClashKind.sameDay);
    expect(r.clashes.single.exactEndB, isNull);
    expect(r.uncomparable, 1); // only B is the vague side
  });

  test("cancelled sittings never clash and never dent coverage", () {
    final r = findExamClashes([
      exam("01-A", terms: [term("20.01.2027", "17:30 - 19:00")]),
      exam("02-B", terms: [ExamTerm("Do, 20.01.2027", "entfällt", "")]),
      exam("03-C", terms: [term("20.01.2027", "18:00")]),
    ], now);
    expect(r.clashes.length, 1); // A vs C only
    expect(r.clashes.single.b.examNumber, "03-C");
    expect(r.uncomparable, 1); // C's missing end, not the cancelled B
  });

  test("uncomparable counts no-time and midnight-span, not date ranges", () {
    final r = findExamClashes([
      exam("01-A", terms: [term("20.01.2027", "17:30 - 19:00")]), // clean
      exam("02-B", terms: [term("22.01.2027", "09:00")]), // no end
      exam("03-C", terms: [term("23.01.2027", "")]), // date but no time at all
      exam("04-D", terms: [term("26.01.2027", "22:00 - 00:30")]), // crosses midnight
      exam("05-E", terms: [ExamTerm("27.02.-06.03.2027", "10:00 - 12:00", "")]), // range
    ], now);
    expect(r.clashes, isEmpty);
    // B, C and D parse a day but can never support a red verdict; E has no
    // parseable date at all -> absent from the model, NOT a coverage gap.
    expect(r.uncomparable, 3);
  });

  test("past sittings are ignored, but yesterday inside the 24h grace is not",
      () {
    final dead = findExamClashes([
      exam("01-A", terms: [term("09.11.2026", "17:30 - 19:00")]), // 3 days ago
      exam("02-B", terms: [term("09.11.2026", "18:30 - 20:00")]),
    ], now);
    expect(dead.clashes, isEmpty);
    expect(dead.uncomparable, 0); // not even counted as coverage

    final yesterday = findExamClashes([
      exam("01-A", terms: [term("11.11.2026", "17:30 - 19:00")]), // Wed 17:30
      exam("02-B", terms: [term("11.11.2026", "18:30 - 20:00")]),
    ], now);
    expect(yesterday.clashes.single.kind, ClashKind.overlap);
  });

  test("two Termins of one registered exam never self-clash", () {
    final r = findExamClashes([
      exam("01-A", terms: [
        term("20.01.2027", "17:30 - 19:00"),
        term("20.01.2027", "18:00 - 19:30"),
      ]),
    ], now);
    expect(r.clashes, isEmpty);
  });

  test("a is always the lower examNumber and the list is deterministically sorted",
      () {
    // fed in reverse so a wrong order cannot pass by accident
    final r = findExamClashes([
      exam("09-Z", terms: [term("21.01.2027", "10:00 - 12:00")]),
      exam("02-B", terms: [term("21.01.2027", "11:00 - 13:00")]),
      exam("01-A", terms: [term("20.01.2027", "17:30 - 19:00")]),
      exam("03-C", terms: [term("20.01.2027", "18:00")]),
    ], now);
    expect(r.clashes.map((c) => "${c.a.examNumber}/${c.b.examNumber}"),
        ["01-A/03-C", "02-B/09-Z"]);
    expect(r.clashes[1].exactEndA, DateTime(2027, 1, 21, 13)); // 02-B swapped in
    expect(r.clashes[1].exactEndB, DateTime(2027, 1, 21, 12)); // ahead of 09-Z
  });

  test("unregistered exams are nobody's problem", () {
    final r = findExamClashes([
      exam("01-A", terms: [term("20.01.2027", "17:30 - 19:00")]),
      exam("02-B", registered: false, terms: [term("20.01.2027", "18:30")]),
    ], now);
    expect(r.clashes, isEmpty);
    expect(r.uncomparable, 0); // B's missing end is not our coverage either
  });

  test("no-time sittings on a shared day clash amber at the day boundary", () {
    final r = findExamClashes([
      exam("01-A", terms: [term("20.01.2027", "")]),
      exam("02-B", terms: [term("20.01.2027", "ab 09:00")]), // no full span
    ], now);
    expect(r.clashes.single.kind, ClashKind.sameDay);
    expect(r.clashes.single.when, DateTime(2027, 1, 20)); // honest midnight
    expect(r.uncomparable, 2);
  });
}
