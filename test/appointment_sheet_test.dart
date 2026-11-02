// The detail panel's contract, decided by the UI review fleet and the
// user: details readable on ARRIVAL (no drag tax), one-tap collapse/
// expand via the header chevron, and the Route CTA attached to the sheet
// (never floating over content). These tests pin exactly that behavior.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kit_mobile/geo/models/kit_place.dart';
import 'package:kit_mobile/settings/providers/settings_provider.dart';
import 'package:kit_mobile/state_management/kit_provider.dart';
import 'package:kit_mobile/timetable/models/timetable_appointment.dart';
import 'package:kit_mobile/timetable/pages/timetable_appointment_page.dart';
import 'package:kit_mobile/tutorials/data/tutorial_manager.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

TimetableAppointment _lecture() =>
    TimetableAppointment(
        begin: DateTime(2026, 11, 2, 9, 45),
        end: DateTime(2026, 11, 2, 11, 15))
      ..title = "Engineering Mechanics I (Lecture) (V), Langhoff"
      ..id = "3161010"
      ..place = (KITPlace()..title = "10.91 Franz-Grashof-Hörsaal");

TimetableAppointment _lunch() => TimetableAppointment(
        type: TimetableAppointmentType.lunchBreak,
        begin: DateTime(2026, 11, 2, 13, 0),
        end: DateTime(2026, 11, 2, 14, 0));

Future<void> _pump(WidgetTester tester, TimetableAppointment ap) async {
  tester.view.physicalSize = const Size(600, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    home: MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => KITProvider()),
        ChangeNotifierProvider(create: (c) => SettingsProvider(context: c)),
        ChangeNotifierProvider(create: (_) => TutorialManager()),
      ],
      child: TimetableAppointmentPage(appointment: ap),
    ),
  ));
  // placeData resolves in a microtask when dataUrl is empty; let the
  // FutureBuilder land before measuring anything
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 60));
}

double _sheetHeight(WidgetTester tester) =>
    tester.getSize(find.byType(BackdropFilter)).height;

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  // locale-free handles: the CTA is found by its icon, the room by value
  final route = find.byIcon(Icons.directions);
  final roomRow = find.textContaining("10.91 Franz-Grashof-Hörsaal");
  testWidgets("opens EXPANDED: room and Route visible without dragging",
      (tester) async {
    await _pump(tester, _lecture());

    expect(roomRow, findsOneWidget);
    expect(route, findsOneWidget);
    // inside the sheet's painted area = actually readable, not merely
    // laid out below the clip (the old 0.2 initial size failed this)
    final sheetBottom = tester.getRect(find.byType(BackdropFilter)).bottom;
    expect(tester.getRect(route).bottom, lessThanOrEqualTo(sheetBottom));
    expect(tester.getRect(roomRow).bottom, lessThanOrEqualTo(sheetBottom));
  });

  testWidgets("chevron collapses to peek and re-expands", (tester) async {
    await _pump(tester, _lecture());
    final openHeight = _sheetHeight(tester);
    expect(openHeight, greaterThan(400), reason: "starts near 0.55 of 900");

    await tester.tap(find.byIcon(Icons.expand_more));
    await tester.pumpAndSettle();
    final peekHeight = _sheetHeight(tester);
    expect(peekHeight, lessThan(openHeight * 0.6));

    // collapsed state keeps room AND CTA genuinely visible (the whole
    // point of putting them first) - not just present-but-clipped
    expect(route, findsOneWidget);
    final sheetTop = 900 - peekHeight;
    expect(tester.getRect(route).bottom, lessThanOrEqualTo(900));
    expect(tester.getRect(route).top, greaterThanOrEqualTo(sheetTop));

    await tester.tap(find.byIcon(Icons.expand_less));
    await tester.pumpAndSettle();
    expect(_sheetHeight(tester), greaterThan(openHeight * 0.9));
  });

  testWidgets("place-less appointment shows no Route button", (tester) async {
    await _pump(tester, _lunch());
    expect(route, findsNothing);
    // ...but the panel itself still works
    expect(find.byIcon(Icons.expand_more), findsOneWidget);
  });
}
