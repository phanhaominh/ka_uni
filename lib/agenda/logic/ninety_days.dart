/// R34.5: the "NÄCHSTE 90 TAGE" join. One date-sorted list over every
/// date the student can walk into in the next three months, merged from
/// the sources the app ALREADY holds - so "explain my semester" has ONE
/// answer instead of five pages:
///  * ILIAS assignment dues     (kauni-due synth events, merged feed)
///  * exam sittings             (kauni-exam synth events, merged feed)
///  * exam registration windows (exam list: needsAction -> "bis END",
///    not-yet-open -> "ab START"; an OPEN window with no stated end
///    has no date to show and is skipped - never guessed)
///  * Fristenbuch entries       (R34.1, handed in as PLAIN RECORDS by
///    the caller - this file must never import that lane's module, so
///    the join cannot couple to its storage or synth layer)
///  * the official term calendar (R34.4 SignMeUp terms: start/end)
///
/// Honesty rule of the whole file: a row exists only if its source
/// certifies a date. Unknown dates (null Fristenbuch bound, end-open
/// window, unparseable term bound) drop out silently - they are never
/// invented, never sorted "to the end" as if known.
///
/// Pure: no context, no clock, no prefs - `now` is injected and every
/// output is deterministic.
library;

import '../../exams/models/exam_list.dart';
import '../../exams/models/exam_synth.dart';
import '../../ilias/due_parse.dart';
import '../../signmeup/signmeup_terms.dart';
import '../../timetable/models/webcal.dart';

/// What a row IS; the card maps this to icon + localized label +
/// provenance citation. Kept on the row (like CockpitKind.urgent) so
/// tests pin the classification, not the widget.
enum NinetyKind {
  due,

  /// "Anmelden bis" of an unregistered exam with an open window.
  examWindowClose,

  /// "Anmeldung ab" of an unregistered exam whose window opens later.
  examWindowOpens,
  examSitting,

  /// Fristenbuch (self-noted) - provenance "you", never scraped truth.
  frb,
  termStart,
  termEnd,
}

/// One dated thing. `allDay` marks date-only entries (Fristenbuch notes,
/// term bounds) so the row renders a date without a time; the renderers'
/// L10n.stamp already hides a midnight HH:mm tail.
typedef NinetyRow = ({DateTime when, bool allDay, NinetyKind kind, String title});

/// Plain input record for Fristenbuch entries (R34.1). `date` null =
/// the store entry carries no usable date - the row is DROPPED, not
/// dated by guess.
typedef FrbEntry = ({String title, DateTime? date});

const int ninetyDaysHorizon = 90;

/// Merge all sources into the unsorted, uncapped row list. Every row is
/// the source's own certified instant; window filtering and sorting
/// happen in [nextNinetyDays] so the horizon rule lives in exactly one
/// place.
///
/// Feed occurrences with OTHER uid prefixes (lectures, personal ICS,
/// SignMeUp tutorials, the kauni-frb synth events) are deliberately NOT
/// rows: recurring series would flood the list, and Fristenbuch rides
/// the typed record parameter instead of its feed shadow - whichever
/// path the caller wires, a note appears exactly once.
List<NinetyRow> ninetyDays({
  required DateTime now,
  List<IcsOccurrence> occurrences = const [],
  List<ExamEntry> exams = const [],
  List<FrbEntry> fristenbuch = const [],
  List<SignMeUpTerm> terms = const [],
}) {
  final rows = <NinetyRow>[];
  bool allDay(DateTime d) => d.hour == 0 && d.minute == 0;

  for (final o in occurrences) {
    if (o.uid.startsWith(dueSynthUidPrefix)) {
      rows.add((
        when: o.start,
        allDay: allDay(o.start),
        kind: NinetyKind.due,
        title: o.title
      ));
    } else if (o.uid.startsWith(examSynthUidPrefix)) {
      rows.add((
        when: o.start,
        allDay: allDay(o.start),
        kind: NinetyKind.examSitting,
        title: o.title
      ));
    }
  }

  for (final e in exams) {
    if (e.registered) continue; // sittings/dereg come via the feed
    if (e.windowStatus == ExamWindowStatus.impossible) continue;
    if (e.needsAction(now)) {
      final end = e.windowEnd;
      // an open window whose end KIT never printed has no date to show:
      // saying "closes" without a date would be the invention this file
      // bans, so such windows stay invisible here (the exams page badge
      // still covers the "act now" side)
      if (end != null) {
        rows.add((
          when: end,
          allDay: allDay(end),
          kind: NinetyKind.examWindowClose,
          title: e.title
        ));
      }
    } else if (e.windowStatus != ExamWindowStatus.unknown &&
        e.windowStart != null &&
        e.windowStart!.isAfter(now)) {
      rows.add((
        when: e.windowStart!,
        allDay: allDay(e.windowStart!),
        kind: NinetyKind.examWindowOpens,
        title: e.title
      ));
    }
  }

  for (final f in fristenbuch) {
    final d = f.date;
    if (d == null) continue; // unknown date: never invented
    rows.add(
        (when: d, allDay: true, kind: NinetyKind.frb, title: f.title));
  }

  for (final t in terms) {
    final s = t.start, e = t.end;
    if (s != null) {
      rows.add((
        when: s,
        allDay: true,
        kind: NinetyKind.termStart,
        title: t.name
      ));
    }
    if (e != null) {
      rows.add((
        when: e,
        allDay: true,
        kind: NinetyKind.termEnd,
        title: t.name
      ));
    }
    // t.cancelEnd is parsed but produces NO row while the wire omits it
    // (verified against the live capture): a model field without wire
    // support must not render a phantom milestone.
  }
  return rows;
}

/// Keep what lies in [now, now+horizonDays], date-sorted: same instant
/// -> all-day rows first, then by title (deterministic tie order, no
/// source-order flapping). Cap for the card.
List<NinetyRow> nextNinetyDays(
  List<NinetyRow> rows,
  DateTime now, {
  int horizonDays = ninetyDaysHorizon,
  int limit = 6,
}) {
  final horizon = now.add(Duration(days: horizonDays));
  final kept = rows
      .where((r) => !r.when.isBefore(now) && !r.when.isAfter(horizon))
      .toList()
    ..sort((a, b) {
      final d = a.when.compareTo(b.when);
      if (d != 0) return d;
      if (a.allDay != b.allDay) return a.allDay ? -1 : 1;
      return a.title.compareTo(b.title);
    });
  return kept.length <= limit ? kept : kept.sublist(0, limit);
}

/// "+N mehr" honest truncation caption count (same rule as the cockpit
/// cards): how many rows exist BEYOND the rendered cap.
int ninetyDaysHidden(
  List<NinetyRow> rows,
  DateTime now, {
  int horizonDays = ninetyDaysHorizon,
  int limit = 6,
}) {
  final total = nextNinetyDays(rows, now,
          horizonDays: horizonDays, limit: rows.length + 1)
      .length;
  return total > limit ? total - limit : 0;
}
