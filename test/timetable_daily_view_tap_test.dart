// Regression: full TimetableDailyView assembly + row-tap hit-testing with a
// faked clock. R12: row taps were dead while the now-line overlay was on
// (hitTestBehavior deferred); the sheet must open with and without it.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kit_mobile/geo/models/kit_place.dart';
import 'package:kit_mobile/settings/providers/settings_provider.dart';
import 'package:kit_mobile/state_management/kit_provider.dart';
import 'package:kit_mobile/timetable/logic/now_clock.dart';
import 'package:kit_mobile/timetable/models/timetable_appointment.dart';
import 'package:kit_mobile/timetable/models/timetable_daily.dart';
import 'package:kit_mobile/timetable/models/timetable_weekly.dart';
import 'package:kit_mobile/timetable/pages/timetable_appointment_page.dart';
import 'package:kit_mobile/timetable/views/timetable_daily_view.dart';
import 'package:kit_mobile/tutorials/data/tutorial_manager.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

TimetableAppointment ap(String title, int id, String room, DateTime b,
    DateTime e) {
  return TimetableAppointment(begin: b, end: e)
    ..title = title
    ..id = '$id'
    ..place = (KITPlace()..title = room);
}

final fake = DateTime(2026, 11, 2, 10, 5);

TimetableDaily monday() => TimetableDaily(weekday: Weekday.monday)
  ..appointments = [
    ap('Engineering Mechanics I (Lecture)(V), Langhoff et al., MACH', 1,
        '10.91 Franz-Grashof-Hörsaal', DateTime(2026, 11, 2, 9, 45),
        DateTime(2026, 11, 2, 11, 15)),
    ap('Thermodynamics A (Tutorial)', 2, '54.11 Testraum',
        DateTime(2026, 11, 2, 12, 0), DateTime(2026, 11, 2, 13, 0)),
    TimetableAppointment(
        type: TimetableAppointmentType.lunchBreak,
        begin: DateTime(2026, 11, 2, 13, 0),
        end: DateTime(2026, 11, 2, 14, 0)),
    ap('Advanced Mathematics I (Group 2)', 3, '20.40 Neuer Hörsaal',
        DateTime(2026, 11, 2, 15, 45), DateTime(2026, 11, 2, 17, 15)),
  ];

Future<void> pumpView(WidgetTester tester,
    {required bool showNowLine}) async {
  await tester.pumpWidget(MaterialApp(
    home: MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => KITProvider()),
        ChangeNotifierProvider(create: (c) => SettingsProvider(context: c)),
        ChangeNotifierProvider(create: (_) => TutorialManager()),
      ],
      child: Scaffold(
        body: SizedBox(
            height: 700,
            child: TimetableDailyView(
                tt: monday(), showNowLine: showNowLine)),
      ),
    ),
  ));
  await tester.pump();
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    NowClock.timeSource = () => fake;
    NowClock.debugPublish(fake);
  });
  tearDown(() => NowClock.timeSource = DateTime.now);

  testWidgets('assembly: running chip, no text overflow', (tester) async {
    await pumpView(tester, showNowLine: true);

    expect(tester.takeException(), isNull,
        reason: 'no overflow/assembly errors');
    expect(find.textContaining('läuft · bis 11:15'), findsOneWidget,
        reason: 'running lecture shows agenda-idiom chip');
    expect(find.textContaining('MITTAGSPAUSE'), findsNothing,
        reason: 'lunch renders localized, not raw title');
    expect(find.textContaining('Mittagspause'), findsOneWidget);
  });

  testWidgets('row tap opens sheet WITH now-line overlay', (tester) async {
    await pumpView(tester, showNowLine: true);
    await tester.tap(find.textContaining('Engineering Mechanics I'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(tester.takeException(), isNull);
    expect(find.byType(TimetableAppointmentPage), findsOneWidget,
        reason: 'opaque full-row target must open the sheet even under '
            'the now-line overlay');
  });

  testWidgets('row tap opens sheet WITHOUT overlay', (tester) async {
    await pumpView(tester, showNowLine: false);
    await tester.tap(find.textContaining('Engineering Mechanics I'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.byType(TimetableAppointmentPage), findsOneWidget);
  });

  testWidgets('rows render chronologically despite appended personal event',
      (tester) async {
    // real-world shape: template claims the generic slots in place, the
    // imported 10:00 appointment lands at the END of the list - the grid
    // used to paint it below the 15:45 lecture
    final d = monday()
      ..appointments.add(
          ap('Zwischentermin Klinik', 9, '54.11', DateTime(2026, 11, 2, 10, 0),
              DateTime(2026, 11, 2, 11, 0)));
    await tester.pumpWidget(MaterialApp(
      home: MultiProvider(
        providers: [
          ChangeNotifierProvider(create: (_) => KITProvider()),
          ChangeNotifierProvider(create: (c) => SettingsProvider(context: c)),
          ChangeNotifierProvider(create: (_) => TutorialManager()),
        ],
        child: Scaffold(
            body: SizedBox(
                height: 900,
                child: TimetableDailyView(tt: d, showNowLine: false))),
      ),
    ));
    await tester.pump();

    double top(String needle) =>
        tester.getTopLeft(find.textContaining(needle, findRichText: true)).dy;
    expect(top('Engineering Mechanics I'), lessThan(top('Zwischentermin')),
        reason: '9:45 lecture above the appended 10:00');
    expect(top('Zwischentermin'), lessThan(top('Advanced Mathematics I')),
        reason: '10:00 above the 15:45 lecture it used to trail');
  });
}
