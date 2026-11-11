// Row TEXT layout on a phone-width card (the "Basics of Manufacturing is
// getting cut off" report of 20.11): long lecture titles must wrap to the
// second line the 90-min box affords INSTEAD OF the room line, and the
// 8-h block seminar may only own a right rail - never the row's title.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kit_mobile/geo/models/kit_place.dart';
import 'package:kit_mobile/settings/providers/settings_provider.dart';
import 'package:kit_mobile/state_management/kit_provider.dart';
import 'package:kit_mobile/timetable/logic/now_clock.dart';
import 'package:kit_mobile/timetable/logic/now_line.dart';
import 'package:kit_mobile/timetable/models/timetable_appointment.dart';
import 'package:kit_mobile/timetable/models/timetable_daily.dart';
import 'package:kit_mobile/timetable/models/timetable_weekly.dart';
import 'package:kit_mobile/timetable/views/timetable_daily_view.dart';
import 'package:kit_mobile/tutorials/data/tutorial_manager.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

TimetableAppointment ap(
    String title, int id, String room, DateTime b, DateTime e) {
  return TimetableAppointment(begin: b, end: e)
    ..title = title
    ..id = '$id'
    ..place = (KITPlace()..title = room);
}

final fake = DateTime(2026, 11, 20, 10, 5);

TimetableDaily friday() => TimetableDaily(weekday: Weekday.friday)
  ..appointments = [
    ap('Advanced Mathematics I (Tutorial)(U)', 1, '30.95 Audimax',
        DateTime(2026, 11, 20, 8, 0), DateTime(2026, 11, 20, 9, 30)),
    ap('Seminar IC USA/Germany (1200008-M) - Block 1/3 [Warteliste]', 2,
        '50.19 Seminarraum 1', DateTime(2026, 11, 20, 9, 0),
        DateTime(2026, 11, 20, 17, 0)),
    TimetableAppointment(
        type: TimetableAppointmentType.lunchBreak,
        begin: DateTime(2026, 11, 20, 13, 0),
        end: DateTime(2026, 11, 20, 13, 30)),
    ap('Basics of Manufacturing Technology (Lecture)', 3,
        '20.40 Egon-Eiermann-Hörsaal', DateTime(2026, 11, 20, 14, 0),
        DateTime(2026, 11, 20, 15, 30)),
  ];

void main() {
  testWidgets('long title wins the second line; seminar stays in its rail',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    NowClock.timeSource = () => fake;
    NowClock.debugPublish(fake);
    // carousel card inner width on Pixel 3: 0.8*393 - 2*4 gutters
    const w = 306.4;
    await tester.pumpWidget(MaterialApp(
      home: MultiProvider(
        providers: [
          ChangeNotifierProvider(create: (_) => KITProvider()),
          ChangeNotifierProvider(create: (c) => SettingsProvider(context: c)),
          ChangeNotifierProvider(create: (_) => TutorialManager()),
        ],
        child: Scaffold(
          body: SizedBox(
              width: w,
              height: 600,
              child: TimetableDailyView(
                  tt: friday(),
                  showNowLine: false,
                  pxPerMin: 0.9,
                  axis: const TimeAxis(8 * 60, 18 * 60))),
        ),
      ),
    ));
    await tester.pump();

    final title =
        find.text('Basics of Manufacturing Technology (Lecture)');
    expect(title, findsOneWidget);
    final r = tester.getRect(title);
    // two wrapped lines at the title scale (14*1.45*2), not one ellipsised
    expect(r.height, greaterThanOrEqualTo(2 * 14 * 1.45 - 1),
        reason: 'the 90-min box must show the FULL title across two lines '
            '- the room line it used to reserve could only ellipsise too');
    expect(tester.takeException(), isNull);
    // the room yields to the title in this box
    expect(find.text('20.40 Egon-Eiermann-Hörsaal'), findsNothing);
    // and the 8-h seminar sits in a RIGHT rail (its text starts past the
    // 0.70 left-region edge), never over the day's normal rows
    final sem = tester
        .getRect(find.textContaining('Seminar IC USA/Germany'));
    expect(sem.left, greaterThan(w * 0.65));
    expect(tester.getRect(title).left, lessThan(w * 0.2),
        reason: 'basics reads from the left edge of the card');
  });
}
