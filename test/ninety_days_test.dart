/// R34.5 pins: the "NÄCHSTE 90 TAGE" merge. The card is a dumb
/// renderer; everything load-bearing lives here: source classification,
/// the 90-day horizon, the never-invent rule for missing bounds, and
/// deterministic ordering.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:kit_mobile/agenda/logic/ninety_days.dart';
import 'package:kit_mobile/exams/models/exam_list.dart';
import 'package:kit_mobile/signmeup/signmeup_terms.dart';
import 'package:kit_mobile/timetable/models/webcal.dart';

void main() {
  // fixed clock: Friday 13.11.2026, 12:00 local
  final now = DateTime(2026, 11, 13, 12);

  IcsOccurrence occ(String uid, DateTime start, String title) =>
      IcsOccurrence(
          start: start,
          end: start.add(const Duration(hours: 1)),
          title: title,
          room: "",
          uid: uid);

  ExamEntry exam(String title,
          {bool registered = false,
          ExamWindowStatus status = ExamWindowStatus.open,
          DateTime? wStart,
          DateTime? wEnd}) =>
      ExamEntry(
          examNumber: "e-$title",
          title: title,
          examiners: "",
          examType: "Klausur",
          registered: registered,
          windowStatus: status,
          windowStart: wStart,
          windowEnd: wEnd);

  SignMeUpTerm term(String name, {DateTime? s, DateTime? e}) =>
      SignMeUpTerm(
          id: name,
          name: name,
          fullName: name,
          start: s,
          end: e,
          cancelEnd: null);

  group('merge', () {
    test('all five sources land in one date-sorted list', () {
      final rows = nextNinetyDays(
        ninetyDays(
          now: now,
          occurrences: [
            occ("kauni-due-1-a", DateTime(2026, 11, 20, 23, 59),
                "Due: AdvMath - Blatt 5"),
            occ("kauni-exam-77-a", DateTime(2027, 1, 26, 8),
                "Klausur: Thermodynamik"),
            occ("regular-feed-event", DateTime(2026, 11, 16, 8),
                "Vorlesung ME I"), // lectures are NOT rows
            occ("kauni-frb-3", DateTime(2026, 12, 1),
                "Frist: Wohnung"), // frb rides the record param only
          ],
          exams: [
            exam("Strömungslehre",
                wStart: DateTime(2026, 11, 1),
                wEnd: DateTime(2026, 11, 30, 12)),
            exam("Maschinenbau-Seminar",
                status: ExamWindowStatus.closed,
                wStart: DateTime(2026, 12, 10, 9)),
          ],
          fristenbuch: [
            (title: "Wohnung kündigen", date: DateTime(2026, 12, 31)),
          ],
          terms: [
            term("SS 2027", s: DateTime(2027, 4, 1)), // beyond 90d
            term("WS 26/27",
                s: DateTime(2026, 10, 1), e: DateTime(2027, 3, 31)),
          ],
        ),
        now,
        limit: 20,
      );
      // date order beats source order; the past WS start and the >90d
      // SS start / WS end never appear
      expect(
          rows
              .map((r) => (r.kind, r.title))
              .toList(),
          [
            (NinetyKind.due, "Due: AdvMath - Blatt 5"),
            (NinetyKind.examWindowClose, "Strömungslehre"),
            (NinetyKind.examWindowOpens, "Maschinenbau-Seminar"),
            (NinetyKind.frb, "Wohnung kündigen"),
            (NinetyKind.examSitting, "Klausur: Thermodynamik"),
          ]);
      expect(rows.any((r) => r.title == "Vorlesung ME I"), isFalse,
          reason: "recurring lectures would flood the card");
      expect(rows.any((r) => r.title.startsWith("Frist:")), isFalse,
          reason: "frb rows come from the typed records, not their "
              "feed shadow - whichever path is wired, never twice");
      expect(rows.any((r) => r.title == "SS 2027"), isFalse);
      expect(rows.any((r) => r.title == "WS 26/27"), isFalse);
    });

    test('due rows classify by uid prefix, timed rows sort by instant', () {
      final rows = nextNinetyDays(
        ninetyDays(now: now, occurrences: [
          occ("kauni-due-9-z", DateTime(2026, 12, 5, 18), "Due: X"),
          occ("kauni-due-1-a", DateTime(2026, 11, 14, 23, 59), "Due: A"),
        ]),
        now,
      );
      expect(rows.map((r) => r.kind).toSet(), {NinetyKind.due});
      expect(rows.map((r) => r.title).toList(), ["Due: A", "Due: X"]);
    });

    test('term rows carry allDay + their own kind for the citation', () {
      final rows = ninetyDays(now: now, terms: [
        term("WS 26/27", s: null, e: DateTime(2027, 3, 31)),
        term("SS 2027", s: DateTime(2027, 2, 1)),
      ]);
      expect(
          rows
              .map((r) => (r.kind, r.allDay, r.title))
              .toList(),
          [
            (NinetyKind.termEnd, true, "WS 26/27"),
            (NinetyKind.termStart, true, "SS 2027"),
          ]);
    });
  });

  group('honesty: unknown dates are never invented', () {
    test('Fristenbuch entry without a date produces no row', () {
      final rows = ninetyDays(now: now,
          fristenbuch: [(title: "Irgendwann beim Prüfungsamt", date: null)]);
      expect(rows, isEmpty);
    });

    test('open window without a stated end has no row (no guess)', () {
      final rows = ninetyDays(now: now,
          exams: [exam("Offen ohne Ende", wStart: DateTime(2026, 11, 1))]);
      expect(rows, isEmpty);
    });

    test('unknown/impossible windows and registered exams produce nothing',
        () {
      final rows = ninetyDays(now: now, exams: [
        exam("Unknown", status: ExamWindowStatus.unknown),
        exam("Impossible", status: ExamWindowStatus.impossible),
        exam("Already written",
            registered: true,
            wStart: DateTime(2026, 11, 1),
            wEnd: DateTime(2026, 11, 30)),
      ]);
      expect(rows, isEmpty);
    });

    test('term bounds that are null on the model render nothing', () {
      final rows = ninetyDays(
          now: now,
          terms: [
            term("Geheimnis", s: null, e: null),
            term("Start", s: DateTime(2027, 1, 1))
          ]);
      expect(rows.map((r) => r.kind).toList(), [NinetyKind.termStart]);
    });
  });

  group('horizon and cap', () {
    test('rows strictly inside [now, now+90d] survive, outside drop', () {
      final rows = nextNinetyDays([
        (
          when: now.add(const Duration(days: 89)),
          allDay: false,
          kind: NinetyKind.due,
          title: "in 89"
        ),
        (
          when: now.add(const Duration(days: 91)),
          allDay: false,
          kind: NinetyKind.due,
          title: "in 91"
        ),
        (
          when: now.subtract(const Duration(minutes: 1)),
          allDay: false,
          kind: NinetyKind.due,
          title: "just past"
        ),
      ], now);
      expect(rows.map((r) => r.title).toList(), ["in 89"]);
    });

    test('cap-6 keeps the soonest rows and the hidden count names the rest',
        () {
      final many = [
        for (var d = 1; d <= 8; d++)
          (
            when: now.add(Duration(days: d)),
            allDay: false,
            kind: NinetyKind.due,
            title: "D$d"
          ),
      ];
      final shown = nextNinetyDays(many, now);
      expect(shown.length, 6);
      expect(shown.last.title, "D6");
      expect(ninetyDaysHidden(many, now), 2);
      expect(ninetyDaysHidden(shown, now), 0);
    });
  });

  group('deterministic order', () {
    test('same instant: all-day rows first, then by title', () {
      final rows = nextNinetyDays([
        (
          when: DateTime(2026, 12, 1, 18),
          allDay: false,
          kind: NinetyKind.due,
          title: "b Timed"
        ),
        (
          when: DateTime(2026, 12, 1),
          allDay: true,
          kind: NinetyKind.frb,
          title: "z Note"
        ),
        (
          when: DateTime(2026, 12, 1),
          allDay: true,
          kind: NinetyKind.termStart,
          title: "a Term"
        ),
      ], now);
      expect(rows.map((r) => r.title).toList(),
          ["a Term", "z Note", "b Timed"]);
    });

    test('input order cannot flip the output (no source-order flapping)', () {
      List<NinetyRow> build(bool shuffle) {
        final a = (
          when: DateTime(2026, 12, 1),
          allDay: true,
          kind: NinetyKind.frb,
          title: "aaa"
        );
        final b = (
          when: DateTime(2026, 12, 1),
          allDay: true,
          kind: NinetyKind.frb,
          title: "bbb"
        );
        return nextNinetyDays(shuffle ? [b, a] : [a, b], now);
      }

      expect(build(true).map((r) => r.title).toList(),
          build(false).map((r) => r.title).toList());
    });
  });
}
