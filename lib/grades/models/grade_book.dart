import '../../parsing/models/hierarchic_table_row.dart';
import '../../state_management/campus/campus_manager.dart';

enum GradeState { passed, failed, pending }

/// One de-duplicated module row of the Studienverlauf, classified for display.
class GradeEntry {
  final String title;
  final GradeState state;

  /// Cleaned grade cell as shown ("1,3", "bestanden", ...); empty for pending.
  final String gradeLabel;

  /// German-decimal value of the grade cell; null when not numeric
  /// (covers both "bestanden"-style strings and a 5,0 FAIL, which IS numeric).
  final double? numericGrade;
  final double? moduleEcts;
  final int level;
  final String titleKey;

  const GradeEntry({
    required this.title,
    required this.state,
    required this.gradeLabel,
    required this.numericGrade,
    required this.moduleEcts,
    required this.level,
    required this.titleKey,
  });
}

/// Read-only model over CampusManager.moduleRows: the Studienverlauf tree
/// flattened into deduplicated module entries plus the SOP progress math.
///
/// Pure computation on already-fetched rows - no scraping, no state.
class GradeBook {
  GradeBook.fromRows(
    List<HierarchicTableRow> rows, {
    required String ectsAcquiredTotal,
    required String avgMark,
  }) {
    // Exact-titleKey dedup: the tree double-lists a module under two
    // section headings with the SAME title, and lists every retake attempt
    // under the module's title. The loose feed matcher
    // (moduleKeysDenoteSameModule) is deliberately NOT used here: it
    // swallows "Brückenkurs Analysis 1" into "Analysis 1" - a distinct
    // module whose credits would vanish - and swapping a graded retake into
    // the pending copy's slot mutates that key mid-pass, so rows already
    // checked against the old key collide non-transitively with the new one.
    final seenAt = <String, int>{}; // titleKey -> index in _modules
    for (final row in rows) {
      // levels 1/2 are the degree row and section headings, not modules
      if (row.level < 3) continue;
      final entry = _classify(row);
      final slot = entry.titleKey.isEmpty ? null : seenAt[entry.titleKey];
      if (slot == null) {
        if (entry.titleKey.isNotEmpty) {
          seenAt[entry.titleKey] = _modules.length;
        }
        _modules.add(entry);
      } else if (_supersedes(entry, _modules[slot])) {
        _modules[slot] = entry;
      }
    }
    for (final m in _modules) {
      switch (m.state) {
        case GradeState.passed:
          _passed.add(m);
        case GradeState.failed:
          _failed.add(m);
        case GradeState.pending:
          _pending.add(m);
      }
    }
    passedEcts =
        _passed.fold<double>(0, (sum, m) => sum + (m.moduleEcts ?? 0));
    // CasCAMPUS reports the official total; "0,0"/unparseable means none yet.
    // Trust it as 0 EXCEPT when modules with real ECTS are already passed -
    // a first-semester tree legitimately has earned credits before the total
    // row catches up. Degree-row cells go through the same cleaning as every
    // other cell (campus_manager stores pointsAcquired raw).
    final parsedTotal = _parseGermanDecimal(_cleanCell(ectsAcquiredTotal));
    final raw = parsedTotal != null && parsedTotal > 0
        ? parsedTotal
        : (passedEcts > 0 ? passedEcts : 0);
    // Round once, HERE: 9.2+10.6+10.2 folds to 29.999999999999996, which the
    // page renders "30,0" while a raw threshold still says not reached -
    // text, progress bar and sopReached must never disagree (ECTS values
    // are integers/halves, one decimal never loses a real value).
    totalEcts = double.parse(raw.toStringAsFixed(1));
    final parsedAvg = _parseGermanDecimal(_cleanCell(avgMark));
    average = parsedAvg != null && parsedAvg > 0 ? parsedAvg : null;
  }

  final List<GradeEntry> _modules = [];
  final List<GradeEntry> _passed = [];
  final List<GradeEntry> _failed = [];
  final List<GradeEntry> _pending = [];

  List<GradeEntry> get modules => List.unmodifiable(_modules);
  List<GradeEntry> get passed => List.unmodifiable(_passed);
  List<GradeEntry> get failed => List.unmodifiable(_failed);
  List<GradeEntry> get pending => List.unmodifiable(_pending);

  late final double passedEcts;
  late final double totalEcts;
  late final double? average;

  /// Studienorientierungsprüfung proxy: 30 CP must be visible by then.
  static const double sopTarget = 30.0;

  double get sopProgress => (totalEcts / sopTarget).clamp(0.0, 1.0);
  bool get sopReached => totalEcts >= sopTarget;

  /// A later same-key row replaces an earlier one when it carries a grade
  /// where there was none (the double-listed copy usually has it) or when it
  /// passed a previously failed attempt: the Studienverlauf lists attempts
  /// chronologically, so a retake must supersede its stale failure - the
  /// alternative permanently shows "failed" with the earned CP missing.
  /// A recorded pass is never demoted.
  static bool _supersedes(GradeEntry later, GradeEntry earlier) {
    switch (earlier.state) {
      case GradeState.pending:
        return later.state != GradeState.pending;
      case GradeState.failed:
        return later.state == GradeState.passed;
      case GradeState.passed:
        return false;
    }
  }

  static GradeEntry _classify(HierarchicTableRow row) {
    final title = _cleanCell(row.title);
    final grade = _cleanCell(row.grade);
    final lowered = grade.toLowerCase();
    final numeric = _parseGermanDecimal(grade);
    // "nicht" BEFORE "bestanden": the failing string contains the passing one.
    final GradeState state;
    if (lowered.contains("nicht")) {
      state = GradeState.failed;
    } else if (numeric != null) {
      state = numeric > 4.0
          ? GradeState.failed
          : (numeric >= 1.0 ? GradeState.passed : GradeState.pending);
    } else if (lowered.contains("bestanden")) {
      state = GradeState.passed;
    } else {
      state = GradeState.pending;
    }
    return GradeEntry(
      title: title,
      state: state,
      gradeLabel: state == GradeState.pending
          ? ""
          : (numeric != null ? grade.replaceAll(RegExp(r"\s+"), "") : grade),
      numericGrade: numeric,
      moduleEcts: _parseGermanDecimal(_cleanCell(row.pointsMax)),
      level: row.level,
      titleKey: CampusManager.lectureTitleKey(title),
    );
  }

  /// Mirrors campus_manager cleanCell (layout entities + squeezed
  /// whitespace); its "0,0" fallback is intentionally NOT mirrored: an empty
  /// grade cell means "no grade yet" here, not a grade of zero. &nbsp; is
  /// the only entity that arrives as text from innerHtml - package:html's
  /// serializer re-escapes just &<>" and U+00A0; other spaces arrive
  /// already decoded and the \s squeeze covers them.
  static String _cleanCell(String raw) => raw
      .replaceAll(RegExp(r"&nbsp;", caseSensitive: false), " ")
      .replaceAll(RegExp(r"\s+"), " ")
      .trim();

  static final _decimal = RegExp(r"^(\d{1,3}[,.]\d{1,2}|\d{1,3})$");

  static double? _parseGermanDecimal(String raw) {
    // cells arrive as "1 , 3" or "1\u00a0,3" (nbsp became a plain space in
    // cleaning) - decimals match across ALL inner whitespace
    final s = raw.replaceAll(RegExp(r"\s+"), "");
    if (!_decimal.hasMatch(s)) return null;
    return double.tryParse(s.replaceAll(",", "."));
  }
}
