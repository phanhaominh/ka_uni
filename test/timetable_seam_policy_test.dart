// The day column draws 1px hairlines between blocks; the SAME boolean list
// feeds the painted seams and the now-line's 1px walk (dayColumnFactor /
// nowLineY), so the policy is a geometry contract, not decoration.
import 'package:flutter_test/flutter_test.dart';
import 'package:kit_mobile/timetable/models/timetable_appointment.dart';
import 'package:kit_mobile/timetable/views/timetable_daily_view.dart';

TimetableAppointment _slot(int startH, int startM, int minutes,
        {bool empty = true, bool lunch = false}) =>
    TimetableAppointment(
      type: lunch
          ? TimetableAppointmentType.lunchBreak
          : TimetableAppointmentType.lecture,
      begin: DateTime(2026, 11, 2, startH, startM),
      end: DateTime(2026, 11, 2, startH, startM)
          .add(Duration(minutes: minutes)),
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
}
