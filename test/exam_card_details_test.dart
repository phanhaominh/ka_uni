import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kit_mobile/exams/models/exam_list.dart';
import 'package:kit_mobile/exams/views/exams_page.dart';
import 'package:kit_mobile/geo/logic/maps_url.dart';
import 'package:kit_mobile/geo/models/kit_place.dart';
import 'package:kit_mobile/state_management/kit_provider.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// R32 exam-card detail lines: the room→Maps Route handoff (R32.8) and the
/// deregistration-deadline chip (R32.3 UI). Cards are pumped through the
/// real ExamsPage with seeded provider state (agenda_page_test's harness
/// idiom); the seam `routeHandoff` pins the URL contract without a launcher.

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

/// a seating hall whose five pool rooms all resolve to THIS one building
KITPlace hoersaal2021() => KITPlace(
      id: "20.21",
      title: "Gebäude 20.21",
      positionList: const [
        ["49.0944", "8.4310"]
      ],
    );

ExamEntry entry(
    {String title = "Testklausur",
    bool registered = false,
    ExamWindowStatus status = ExamWindowStatus.unknown,
    List<(String day, String time, String room)> terms = const [],
    DateTime? windowStart,
    DateTime? windowEnd,
    DateTime? deregEnd}) {
  final e = ExamEntry(
      examNumber: "20.01",
      title: title,
      examiners: "Prof. X",
      examType: "Schriftliche Prüfung",
      registered: registered,
      windowStatus: status,
      windowStart: windowStart,
      windowEnd: windowEnd,
      deregEnd: deregEnd);
  for (final (day, time, room) in terms) {
    e.terms.add(ExamTerm(day, time, room));
  }
  return e;
}

Future<void> pumpExams(WidgetTester tester,
    {required List<ExamEntry> exams,
    List<KITPlace> places = const []}) async {
  tester.view.physicalSize = const Size(900, 1600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  SharedPreferences.setMockInitialValues({});
  final vm = KITProvider();
  vm.campusManager.examsLoaded = true;
  vm.campusManager.examsFetchedAt = DateTime.now();
  vm.campusManager.exams = exams;
  vm.topographyManager.places = places;
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
          reason: "two sittings under one seating key must yield ONE "
              "handoff line - and no (+N), it is still a single key");
      expect(find.text("Geb. 35.10 · Route"), findsOneWidget);
      final row = find.ancestor(
          of: find.text("Geb. 30.95, HS 1 · Route"),
          matching: find.byType(InkWell));
      expect(row, findsOneWidget);
      expect(tester.getSize(row).height, greaterThanOrEqualTo(44),
          reason: "touch target: Material's 44 dp floor, the ~25 dp row "
              "was too small to hit reliably");
    });

    testWidgets(
        'five pool seating keys resolving to one building render ONE row',
        (tester) async {
      // the real 20.21 case: Pool A..E are five cascampus seating keys for
      // one building - five identical Rows told the student nothing new
      // five times
      await pumpExams(tester, places: [hoersaal2021(), geb3095()], exams: [
        entry(registered: true, terms: const [
          ("Di, 23.03.2027", "09:00 - 11:00", "20.21 Pool A"),
          ("Di, 23.03.2027", "09:00 - 11:00", "20.21 Pool B"),
          ("Di, 23.03.2027", "09:00 - 11:00", "20.21 Pool C"),
          ("Di, 23.03.2027", "09:00 - 11:00", "20.21 Pool D"),
          ("Di, 23.03.2027", "09:00 - 11:00", "20.21 Pool E"),
          ("Fr, 26.06.2027", "09:00 - 11:00", "Geb. 30.95, HS 1"),
        ]),
      ]);
      expect(find.text("20.21 Pool A (+4) · Route"), findsOneWidget,
          reason: "URL-keyed dedupe: first key labels, 4 further keys "
              "collapse into the (+4) suffix");
      // no second row for the pooled building, and the distinct building
      // still renders its own row
      expect(find.textContaining(" · Route"), findsNWidgets(2));
      expect(find.textContaining("Pool B (+"), findsNothing);
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

  group("deregistration chip (R32.3)", () {
    testWidgets('registered exam without a deadline shows no chip',
        (tester) async {
      await pumpExams(tester, exams: [entry(registered: true)]);
      expect(find.textContaining("abmelden bis"), findsNothing);
    });

    testWidgets('an expired deregistration deadline never renders live',
        (tester) async {
      await pumpExams(tester,
          exams: [
            entry(
                registered: true,
                deregEnd: DateTime.now().subtract(const Duration(days: 2)))
          ]);
      expect(find.textContaining("abmelden bis"), findsNothing);
    });

    testWidgets('a live deregistration deadline renders the muted chip',
        (tester) async {
      await pumpExams(tester,
          exams: [
            entry(
                registered: true,
                deregEnd: DateTime.now().add(const Duration(days: 5)))
          ]);
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
    });

    testWidgets('runway under three days turns the chip error-colored',
        (tester) async {
      await pumpExams(tester,
          exams: [
            entry(
                registered: true,
                deregEnd: DateTime.now().add(const Duration(hours: 30)))
          ]);
      final chipText = find.textContaining("abmelden bis");
      expect(chipText, findsOneWidget);
      final scheme =
          Theme.of(tester.element(find.byType(ExamsPage))).colorScheme;
      expect(tester.widget<Text>(chipText).style?.color, scheme.error);
    });
  });
}
