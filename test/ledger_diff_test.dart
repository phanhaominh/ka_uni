import 'package:flutter_test/flutter_test.dart';
import 'package:kit_mobile/grades/logic/ledger_diff.dart';
import 'package:kit_mobile/grades/models/grade_book.dart';

// Entries are built directly: the diff is pure computation over the
// already-classified modules, so no HTML fixtures are involved here.
GradeEntry _entry(String title,
        {GradeState state = GradeState.pending, String gradeLabel = ""}) =>
    GradeEntry(
      title: title,
      state: state,
      gradeLabel: gradeLabel,
      numericGrade: null,
      moduleEcts: 5,
      level: 3,
      titleKey: title.toLowerCase(),
    );

GradeEntry _graded(String title, String label,
        {GradeState state = GradeState.passed}) =>
    _entry(title, state: state, gradeLabel: label);

void main() {
  test("first run seeds silently: 30 graded rows, empty previous, ZERO events",
      () {
    // DOCTRINE, pinned loudly: a snapshot-less first fetch is the SEED run.
    // A fresh install legitimately sees 30+ already-graded modules; firing
    // "grade published" for each would announce months of old news in one
    // storm and burn the student's trust in the channel forever.
    final tree = [
      for (var i = 0; i < 30; i++) _graded("Modul $i", "${1 + (i % 4)},0"),
    ];
    expect(ledgerDiff(now: tree, previous: const {}), isEmpty);
  });

  test("pending -> graded is the publication itself, not a change", () {
    final previous = ledgerSnapshot([_entry("Analysis 1")]);
    final events = ledgerDiff(
      now: [_graded("Analysis 1", "1,3")],
      previous: previous,
    );
    expect(events.single.titleKey, "analysis 1");
    expect(events.single.state, GradeState.passed);
    expect(events.single.gradeLabel, "1,3");
    expect(events.single.changed, isFalse);
  });

  test("retake landing on a graded cell is CHANGED (5,0 -> 1,3)", () {
    final previous =
        ledgerSnapshot([_graded("Analysis 1", "5,0", state: GradeState.failed)]);
    final events = ledgerDiff(
      now: [_graded("Analysis 1", "1,3")],
      previous: previous,
    );
    expect(events.single.changed, isTrue);
    expect(events.single.gradeLabel, "1,3");
    expect(events.single.state, GradeState.passed);
  });

  test("pending -> pending is silence", () {
    final previous = ledgerSnapshot([_entry("Thermodynamik A")]);
    final events = ledgerDiff(
      now: [_entry("Thermodynamik A")],
      previous: previous,
    );
    expect(events, isEmpty);
  });

  test("a row vanishing from the fetch is NOT an announcement", () {
    // silence about disappearing rows: the tree renders partially while
    // CasCAMPUS reloads; pushing "grade removed?" on every glitch would be
    // a false alarm.
    final previous = ledgerSnapshot([
      _graded("Algorithmen und Datenstrukturen", "2,0"),
      _entry("Betriebssysteme"),
    ]);
    final events = ledgerDiff(
      now: [_graded("Algorithmen und Datenstrukturen", "2,0")],
      previous: previous,
    );
    expect(events, isEmpty);
  });

  test("double-listed retake copies dedup last-wins and never re-fire", () {
    // The raw tree lists the pending attempt first, the graded attempt
    // second (chronological). If the snapshot kept the FIRST copy, every
    // fetch would "publish" the graded copy again - a phantom push on
    // refresh after refresh. Same entries as previous AND now must diff to
    // nothing, whatever the tree's double-listing looks like.
    final tree = [
      _entry("Analysis 2"),
      _graded("Analysis 2", "4,0"),
    ];
    expect(ledgerDiff(now: tree, previous: ledgerSnapshot(tree)), isEmpty);
    expect(ledgerSnapshot(tree)["analysis 2"], "passed|4,0");
  });

  test("a genuinely new module fires once the snapshot is seeded", () {
    // the seed doctrine must not swallow the real signal: second fetch,
    // one never-seen titleKey
    final previous = ledgerSnapshot([_graded("Analysis 1", "1,3")]);
    final events = ledgerDiff(
      now: [_graded("Analysis 1", "1,3"), _entry("Datenbanken")],
      previous: previous,
    );
    expect(events.single.titleKey, "datenbanken");
    expect(events.single.changed, isFalse);
  });

  test("untitled rows never key the snapshot or the diff", () {
    final untitled = GradeEntry(
      title: "  ",
      state: GradeState.passed,
      gradeLabel: "1,0",
      numericGrade: 1.0,
      moduleEcts: null,
      level: 3,
      titleKey: "",
    );
    expect(ledgerSnapshot([untitled]), isEmpty);
    final previous = ledgerSnapshot([_entry("Diskrete Mathematik")]);
    final events = ledgerDiff(
      now: [untitled, _entry("Diskrete Mathematik")],
      previous: previous,
    );
    expect(events, isEmpty);
  });

  test("snapshot keeps the grade label verbatim, comma and all", () {
    final snap = ledgerSnapshot([
      _graded("Numerische Verfahren", "5,0", state: GradeState.failed),
      _graded("Softskills", "bestanden"),
      _entry("Kolloquium"),
    ]);
    expect(snap, {
      "numerische verfahren": "failed|5,0",
      "softskills": "passed|bestanden",
      "kolloquium": "pending|",
    });
  });
}
