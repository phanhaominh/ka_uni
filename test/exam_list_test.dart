import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kit_mobile/exams/models/exam_list.dart';

void main() {
  test('parses real possibleexams fixture', () {
    final raw = File('test/fixtures/possibleexams.html').readAsStringSync();
    final exams = ExamListParser.parse(raw);
    expect(exams.length, greaterThanOrEqualTo(20));

    final em1 = exams.firstWhere((e) => e.title == "Engineering Mechanics I");
    expect(em1.registered, isFalse);
    expect(em1.windowStatus, ExamWindowStatus.impossible);
    expect(em1.needsAction(DateTime(2026, 10, 30)), isFalse);

    // "Anmeld ung ab 15.11.2026" -> closed before, open after the start
    final mcs = exams.firstWhere(
        (e) => e.title == "Measurement and Control Systems");
    expect(mcs.windowStatus, ExamWindowStatus.closed);
    expect(mcs.windowStart, DateTime(2026, 11, 15, 0, 0));
    expect(mcs.needsAction(DateTime(2026, 11, 14)), isFalse);
    expect(mcs.needsAction(DateTime(2026, 11, 16)), isTrue);

    // "Anmelden bis 07.12.2026 23:59" -> open until end
    final tut = exams.firstWhere(
        (e) => e.title == "Tutorial Engineering Mechanics III");
    expect(tut.windowStatus, ExamWindowStatus.open);
    expect(tut.windowEnd, DateTime(2026, 12, 7, 23, 59));
    expect(tut.needsAction(DateTime(2026, 12, 1)), isTrue);
    expect(tut.needsAction(DateTime(2026, 12, 8)), isFalse);

    // exam terms attach to the preceding exam (EM2 owns the 23.03 date)
    final em2 = exams.firstWhere((e) => e.title == "Engineering Mechanics II");
    expect(em2.terms, isNotEmpty);
    expect(em2.terms.first.dayLabel, contains("2027"));
    expect(em2.terms.first.room, contains("Gottlieb-Daimler"));

    // caption
    expect(ExamListParser.semesterCaption(raw), contains("WS 26/27"));
  });

  test('registered + cancelled + range-term edge cases', () {
    final raw =
        File('test/fixtures/possibleexams_edgecases.html').readAsStringSync();
    final exams = ExamListParser.parse(raw);
    expect(exams.length, 3);

    final reg = exams.firstWhere((e) => e.examNumber == "01-A-9001");
    expect(reg.registered, isTrue);
    // normal term parses; the entfaellt term never yields a start
    expect(reg.terms.first.startAt, DateTime(2027, 3, 23, 17, 30));
    expect(reg.terms[1].isCancelled, isTrue);
    expect(reg.terms[1].startAt, isNull);
    // countdown anchors on the non-cancelled term only
    expect(reg.nextRegisteredTerm(DateTime(2027, 1, 1)),
        DateTime(2027, 3, 23, 17, 30));
    // placeholder room "-" normalizes to empty
    expect(reg.terms[1].roomLabel, isEmpty);

    final range = exams.firstWhere((e) => e.examNumber == "01-A-9002");
    // block-range dayLabel must NOT silently resolve to the range end
    expect(range.terms.first.dayLabel, contains("12.04.2027"));
    expect(range.terms.first.startAt, DateTime(2027, 4, 12, 10, 0));

    // open-ended window: needsAction true, null deadline (agenda guard)
    final openEnded = exams.firstWhere((e) => e.examNumber == "01-A-9003");
    expect(openEnded.needsAction(DateTime(2026, 11, 20)), isTrue);
    expect(openEnded.windowEnd, isNull);
  });
}
