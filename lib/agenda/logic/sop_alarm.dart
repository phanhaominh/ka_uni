/// R33.5: the SOP EARLY WARNING. One cockpit row that speaks BEFORE the
/// semester's exams, when the ledger already shows a module at the edge of
/// the exam law: two recorded fails mean the NEXT fail is the third try
/// and ends the exam for good ("dritter Versuch", PO). After the sitting
/// is graded the ledger says it anyway - the whole value is the warning
/// window before it.
///
/// Pure logic: no context, no prefs, no l10n, injected `now` - exactly
/// like `cockpitPlan` it rides in.
library;

import '../../grades/models/grade_book.dart';
import '../../handbook/ampel.dart' show currentTerm;
import '../../handbook/handbook_data.dart' show HandbookModule, handbookKey;
import '../../parsing/models/hierarchic_table_row.dart';
import '../../state_management/campus/campus_manager.dart' show CampusManager;

/// The result shape: `cpFloor` is the sum of handbook CP over
/// ledger-PASSED modules (rounded once, here); `exposedModules` names the
/// modules two recorded fails away from a final fail that are
/// offered/registered right now (ledger wording - the ledger is the
/// evidence); `attemptsKnown` is false while the Studienverlauf tree is
/// unavailable, then `exposedModules` means "cannot tell", not "nobody".
typedef SopAlarm = ({
  int cpFloor,
  List<String> exposedModules,
  bool attemptsKnown,
});

/// Build the warning from the handbook catalogue, the deduplicated ledger
/// ([ledger] = `GradeBook.modules`) and the RAW Studienverlauf rows
/// ([rows] = `CampusManager.moduleRows` - the dedup keeps one entry per
/// title, so only the raw tree still shows every retake attempt).
/// [takingKeys] is `enrolledLectureTitles` (lectureTitleKey space, same
/// key the Ampel feeds as `takingKeys`).
///
/// Honesty rules (the wording this feeds is load-bearing):
///  * The CP line is a FLOOR ("mindestens/at least"): only modules the
///    ledger shows as PASSED and the handbook prices count; imported or
///    catalogue-unknown credits never inflate it, they just make it a
///    lower bound - so the sentence may never drop the hedge word.
///  * Pending rows never count as anything: an ungraded attempt is not a
///    fail and an ungraded module earns no CP (same rule as the Ampel).
///  * Exposure requires POSITIVE ledger evidence: two failing grade rows
///    for the same module title AND the module's current (deduplicated)
///    verdict still FAILED - a later pass supersedes the stale fails,
///    exactly like `GradeBook._supersedes`. A module the handbook does
///    not price cannot be shown as exposed: unknown CP must not become an
///    invented claim.
///  * The module must be (re)reachable NOW - offered in the current term
///    or on the current timetable - because "the next fail is fatal" is
///    only actionable while a next attempt is actually on the table.
///  * Without raw tree rows (attemptsKnown false) the attempt count is
///    UNKNOWN, not zero: the row then falls back to the CP floor line
///    alone and never claims nobody is exposed.
SopAlarm sopEarlyWarning({
  required List<HandbookModule> modules,
  required List<GradeEntry> ledger,
  required List<HierarchicTableRow> rows,
  Set<String> takingKeys = const {},
  required DateTime now,
}) {
  final byKey = {for (final m in modules) m.titleKey: m};

  // CP floor: handbook prices × ledger passes, both sides through the
  // shared handbookKey normalizer (typographic dashes fold, the Ampel's
  // matching rule). A ledger pass the handbook does not list adds 0 and
  // makes the floor honest-but-incomplete, never wrong - hence
  // "mindestens".
  var cp = 0.0;
  final verdict = <String, GradeState>{};
  for (final g in ledger) {
    final key = handbookKey(g.title);
    if (key.isEmpty) continue;
    verdict[key] = g.state; // dedup already resolved supersedes
    if (g.state == GradeState.passed) cp += byKey[key]?.ects ?? 0;
  }

  final exposed = <String>[];
  if (rows.isNotEmpty) {
    // Failing grade rows per module title. The tree lists every attempt
    // under the module title (that is why GradeBook dedups at all), so
    // two FAIL rows for one title are two recorded fails. Levels 1/2 are
    // the degree row and section headings, not attempts.
    final fails = <String, int>{};
    for (final r in rows) {
      if (r.level < 3) continue;
      final key = handbookKey(r.title);
      if (key.isEmpty || !_fails(r.grade)) continue;
      fails[key] = (fails[key] ?? 0) + 1;
    }
    final term = currentTerm(now);
    for (final e in fails.entries) {
      if (e.value < 2) continue;
      // a recorded later pass ends the saga - only a still-FAILED
      // verdict keeps the third-attempt cascade alive
      if (verdict[e.key] != GradeState.failed) continue;
      final m = byKey[e.key];
      if (m == null) continue; // unknown CP/offer: never invent exposure
      final reachableNow = m.terms.contains(term) ||
          takingKeys.contains(CampusManager.lectureTitleKey(m.title));
      if (!reachableNow) continue;
      exposed.add(m.title);
    }
    exposed.sort();
  }

  return (
    cpFloor: cp.round(),
    exposedModules: exposed,
    attemptsKnown: rows.isNotEmpty,
  );
}

/// A grade cell that POSITIVELY records a fail - the two FAIL branches of
/// `GradeBook._classify` mirrored over the raw cell: the word "nicht"
/// (checked BEFORE "bestanden": the failing string contains the passing
/// one, and cells arrive as scraped HTML) or a German decimal above 4.0
/// (which covers the numeric 5,0 FAIL that no word flags). Anything else
/// - empty, "bestanden", a mark <= 4.0 - is not evidence of a fail.
bool _fails(String rawCell) {
  final cell = rawCell
      .replaceAll(RegExp("&nbsp;", caseSensitive: false), " ")
      .replaceAll(RegExp(r"\s+"), " ")
      .trim();
  if (cell.toLowerCase().contains("nicht")) return true;
  final s = cell.replaceAll(RegExp(r"\s+"), "");
  final numeric = double.tryParse(s.replaceAll(",", "."));
  return numeric != null && numeric > 4.0;
}
