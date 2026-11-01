import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kit_mobile/l10n/l10n.dart';
import 'package:kit_mobile/module/models/module.dart';
import 'package:kit_mobile/parsing/models/hierarchic_table_row.dart';
import 'package:kit_mobile/settings/views/module_tree_debug_page.dart';
import 'package:kit_mobile/state_management/campus/campus_manager.dart';
import 'package:kit_mobile/student/student.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The diagnostic answers "is Advanced Mathematics I in the tree at all, and
/// what does CampusKIT print there?" on the device: every Studienverlauf row
/// at any level (the card admits rows by title, never by level), the feed
/// rule's hit marker and an admission verdict - shown, feed-miss,
/// duplicate-clash against an already admitted row, or placeholder-ghost.

HierarchicTableRow _row(String title, {int level = 4, int year = 0}) =>
    HierarchicTableRow(
      level: level,
      title: title,
      href: "https://cascampus.studium.kit.edu/campus/student/module.asp?id=1",
      type: "Modul",
      statusStr: "",
      grade: "",
      pointsAcquired: "",
      pointsMax: "",
    )..year = year;

/// Feed: the tutorial copy of Advanced Mathematics I and the Thermodynamics
/// lecture. Tree: a heading, a section heading, the fetched admitted AM1, an
/// off-feed module, the unfetched AM1 copy (ghost), the admitted-but-not-yet
/// -fetched Thermodynamics row and its unfetched second copy (clash).
CampusManager _seededManager() {
  final cm = CampusManager(Student.empty, () {});
  cm.enrolledLectureTitles = {
    CampusManager.lectureTitleKey("Advanced Mathematics I (Tutorial - Group 1)"),
    CampusManager.lectureTitleKey("Thermodynamics of Mechanical Engineers"),
  };

  final am1 = _row("Advanced Mathematics I");
  final thermo = _row("Thermodynamics of Mechanical Engineers");
  cm.moduleRows.addAll([
    _row("Module im Studienverlauf", level: 2),
    _row("Pflichtmodule", level: 3),
    am1,
    _row("Engineering Mechanics III"),
    _row("Advanced Mathematics I", year: 2026),
    thermo,
    _row("Thermodynamics of Mechanical Engineers", year: 2026),
  ]);
  cm.rowModules[am1.id] = KITModule()
    ..id = "csbr-${am1.id}"
    ..title = "Advanced Mathematics I"
    ..row = am1;
  // the card admits exactly these two: the fetched AM1 and the Thermodynamics
  // row whose page fetch simply has not landed yet
  cm.relevantModuleRowIDs = [am1.id, thermo.id];
  return cm;
}

Future<Map<String, Object?>> _prefsSnapshot() async {
  final prefs = await SharedPreferences.getInstance();
  return {for (final key in prefs.getKeys()) key: prefs.get(key)};
}

void main() {
  test("every row gets its feed, page and admission verdict", () {
    final entries = ModuleTreeDebugPage.entries(_seededManager());

    // every level is listed, headings included: card admission is a title
    // rule and never filters by level
    expect(entries.map((e) => e.level), [2, 3, 4, 4, 4, 4, 4]);
    expect(entries.map((e) => e.onFeed),
        [false, false, true, false, true, true, true]);
    // exactly one of the two AM1 copies has a fetched page, and so does no
    // other row
    expect(entries.map((e) => e.pageLoaded),
        [false, false, true, false, false, false, false]);
    expect(entries.map((e) => e.admitted),
        [false, false, true, false, false, true, false]);
    expect(entries.map((e) => e.reason), [
      ModuleTreeDebugReason.feedMiss, // the level-2 heading is no feed title
      ModuleTreeDebugReason.feedMiss, // "Pflichtmodule" is a section heading
      ModuleTreeDebugReason.shown, // the admitted, fetched AM1
      ModuleTreeDebugReason.feedMiss, // EM III is not on this semester's feed
      ModuleTreeDebugReason.placeholderGhost, // unfetched copy, fetched twin
      ModuleTreeDebugReason.shown, // admitted while its page is still pending
      ModuleTreeDebugReason.duplicateClash, // key already carried by the twin
    ]);
  });

  testWidgets("rows show level, dimming, check and rejection reason",
      (tester) async {
    final copied = <String>[];
    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == "Clipboard.setData") {
        copied.add((call.arguments as Map)["text"] as String);
      }
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));
    await tester.pumpWidget(
        MaterialApp(home: ModuleTreeDebugPage(campusManager: _seededManager())));

    expect(find.text("Modul-Baum (Debug)"), findsOneWidget);

    // heading rows are shown too - dimmed and marked, since nothing below
    // the module level can be a module
    expect(find.text("L2"), findsOneWidget);
    expect(find.text("(kein Modul)"), findsOneWidget);
    final outline =
        Theme.of(tester.element(find.text("L3"))).colorScheme.outline;
    expect(
        tester.widget<Text>(find.text("Module im Studienverlauf")).style?.color,
        outline);
    expect(tester.widget<Text>(find.text("Pflichtmodule")).style?.color,
        isNot(outline));

    // admitted rows carry the check, the rest their rejection cause
    expect(find.byIcon(CupertinoIcons.check_mark_circled_solid),
        findsNWidgets(2));
    expect(find.text("Thermodynamics of Mechanical Engineers"),
        findsNWidgets(2));
    expect(find.text("nicht auf dem Stundenplan"), findsNWidgets(3));
    expect(find.text("Platzhalter - geladene Karte vorhanden"), findsOneWidget);
    expect(find.text("Dublette - schon auf der Karte"), findsOneWidget);
    expect(find.text("(noch keine Seite geladen)"), findsNWidgets(6));

    // long-press anywhere on the row copies the title, so it can be pasted
    // into a bug report instead of retyped off a screenshot
    await tester.longPress(find.text("Engineering Mechanics III"));
    await tester.pump();

    expect(copied, ["Engineering Mechanics III"]);
    expect(find.textContaining("kopiert"), findsOneWidget);
  });

  testWidgets("a huge tree renders only the visible slice", (tester) async {
    // a tree can hold thousands of rows: eagerly building them all made
    // the page stutter - with a builder only viewport + cache extent build
    final cm = _seededManager();
    for (var i = 0; i < 400; i++) {
      cm.moduleRows.add(_row("Bulk Module $i"));
    }
    await tester.pumpWidget(
        MaterialApp(home: ModuleTreeDebugPage(campusManager: cm)));

    expect(find.text("Advanced Mathematics I"), findsNWidgets(2));
    expect(find.byType(GestureDetector).evaluate().length, lessThan(100));
  });

  testWidgets("the list is one snapshot taken when the page opened",
      (tester) async {
    final cm = _seededManager();
    await tester.pumpWidget(
        MaterialApp(home: ModuleTreeDebugPage(campusManager: cm)));

    // reopening the page re-reads; re-rendering the open page must not
    // re-run the per-row fuzzy feed matching for thousands of rows
    cm.moduleRows.add(_row("Late Addition"));
    await tester.pump();

    expect(find.text("Late Addition"), findsNothing);
    expect(find.text("Advanced Mathematics I"), findsNWidgets(2));
  });

  testWidgets("pumping and copying change no stored state", (tester) async {
    SharedPreferences.setMockInitialValues({"debug-purity-marker": "keep"});
    await tester.pumpWidget(MaterialApp(
        home: ModuleTreeDebugPage(campusManager: _seededManager())));
    final before = await _prefsSnapshot();

    await tester.longPress(find.text("Engineering Mechanics III"));
    await tester.pump();

    expect(await _prefsSnapshot(), before);
  });

  testWidgets("verdicts are localized too", (tester) async {
    await L10n.reload(prefOverride: "en");
    addTearDown(() => L10n.reload(prefOverride: "de"));

    await tester.pumpWidget(
        MaterialApp(home: ModuleTreeDebugPage(campusManager: _seededManager())));

    expect(find.text("Module tree (debug)"), findsOneWidget);
    expect(find.text("(not a module)"), findsOneWidget);
    expect(find.text("not on the timetable"), findsNWidgets(3));
    expect(find.text("placeholder - fetched card exists"), findsOneWidget);
    expect(find.text("duplicate - already on card"), findsOneWidget);
  });

  testWidgets("an unrun module tree says so instead of showing nothing",
      (tester) async {
    await tester.pumpWidget(MaterialApp(
        home: ModuleTreeDebugPage(
            campusManager: CampusManager(Student.empty, () {}))));

    expect(
        find.text("Noch kein Modul-Baum gelaufen – auf der Startseite ziehen"),
        findsOneWidget);
    expect(find.byIcon(CupertinoIcons.check_mark_circled_solid), findsNothing);
  });
}
