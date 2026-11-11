// The day pipeline feeding the absolute time axis: which rows exist and
// which of them anchor the week's shared window.
import 'package:flutter_test/flutter_test.dart';
import 'package:kit_mobile/timetable/models/timetable_appointment.dart';
import 'package:kit_mobile/timetable/models/timetable_daily.dart';
import 'package:kit_mobile/timetable/models/timetable_weekly.dart';
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

TimetableDaily _day(List<TimetableAppointment> a) =>
    TimetableDaily(weekday: Weekday.monday)..appointments = a;

void main() {
  group("dayRows", () {
    test("scaffold placeholders STAY (they carry cancel ghosts)", () {
      final rows = TimetableDailyView.dayRows(
          _day([
            _slot(8, 0, 90, empty: false),
            _slot(9, 45, 90),
            _slot(11, 30, 90, empty: false),
          ]),
          const {});
      expect(rows.length, 3,
          reason: 'on the absolute axis an empty row owns no pixels, but a '
              'removed lecture must still find its vacated 9:45 slot');
    });

    test("chronological by TIME OF DAY, not by stamped date", () {
      // template rows carry mixed dates; a raw DateTime compare once put
      // Nov-2's 13:00 lunch above Nov-5's 08:00 lecture
      final late13 = _slot(13, 0, 30, empty: false)..begin = DateTime(2026, 11, 2, 13);
      final early8 = _slot(8, 0, 90, empty: false)..begin = DateTime(2026, 11, 5, 8);
      final rows = TimetableDailyView.dayRows(_day([late13, early8]), const {});
      expect(rows.first.begin.hour, 8);
    });
  });

  group("contentBlocksFor", () {
    test("lectures AND lunch anchor the axis; scaffolds never do", () {
      final blocks = TimetableDailyView.contentBlocksFor(_day([
        _slot(8, 0, 90, empty: false),
        _slot(9, 45, 90), // scaffold: generic 90 min, no time semantics
        _slot(11, 30, 105, empty: false),
        _slot(13, 0, 30, lunch: true),
        _slot(14, 30, 90), // trailing scaffold
      ]));
      expect(blocks.map((b) => b.beginMin), [8 * 60, 11 * 60 + 30, 13 * 60]);
      expect(blocks.map((b) => b.durationMin), [90, 105, 30]);
      expect(blocks.every((b) => b.content), isTrue);
    });

    test("a row whose wall span is bogus gets the 90-min default", () {
      // all-day VALUE=DATE events stamp end==begin (or past midnight);
      // the axis must get a sane block, not a zero or 23-hour monster
      final broken = TimetableAppointment(
          type: TimetableAppointmentType.lecture,
          begin: DateTime(2026, 11, 2, 10),
          end: DateTime(2026, 11, 2, 10))
        ..title = "Klausur"
        ..id = "1";
      final blocks = TimetableDailyView.contentBlocksFor(_day([broken]));
      expect(blocks.single.durationMin, 90);
    });
  });
}
