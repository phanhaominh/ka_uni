import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kit_mobile/grades/models/grade_book.dart';
import 'package:kit_mobile/handbook/ampel.dart';
import 'package:kit_mobile/handbook/handbook_data.dart';
import 'package:kit_mobile/parsing/models/hierarchic_table_row.dart';
import 'package:kit_mobile/state_management/campus/campus_manager.dart';

/// Wave D R26: the Schein-Ampel only may under-report, never inflate;
/// gates fire on POSITIVE ledger evidence only.
void main() {
  HandbookModule mod(String title,
          {double ects = 5,
          List<String> terms = const ["WS"],
          List<Map<String, dynamic>> parts = const []}) =>
      HandbookModule.fromJson({
        "code": "T-X-${title.hashCode}",
        "title": title,
        "ects": ects,
        "terms": terms,
        "examType": "written",
        "parts": parts,
        "gates": parts.isEmpty
            ? const []
            : [
                {
                  "requires": "prerequisite must be passed",
                  "edge": "p -> x",
                  "page": 78
                }
              ],
      });

  Handbook handbook(List<HandbookModule> ms) =>
      Handbook(version: "test", source: "test", modules: ms);

  HierarchicTableRow row(String title, String grade) => HierarchicTableRow(
      level: 3,
      title: title,
      href: "",
      type: "",
      statusStr: "",
      grade: grade,
      pointsAcquired: grade.isEmpty ? "" : "5",
      pointsMax: "5");

  GradeBook book(List<HierarchicTableRow> rows) => GradeBook.fromRows(rows,
      ectsAcquiredTotal: "0,0", avgMark: "");

  test("ledger drives passed/failed; unknown titles are planned", () {
    final plan = ampelPlan(
      handbook: handbook([
        mod("Analysis I"),
        mod("Mechanics II"),
        mod("Thermodynamics I"),
      ]),
      book: book([
        row("Analysis I", "1,3"),
        row("Mechanics II", "5,0"),
      ]),
      signupOpenKeys: {},
      takingKeys: {},
    );
    expect(plan.by(AmpelState.passed).single.module.title, "Analysis I");
    expect(plan.by(AmpelState.failed).single.module.title, "Mechanics II");
    expect(plan.by(AmpelState.planned).single.module.title,
        "Thermodynamics I");
  });

  test("feed keys decide in-progress; open signup outranks it", () {
    final taking = {
      CampusManager.lectureTitleKey("Analysis I"),
      CampusManager.lectureTitleKey("Mechanics II"),
    };
    final plan = ampelPlan(
      handbook: handbook([mod("Analysis I"), mod("Mechanics II")]),
      book: book([]),
      signupOpenKeys: {CampusManager.lectureTitleKey("Mechanics II")},
      takingKeys: taking,
    );
    expect(plan.by(AmpelState.inProgress).single.module.title, "Analysis I");
    expect(plan.by(AmpelState.signupOpen).single.module.title,
        "Mechanics II");
  });

  test("gate blocks only on a POSITIVELY failed prerequisite part", () {
    final amParts = [
      {
        "code": "P1",
        "title": "Advanced Mathematics I Prerequisite",
        "ects": 0,
        "type": "prerequisite",
        "attendsTo": "P1",
      }
    ];
    final plan = ampelPlan(
      handbook: handbook([
        mod("Advanced Mathematics I", ects: 7, parts: amParts),
      ]),
      book: book([row("Advanced Mathematics I Prerequisite", "nicht bestanden")]),
      signupOpenKeys: {},
      takingKeys: {},
    );
    final m = plan.all.single;
    expect(m.blockedBy, ["Advanced Mathematics I Prerequisite"]);

    // invisible prerequisite (never in the tree): must NOT shout
    final quiet = ampelPlan(
      handbook: handbook([
        mod("Advanced Mathematics I", ects: 7, parts: amParts),
      ]),
      book: book([]),
      signupOpenKeys: {},
      takingKeys: {},
    );
    expect(quiet.all.single.blockedBy, isEmpty);

    // passed prerequisite: gate cleared
    final cleared = ampelPlan(
      handbook: handbook([
        mod("Advanced Mathematics I", ects: 7, parts: amParts),
      ]),
      book: book([row("Advanced Mathematics I Prerequisite", "bestanden")]),
      signupOpenKeys: {},
      takingKeys: {},
    );
    expect(cleared.all.single.blockedBy, isEmpty);
  });

  test("term helpers + remaining", () {
    expect(currentTerm(DateTime(2026, 11, 12)), "WS");
    expect(currentTerm(DateTime(2026, 5, 1)), "SS");
    expect(otherTerm("WS"), "SS");
    final plan = ampelPlan(
      handbook: handbook([mod("Done"), mod("Todo", terms: ["SS"])]),
      book: book([row("Done", "2,0")]),
      signupOpenKeys: {},
      takingKeys: {},
    );
    expect(plan.remaining.map((m) => m.module.title), ["Todo"]);
    expect(plan.remaining.single.offeredIn("SS"), isTrue);
    expect(plan.remaining.single.offeredIn("WS"), isFalse);
  });

  test("shipped handbook asset satisfies the app contract", () {
    final raw = File("assets/mei/handbook_spo2024.json").readAsStringSync();
    final j = jsonDecode(raw) as Map<String, dynamic>;
    final modules = [
      for (final m in j["modules"] as List)
        HandbookModule.fromJson(Map<String, dynamic>.from(m as Map))
    ];
    expect(modules.length, greaterThan(60));
    // every gate cites a page; every part attends to a module code that
    // exists; every module has a usable key
    final codes = modules.map((m) => m.code).toSet();
    for (final m in modules) {
      expect(m.titleKey, isNotEmpty);
      // PDF page-number tokens must never be baked into catalogue titles
      // (extraction scrub): a contaminated title silently reads the
      // passed module as "planned" (ledger key mismatch) AND shows the
      // garbled string to the user
      expect(m.title, isNot(matches(RegExp(r"\.\s\d{2,3}\s"))),
          reason: "page artifact in title: ${m.title}");
      for (final g in m.gates) {
        expect(g.page, greaterThan(0), reason: "${m.code} gate page-less");
      }
      for (final p in m.parts) {
        expect(codes, contains(p.attendsTo),
            reason: "${p.code} attends to unknown ${p.attendsTo}");
      }
    }
    // the first-week courses the student actually has must be findable
    final keys = modules.map((m) => m.titleKey).toSet();
    for (final t in [
      "advanced mathematics i",
      "engineering mechanics i",
      "basics of manufacturing technology",
      "materials science i and ii",
    ]) {
      expect(keys, contains(t), reason: "missing $t");
    }
  });
}
