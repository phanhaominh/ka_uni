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
enum ClashKind { overlap, sameDay }

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

  const ExamClash(this.a, this.b, this.when, this.kind,
      {this.exactEndA, this.exactEndB});
}

typedef ExamClashReport = ({List<ExamClash> clashes, int uncomparable});

class _Sitting {
  final ExamEntry exam;
  final DateTime day; // midnight of the parsed sitting date
  final DateTime? start; // null: no time token at all
  final DateTime? end; // null: no FULL span -> never guess

  _Sitting(this.exam, this.day, this.start, this.end);
}

/// FULL-anchor "HH:MM - HH:MM" (hyphen or en/em dash). Anchored on
/// purpose: "09:00 c.t." or "17:30 - 19:00 (Hörsaal)" must stay UNKNOWN
/// rather than be half-parsed into a fabricated end.
final _span = RegExp(r'^\s*(\d{1,2}):(\d{2})\s*[-\u2013\u2014]\s*(\d{1,2}):(\d{2})\s*$');

// Mirrors of the ExamTerm.startAt guards; ExamTerm keeps its own regexes
// private and the clash code must resolve the DAY even when the model
// refuses to guess a start (time token missing).
final _date = RegExp(r'(\d{2})\.(\d{2})\.(\d{4})');
final _dayFragment = RegExp(r'\d{1,2}\.\d{1,2}');

/// Midnight of the concrete sitting date, same one-fragment rule as
/// `ExamTerm.startAt` (range labels like "27.02.-06.03.2027" stay
/// unparseable and are simply not comparable - see that doc).
DateTime? _dateOf(ExamTerm t) {
  if (t.isCancelled) return null;
  if (_dayFragment.allMatches(t.dayLabel).length != 1) return null;
  final d = _date.firstMatch(t.dayLabel);
  if (d == null) return null;
  return DateTime(
      int.parse(d.group(3)!), int.parse(d.group(2)!), int.parse(d.group(1)!));
}

/// The proven end of a sitting, null unless the FULL anchored span
/// parses AND lands after the start. A span crossing midnight
/// ("22:00 - 00:30") is treated as unknown rather than invented onto the
/// next day - a wrong next-day end would forge a cross-day clash.
DateTime? _endOf(ExamTerm t, DateTime day, DateTime start) {
  final m = _span.firstMatch(t.time);
  if (m == null) return null;
  final end = DateTime(day.year, day.month, day.day, int.parse(m.group(3)!),
      int.parse(m.group(4)!));
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
ExamClashReport findExamClashes(List<ExamEntry> exams, DateTime now) {
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
      sittings.add(_Sitting(e, day, start, start == null ? null : _endOf(t, day, start)));
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
      clashes.add(ExamClash(
        lo.exam,
        hi.exam,
        when,
        overlap ? ClashKind.overlap : ClashKind.sameDay,
        exactEndA: lo.end,
        exactEndB: hi.end,
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
