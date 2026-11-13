import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kit_mobile/exams/models/exam_list.dart';
import 'package:kit_mobile/exams/views/exams_page.dart';
import 'package:kit_mobile/geo/logic/maps_url.dart';
import 'package:kit_mobile/geo/models/kit_place.dart';
import 'package:kit_mobile/signmeup/signmeup_manager.dart';
import 'package:kit_mobile/state_management/kit_provider.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// R32 exam-card detail lines: the room→Maps Route handoff (R32.8), the
/// SignMeUp seats-filled sub-line on registration rows (R32.4) and the
/// deregistration-deadline chip (R32.3 UI). Cards are pumped through the
/// real ExamsPage with seeded provider state (agenda_page_test's harness
/// idiom); the seams `routeHandoff`/`seatsLine` pin the URL and wording
/// contracts without a launcher.

KITPlace geb3095() => KITPlace(
      id: "30.95",
      title: "Gebäude 30.95",
      positionList: const [
        ["49.0907", "8.4245"]
      ],
    );

/// a directory entry without a pin: Maps must get a search, never a
/// confidently wrong destination coordinate
KITPlace pinless() => KITPlace(id: "35.10", title: "Institut 35.10");

ExamEntry entry(
    {String title = "Testklausur",
    bool registered = false,
    ExamWindowStatus status = ExamWindowStatus.unknown,
    List<(String day, String time, String room)> terms = const [],
    DateTime? windowStart,
    DateTime? windowEnd}) {
  final e = ExamEntry(
      examNumber: "20.01",
      title: title,
      examiners: "Prof. X",
      examType: "Schriftliche Prüfung",
      registered: registered,
      windowStatus: status,
      windowStart: windowStart,
      windowEnd: windowEnd);
  for (final (day, time, room) in terms) {
    e.terms.add(ExamTerm(day, time, room));
  }
  return e;
}

/// ExamEntry carrying a deregistration deadline. NO @override annotation:
/// it must compile both before LANE N lands `DateTime? deregEnd` on
/// ExamEntry (then it merely declares a member) and after (then it
/// overrides the real field's getter).
class DeregExam extends ExamEntry {
  DeregExam(DateTime? dereg)
      : _dereg = dereg,
        super(
            examNumber: "20.01",
            title: "Abmeldeklausur",
            examiners: "Prof. X",
            examType: "Schriftliche Prüfung",
            registered: true,
            windowStatus: ExamWindowStatus.unknown);
  final DateTime? _dereg;
  DateTime? get deregEnd => _dereg;
}

/// Whether ExamEntry itself already answers `deregEnd` (LANE N landed) —
/// probed dynamically because LANE E's bridge extension is library-private
/// and shadows the [DeregExam] override from the card's static view until
/// the real field exists.
bool deregEndLanded() {
  final probe = entry(registered: true);
  try {
    (probe as dynamic).deregEnd;
    return true;
  } on NoSuchMethodError {
    return false;
  }
}

List<SignMeUpProcedure> fixtureProcedures() {
  final decoded =
      jsonDecode(File('test/fixtures/smuprocedures.json').readAsStringSync())
          as Map<String, dynamic>;
  return (decoded["procedures"] as List)
      .map((e) => SignMeUpProcedure.fromJson(e as Map<String, dynamic>))
      .toList();
}

Future<void> pumpExams(WidgetTester tester,
    {required List<ExamEntry> exams,
    List<KITPlace> places = const [],
    List<SignMeUpProcedure> procedures = const []}) async {
  tester.view.physicalSize = const Size(900, 1600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  SharedPreferences.setMockInitialValues({});
  final vm = KITProvider();
  vm.campusManager.examsLoaded = true;
  vm.campusManager.examsFetchedAt = DateTime.now();
  vm.campusManager.exams = exams;
  vm.topographyManager.places = places;
  vm.signMeUpManager.procedures = procedures;
  await tester.pumpWidget(ChangeNotifierProvider<KITProvider>(
    create: (_) => vm,
    child: const MaterialApp(home: ExamsPage()),
  ));
  // let the provider's fire-and-forget session/directory pings settle so
  // teardown finds no pending timers (agenda_page_test's drain)
  for (var i = 0; i < 40; i++) {
    await tester.pump(const Duration(seconds: 1));
  }
}

void main() {
  group("route handoff (R32.8)", () {
    test("resolved room with a pin becomes exact walking directions", () {
      final r = ExamsPage.routeHandoff([geb3095()], "Geb. 30.95, HS 1");
      expect(r?.room, "Geb. 30.95, HS 1");
      expect(r?.url, mapsDirectionsUrl(const LatLng(49.0907, 8.4245)));
    });

    test("resolved pin-less place goes to Maps as a search", () {
      final r = ExamsPage.routeHandoff([pinless()], "Geb. 35.10");
      expect(r?.url, mapsSearchUrl("Institut 35.10 KIT Karlsruhe"));
    });

    test("empty, unresolvable or online rooms certify nothing", () {
      expect(ExamsPage.routeHandoff([geb3095()], ""), isNull);
      expect(ExamsPage.routeHandoff([geb3095()], "   "), isNull);
      expect(ExamsPage.routeHandoff([], "Geb. 30.95, HS 1"), isNull);
      expect(ExamsPage.routeHandoff([geb3095()], "Online"), isNull);
      expect(ExamsPage.routeHandoff([geb3095()], "bei Prof. X"), isNull);
    });

    testWidgets('registered card offers one tappable Route line per room',
        (tester) async {
      await pumpExams(tester, places: [geb3095(), pinless()], exams: [
        entry(registered: true, terms: const [
          ("Di, 23.03.2027", "09:00 - 11:00", "Geb. 30.95, HS 1"),
          ("Fr, 26.06.2027", "09:00 - 11:00", "Geb. 30.95, HS 1"),
          ("Fr, 26.06.2027", "12:00 - 14:00", "Geb. 35.10"),
        ]),
      ]);
      expect(find.text("Geb. 30.95, HS 1 · Route"), findsOneWidget,
          reason: "two sittings in one room must yield ONE handoff line");
      expect(find.text("Geb. 35.10 · Route"), findsOneWidget);
      expect(
          find.ancestor(
              of: find.text("Geb. 30.95, HS 1 · Route"),
              matching: find.byType(InkWell)),
          findsOneWidget);
    });

    testWidgets('unresolvable room and online exams render no line, ever',
        (tester) async {
      await pumpExams(tester, places: [geb3095()], exams: [
        entry(title: "Onlineklausur", terms: const [
          ("Di, 23.03.2027", "09:00 - 11:00", "Online"),
        ]),
        entry(title: "Ohne Raumangabe"),
        entry(
            title: "Raum unbekannt",
            terms: const [
              ("Di, 23.03.2027", "09:00 - 11:00", "Geb. 99.99"),
            ]),
      ]);
      expect(find.textContaining("· Route"), findsNothing);
    });

    testWidgets('a cancelled sitting gets no Route line', (tester) async {
      await pumpExams(tester, places: [geb3095()], exams: [
        entry(terms: const [
          ("Mo, 02.03.2027 entfällt", "10:00 - 12:00", "Geb. 30.95, HS 1"),
        ]),
      ]);
      expect(find.textContaining("· Route"), findsNothing);
    });

    testWidgets('tapping the Route line survives a missing Maps app',
        (tester) async {
      await pumpExams(tester, places: [geb3095()], exams: [
        entry(registered: true, terms: const [
          ("Di, 23.03.2027", "09:00 - 11:00", "Geb. 30.95, HS 1"),
        ]),
      ]);
      await tester.tap(find.text("Geb. 30.95, HS 1 · Route"));
      await tester.pump(); // the launcher error is contained, not thrown
    });
  });

  group("seats sub-line (R32.4)", () {
    test('live procedure fixture: fill line, allocation joined word-split',
        () {
      final procs = fixtureProcedures();
      expect(
          ExamsPage.seatsLine(
              procs, "Detectors for Particle and Astroparticle Physics"),
          "17/30 belegt · First Come First Served");
      expect(ExamsPage.seatsLine(procs, "Lernmotivation verstehen und fördern"),
          "1/20 belegt · Manual");
    });

    test('placesNumber 0 or absent means unknown, never a fill line', () {
      final procs = fixtureProcedures();
      // 148 registrations, but no announced places: honesty over noise
      expect(ExamsPage.seatsLine(procs, "Tutorium HMI Physik"), isNull);
      expect(ExamsPage.seatsLine(procs, "Particle Physics I"), isNull);
    });

    test('matching is case/whitespace tolerant but never fuzzy', () {
      final procs = fixtureProcedures();
      expect(
          ExamsPage.seatsLine(
              procs, "  detectors for particle and ASTROPARTICLE physics "),
          isNotNull);
      // the I/II trap: a different procedure must never lend its seats
      expect(ExamsPage.seatsLine(procs, "Particle Physics II"), isNull);
      expect(ExamsPage.seatsLine([], "CAE-Workshop"), isNull);
      expect(ExamsPage.seatsLine(fixtureProcedures(), ""), isNull);
    });

    testWidgets('matching exam card renders the fill sub-line',
        (tester) async {
      await pumpExams(tester, procedures: fixtureProcedures(), exams: [
        entry(
            title: "Detectors for Particle and Astroparticle Physics",
            status: ExamWindowStatus.open,
            windowStart: DateTime.now().subtract(const Duration(days: 1)),
            windowEnd: DateTime.now().add(const Duration(days: 7))),
        entry(title: "Tutorium HMI Physik"),
      ]);
      expect(find.text("17/30 belegt · First Come First Served"),
          findsOneWidget);
      expect(find.textContaining("148"), findsNothing);
      expect(find.textContaining(RegExp(r"\d+/\d+ belegt")), findsOneWidget);
    });

    testWidgets('exam without a matching procedure shows no fill line',
        (tester) async {
      await pumpExams(tester, procedures: fixtureProcedures(), exams: [
        entry(title: "ganz normale Prüfung"),
      ]);
      expect(find.textContaining(RegExp(r"\d+/\d+ belegt")), findsNothing);
    });
  });

  group("deregistration chip (R32.3)", () {
    // the two positive chip assertions stay skipped until LANE N lands the
    // real ExamEntry.deregEnd field (see deregEndLanded) — they then run
    // automatically, no test edit needed
    final landed = deregEndLanded();

    testWidgets('registered exam without a deadline shows no chip',
        (tester) async {
      await pumpExams(tester, exams: [entry(registered: true)]);
      expect(find.textContaining("abmelden bis"), findsNothing);
    });

    testWidgets('an expired deregistration deadline never renders live',
        (tester) async {
      await pumpExams(tester,
          exams: [DeregExam(DateTime.now().subtract(const Duration(days: 2)))]);
      expect(find.textContaining("abmelden bis"), findsNothing);
    });

    testWidgets('a live deregistration deadline renders the muted chip',
        (tester) async {
      await pumpExams(tester,
          exams: [DeregExam(DateTime.now().add(const Duration(days: 5)))]);
      final chipText = find.textContaining("abmelden bis");
      expect(chipText, findsOneWidget);
      expect(find.ancestor(of: chipText, matching: find.byType(Chip)),
          findsOneWidget);
      // register-by tier: quiet outline while there is runway …
      final scheme =
          Theme.of(tester.element(find.byType(ExamsPage))).colorScheme;
      expect(tester.widget<Text>(chipText).style?.color, scheme.outline);
      expect(find.text("angemeldet"), findsOneWidget,
          reason: "the status chip stays; the deadline joins its row");
    }, skip: !landed);

    testWidgets('runway under three days turns the chip error-colored',
        (tester) async {
      await pumpExams(tester,
          exams: [DeregExam(DateTime.now().add(const Duration(hours: 30)))]);
      final chipText = find.textContaining("abmelden bis");
      expect(chipText, findsOneWidget);
      final scheme =
          Theme.of(tester.element(find.byType(ExamsPage))).colorScheme;
      expect(tester.widget<Text>(chipText).style?.color, scheme.error);
    }, skip: !landed);
  });
}
