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
  smuOpens,

  /// R35.1 ONE ACTION LIST: the next registered sitting, ported from the
  /// agenda's deleted `_nextExamCard` with its full semantics - the
  /// earliest [ExamEntry.nextRegisteredTerm] across the exam list, shown
  /// only within a 45-day horizon (the card's `days > 45` gate), with
  /// [CockpitItem.room] filled only when the best start resolves to
  /// exactly ONE unambiguous non-empty room, and TODAY-allowed (the old
  /// card printed an exam sitting later today; the strictly-future rule
  /// of every other row deliberately does NOT apply here). Replaces the
  /// matching plain [examSitting] row instead of duplicating it.
  examNext,

  /// R35.1: the exam list has not proven itself yet (agenda's old
  /// `examsLoading` pending card). A FIRST-CLASS unknown row: the
  /// collapsed list may never present a filtered view while its exam
  /// data is simply not there yet. Status rows sit OUTSIDE the
  /// [maxItems] budget - a cap that silently swallowed the unknown
  /// would make the collapse dishonest. Empty title: the renderer
  /// localizes it (reuses the `agenda.examsLoading` string).
  unknownExams,

  /// R35.1: SignMeUp procedures exist but the "mine" fetch is unproven
  /// (agenda's old `signMeUpNotCurrent` pending card) - "not
  /// registered" is indistinguishable from "fetch failed", so the list
  /// says so instead of staying silent. See [unknownExams] for the
  /// outside-the-cap rule. Empty title; render via
  /// `agenda.signMeUpNotCurrent`.
  unknownSmu
}

/// R35.1: where a row's tap goes - the per-card deep links the collapsed
/// list must preserve (the old separate cards carried them: the exam
/// registration CTA opened [ExamsPage], the SignMeUp CTA opened the
/// portal). Pure data; the renderer maps these onto pushPageOnce /
/// external launch exactly as the deleted card builders did.
enum CockpitAction {
  /// exam kinds -> the exam registration page (the CTA target of the
  /// old `_examsSection`, and the route the deep-link queue knows).
  examsPage,

  /// SignMeUp kinds -> https://plus.campus.kit.edu/signmeup (the exact
  /// URL of the old `_signMeUpSection` CTA).
  signMeUpPortal,

  /// dues, own Fristenbuch notes, and status/unknown rows: never had a
  /// tap target - a dead chevron is worse than no chevron (F12 rule).
  none
}

/// Deep-link target for one cockpit row kind (R35.1 link preservation).
CockpitAction cockpitAction(CockpitKind kind) => switch (kind) {
      CockpitKind.examSignupOpen ||
      CockpitKind.examSignupOpens ||
      CockpitKind.examDereg ||
      CockpitKind.examSitting ||
      CockpitKind.examNext =>
        CockpitAction.examsPage,
      CockpitKind.smuOpen || CockpitKind.smuOpens =>
        CockpitAction.signMeUpPortal,
      CockpitKind.due ||
      CockpitKind.frb ||
      CockpitKind.unknownExams ||
      CockpitKind.unknownSmu =>
        CockpitAction.none,
    };

class CockpitItem {
  final CockpitKind kind;

  /// The moment that matters: deadline time or window-open time.
  final DateTime when;
  final String title;

  /// R35.1: room label for [CockpitKind.examNext] only - filled solely
  /// when the sitting resolves to exactly ONE non-empty room (two pool
  /// sittings can share a start; labeling one room would misattribute a
  /// sibling - the disambiguation rule of the deleted `_nextExamCard`).
  /// Null on every other kind.
  final String? room;

  const CockpitItem(this.kind, this.when, this.title, {this.room});

  /// <3 days runway (strict): the card paints these in error color.
  /// Deliberately on the item, not the widget, so tests pin the
  /// boundary. Status unknowns are NEVER urgent: an unknown is not a
  /// deadline, and error paint would shout at an unproven source.
  bool urgent(DateTime now) => switch (kind) {
        CockpitKind.unknownExams || CockpitKind.unknownSmu => false,
        _ => when.isBefore(now.add(_urgentRunway)),
      };

  static const _urgentRunway = Duration(days: 3);
}

const cockpitHorizonDays = 28;

/// Build the timeline. [occurrences] is the MERGED feed parse (incl. the
/// synth blocks); [smuProven] must be `loadedMine` - without a proven
/// "mine" fetch the process cannot tell "not registered" from "fetch
/// failed" and must not shout (same rule as `_signMeUpRows`). An
/// unproven fetch over NON-empty procedures yields an
/// [CockpitKind.unknownSmu] status row instead of silence (R35.1).
/// [examsPending] is the agenda's old `examsLoading` condition (ready,
/// exam list not loaded, no broken-surface banner) - it yields the
/// [CockpitKind.unknownExams] status row (R35.1).
///
/// Only STRICTLY FUTURE dates appear: today's rows live in the today
/// section already and duplicating them here would make the two lists
/// disagree the moment one refresh lands between builds. The one
/// exception is [CockpitKind.examNext] - the ported `_nextExamCard`
/// printed an exam sitting later today and still does.
List<CockpitItem> cockpitPlan({
  required List<IcsOccurrence> occurrences,
  required List<ExamEntry> exams,
  required List<SignMeUpProcedure> procedures,
  required Set<int> registeredProcedureIds,
  required bool smuProven,
  required DateTime now,
  bool examsPending = false,
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

  // R35.1: the next registered sitting, ported from the agenda's
  // deleted `_nextExamCard` with every one of its semantics intact:
  //  * registered-term selection: earliest ExamEntry.nextRegisteredTerm
  //    across the list (registered exams only by construction);
  //  * room disambiguation: two pool sittings can share a start; the
  //    room label appears only when the best start resolves to exactly
  //    one non-empty room, else a sibling room would be misattributed;
  //  * the 45-day gate (`days > 45` printed nothing; whole CALENDAR
  //    days, same math as L10n.daysFromNow, deliberately local to keep
  //    this file l10n-free);
  //  * day-offset weight: it sorts on its own date and its tier below
  //    guarantees no informational crowd-out (see the per-kind floors).
  // It REPLACES the matching plain sitting row (synth SUMMARY prefix
  // "Klausur: ", see exam_synth.dart) instead of duplicating it.
  ExamEntry? nextExam;
  DateTime? nextExamAt;
  String? nextExamRoom;
  for (final e in exams) {
    final at = e.nextRegisteredTerm(now);
    if (at != null && (nextExamAt == null || at.isBefore(nextExamAt))) {
      nextExam = e;
      nextExamAt = at;
      final atTerms = e.terms.where((t) => t.startAt == at).toList();
      final rooms = atTerms.map((t) => t.room).toSet();
      // roomLabel, not raw room: "-" / "--" placeholders print nothing
      // (the deleted card leaked them); "ILIAS" stays - online IS a
      // location statement
      nextExamRoom = rooms.length == 1 && atTerms.first.roomLabel.isNotEmpty
          ? rooms.first
          : null;
    }
  }
  final nextExamDays = nextExamAt == null
      ? null
      : DateTime(nextExamAt.year, nextExamAt.month, nextExamAt.day)
              .difference(dayStart)
              .inDays;
  if (nextExam != null && nextExamAt != null &&
      nextExamDays != null && nextExamDays <= 45) {
    final title = nextExam.title;
    items.removeWhere((i) =>
        i.kind == CockpitKind.examSitting &&
        i.when == nextExamAt &&
        (i.title == title || i.title == "Klausur: $title"));
    items.add(CockpitItem(CockpitKind.examNext, nextExamAt, title,
        room: nextExamRoom));
  }
  // Status unknowns live OUTSIDE the budget entirely (R35.1): an
  // eviction that hides "we do not know yet" would make the collapse
  // lie about what the sources proved. `when` = now: sort-first anchor
  // that still prints as TODAY (an epoch anchor rendered as "in
  // -20831 Tagen" under the plain row template).
  final unknowns = <CockpitItem>[
    if (examsPending) CockpitItem(CockpitKind.unknownExams, now, ""),
    if (!smuProven && procedures.isNotEmpty)
      CockpitItem(CockpitKind.unknownSmu, now, ""),
  ];

  items.sort((a, b) => a.when.compareTo(b.when));
  // R35.1 PER-KIND FLOORS, replacing the R28 dues-only reservation: the
  // audit's core-purpose miss was a Klaus phase whose 8 sitting rows
  // evicted every open Anmeldung through a dues-first (or plain
  // dues-last) global take. Now every kind present claims one slot
  // before any kind claims a second (round-robin), and the kind ORDER
  // carries the weight: act-now signups first, the student's own
  // deadlines (dues, Fristenbuch) next, then the dereg next-act and the
  // registered next exam, then future-window info, sittings LAST.
  // Within a kind the earliest dates win; the R28 doctrine survives —
  // dues still outrank sitting rows outright.
  const kindTiers = [
    CockpitKind.examSignupOpen,
    CockpitKind.smuOpen,
    CockpitKind.due,
    CockpitKind.frb,
    CockpitKind.examDereg,
    CockpitKind.examNext,
    CockpitKind.examSignupOpens,
    CockpitKind.smuOpens,
    CockpitKind.examSitting,
  ];
  final byKind = <CockpitKind, List<CockpitItem>>{};
  for (final i in items) {
    byKind.putIfAbsent(i.kind, () => []).add(i);
  }
  final kept = <CockpitItem>[];
  for (var round = 0; kept.length < maxItems; round++) {
    var took = false;
    for (final kind in kindTiers) {
      final list = byKind[kind];
      if (list == null || round >= list.length) continue;
      kept.add(list[round]);
      took = true;
      if (kept.length == maxItems) break;
    }
    if (!took) break;
  }
  kept.sort((a, b) => a.when.compareTo(b.when));
  return <CockpitItem>[...unknowns, ...kept];
}
