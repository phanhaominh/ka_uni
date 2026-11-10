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
import 'package:kit_mobile/timetable/models/webcal.dart';
import 'package:kit_mobile/timetable/pages/timetable_appointment_page.dart';
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

final fake = DateTime(2026, 11, 2, 10, 5);

TimetableDaily monday() => TimetableDaily(weekday: Weekday.monday)
  ..appointments = [
    ap(
        'Engineering Mechanics I (Lecture)(V), Langhoff et al., MACH',
        1,
        '10.91 Franz-Grashof-Hörsaal',
        DateTime(2026, 11, 2, 9, 45),
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

Future<void> pumpView(WidgetTester tester, {required bool showNowLine}) async {
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
            child: TimetableDailyView(tt: monday(), showNowLine: showNowLine)),
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
      ..appointments.add(ap('Zwischentermin Klinik', 9, '54.11',
          DateTime(2026, 11, 2, 10, 0), DateTime(2026, 11, 2, 11, 0)));
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

  testWidgets(
      'future carousel page sorts by time-of-day across mixed '
      'date stamps', (tester) async {
    // the reported Thu-5.11 breakage: model rows carry mixed DATES -
    // feed lectures stamped with their real occurrence date, the lunch row
    // with "today" - and a full-DateTime compare floated 13:00 Lunch of
    // Nov 2 above the 08:00 lecture of Nov 5
    final thursday = TimetableDaily(weekday: Weekday.thursday)
      ..appointments = [
        TimetableAppointment(
            type: TimetableAppointmentType.lunchBreak,
            begin: DateTime(2026, 11, 2, 13, 0),
            end: DateTime(2026, 11, 2, 14, 0))
          ..title = '—',
        ap('Advanced Mathematics I (Lecture)', 4, '31.6 Hörsaalgebäude',
            DateTime(2026, 11, 5, 8, 0), DateTime(2026, 11, 5, 9, 30)),
        ap('Tutorial: Materials Science', 5, '30.40',
            DateTime(2026, 11, 5, 9, 45), DateTime(2026, 11, 5, 11, 15)),
        ap('Materials Science and Engineering I', 6, '10.30',
            DateTime(2026, 11, 5, 11, 30), DateTime(2026, 11, 5, 13, 0)),
      ];
    await tester.pumpWidget(MaterialApp(
      home: MultiProvider(
        providers: [
          ChangeNotifierProvider(create: (_) => KITProvider()),
          ChangeNotifierProvider(create: (c) => SettingsProvider(context: c)),
          ChangeNotifierProvider(create: (_) => TutorialManager()),
        ],
        child: Scaffold(
            body: SizedBox(
                height: 1000,
                child: TimetableDailyView(tt: thursday, showNowLine: false))),
      ),
    ));
    await tester.pump();

    double top(String needle) =>
        tester.getTopLeft(find.textContaining(needle, findRichText: true)).dy;
    expect(top('Advanced Mathematics I'),
        lessThan(top('Materials Science and Engineering I')),
        reason: '08:00 before 11:30 regardless of stamp dates');
    expect(top('Tutorial: Materials Science'), lessThan(top('Mittagspause')),
        reason: '09:45 before the Nov-2-stamped 13:00 lunch');
  });

  testWidgets('free chip names the real gap; day-edge voids are trimmed',
      (tester) async {
    TimetableAppointment emptySlot(int h1, int m1, int h2, int m2) =>
        TimetableAppointment(
            begin: DateTime(2026, 11, 3, h1, m1),
            end: DateTime(2026, 11, 3, h2, m2))
          ..title = '—';
    final d = TimetableDaily(weekday: Weekday.tuesday)
      ..appointments = [
        ap('Engineering Mechanics I', 1, '10.91', DateTime(2026, 11, 3, 9, 45),
            DateTime(2026, 11, 3, 11, 15)),
        emptySlot(11, 30, 13, 0),
        TimetableAppointment(
            type: TimetableAppointmentType.lunchBreak,
            begin: DateTime(2026, 11, 3, 13, 0),
            end: DateTime(2026, 11, 3, 14, 0)),
        emptySlot(14, 0, 15, 30),
        ap('Advanced Mathematics I', 2, '31.6', DateTime(2026, 11, 3, 15, 0),
            DateTime(2026, 11, 3, 16, 30)),
        // trailing scaffold after the last lecture: pure void, must vanish
        emptySlot(18, 0, 19, 30),
      ];
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

    // EM really ends 11:15 -> 1:45 free, though the 11:30 scaffold spans
    // only 1:30; lunch->15:00 is a real 1:00 though the scaffold spans 1:30
    expect(find.textContaining('1:45'), findsOneWidget,
        reason: 'chip reports the real gap, not the placeholder span');
    expect(find.textContaining('1:00'), findsOneWidget);
    expect(find.textContaining('1:30'), findsNothing,
        reason: 'trailing void trimmed: no third scaffold chip');
  });

  testWidgets('adjacent classes leave no phantom band; a gap run counts ONCE',
      (tester) async {
    TimetableAppointment emptySlot(int h1, int m1, int h2, int m2) =>
        TimetableAppointment(
            begin: DateTime(2026, 11, 2, h1, m1),
            end: DateTime(2026, 11, 2, h2, m2))
          ..title = '—';
    final d = TimetableDaily(weekday: Weekday.monday)
      ..appointments = [
        ap('Algorithms', 1, '50.20', DateTime(2026, 11, 2, 8, 0),
            DateTime(2026, 11, 2, 9, 0)),
        // scaffold placeholder sitting between two classes that touch at
        // 09:00: it used to fall back to its 90-min default span and open
        // an invisible void between the neighbours
        emptySlot(9, 0, 10, 30),
        ap('Thermodynamics A', 2, '54.11', DateTime(2026, 11, 2, 9, 0),
            DateTime(2026, 11, 2, 10, 30)),
        // one real 3:00 gap spread over TWO scaffold placeholders: only
        // the last row of the run may claim it (was: every placeholder
        // counted the same 180 minutes, tripling the band and squashing
        // the fit-factor for the whole day)
        emptySlot(10, 30, 12, 0),
        emptySlot(12, 0, 13, 30),
        ap('Mechanics B', 3, '10.91', DateTime(2026, 11, 2, 13, 30),
            DateTime(2026, 11, 2, 15, 0)),
      ];
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
                child: TimetableDailyView(tt: d, showNowLine: false))),
      ),
    ));
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.textContaining(' · 3:00'), findsOneWidget,
        reason: 'zero-gap placeholder dropped AND the run emits exactly '
            'one chip, not one per placeholder (localized word differs by '
            'locale, the time suffix does not)');
    // the touch pair must be flush: Thermodynamics' top edge sits exactly
    // on Algorithms' bottom edge (one 1px seam between the boxes)
    final a = tester.getRect(find.text('08:00'));
    final b = tester.getRect(find.text('09:00'));
    expect(b.top - a.bottom, lessThan(90),
        reason: 'no invisible 90-min band between adjacent classes');
  });

  testWidgets('cross-midnight row shows the running chip over its span',
      (tester) async {
    // personal ICS 22:00→02:00: _spanMin commits a 90-minute block, but the
    // raw wall endMin (02:00 = 120) lies below every evening minute, so the
    // raw compare never let the "läuft · bis" chip show although the row
    // visibly runs - the chip must use the span the layout committed to
    final night = DateTime(2026, 11, 2, 22, 30);
    NowClock.timeSource = () => night;
    NowClock.debugPublish(night);
    final d = TimetableDaily(weekday: Weekday.monday)
      ..appointments = [
        ap('Nachtshift (ICS)', 7, '54.11', DateTime(2026, 11, 2, 22, 0),
            DateTime(2026, 11, 3, 2, 0)),
      ];
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
                child: TimetableDailyView(tt: d, showNowLine: true))),
      ),
    ));
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.textContaining('läuft · bis 02:00'), findsOneWidget,
        reason: '22:30 lies inside the rendered 90-min block');
  });

  testWidgets('ghost card scales into its short gap box', (tester) async {
    // a lecture cancelled 9:40→10:00 leaves a 20-min gap = 18 px; the struck
    // title + 'Entfällt' line measure ~45 px, and the old unclipped Column
    // painted RenderFlex overflow stripes over BOTH neighbouring lectures
    TimetableAppointment emptySlot(int h1, int m1, int h2, int m2) =>
        TimetableAppointment(
            begin: DateTime(2026, 11, 2, h1, m1),
            end: DateTime(2026, 11, 2, h2, m2))
          ..title = '—';
    final d = TimetableDaily(weekday: Weekday.monday)
      ..appointments = [
        ap('Konstruktion I (Lecture)', 1, '10.91', DateTime(2026, 11, 2, 8, 0),
            DateTime(2026, 11, 2, 9, 40)),
        emptySlot(9, 45, 11, 15),
        ap('Rechnungswesen (Tutorial)', 2, '54.11',
            DateTime(2026, 11, 2, 10, 0), DateTime(2026, 11, 2, 11, 0)),
      ];
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
              tt: d,
              changes: [
                IcsChange(
                    kind: IcsChangeKind.removed,
                    title: 'Gestrichene Vorlesung',
                    when: DateTime(2026, 11, 2, 9, 45),
                    room: ''),
              ],
            ),
          ),
        ),
      ),
    ));
    await tester.pump();
    expect(tester.takeException(), isNull,
        reason: 'the ~45px ghost content must scale down into the 18px box, '
            'not overflow-report over both neighbours');
    expect(find.textContaining('Gestrichene Vorlesung'), findsOneWidget);
    expect(find.textContaining('Entfällt'), findsOneWidget);
  });

  testWidgets('free-gap chip only names gaps that hold a text line',
      (tester) async {
    // a 15-min gap measures 13.5 px - less than one bodySmall line - and
    // Center does not clip, so the chip used to straddle the seam hairline;
    // it is now SUPPRESSED below one line height, shown for real gaps
    TimetableAppointment emptySlot(int h1, int m1, int h2, int m2) =>
        TimetableAppointment(
            begin: DateTime(2026, 11, 2, h1, m1),
            end: DateTime(2026, 11, 2, h2, m2))
          ..title = '—';
    Future<void> pumpGap({required int prevEnd, required int next}) async {
      final d = TimetableDaily(weekday: Weekday.monday)
        ..appointments = [
          ap('Englisch I (Lecture)', 1, '10.91', DateTime(2026, 11, 2, 8, 0),
              DateTime(2026, 11, 2).add(Duration(minutes: prevEnd))),
          emptySlot(0, prevEnd + 5, 0, prevEnd + 95),
          ap(
              'Datenbanken (Lecture)',
              2,
              '54.11',
              DateTime(2026, 11, 2).add(Duration(minutes: next)),
              DateTime(2026, 11, 2).add(Duration(minutes: next + 60))),
        ];
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
                  child: TimetableDailyView(tt: d, showNowLine: false))),
        ),
      ));
      await tester.pump();
      expect(tester.takeException(), isNull);
    }

    // 9:45 → 10:00 gap = 15 min = 13.5 px: too short for a whole line
    await pumpGap(prevEnd: 9 * 60 + 45, next: 10 * 60);
    expect(find.textContaining(' · '), findsNothing,
        reason: 'sub-line-height gap stays a bare seam, no straddling chip');

    // 9:00 → 11:30 gap = 150 min: roomy, the chip must name it as before
    await pumpGap(prevEnd: 9 * 60, next: 11 * 60 + 30);
    expect(find.textContaining(' · 2:30'), findsOneWidget,
        reason: 'a gap with room still names itself');
  });
}
