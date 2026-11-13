/// R35.5 GAP-HOUR PLANNER - what can I actually DO between two lectures.
///
/// A join over sources the app already fetches: schedule gaps (>= 45 min,
/// derived by the caller from the same occurrences the agenda lists), the
/// mensa plan (serving windows are REAL data: the SW prints "11-14 Uhr"
/// per line) and the library's free-seat counts. Nothing invented, and
/// the freshness rule is strict: a stale source contributes NOTHING -
/// not even a hedged clause. "Mensa closed" written from a three-day-old
/// page is a fabrication with better manners.
///
/// Pure: no prefs, no managers, no context; the caller resolves sources
/// into the plain inputs below and decides what "fresh" means per source
/// (null = stale/unknown = omitted).
library;

/// One free stretch (both ends local, gapMinutes >= 45 enforced by the
/// caller's derivation - see agenda gap logic).
typedef Gap = ({DateTime start, DateTime end});

int gapMinutes(Gap g) => g.end.difference(g.start).inMinutes;

/// Gaps strictly BETWEEN consecutive events on the remainder of the day.
/// Intervals are MERGED first (a chain A(9-12),B(10-11),C(13-14) has its
/// free stretch at 12-13, not 11-13 — naive consecutive pairing would
/// open a gap inside the still-running A). Deliberately no trailing
/// "until whenever" gap: the day's end is not a certified fact. Plain
/// records keep this free of the webcal model.
List<Gap> deriveGaps(
    List<({DateTime start, DateTime end})> events, DateTime now) {
  final evs = events.where((e) => !e.end.isBefore(now)).toList()
    ..sort((a, b) => a.start.compareTo(b.start));
  final merged = <({DateTime start, DateTime end})>[];
  for (final e in evs) {
    if (merged.isNotEmpty && !e.start.isAfter(merged.last.end)) {
      if (e.end.isAfter(merged.last.end)) {
        merged[merged.length - 1] =
            (start: merged.last.start, end: e.end);
      }
    } else {
      merged.add(e);
    }
  }
  final out = <Gap>[];
  for (var i = 0; i + 1 < merged.length; i++) {
    final from =
        merged[i].end.isAfter(now) ? merged[i].end : now;
    final to = merged[i + 1].start;
    if (to.isAfter(from)) out.add((start: from, end: to));
  }
  return out;
}

/// Serving window "11-14 Uhr" / "11.00 - 14.00 Uhr" as printed by the SW
/// in a line's sub-runs; returns (from, to) on that plan date. Several
/// windows per line are possible ("11-14 Uhr · 17-19 Uhr") - all parse.
/// Text without a full pair stays unparsed (no half-windows).
List<({DateTime from, DateTime to})> servingWindows(
    String? sub, DateTime day) {
  if (sub == null) return const [];
  final re = RegExp(r"(\d{1,2})(?:[.,](\d{2}))?\s*[-–]\s*(\d{1,2})(?:[.,](\d{2}))?\s*Uhr");
  final out = <({DateTime from, DateTime to})>[];
  for (final m in re.allMatches(sub)) {
    final h1 = int.parse(m.group(1)!), h2 = int.parse(m.group(3)!);
    final m1 = int.parse(m.group(2) ?? "0"), m2 = int.parse(m.group(4) ?? "0");
    if (h1 > 23 || h2 > 23 || m1 > 59 || m2 > 59) continue;
    final from = DateTime(day.year, day.month, day.day, h1, m1);
    final to = DateTime(day.year, day.month, day.day, h2, m2);
    if (!to.isAfter(from)) continue; // "14-11" is a misprint, not a window
    out.add((from: from, to: to));
  }
  return out;
}

/// One rendered line: the gap plus at most two certified clauses.
typedef GapPlan = ({Gap gap, List<String> clauses});

/// Build plan lines for today's gaps (sorted, cap [limit]).
/// [mensaWindows] = already-parsed serving windows for that day (empty or
/// null when the mensa page is stale); [seatsFree] = total free library
/// seats right now (null when the Anny data is stale). Clause wording is
/// caller-l10n'd upstream: this returns keys-with-data the UI maps to
/// strings - keep it plain: "mensa" / "seats".
List<GapPlan> planGaps({
  required List<Gap> gaps,
  required DateTime now,
  List<({DateTime from, DateTime to})>? mensaWindows,
  int? seatsFree,
  int limit = 3,
  int minMinutes = 45,
}) {
  final kept = gaps
      .where((g) =>
          gapMinutes(g) >= minMinutes &&
          // only the REST of today matters; a gap that already ran is
          // history, not a plan
          g.end.isAfter(now))
      .toList()
    ..sort((a, b) => a.start.compareTo(b.start));
  final out = <GapPlan>[];
  for (final g in kept) {
    final clauses = <String>[];
    for (final w in mensaWindows ?? const <Never>[]) {
      // strict overlap: a gap starting exactly when the kitchen closes
      // has ZERO minutes of mensa - touching edges must not claim it
      final overlaps = g.start.isBefore(w.to) && g.end.isAfter(w.from);
      if (overlaps) {
        clauses.add("mensa");
        break;
      }
    }
    if (seatsFree != null && seatsFree > 0) clauses.add("seats");
    out.add((gap: g, clauses: clauses));
    if (out.length >= limit) break;
  }
  return out;
}
