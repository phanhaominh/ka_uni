import 'package:flutter_test/flutter_test.dart';
import 'package:kit_mobile/grades/logic/grade_sim.dart';
import 'package:kit_mobile/grades/models/grade_book.dart';

/// R29: the grade simulator. Hand-computed weighted math, the exclusion
/// fences (pending/failed/5,0/bestanden), and the two "honest answers" -
/// divergence needs two numbers, neededFor returns null when nothing can
/// reach the target.
void main() {
  GradeEntry entry(
    String title, {
    GradeState state = GradeState.passed,
    String label = "",
    double? grade,
    double? ects,
  }) =>
      GradeEntry(
        title: title,
        state: state,
        gradeLabel: label,
        numericGrade: grade,
        moduleEcts: ects,
        level: 3,
        titleKey: title.toLowerCase(),
      );

  GradeEntry graded(String title, double grade, double ects) =>
      entry(title, label: grade.toString(), grade: grade, ects: ects);
  GradeEntry bestanden(String title, double ects) =>
      entry(title, label: "bestanden", ects: ects);
  GradeEntry open(String title, double ects) =>
      entry(title, state: GradeState.pending, ects: ects);
  GradeEntry failed5(String title, double ects) => entry(title,
      state: GradeState.failed, label: "5,0", grade: 5.0, ects: ects);

  test("ects-weighted mean, not the unweighted midpoint", () {
    final sim = simulate(
        entries: [graded("A", 1.0, 6), graded("B", 4.0, 12)],
        officialAverage: null);
    // (6*1.0 + 12*4.0) / 18 = 54/18 = 3.0, the naive midpoint would be 2.5
    expect(sim.selfAverage, 3.0);
    expect(sim.countedModules, 2);
    expect(sim.countedEcts, 18);
    expect(sim.passedEcts, 18);
  });

  test("the mean is normalized once - no 1.0999999999999999", () {
    // (3*1.0 + 3*1.2) / 6 folds to 1.0999999999999999 in binary
    final sim = simulate(
        entries: [graded("A", 1.0, 3), graded("B", 1.2, 3)],
        officialAverage: null);
    expect(sim.selfAverage, 1.1);
  });

  test("pending, failed and the numeric 5,0 never weigh in", () {
    final sim = simulate(
        entries: [
          graded("A", 1.0, 6),
          open("P", 5),
          failed5("F", 3), // numeric, yet state==failed - excluded
        ],
        officialAverage: null);
    expect(sim.selfAverage, 1.0);
    expect(sim.countedModules, 1);
    expect(sim.countedEcts, 6);
  });

  test("bestanden earns CP but carries no number to weigh", () {
    final sim = simulate(
        entries: [graded("A", 1.0, 6), bestanden("B", 3)],
        officialAverage: null);
    expect(sim.selfAverage, 1.0); // B is not in the mean...
    expect(sim.countedModules, 1);
    expect(sim.countedEcts, 6); // ...but its CP are earned credits
    expect(sim.passedEcts, 9);
  });

  test("empty ledger simulates to nulls and zeros without throwing", () {
    final sim = simulate(entries: [], officialAverage: null);
    expect(sim.selfAverage, isNull);
    expect(sim.officialAverage, isNull);
    expect(sim.countedModules, 0);
    expect(sim.countedEcts, 0);
    expect(sim.passedEcts, 0);
    expect(sim.divergesFromOfficial, isFalse);
    expect(sim.basisNote, "0 · 0");
  });

  test("whatIf swaps a retake into the counted average", () {
    final base = simulate(
        entries: [graded("A", 4.0, 6), graded("B", 4.0, 12)],
        officialAverage: null);
    expect(base.selfAverage, 4.0);
    expect(whatIf(base: base, replacing: graded("A", 4.0, 6), newGrade: 1.0),
        3.0); // (6*1.0 + 12*4.0)/18
  });

  test("whatIf adds a pending or failed module as passed", () {
    final base = simulate(entries: [graded("B", 4.0, 12)],
        officialAverage: null);
    expect(whatIf(base: base, replacing: open("A", 6), newGrade: 1.0), 3.0);
    // the recorded 5,0 fail is not counted; a passed retake supersedes it
    expect(
        whatIf(base: base, replacing: failed5("F", 12), newGrade: 1.0),
        2.5); // (12*1.0 + 12*4.0)/24 = 60/24
  });

  test("whatIf with a failing grade drops the module from the mean", () {
    final base = simulate(
        entries: [graded("A", 1.0, 6), graded("B", 4.0, 12)],
        officialAverage: null);
    expect(whatIf(base: base, replacing: graded("B", 4.0, 12), newGrade: 5.0),
        1.0); // 5,0 weighs nothing; only A remains
  });

  test("whatIf on an empty fold stays null", () {
    final base = simulate(entries: [], officialAverage: null);
    expect(whatIf(base: base, replacing: open("A", 0), newGrade: 1.0), isNull);
  });

  test("neededFor offers the worst sufficient grade, never above 4,0", () {
    final base = simulate(
        entries: [graded("A", 1.0, 6), graded("B", 4.0, 6)],
        officialAverage: null);
    final pending = open("C", 6);
    // (6*1.0 + 6*4.0 + 6*g)/18 <= 3.1  <=>  g <= 4.3 - but 4,3 does not
    // pass, so the answer caps at the worst real passing grade
    expect(neededFor(base: base, pending: pending, targetAverage: 3.1), 4.0);
    // (30 + 6g)/18 <= 2.5  <=>  g <= 2.5 - exact grid point
    expect(neededFor(base: base, pending: pending, targetAverage: 2.5), 2.5);
  });

  test("neededFor pins the 1,0 boundary and answers null beyond it", () {
    final base = simulate(entries: [graded("B", 4.0, 12)],
        officialAverage: null);
    final pending = open("A", 6);
    // (6*1.0 + 48)/18 = 3.0: exactly reachable at 1,0 only
    expect(neededFor(base: base, pending: pending, targetAverage: 3.0), 1.0);
    // below that even the best achievable grade misses - honest null
    expect(neededFor(base: base, pending: pending, targetAverage: 2.9), isNull);
  });

  test("neededFor is null when the module has no CP to move the mean", () {
    final base = simulate(entries: [graded("B", 4.0, 12)],
        officialAverage: null);
    expect(
        neededFor(
            base: base,
            pending: entry("A", state: GradeState.pending, ects: null),
            targetAverage: 1.5),
        isNull);
    expect(
        neededFor(
            base: base, pending: open("A", 0), targetAverage: 1.5),
        isNull);
  });

  test("divergence needs two numbers and a gap over 0,05", () {
    final sim = simulate(
        entries: [graded("A", 3.0, 6)], officialAverage: 2.5);
    expect(sim.selfAverage, 3.0);
    expect(sim.divergesFromOfficial, isTrue);
    // exactly 0,05 apart is not "more than" - no caution
    expect(
        simulate(entries: [graded("A", 3.0, 6)], officialAverage: 3.05)
            .divergesFromOfficial,
        isFalse);
    // missing numbers on either side never convict
    expect(simulate(entries: [graded("A", 3.0, 6)], officialAverage: null)
        .divergesFromOfficial, isFalse);
    expect(simulate(entries: [], officialAverage: 2.5).divergesFromOfficial,
        isFalse);
    // a raw "0,0" from CasCAMPUS means "none yet", not an average of zero
    final zeroed =
        simulate(entries: [graded("A", 3.0, 6)], officialAverage: 0.0);
    expect(zeroed.officialAverage, isNull);
    expect(zeroed.divergesFromOfficial, isFalse);
  });

  test("basisNote carries the counts, not a label", () {
    final sim = simulate(
        entries: [graded("A", 1.0, 6), graded("B", 4.0, 12)],
        officialAverage: null);
    expect(sim.basisNote, "2 · 18");
    expect(
        simulate(entries: [graded("A", 2.0, 7.5)], officialAverage: null)
            .basisNote,
        "1 · 7.5");
  });
}
