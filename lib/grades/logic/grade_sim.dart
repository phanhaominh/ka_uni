/// R29: THE GRADE SIMULATOR. Answers the two questions the ledger itself
/// cannot: "what is my average made of?" (ECTS-weighted, over the modules
/// that actually carry a grade) and "what would I need on the pending
/// module to land at X?".
///
/// Pure logic: no prefs, no context, no l10n - it returns numbers and the
/// UI writes the German sentence (same fence as ledger_diff).
///
/// Honesty rule of this file: the self-computed average never pretends to
/// be the official one. It is a PARTIAL figure by construction -
/// "bestanden"-style passes earn CP but have no number to weigh, modules
/// without CP cannot be weighted at all, and every pending or failed
/// module is absent until a grade lands. [GradeSim.divergesFromOfficial]
/// is the loud counterpart: when CasCAMPUS prints a different number, the
/// page raises the caution instead of the student trusting half a sum.
library;

import '../models/grade_book.dart';

/// One graded module that pulls its weight in the average. Carried on the
/// result so [whatIf]/[neededFor] can re-fold without the caller keeping
/// the entry list alive.
typedef _Weight = ({String titleKey, double grade, double ects});

/// The worst PASSING German grade. GradeBook._classify maps every numeric
/// above 4.0 to failed - a 5,0 IS numeric but earns nothing - so the real
/// average never weighs more than 4,0, and the simulator must not offer
/// more than 4,0 either.
const _maxPassingGrade = 4.0;

/// Best achievable grade; the grid [neededFor] walks starts here.
const _bestGrade = 1.0;

/// Comparison slack for values already [normalized] - it swallows binary
/// representation noise only, never a full tenth of a grade.
const _eps = 1e-9;

/// Round the mean once, HERE: products like 6 * 1.1 fold to
/// 3.3000000000000003 where the German system says exactly 3,3, and text,
/// divergence flags and threshold comparisons must never disagree about
/// which one it is (same fence as GradeBook rounding totalEcts). Four
/// decimals: finer than any official average, tight enough to kill noise.
double _normalize(double v) => double.parse(v.toStringAsFixed(4));

/// One-shot rounding for CP sums, mirroring `GradeBook.totalEcts`: a
/// displayed sum and a threshold must not straddle a float hairline.
double _roundCp(double v) => double.parse(v.toStringAsFixed(1));

/// The (partial) simulated state of the degree average.
class GradeSim {
  /// ECTS-weighted mean over [countedModules] graded-passing modules;
  /// null when nothing is weightable yet (first-semester ledger).
  final double? selfAverage;

  /// CasCAMPUS' own figure, verbatim (already 0-sanitized by the caller
  /// or here); null until the ledger reports one.
  final double? officialAverage;

  /// Modules that actually weigh in [selfAverage].
  final int countedModules;

  /// CP of exactly those modules - the denominator of the mean.
  final double countedEcts;

  /// ALL earned CP (GradeBook.passedEcts parity): includes
  /// "bestanden"-style passes and CP-less passes, which earn credits but
  /// carry no number to weigh.
  final double passedEcts;

  /// The weighted modules behind the mean - private payload so the fold
  /// in [_reFold] stays the single place the average is ever rebuilt.
  final List<_Weight> _weights;

  const GradeSim._({
    this.selfAverage,
    this.officialAverage,
    this.countedModules = 0,
    this.countedEcts = 0,
    this.passedEcts = 0,
    List<_Weight> weights = const [],
  }) : _weights = weights;

  /// True when the self-computed and the official average measurably
  /// disagree. Missing numbers on EITHER side never flag: "cannot compare"
  /// must not shout - only two present numbers that differ by more than
  /// [divergenceThreshold] convict the data. The UI shows its caution on
  /// true and labels the threshold; this logic file owns only the verdict.
  bool get divergesFromOfficial {
    final mine = selfAverage, theirs = officialAverage;
    if (mine == null || theirs == null) return false;
    return (mine - theirs).abs() > divergenceThreshold + _eps;
  }

  static const divergenceThreshold = 0.05;

  /// What the average is built on: `<modules> · <CP>` - counts only, in
  /// no language and not a localization key. The page owns its labels, so
  /// this can never drift into a static sentence that lies when the
  /// counts change.
  String get basisNote =>
      '$countedModules · ${countedEcts == countedEcts.roundToDouble() ? countedEcts.toStringAsFixed(0) : countedEcts.toStringAsFixed(1)}';
}

/// Fold the ledger into a simulator snapshot.
///
/// [entries] should be `GradeBook.modules` (already de-duplicated, so a
/// retake can never be double-weighted). A module weighs in only when it
/// would pull its weight in the real average: state passed (GradeBook
/// classifies every numeric > 4.0 - the 5,0 fail - and every "nicht
/// bestanden" as failed, so they never enter), a numeric grade (the
/// "bestanden"-style pass has no number to weigh), and real CP. The
/// numeric bounds are belt-and-braces for hand-built entries that skip
/// the classifier: a < 1.0 cell classifies as pending, never a grade.
GradeSim simulate({
  required List<GradeEntry> entries,
  required double? officialAverage,
}) {
  final weights = <_Weight>[];
  var earned = 0.0;
  for (final e in entries) {
    if (e.state != GradeState.passed) continue;
    earned += e.moduleEcts ?? 0;
    final grade = e.numericGrade;
    final ects = e.moduleEcts;
    if (grade == null ||
        grade < _bestGrade ||
        grade > _maxPassingGrade ||
        ects == null ||
        ects <= 0) {
      continue;
    }
    weights.add((titleKey: e.titleKey, grade: grade, ects: ects));
  }
  return GradeSim._(
    selfAverage: _mean(weights),
    // "0,0" from CasCAMPUS means "none yet", never an average of zero -
    // same sanitizing GradeBook applies to avgMark, so a raw 0.0 passed
    // here cannot fake a divergence.
    officialAverage:
        officialAverage != null && officialAverage > 0 ? officialAverage : null,
    countedModules: weights.length,
    countedEcts: _roundCp(weights.fold<double>(0, (s, w) => s + w.ects)),
    passedEcts: _roundCp(earned),
    weights: weights,
  );
}

/// The average if [replacing]'s grade became [newGrade].
///
/// The titleKey already weighs in -> its grade is SWAPPED (a retake result
/// replaces the recorded one). It does not (pending module, or a recorded
/// fail the student is re-sitting) -> the entry joins as a pass with its
/// own CP. A [newGrade] outside the passing 1,0-4,0 window does not weigh:
/// swapping a pass to 5,0 drops the module from the mean rather than
/// averaging a fail, because a failing grade has no business in an
/// average. Null when nothing weightable is left.
double? whatIf({
  required GradeSim base,
  required GradeEntry replacing,
  required double newGrade,
}) =>
    _reFold(base, replacing, newGrade);

/// The grade the pending module must deliver for the average to be at most
/// [targetAverage].
///
/// The answer is the WORST passing grade on the real 0.1 grid that still
/// reaches the target - "no worse than this" - which is what a student
/// means by "what do I need": anything better also works, finer than a
/// tenth no grade ever exists. The grid stops at 4,0, not 5,0: the promise
/// is the module PASSES with the offered grade, and > 4,0 fails (see
/// [_maxPassingGrade]). Null - the honest answer - when even a 1,0 misses
/// the target or the module has no CP and can therefore not move the
/// average at all.
double? neededFor({
  required GradeSim base,
  required GradeEntry pending,
  required double targetAverage,
  double step = 0.1,
}) {
  final ects = pending.moduleEcts;
  if (ects == null || ects <= 0 || step <= 0) return null;
  // Walk from the worst offerable grade DOWN; the mean grows monotonically
  // with the grade, so the first candidate that reaches the target is the
  // worst sufficient one. round (not floor): 3.0/0.1 folds to
  // 29.999999999999996 in binary, and floor would silently lose the 4,0
  // candidate. Candidates still past 4,0 are skipped outright.
  final steps = ((_maxPassingGrade - _bestGrade) / step).round();
  for (var i = steps; i >= 0; i--) {
    final grade = _normalize(_bestGrade + i * step);
    if (grade > _maxPassingGrade) continue;
    final mean = _reFold(base, pending, grade);
    if (mean != null && mean <= targetAverage + _eps) return grade;
  }
  return null; // even 1,0 does not reach it
}

/// The single fold: base weights minus [entry]'s old weight (swap), plus
/// [grade] if it is a passing one (swap back in, or fresh add).
double? _reFold(GradeSim base, GradeEntry entry, double grade) {
  var kept = <_Weight>[];
  double? swappedEcts;
  for (final w in base._weights) {
    if (entry.titleKey.isNotEmpty && w.titleKey == entry.titleKey) {
      swappedEcts = w.ects; // same module, keep its recorded CP
      continue;
    }
    kept.add(w);
  }
  if (grade >= _bestGrade && grade <= _maxPassingGrade) {
    final ects = swappedEcts ?? entry.moduleEcts ?? 0;
    if (ects > 0) {
      kept = [
        ...kept,
        (titleKey: entry.titleKey, grade: grade, ects: ects),
      ];
    }
  }
  return _mean(kept);
}

double? _mean(List<_Weight> weights) {
  var cp = 0.0, sum = 0.0;
  for (final w in weights) {
    cp += w.ects;
    sum += w.grade * w.ects;
  }
  return cp > 0 ? _normalize(sum / cp) : null;
}
