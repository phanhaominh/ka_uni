import '../../exams/models/exam_list.dart';
import '../../exams/models/exam_synth.dart';
import '../../fristenbuch/fristenbuch.dart';
import '../../ilias/due_parse.dart';
import '../../signmeup/signmeup_manager.dart';
import '../../timetable/models/webcal.dart';

/// Wave C (R25): the DEADLINE COCKPIT. One merged, sorted timeline over
/// every date the student can miss, assembled from the same three sources
/// the agenda already renders in isolation:
///  * ILIAS assignment deadlines   (kauni-due synth events, merged feed)
///  * exam sittings                (kauni-exam synth events, merged feed)
///  * exam registration windows    (exam list, not in the feed)
///  * exam deregistration deadlines (R32.3, exam list: "Abmelden bis" of
///    a REGISTERED exam)
///  * SignMeUp course allocation   (procedure windows, not in the feed)
/// Pure logic: no context, injected `now`, deterministic. The alarms for
/// these dates already exist (id bands 500-600 exam signup, 700-799
/// SignMeUp, 10-400 T−30 lecture reminders which cover every merged-feed
/// event incl. dues); the cockpit is the one place the student SEES them
/// together, so nothing here re-arms anything.
enum CockpitKind {
  due,

  /// R34.1: a manually noted Fristenbuch deadline ("Frist: <label>").
  /// Same timeline seat as [due] but a DIFFERENT provenance: scraped
  /// truth vs the student's own note — the card labels them apart, so an
  /// own note never wears a KIT-deadline look.
  frb,
  examSignupOpen,
  examSignupOpens,

  /// R32.3: deregistration deadline of a REGISTERED exam ("Abmelden bis")
  /// - the one date on a registered exam the student can still act on.
  examDereg,
  examSitting,
  smuOpen,
  smuOpens
}

class CockpitItem {
  final CockpitKind kind;

  /// The moment that matters: deadline time or window-open time.
  final DateTime when;
  final String title;

  const CockpitItem(this.kind, this.when, this.title);

  /// <3 days runway (strict): the card paints these in error color.
  /// Deliberately on the item, not the widget, so tests pin the boundary.
  bool urgent(DateTime now) => when.isBefore(now.add(_urgentRunway));

  static const _urgentRunway = Duration(days: 3);
}

const cockpitHorizonDays = 28;

/// Build the timeline. [occurrences] is the MERGED feed parse (incl. the
/// synth blocks); [smuProven] must be `loadedMine` - without a proven
/// "mine" fetch the process cannot tell "not registered" from "fetch
/// failed" and must not shout (same rule as `_signMeUpRows`).
///
/// Only STRICTLY FUTURE dates appear: today's rows live in the today
/// section already and duplicating them here would make the two lists
/// disagree the moment one refresh lands between builds.
List<CockpitItem> cockpitPlan({
  required List<IcsOccurrence> occurrences,
  required List<ExamEntry> exams,
  required List<SignMeUpProcedure> procedures,
  required Set<int> registeredProcedureIds,
  required bool smuProven,
  required DateTime now,
  int horizonDays = cockpitHorizonDays,
  int maxItems = 8,
}) {
  final dayStart = DateTime(now.year, now.month, now.day);
  final tomorrow = DateTime(dayStart.year, dayStart.month, dayStart.day + 1);
  final horizon = dayStart.add(Duration(days: horizonDays));
  final items = <CockpitItem>[];

  void add(CockpitKind kind, DateTime when, String title,
      {int? horizonOverrideDays}) {
    final limit = horizonOverrideDays == null
        ? horizon
        : dayStart.add(Duration(days: horizonOverrideDays));
    if (when.isBefore(tomorrow) || !when.isBefore(limit)) return;
    items.add(CockpitItem(kind, when, title));
  }

  for (final o in occurrences) {
    if (o.uid.startsWith(frbSynthUidPrefix)) {
      add(CockpitKind.frb, o.start, o.title);
    } else if (o.uid.startsWith(dueSynthUidPrefix)) {
      add(CockpitKind.due, o.start, o.title);
    } else if (o.uid.startsWith(examSynthUidPrefix)) {
      // exam sittings live in the semester-end block, routinely 6+ weeks
      // out - the standard 28d horizon would hide the whole Klaus phase
      add(CockpitKind.examSitting, o.start, o.title,
          horizonOverrideDays: 60);
    }
  }

  for (final e in exams) {
    if (e.registered) {
      // R32.3: a future "Abmelden bis" inside the horizon is actionable
      // even though the registration itself is done; [add] keeps it
      // strictly future (tomorrow onward, same rule as every other row)
      final d = e.deregEnd;
      if (d != null) add(CockpitKind.examDereg, d, e.title);
      continue; // sittings already came from the feed
    }
    if (e.windowStatus == ExamWindowStatus.impossible) continue;
    if (e.needsAction(now)) {
      if (e.windowEnd != null) {
        add(CockpitKind.examSignupOpen, e.windowEnd!, e.title);
      }
    } else if (e.windowStatus != ExamWindowStatus.unknown &&
        e.windowStart != null &&
        e.windowStart!.isAfter(now)) {
      // a window whose END is unknown but whose OPEN is known past-dated:
      // needsAction can never turn true here (windowIsOpen is false for
      // unknown), so the "opens" row is the only honest signal
      add(CockpitKind.examSignupOpens, e.windowStart!, e.title);
    } // an OPEN window with no stated end has no date to show - skipped
  }

  if (smuProven) {
    for (final p in procedures) {
      if (registeredProcedureIds.contains(p.id)) continue;
      if (p.needsAction(now, registeredProcedureIds)) {
        add(CockpitKind.smuOpen, p.registrationEnd!, p.name);
      } else if (p.opensWithin(now, const Duration(days: 3))) {
        add(CockpitKind.smuOpens, p.registrationStart!, p.name);
      }
    }
  }

  items.sort((a, b) => a.when.compareTo(b.when));
  // dues are the card's reason to exist: a Klaus phase with 8 sitting
  // rows must not evict them via the global cap (in-horizon dues fill
  // the list first, everything else takes what is left)
  final keepDues =
      items.where((i) => i.kind == CockpitKind.due).take(maxItems).toList();
  final keepRest =
      items.where((i) => i.kind != CockpitKind.due).take(maxItems - keepDues.length);
  return <CockpitItem>[...keepDues, ...keepRest]
    ..sort((a, b) => a.when.compareTo(b.when));
}
