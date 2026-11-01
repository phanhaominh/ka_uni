import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kit_mobile/module/models/module.dart';
import 'package:kit_mobile/parsing/models/hierarchic_table_row.dart';
import 'package:kit_mobile/settings/views/module_tree_debug_page.dart';
import 'package:kit_mobile/state_management/campus/campus_manager.dart';
import 'package:kit_mobile/student/student.dart';

/// The diagnostic answers "is Advanced Mathematics I in the tree at all, and
/// what does CampusKIT print there?" on the device: every module-level
/// Studienverlauf row, whether the timetable-feed rule recognizes the title
/// (the very rule that fills the "current modules" card) and whether the
/// row's module page was ever fetched.

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

/// One section heading, one fetched match, one module that is not on the
/// feed, and the second copy of the matched module (never fetched).
CampusManager _seededManager() {
  final cm = CampusManager(Student.empty, () {});
  cm.enrolledLectureTitles = {
    CampusManager.lectureTitleKey("Advanced Mathematics I (Tutorial - Group 1)"),
  };

  final am1 = _row("Advanced Mathematics I");
  cm.moduleRows.addAll([
    _row("Module im Studienverlauf", level: 2),
    _row("Pflichtmodule", level: 3),
    am1,
    _row("Engineering Mechanics III"),
    _row("Advanced Mathematics I", year: 2026),
  ]);
  cm.rowModules[am1.id] = KITModule()
    ..id = "csbr-${am1.id}"
    ..title = "Advanced Mathematics I"
    ..row = am1;
  return cm;
}

void main() {
  test("the list is built from the tree with its feed and page flags", () {
    final entries = ModuleTreeDebugPage.entries(_seededManager());

    // level 2 is the profile/grade heading, not a module -> not listed
    expect(entries.map((e) => e.level), [3, 4, 4, 4]);
    expect(
        entries.map((e) => e.title),
        [
          "Pflichtmodule",
          "Advanced Mathematics I",
          "Engineering Mechanics III",
          "Advanced Mathematics I"
        ]);
    // only the titles the merged feed carries get a check; the section
    // heading and the later-semester module do not
    expect(entries.map((e) => e.onFeed), [false, true, false, true]);
    // exactly one of the two copies has a fetched page
    expect(entries.map((e) => e.pageLoaded), [false, true, false, false]);
  });

  testWidgets("rows show the level, the missing-page marker and the check",
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
    expect(find.text("Advanced Mathematics I"), findsNWidgets(2));
    expect(find.text("L3"), findsOneWidget);
    expect(find.text("(noch keine Seite geladen)"), findsNWidgets(3));
    expect(find.byIcon(CupertinoIcons.check_mark_circled_solid),
        findsNWidgets(2));

    // long-press anywhere on the row copies the title, so it can be pasted
    // into a bug report instead of retyped off a screenshot
    await tester.longPress(find.text("Engineering Mechanics III"));
    await tester.pump();

    expect(copied, ["Engineering Mechanics III"]);
    expect(find.textContaining("kopiert"), findsOneWidget);
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
