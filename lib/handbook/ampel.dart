import '../grades/models/grade_book.dart';
import '../state_management/campus/campus_manager.dart';
import 'handbook_data.dart';

/// Wave D (R26): the SCHEIN-AMPEL — program-progress traffic light over the
/// official MEI handbook crossed with the LIVE Campus ledger (+ exam
/// registration state). The handbook is static catalogue data; every
/// pass/fail/in-progress claim comes from the ledger only, matched on the
/// shared lowercased-title key. An unmatched handbook module therefore
/// reads as "not taken": the Ampel may under-report progress but must
/// never claim a credit the ledger does not show.
enum AmpelState { passed, failed, inProgress, signupOpen, planned }

class AmpelModule {
  final HandbookModule module;
  final AmpelState state;

  /// The ledger row that matched (null = handbook-only module, never seen
  /// in the Studienverlauf yet).
  final GradeEntry? grade;

  /// Titles of known-UNPASSED prerequisite parts ("... Prerequisite"
  /// homework courses) whose gate blocks THIS module's exam admission.
  final List<String> blockedBy;

  const AmpelModule(this.module, this.state,
      {this.grade, this.blockedBy = const []});

  /// Offered in the semester `now` falls in or in the one starting next —
  /// i.e. the candidate list for the NEXT registration round.
  bool offeredIn(String term) => module.terms.contains(term);
}

class AmpelPlan {
  final List<AmpelModule> all;

  /// B.Sc. MEI total per SPO 2024 §: 180 CP. The handbook's own module sum
  /// (~303) counts EVERY elective catalogue option, so it is NOT a
  /// denominator — and passing counts come from the ledger, never from
  /// handbook matching (an unmatched passed module would vanish from the
  /// numerator; the ledger knows its own total).
  const AmpelPlan(this.all);

  static const degreeEctsTarget = 180.0;

  List<AmpelModule> by(AmpelState s) =>
      all.where((m) => m.state == s).toList();

  /// Modules the ledger has never shown — what is still ahead.
  List<AmpelModule> get remaining => all
      .where((m) =>
          m.state == AmpelState.planned ||
          m.state == AmpelState.signupOpen ||
          m.state == AmpelState.inProgress)
      .toList();
}

/// Current official term: WS runs Oct 1 - Mar 31 (labelled by its start
/// year), SS the rest. Used only for "offered now/next" hints.
String currentTerm(DateTime now) =>
    now.month >= 10 || now.month <= 3 ? "WS" : "SS";

String otherTerm(String term) => term == "WS" ? "SS" : "WS";

AmpelPlan ampelPlan({
  required Handbook handbook,
  required GradeBook book,
  /// [CampusManager.lectureTitleKey] keys of exams whose registration
  /// window is OPEN and which are not registered yet (needsAction).
  required Set<String> signupOpenKeys,
  /// cm.enrolledLectureTitles: lectureTitleKey-space keys of the lectures
  /// on the current timetable — the in-progress signal.
  required Set<String> takingKeys,
}) {
  final gradeByKey = {for (final g in book.modules) g.titleKey: g};
  final items = <AmpelModule>[];

  for (final m in handbook.modules) {
    final g = gradeByKey[m.titleKey];
    // feed/exam data lives in the loose lectureTitleKey space (prefixes,
    // group labels and course numbers stripped) — re-key the handbook
    // title through the same normalizer instead of trusting raw equality
    final feedKey = CampusManager.lectureTitleKey(m.title);
    final AmpelState state;
    if (g != null && g.state == GradeState.passed) {
      state = AmpelState.passed;
    } else if (g != null && g.state == GradeState.failed) {
      state = AmpelState.failed;
    } else if (signupOpenKeys.contains(feedKey)) {
      // registration-open beats in-progress: the actionable date wins
      state = AmpelState.signupOpen;
    } else if (takingKeys.contains(feedKey)) {
      state = AmpelState.inProgress;
    } else {
      state = AmpelState.planned;
    }
    // Gate check: a prerequisite PART counts as unmet only when the ledger
    // positively shows it failed or the part itself is being taken while
    // the parent's admission already looms. "unknown" never blocks — an
    // unlisted 0-CP homework course is invisible to the tree often enough.
    final blocked = <String>[];
    for (final p in m.parts.where((p) => p.type == "prerequisite")) {
      final pg = gradeByKey[p.titleKey];
      if (pg != null && pg.state == GradeState.failed) {
        blocked.add(p.title);
      }
    }
    items.add(AmpelModule(m, state, grade: g, blockedBy: blocked));
  }
  return AmpelPlan(items);
}
