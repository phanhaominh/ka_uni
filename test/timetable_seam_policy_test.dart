// The day column draws 1px hairlines between blocks; the SAME boolean list
// feeds the painted seams and the now-line's 1px walk (dayColumnFactor /
// nowLineY), so the policy is a geometry contract, not decoration.
import 'package:flutter_test/flutter_test.dart';
import 'package:kit_mobile/timetable/logic/now_line.dart';
import 'package:kit_mobile/timetable/models/timetable_appointment.dart';
import 'package:kit_mobile/timetable/views/timetable_daily_view.dart';

TimetableAppointment _slot(int startH, int startM, int minutes,
        {bool empty = true, bool lunch = false}) =>
    TimetableAppointment(
      type: lunch
          ? TimetableAppointmentType.lunchBreak
          : TimetableAppointmentType.lecture,
      begin: DateTime(2026, 11, 2, startH, startM),
      end:
          DateTime(2026, 11, 2, startH, startM).add(Duration(minutes: minutes)),
    )
      ..title = empty ? "—" : (lunch ? "Mittagspause" : "Lecture")
      ..id = empty ? "" : "1";

void main() {
  group("dayColumnSeams", () {
    test("no seam after the last row, whatever it is", () {
      final rows = [
        _slot(8, 0, 60),
        _slot(9, 0, 60, empty: false),
      ];
      final seams = dayColumnSeams(rows);
      expect(seams.length, rows.length);
      expect(seams.last, isFalse);
    });

    test("no seam floats inside a pure void run", () {
      // void | void | lecture: seam 0 sits between two empty slots and
      // must stay hidden; seam 1 touches the lecture, so it marks the
      // lecture's top edge and stays
      final rows = [
        _slot(8, 0, 60),
        _slot(9, 0, 60),
        _slot(10, 0, 60, empty: false),
      ];
      expect(dayColumnSeams(rows), [false, true, false]);
    });

    test("a seam survives when at least one side is content", () {
      final rows = [
        _slot(10, 0, 60, empty: false),
        _slot(11, 0, 60), // free gap after a lecture
        _slot(12, 0, 60, empty: false),
        _slot(13, 0, 60, lunch: true), // lunch = structure, not void
        _slot(14, 0, 60), // trailing void
      ];
      expect(dayColumnSeams(rows), [true, true, true, true, false]);
    });

    test("every row being empty yields no seams at all", () {
      final rows = [_slot(8, 0, 60), _slot(9, 0, 60), _slot(10, 0, 60)];
      expect(dayColumnSeams(rows).every((s) => !s), isTrue);
    });
  });

  group("dayColumnBlocks", () {
    test("a gap band starts where its pixels do, not at the placeholder", () {
      final rows = [
        _slot(8, 0, 60, empty: false),
        _slot(9, 45, 90), // scaffold placeholder: nominal 9:45, generic 1:30
        _slot(11, 30, 90, empty: false),
      ];
      final blocks = dayColumnBlocks(rows);
      expect(blocks.map((b) => b.durationMin), [60, 150, 90],
          reason: 'the placeholder row owns the real 9:00..11:30 gap');
      expect(blocks[1].content, isFalse);
      expect(blocks[1].beginMin, 9 * 60,
          reason: 'band top pixel shows 9:00, the previous lecture\'s end: '
              'fed with the placeholder\'s nominal 9:45 the walk window '
              'shifted 45 min late and drew the line through the next '
              'lecture while the gap still had minutes left');

      // end-to-end, mirroring the painted Column: 11:35 resolves INSIDE
      // the lecture block (5 px in), never near the gap band's bottom...
      expect(
          nowLineY(
              blocks: blocks,
              heights: const [60, 150, 90],
              minutesOfDay: 11 * 60 + 35),
          closeTo(60 + 1 + 150 + 1 + 5, 1e-9));
      // ...and the placeholder's nominal start lands 45 min INTO the band
      expect(
          nowLineY(
              blocks: blocks,
              heights: const [60, 150, 90],
              minutesOfDay: 9 * 60 + 45),
          closeTo(60 + 1 + 45, 1e-9));
    });
  });
}
