import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kit_mobile/agenda/logic/next_up.dart';
import 'package:kit_mobile/agenda/views/agenda_page.dart';
import 'package:kit_mobile/agenda/views/chronicle_page.dart';
import 'package:kit_mobile/agenda/views/room_change_line.dart';
import 'package:kit_mobile/l10n/l10n.dart';
import 'package:kit_mobile/state_management/kit_provider.dart';
import 'package:kit_mobile/timetable/models/webcal.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

String two(int n) => n.toString().padLeft(2, "0");

/// naive wall-time ICS stamp (the feed's format)
String icsStamp(DateTime d) => "${d.year}${two(d.month)}${two(d.day)}"
    "T${two(d.hour)}${two(d.minute)}${two(d.second)}";

String ev(String uid, DateTime start, DateTime end, String summary,
        String room) =>
    "BEGIN:VEVENT\r\nUID:$uid\r\n"
    "DTSTART:${icsStamp(start)}\r\nDTEND:${icsStamp(end)}\r\n"
    "SUMMARY:$summary\r\nLOCATION:$room\r\nEND:VEVENT\r\n";

String icsDoc(List<String> events) =>
    "BEGIN:VCALENDAR\r\nVERSION:2.0\r\n${events.join()}END:VCALENDAR\r\n";

/// the agenda's post-paint refetch tail arms the SignMeUp cold retry
/// (20 s fake sleep) and the ILIAS wait carries a 30 s timeout timer;
/// advance past BOTH without demanding frame quiescence so teardown finds
/// no pending timers (same helper shape as notification_deep_links_test)
Future<void> drainRefetchTail(WidgetTester tester) async {
  for (var i = 0; i < 40; i++) {
    await tester.pump(const Duration(seconds: 1));
  }
}

Future<void> pumpAgenda(WidgetTester tester,
    {String? ics,
    List<IcsChange> changes = const [],
    String? fetchedAt,
    required String marker,
    Size surface = const Size(800, 1200)}) async {
  tester.view.physicalSize = surface;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  SharedPreferences.setMockInitialValues({
    if (ics != null) "DATA_webcalIcsCache": ics,
    if (changes.isNotEmpty) "DATA_webcalChanges": IcsChange.encode(changes),
    if (fetchedAt != null) "DATA_webcalFetchedAt": fetchedAt,
  });
  await tester.pumpWidget(ChangeNotifierProvider<KITProvider>(
    create: (_) => KITProvider(),
    child: const MaterialApp(home: AgendaPage()),
  ));
  // bounded wait until the cache-driven rebuild landed (a marker inside
  // the rendered content proves it; avoids microtask-order flakiness)
  for (var i = 0;
      i < 10 && find.textContaining(marker).evaluate().isEmpty;
      i++) {
    await tester.pump();
  }
  await drainRefetchTail(tester);
  expect(find.textContaining(marker), findsWidgets,
      reason: "agenda never rendered the seeded content");
}

/// the R12 row-emphasis dot: the only tertiary CIRCLE container the page
/// draws is the one in [_dayRow]'s touched-row prefix
Finder emphasisDots(WidgetTester tester) {
  final scheme = Theme.of(tester.element(find.byType(AgendaPage))).colorScheme;
  return find.byWidgetPredicate((w) =>
      w is Container &&
      w.decoration is BoxDecoration &&
      (w.decoration! as BoxDecoration).shape == BoxShape.circle &&
      (w.decoration! as BoxDecoration).color == scheme.tertiary);
}

void main() {
  testWidgets(
      "empty today card names tomorrow, not a later date, when tomorrow has lectures",
      (tester) async {
    final now = DateTime.now();
    final tomorrow = DateTime(now.year, now.month, now.day + 1, 10);
    final later = DateTime(now.year, now.month, now.day + 3, 10);
    await pumpAgenda(tester,
        ics: icsDoc([
          ev("m1@kit", tomorrow, tomorrow.add(const Duration(hours: 1)),
              "Morgen V", "HS 30"),
          ev("s1@kit", later, later.add(const Duration(hours: 1)), "Später V",
              "HS 31"),
        ]),
        marker: "Morgen V");
    // `upcoming` only holds lectures AFTER tomorrow — the empty state
    // must still answer with the FIRST day that has lectures
    expect(find.text(L10n.t("agenda.noEventsUntil", [L10n.stamp(tomorrow)])),
        findsOneWidget);
    expect(find.text(L10n.t("agenda.noEventsUntil", [L10n.stamp(later)])),
        findsNothing);
  });

  testWidgets("room delta only decorates the lecture its title names",
      (tester) async {
    final now = DateTime.now();
    final a14 = DateTime(now.year, now.month, now.day, 14);
    await pumpAgenda(tester,
        ics: icsDoc([
          ev("a@kit", a14, a14.add(const Duration(hours: 2)), "Analysis I",
              "HS 104"),
          ev("b@kit", a14, a14.add(const Duration(minutes: 90)),
              "Linear Algebra", "HS 105"),
        ]),
        changes: [
          IcsChange(
              kind: IcsChangeKind.changed,
              title: "Analysis I",
              when: a14,
              room: "HS 999",
              oldRoom: "HS 104"),
        ],
        marker: "14:00–16:00  Analysis I");
    final delta = L10n.t("agenda.roomChangedTo", ["HS 104", "HS 999"]);
    // block-only matching marked BOTH parallel 14:00 lectures — the
    // wrong one would have walked the student to the wrong room
    expect(find.text(delta), findsOneWidget);
    expect(emphasisDots(tester), findsOneWidget);

    // and it sits on the Analysis row, not the parallel lecture
    final analysisRow = find
        .ancestor(
            of: find.text("14:00–16:00  Analysis I"),
            matching: find.byType(Column))
        .first;
    final linearRow = find
        .ancestor(
            of: find.text("14:00–15:30  Linear Algebra"),
            matching: find.byType(Column))
        .first;
    expect(find.descendant(of: analysisRow, matching: find.text(delta)),
        findsOneWidget);
    expect(find.descendant(of: linearRow, matching: find.text(delta)),
        findsNothing);
    expect(find.descendant(of: linearRow, matching: emphasisDots(tester)),
        findsNothing);
  });

  testWidgets("an added lecture named by the band gets the emphasis dot",
      (tester) async {
    final now = DateTime.now();
    final tm10 = DateTime(now.year, now.month, now.day + 1, 10);
    await pumpAgenda(tester,
        ics: icsDoc([
          ev("n1@kit", tm10, tm10.add(const Duration(hours: 1)), "Brückenkurs",
              "HS 5"),
        ]),
        changes: [
          IcsChange(
              kind: IcsChangeKind.added,
              title: "Brückenkurs",
              when: tm10,
              room: "HS 5"),
        ],
        marker: "Brückenkurs");
    // the R12 comment promised the dot for every delta the band shows;
    // blockKeys used to admit kind==changed only, so added rows sat quiet
    expect(emphasisDots(tester), findsOneWidget);
    // no room-delta line for an added kind ("Neu: …" has no arrow either)
    expect(find.textContaining("→"), findsNothing);
  });

  testWidgets(
      "a lecture that merely gains its first room shows no dangling arrow",
      (tester) async {
    final now = DateTime.now();
    final t16 = DateTime(now.year, now.month, now.day, 16);
    await pumpAgenda(tester,
        ics: icsDoc([
          ev("g@kit", t16, t16.add(const Duration(hours: 2)), "Seminar X",
              "HS 7"),
        ]),
        changes: [
          IcsChange(
              kind: IcsChangeKind.changed,
              title: "Seminar X",
              when: t16,
              room: "HS 7",
              oldRoom: ""),
        ],
        marker: "16:00–18:00  Seminar X");
    // the old render: " → HS 7" — an arrow out of nowhere
    expect(
        find.text(L10n.t("agenda.roomChangedTo", ["", "HS 7"])), findsNothing);
    expect(find.textContaining("→"), findsNothing);
    // the row is still marked (describe() shows it in the band too)
    expect(emphasisDots(tester), findsOneWidget);
  });

  testWidgets(
      "pending row wraps its text instead of overflowing beside the spinner",
      (tester) async {
    // empty cache -> both day cards show the pending row; the layout
    // must flex the Text (a ~70-char label overflowed a Pixel-3-class
    // width in the bare-Text shape)
    await pumpAgenda(tester,
        marker: L10n.t("agenda.timetableLoading"),
        surface: const Size(320, 700));
    final label = find.text(L10n.t("agenda.timetableLoading"));
    expect(label, findsWidgets);
    final row = tester.widget<Row>(
        find.ancestor(of: label, matching: find.byType(Row)).first);
    expect(row.children.whereType<Expanded>(), hasLength(1));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      "CHANGED band header truncates on narrow screens instead of overflowing",
      (tester) async {
    final now = DateTime.now();
    await pumpAgenda(tester,
        changes: [
          // exactly 6: the band renders only the NEWEST 6 deltas, so a
          // 7th would hide the marker row (the header count is the point
          // of this test, not the row list)
          for (var i = 0; i < 6; i++)
            IcsChange(
                kind: IcsChangeKind.changed,
                title: "Aenderung $i",
                when: now.add(Duration(days: 1 + i)),
                room: "10.3$i",
                oldRoom: "10.1$i"),
        ],
        marker: "Aenderung 0",
        surface: const Size(240, 900)); // Pixel-3-class minus, forces the clash
    final header = find.text(L10n.t("agenda.timetableChangedN", [6]));
    expect(header, findsOneWidget);
    final t = tester.widget<Text>(header);
    expect(t.maxLines, 1);
    expect(t.overflow, TextOverflow.ellipsis);
    expect(find.ancestor(of: header, matching: find.byType(Expanded)),
        findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets("hero strikes the old room when a fresh feed confirms the swap",
      (tester) async {
    final now = DateTime.now();
    final start = DateTime(now.year, now.month, now.day, now.hour, now.minute)
        .add(const Duration(hours: 3));
    await pumpAgenda(tester,
        ics: icsDoc([
          ev("h@kit", start, start.add(const Duration(hours: 1)), "Hero V",
              "HS 999"),
        ]),
        changes: [
          IcsChange(
              kind: IcsChangeKind.changed,
              title: "Hero V",
              when: start,
              room: "HS 999",
              oldRoom: "HS 104"),
        ],
        fetchedAt: now.toIso8601String(),
        marker: "Hero V");
    expect(find.byType(NextUpCard), findsOneWidget);
    final line = tester.widget<RoomChangeLine>(find.byType(RoomChangeLine));
    expect(line.delta.oldRoom, "HS 104");
    expect(line.delta.room, "HS 999");
  });

  testWidgets("a stale feed keeps the hero silent about the swap",
      (tester) async {
    final now = DateTime.now();
    final start = DateTime(now.year, now.month, now.day, now.hour, now.minute)
        .add(const Duration(hours: 3));
    await pumpAgenda(tester,
        ics: icsDoc([
          ev("h@kit", start, start.add(const Duration(hours: 1)), "Hero V",
              "HS 999"),
        ]),
        changes: [
          IcsChange(
              kind: IcsChangeKind.changed,
              title: "Hero V",
              when: start,
              room: "HS 999",
              oldRoom: "HS 104"),
        ],
        fetchedAt: now.subtract(const Duration(hours: 31)).toIso8601String(),
        marker: "Hero V");
    // the hero itself renders from the cache — only the struck-room CLAIM
    // needs a feed the 30 h freshness rule still vouches for
    expect(find.byType(NextUpCard), findsOneWidget);
    expect(find.byType(RoomChangeLine), findsNothing);
  });

  testWidgets("a swap about another occurrence leaves the hero untouched",
      (tester) async {
    final now = DateTime.now();
    final start = DateTime(now.year, now.month, now.day, now.hour, now.minute)
        .add(const Duration(hours: 3));
    await pumpAgenda(tester,
        ics: icsDoc([
          ev("h@kit", start, start.add(const Duration(hours: 1)), "Hero V",
              "HS 999"),
        ]),
        changes: [
          // right title, different occurrence
          IcsChange(
              kind: IcsChangeKind.changed,
              title: "Hero V",
              when: start.add(const Duration(days: 1)),
              room: "HS 999",
              oldRoom: "HS 104"),
          // right slot, different lecture
          IcsChange(
              kind: IcsChangeKind.changed,
              title: "Fremd V",
              when: start,
              room: "HS 999",
              oldRoom: "HS 104"),
        ],
        fetchedAt: now.toIso8601String(),
        marker: "Hero V");
    expect(find.byType(NextUpCard), findsOneWidget);
    expect(find.byType(RoomChangeLine), findsNothing);
  });

  testWidgets("the band footer opens the chronicle over the whole store",
      (tester) async {
    final now = DateTime.now();
    final cOld = IcsChange(
        kind: IcsChangeKind.removed,
        title: "Alt Entfall",
        when: DateTime(now.year, now.month, now.day - 5, 10),
        room: "HS 1");
    final cNew = IcsChange(
        kind: IcsChangeKind.changed,
        title: "Neu Raum",
        when: DateTime(now.year, now.month, now.day + 1, 10),
        room: "HS 9",
        oldRoom: "HS 8");
    await pumpAgenda(tester,
        changes: [cOld, cNew], marker: L10n.t("agenda.timetableChangedN", [1]));
    // the band filter (when>=today) keeps the past delta out of the band...
    expect(find.text(cOld.describe()), findsNothing);
    expect(find.text(L10n.t("timetable.olderChanges")), findsOneWidget);
    await tester.tap(find.text(L10n.t("timetable.olderChanges")));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    // ...the chronicle shows it anyway and states its own coverage (the
    // band keeps rendering below the pushed route — assert inside the
    // chronicle, not app-wide)
    final page = find.byType(ChroniclePage);
    expect(page, findsOneWidget);
    expect(find.text(L10n.t("timetable.chronicleTitle")), findsOneWidget);
    expect(find.text(L10n.t("timetable.chronicleCoverage")), findsOneWidget);
    expect(find.descendant(of: page, matching: find.text(cOld.describe())),
        findsOneWidget);
    expect(find.descendant(of: page, matching: find.text(cNew.describe())),
        findsOneWidget);
  });

  testWidgets("an all-fresh store hides the chronicle link", (tester) async {
    // R32 audit F7c: the band renders only `when >= today` deltas; with
    // NOTHING older in the store the "Ältere Änderungen" button opened a
    // chronicle showing exactly what the band already showed — a dead end
    // dressed as a link, so it must not render at all
    final now = DateTime.now();
    final cNew = IcsChange(
        kind: IcsChangeKind.changed,
        title: "Neu Raum",
        when: DateTime(now.year, now.month, now.day + 1, 10),
        room: "HS 9",
        oldRoom: "HS 8");
    await pumpAgenda(tester,
        changes: [cNew], marker: L10n.t("agenda.timetableChangedN", [1]));
    expect(find.text(cNew.describe()), findsOneWidget,
        reason: "the band itself stays up - only the chronicle link goes");
    expect(find.text(L10n.t("timetable.olderChanges")), findsNothing);
    expect(find.text(L10n.t("agenda.dismiss")), findsOneWidget,
        reason: "dismiss remains: the fresh band still needs an exit");
  });
}
