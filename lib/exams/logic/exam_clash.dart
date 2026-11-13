import '../../agenda/logic/walk_hint.dart';
import '../models/exam_list.dart';

/// R29: exam clash detection. Two registered exams whose sittings sit on
/// the same day are at least worth a look (amber); if both sittings carry
/// a provable end and the intervals strictly intersect, the student is
/// double-booked (red). Pure logic: no prefs, no context, injected `now`,
/// deterministic output order. The UI picks colors and words; this only
/// classifies.
///
/// The honesty rule mirrors the rest of the app: an unknown end time is
/// NEVER guessed at, so it can never raise nor deny a red verdict. That
/// is why the result carries an [ExamClashReport.uncomparable] count -
/// without it an empty clash list would read "all clear" even when half
/// the schedule was unparseable.
enum ClashKind { overlap, sameDay, walkImpossible }

class ExamClash {
  final ExamEntry a;
  final ExamEntry b;

  /// Start of the clashing day block: the earlier known start; midnight
  /// of the day if either sitting has no parseable time (amber with an
  /// unknown clock must not pretend to know when it began).
  final DateTime when;
  final ClashKind kind;

  /// The proven ends of exactly the two sittings that clashed, null when
  /// the source carried no full span. Surfaced so the card can say which
  /// side is the vague one.
  final DateTime? exactEndA;
  final DateTime? exactEndB;

  /// R35.4: minutes of walking certified between the two sittings' rooms
  /// (both rooms geocodable via the caller's resolver), null when either
  /// room is a placeholder or unknown place. `walkImpossible` is exactly
  /// "walkMinutes exceeds the proven gap" — the same geometry the agenda
  /// Fußweg hint uses, escalated because a Klausur is not a lecture.
  final int? walkMinutes;

  const ExamClash(this.a, this.b, this.when, this.kind,
      {this.exactEndA, this.exactEndB, this.walkMinutes});
}

typedef ExamClashReport = ({List<ExamClash> clashes, int uncomparable});

class _Sitting {
  final ExamEntry exam;
  final DateTime day; // midnight of the parsed sitting date
  final DateTime? start; // null: no time token at all
  final DateTime? end; // null: no FULL span -> never guess
  final String room; // raw ICS-style room text, "" when placeholder

  _Sitting(this.exam, this.day, this.start, this.end, this.room);
}

/// FULL-anchor "HH:MM - HH:MM" (hyphen or en/em dash). Anchored on
/// purpose: "09:00 c.t." or "17:30 - 19:00 (Hörsaal)" must stay UNKNOWN
/// rather than be half-parsed into a fabricated end.
// 24-h "17:30 - 19:00" and the EN portal's "11:00 AM - 1:00 PM" (the
// locale follows the student: an English session used to make EVERY
// span unparseable, collapsing the whole exam list to "uncomparable").
final _span24 =
    RegExp(r'^\s*(\d{1,2}):(\d{2})\s*[-\u2013\u2014]\s*(\d{1,2}):(\d{2})\s*$');
final _spanAmPm = RegExp(
    r'^\s*(\d{1,2}):(\d{2})\s*([AP]M)\s*[-\u2013\u2014]\s*(\d{1,2}):(\d{2})\s*([AP]M)\s*$',
    caseSensitive: false);

// Day resolution goes through ExamTerm.parseCasDate - the single place
// that knows Campus' two date spellings; a local mirror would drift the
// moment the parser learns a third.

/// Midnight of the concrete sitting date, same one-date rule as
/// `ExamTerm.startAt` (range labels like "27.02.-06.03.2027" stay
/// unparseable and are simply not comparable - see that doc).
DateTime? _dateOf(ExamTerm t) =>
    t.isCancelled ? null : ExamTerm.parseCasDate(t.dayLabel);

int? _pmHour(String h, String ampm) {
  final hour = int.parse(h);
  if (hour < 1 || hour > 12) return null;
  final pm = ampm.toUpperCase() == "PM";
  if (pm && hour < 12) return hour + 12;
  if (!pm && hour == 12) return 0;
  return hour;
}

/// The proven end of a sitting, null unless the FULL anchored span
/// parses AND lands after the start. A span crossing midnight
/// ("22:00 - 00:30") is treated as unknown rather than invented onto the
/// next day - a wrong next-day end would forge a cross-day clash; the
/// AM/PM spelling makes "9:00 AM - 1:00 PM" provable instead.
DateTime? _endOf(ExamTerm t, DateTime day, DateTime start) {
  final m24 = _span24.firstMatch(t.time);
  if (m24 != null) {
    final end = DateTime(day.year, day.month, day.day,
        int.parse(m24.group(3)!), int.parse(m24.group(4)!));
    return end.isAfter(start) ? end : null;
  }
  final mp = _spanAmPm.firstMatch(t.time);
  if (mp == null) return null;
  final eh = _pmHour(mp.group(4)!, mp.group(6)!);
  if (eh == null) return null;
  final end =
      DateTime(day.year, day.month, day.day, eh, int.parse(mp.group(5)!));
  return end.isAfter(start) ? end : null;
}

DateTime _dayStart(DateTime t) => DateTime(t.year, t.month, t.day);

/// One extra day of slack on the cutoff: a sitting that started up to
/// 24h ago may still run into (or share a day with) a future one, and
/// the student is far from done caring about yesterday's exam.
const _lookback = Duration(days: 1);

/// Find all same-day clashes among REGISTERED exams.
///
/// Sittings are the comparison unit (1. and 2. Termin are separate
/// sittings), but a registered exam NEVER clashes with itself: two
/// Termins of one exam are alternative attempts, not a double booking.
/// Cancelled sittings ("entfällt") are dropped like everywhere else;
/// unparseable dates (ranges, text) drop out of both lists - they are
/// not "uncomparable", they are absent from the schedule model.
///
/// [uncomparable] counts DISTINCT registered exams that have at least
/// one in-window sitting whose date parses but whose end cannot be
/// proven (no full span - which includes "no time at all"). Every red
/// verdict involving such an exam is impossible, so callers may only
/// claim "no clashes" when `clashes.isEmpty && uncomparable == 0`.
///
/// Deterministic: pairs sorted by (when, a.examNumber, b.examNumber),
/// and within a pair `a` is the lower examNumber so the two sides - and
/// their `exactEnd` fields - never swap between builds.
///
/// [distance] (R35.4) resolves two raw room strings to great-circle
/// metres, null when either does not name a known place. Without it (or
/// without a resolvable room pair) the classifier behaves exactly as
/// before: an unreachable-between is then simply not certifiable, and
/// inventing one would be the worst verdict this file could ship.
ExamClashReport findExamClashes(List<ExamEntry> exams, DateTime now,
    {double? Function(String roomA, String roomB)? distance}) {
  final cutoff = now.subtract(_lookback);
  final sittings = <_Sitting>[];
  for (final e in exams) {
    if (!e.registered) continue;
    for (final t in e.terms) {
      final day = _dateOf(t);
      if (day == null) continue;
      final start = t.startAt; // already null-safe re: missing time
      // Unknown start: judge "future-ish" by the day itself, else a
      // no-time sitting is dropped on a technicality and silently
      // shrinks coverage.
      final futureish = start != null
          ? !start.isBefore(cutoff)
          : !day.isBefore(_dayStart(cutoff));
      if (!futureish) continue;
      sittings.add(_Sitting(e, day, start,
          start == null ? null : _endOf(t, day, start), t.room));
    }
  }

  final clashes = <ExamClash>[];
  for (var i = 0; i < sittings.length; i++) {
    for (var j = i + 1; j < sittings.length; j++) {
      final x = sittings[i], y = sittings[j];
      if (identical(x.exam, y.exam)) continue; // self-pair never
      if (x.day != y.day) continue;
      final sa = x.start, sb = y.start;
      final overlap = sa != null &&
          sb != null &&
          x.end != null &&
          y.end != null &&
          sa.isBefore(y.end!) &&
          sb.isBefore(x.end!); // strict: 17:30-19:00 vs 19:00-20:00 passes
      final when = sa != null && sb != null
          ? (sa.isBefore(sb) ? sa : sb)
          : x.day;
      final first = x.exam.examNumber.compareTo(y.exam.examNumber) <= 0;
      final lo = first ? x : y, hi = first ? y : x;
      // R35.4 walk escalation: both spans proven, no strict overlap, but
      // the gap between them is shorter than the certified walk between
      // the two rooms -> red "nicht erreichbar", not a friendly same-day.
      // Any missing piece (end, room, place) keeps the honest sameDay.
      int? walkMin;
      var kind = ClashKind.sameDay;
      if (!overlap &&
          distance != null &&
          sa != null &&
          sb != null &&
          x.end != null &&
          y.end != null) {
        final earlier = sa.isBefore(sb) ? x : y;
        final later = sa.isBefore(sb) ? y : x;
        final gap = later.start!.difference(earlier.end!).inMinutes;
        if (gap >= 0 &&
            !ExamTerm.isPlaceholderRoom(earlier.room) &&
            !ExamTerm.isPlaceholderRoom(later.room)) {
          final meters = distance(earlier.room, later.room);
          if (meters != null) {
            walkMin = walkMinutesFor(meters);
            if (walkMin > gap) kind = ClashKind.walkImpossible;
          }
        }
      }
      clashes.add(ExamClash(
        lo.exam,
        hi.exam,
        when,
        overlap ? ClashKind.overlap : kind,
        exactEndA: lo.end,
        exactEndB: hi.end,
        walkMinutes: walkMin,
      ));
    }
  }
  clashes.sort((p, q) {
    final w = p.when.compareTo(q.when);
    if (w != 0) return w;
    final an = p.a.examNumber.compareTo(q.a.examNumber);
    if (an != 0) return an;
    return p.b.examNumber.compareTo(q.b.examNumber);
  });

  final uncomparable = <ExamEntry>{};
  for (final s in sittings) {
    // start == null implies end == null; one check covers both.
    if (s.end == null) uncomparable.add(s.exam);
  }
  return (clashes: clashes, uncomparable: uncomparable.length);
}
