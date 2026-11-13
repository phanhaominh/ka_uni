import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kit_mobile/exams/models/exam_list.dart';

void main() {
  test('parses real possibleexams fixture', () {
    final raw = File('test/fixtures/possibleexams.html').readAsStringSync();
    final exams = ExamListParser.parse(raw);
    // exact fixture count (was a `>= 20` floor that let parse regressions
    // inside the slack pass silently)
    expect(exams.length, 23);

    final em1 = exams.firstWhere((e) => e.title == "Engineering Mechanics I");
    expect(em1.registered, isFalse);
    expect(em1.windowStatus, ExamWindowStatus.impossible);
    expect(em1.needsAction(DateTime(2026, 10, 30)), isFalse);

    // "Anmeld ung ab 15.11.2026" -> closed before, open after the start
    final mcs =
        exams.firstWhere((e) => e.title == "Measurement and Control Systems");
    expect(mcs.windowStatus, ExamWindowStatus.closed);
    expect(mcs.windowStart, DateTime(2026, 11, 15, 0, 0));
    expect(mcs.needsAction(DateTime(2026, 11, 14)), isFalse);
    expect(mcs.needsAction(DateTime(2026, 11, 16)), isTrue);

    // "Anmelden bis 07.12.2026 23:59" -> open until end
    final tut = exams
        .firstWhere((e) => e.title == "Tutorial Engineering Mechanics III");
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
    expect(exams.length, 4);

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

    // R32.3: German "Abmelden bis" lands on deregEnd - and on NOTHING
    // else. "Abmelden bis" must never feed the window fields (An ≠ Ab in
    // _deDateTime; this pins that it stays that way): the deadline of a
    // registered exam is not an Anmeldung window.
    final dereg = exams.firstWhere((e) => e.examNumber == "01-A-9004");
    expect(dereg.registered, isTrue);
    expect(dereg.deregEnd, DateTime(2027, 2, 19, 23, 59));
    expect(dereg.windowStatus, ExamWindowStatus.unknown,
        reason: "dereg date must never set a window status");
    expect(dereg.windowStart, isNull,
        reason: "dereg date must never feed windowStart");
    expect(dereg.windowEnd, isNull,
        reason: "dereg date must never feed windowEnd");
  });

  test('range guard counts date fragments, not dash spelling', () {
    // every range spelling is exactly two "d.m" fragments; a concrete
    // sitting label exactly one. The old dash-conjunct guard missed
    // "27.02.2027 – 06.03.2027" (dash not glued to a fragment) and a
    // full-date-token count would miss "27.02.-06.03.2027" (its first
    // fragment has no year, so firstMatch resolves to the range END).
    ExamTerm t(String dayLabel) =>
        ExamTerm(dayLabel, "10:00 - 12:00", "AVI 105");
    expect(t("27.02.-06.03.2027").startAt, isNull);
    expect(t("27.02.2027 – 06.03.2027").startAt, isNull);
    expect(t("12.04 - 30.04.2027").startAt, isNull);
    expect(t("23.03.2027").startAt, DateTime(2027, 3, 23, 10, 0));
    expect(
        t("Fr, 16.04.2027, 2. Termin").startAt, DateTime(2027, 4, 16, 10, 0));
  });

  test('English portal locale: US dates and AM/PM spans parse', () {
    // an EN session renders the SAME sittings the German view shows as
    // "Mi, 24.02.2027" / "11:00 - 13:00" as "Wed, 2/24/2027" /
    // "11:00 AM - 1:00 PM" (observed live on CAS, exam 7700085)
    ExamTerm t(String dayLabel, String time) => ExamTerm(dayLabel, time, "HS3");
    expect(t("Wed, 2/24/2027", "11:00 AM - 1:00 PM").startAt,
        DateTime(2027, 2, 24, 11, 0));
    // a 1 PM sitting starts at 13:00, never 01:00
    expect(
        t("Thu, 3/4/2027", "1:00 PM - 3:00 PM").startAt,
        DateTime(2027, 3, 4, 13, 0));
    expect(t("Fri, 3/5/2027", "12:00 AM - 12:30 AM").startAt,
        DateTime(2027, 3, 5, 0, 0));
    expect(t("Fri, 3/5/2027", "12:00 PM - 12:30 PM").startAt,
        DateTime(2027, 3, 5, 12, 0));
    // the range guard holds for the US spelling too
    expect(
        t("2/24/2027 - 3/1/2027", "11:00 AM - 1:00 PM").startAt, isNull);
    // nonsense month rejected
    expect(t("13/40/2027", "11:00 AM - 1:00 PM").startAt, isNull);
    // a label mixing both locale spellings is ambiguous -> refuse
    expect(t("24.02. 2/24/2027", "10:00 - 12:00").startAt, isNull);
    // cancelled sittings in EITHER language never count down
    expect(ExamTerm("Wed, 2/24/2027", "cancelled", "HS3").isCancelled, isTrue);
    expect(ExamTerm("Wed, 2/24/2027", "entfällt", "HS3").isCancelled, isTrue);
    expect(
        ExamTerm("Wed, 2/24/2027", "cancelled", "HS3").startAt, isNull);
  });

  test('English feed: Signed in / Register windows / US term cells', () {
    // cell texts are verbatim live-feed strings (Signed in chip!)
    final raw = File('test/fixtures/possibleexams_en.html').readAsStringSync();
    final exams = ExamListParser.parse(raw);
    expect(exams.length, 4);

    final adv = exams.firstWhere((e) => e.examNumber == "76-T-MATH-113493");
    expect(adv.registered, isTrue, reason: '"Signed in" is the EN chip');
    expect(adv.terms.single.startAt, DateTime(2027, 3, 23, 11, 0));

    final em1 = exams.firstWhere((e) => e.examNumber == "76-T-MACH-100282-e");
    expect(em1.registered, isFalse, reason: '"Not registered" stays false');
    expect(em1.windowStatus, ExamWindowStatus.open);
    expect(em1.windowEnd, DateTime(2027, 3, 31, 23, 59));

    final from = exams.firstWhere((e) => e.examNumber == "76-T-MATH-106718");
    expect(from.windowStatus, ExamWindowStatus.closed);
    expect(from.windowStart, DateTime(2026, 11, 15, 0, 0),
        reason: '"12:00 AM" is midnight, not noon');

    final unreg = exams.firstWhere((e) => e.examNumber == "76-T-WINN-104865");
    expect(unreg.windowStatus, ExamWindowStatus.unknown,
        reason: '"Unregister until" is the DEREGISTRATION deadline');
    expect(unreg.windowEnd, isNull);
    expect(unreg.windowStart, isNull,
        reason: "dereg date must never feed windowStart");
    // R32.3: the EN literal parses onto deregEnd (US M/D + 11:59 PM ->
    // 23:59 via the shared enWindowDate rehydration)
    expect(unreg.registered, isTrue, reason: '"Signed in" chip');
    expect(unreg.deregEnd, DateTime(2027, 2, 19, 23, 59));
  });

  test('examListHasRows separates the empty state from a cell reflow', () {
    // real data page: rows present => a zero-entry parse must count as
    // breakage, not the valid empty state the old gate waved through
    final raw = File('test/fixtures/possibleexams.html').readAsStringSync();
    expect(ExamListParser.examListHasRows(raw), isTrue);

    // well-formed empty state: table stays, only a colspan notice inside
    expect(
        ExamListParser.examListHasRows(
            '<table id="EXAMLIST"><tbody class="tablehead"><tr><th>x</th>'
            '</tr></tbody><tbody class="tablecontent"><tr>'
            '<td colspan="8">Keine Einträge</td></tr></tbody></table>'),
        isFalse);

    // no table at all (login bounce OR a table-id reflow that leaves only
    // the <a name="EXAMLIST"> anchor): absence of the table CANNOT certify
    // the empty state - hasRows must report "there might be data" so the
    // fetch gate falls through to the surface-broken funnel
    expect(ExamListParser.examListHasRows('<html><body>nope</body></html>'),
        isTrue);
    expect(
        ExamListParser.examListHasRows(
            '<a name="EXAMLIST"></a><table id="SOMETHING_ELSE">'
            '<tbody class="tablecontent"><tr><td>a</td><td>b</td></tr>'
            '</tbody></table>'),
        isTrue);
  });
}
