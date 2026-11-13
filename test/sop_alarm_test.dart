import 'package:flutter_test/flutter_test.dart';
import 'package:kit_mobile/agenda/logic/sop_alarm.dart';
import 'package:kit_mobile/grades/models/grade_book.dart';
import 'package:kit_mobile/handbook/handbook_data.dart';
import 'package:kit_mobile/l10n/l10n.dart';
import 'package:kit_mobile/parsing/models/hierarchic_table_row.dart';
import 'package:kit_mobile/state_management/campus/campus_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// R33.5: the SOP early-warning cockpit row's logic. Fixtures are raw
/// Studienverlauf trees fed through the REAL GradeBook dedup, so the
/// "two recorded fails" claim is pinned against the same view the app
/// computes elsewhere - and the honesty cases (pending never counts,
/// unknown attempts never invent exposure) fail loudly if loosened.
void main() {
  final now = DateTime(2026, 11, 13, 9); // a Friday in WS

  HandbookModule mod(String title, double ects,
          {List<String> terms = const ["WS"]}) =>
      HandbookModule(
          code: "T-ME-$title",
          title: title,
          ects: ects,
          terms: terms,
          examType: "Klausur",
          parts: const [],
          gates: const []);

  final handbook = [
    mod("Analysis 1", 6),
    mod("Mechanik I", 6),
    mod("Thermodynamik", 6),
    mod("Strömungslehre", 6, terms: ["SS"]),
  ];

  HierarchicTableRow row(String title, String grade, {int level = 3}) =>
      HierarchicTableRow(
          level: level,
          title: title,
          href: "https://example/$title",
          type: "Modul",
          statusStr: "",
          grade: grade,
          pointsAcquired: "",
          pointsMax: "6,0");

  GradeBook book(List<HierarchicTableRow> rows) =>
      GradeBook.fromRows(rows, ectsAcquiredTotal: "0,0", avgMark: "");

  SopAlarm warn(List<HierarchicTableRow> rows,
          {Set<String> takingKeys = const {}}) =>
      sopEarlyWarning(
          modules: handbook,
          ledger: book(rows).modules,
          rows: rows,
          takingKeys: takingKeys,
          now: now);

  test("passed modules floor the CP count; no fails, no exposure", () {
    final a = warn([
      row("Analysis 1", "1,0"),
      row("Mechanik I", "bestanden"),
      row("Thermodynamik", ""), // pending: never CP, never a fail
      row("Brückenkurs Mathe", "1,3"), // passed but not in the handbook
      row("Abschnitt", "0", level: 2), // heading, not a module
    ]);
    expect(a.attemptsKnown, isTrue);
    expect(a.cpFloor, 12,
        reason: "only handbook-priced passes count - the floor "
            "under-reports imported credit, it never inflates");
    expect(a.exposedModules, isEmpty);
  });

  test("two recorded fails on a module offered now are exposure", () {
    final a = warn([
      row("Analysis 1", "1,0"),
      row("Thermodynamik", "5,0"),
      row("Thermodynamik", "4,5"), // 4,0 would already be "ausreichend"
    ]);
    expect(a.cpFloor, 6);
    expect(a.exposedModules, ["Thermodynamik"]);
  });

  test("the scraped string fail cell counts too", () {
    // CampusKIT renders e.g. "nicht bestanden (2. Versuch)" - the word
    // "nicht" must be checked BEFORE "bestanden" it contains
    final a = warn([
      row("Thermodynamik", "nicht bestanden (1. Versuch)"),
      row("Thermodynamik", "5,0"),
    ]);
    expect(a.exposedModules, ["Thermodynamik"]);
  });

  test("one fail is not exposure, a later pass cancels two", () {
    final single = warn([
      row("Thermodynamik", "5,0"),
      row("Analysis 1", "2,0"),
    ]);
    expect(single.exposedModules, isEmpty);

    final retaken = warn([
      row("Thermodynamik", "5,0"),
      row("Thermodynamik", "4,5"),
      row("Thermodynamik", "3,0"), // the passed retake supersedes
    ]);
    expect(retaken.exposedModules, isEmpty,
        reason: "the ledger's CURRENT verdict is passed - the saga ended, "
            "warning about a fatal next attempt would be a lie");
    expect(retaken.cpFloor, 6);
  });

  test("exposure requires the module to be reachable now", () {
    final twoFails = [
      row("Strömungslehre", "5,0"),
      row("Strömungslehre", "5,0"),
    ];
    // SS-only module in WS, not on the timetable: no next attempt on the
    // table, so the row stays silent
    expect(warn(twoFails).exposedModules, isEmpty);
    // re-registered on the current timetable: actionable again
    expect(
        warn(twoFails,
                takingKeys: {CampusManager.lectureTitleKey("Strömungslehre")})
            .exposedModules,
        ["Strömungslehre"]);
  });

  test("a two-fail module the handbook does not price is never exposed", () {
    final a = warn([
      row("Exotenmodul", "5,0"),
      row("Exotenmodul", "5,0"),
    ]);
    expect(a.exposedModules, isEmpty,
        reason: "no CP, no offer list, no PO claim from unknown data");
  });

  test("without tree rows attempts are UNKNOWN, not zero", () {
    // rows cleared but a ledger snapshot survives: the honest output is
    // the CP floor alone - the caller must never render "all clear"
    final a = sopEarlyWarning(
        modules: handbook,
        ledger: [
          const GradeEntry(
              title: "Analysis 1",
              state: GradeState.passed,
              gradeLabel: "1,0",
              numericGrade: 1.0,
              moduleEcts: 6,
              level: 3,
              titleKey: "analysis 1"),
        ],
        rows: const [],
        now: now);
    expect(a.attemptsKnown, isFalse);
    expect(a.exposedModules, isEmpty);
    expect(a.cpFloor, 6,
        reason: "the CP line stays computable, so the row degrades to "
            "the \u201cat least\u201d line alone instead of vanishing honest info");
  });

  test("hedge wording is locked in both languages", () async {
    // registered BEFORE the flip: the reset used to sit after the expects,
    // so a failing expect left _language='en' for the rest of the isolate
    // and silently re-language every later L10n assertion; addTearDown
    // runs the reset on the failure path too
    addTearDown(() async {
      SharedPreferences.setMockInitialValues({});
      await L10n.reload();
    });
    // de is the default effective language
    expect(L10n.t("agenda.sopWarnCp", [30]), "Mindestens 30 LP errungen");
    expect(L10n.t("agenda.sopWarnExposed", ["Thermodynamik"]),
        contains("laut Prüfungsledger"));
    expect(L10n.t("agenda.sopWarnExposed", ["Thermodynamik"]),
        contains("dritten Versuch"));
    SharedPreferences.setMockInitialValues({L10n.languagePrefKey: "en"});
    await L10n.reload();
    expect(L10n.t("agenda.sopWarnCp", [30]), "At least 30 CP earned");
    expect(L10n.t("agenda.sopWarnExposed", ["Thermodynamik"]),
        contains("per the grades ledger"));
  });
}
