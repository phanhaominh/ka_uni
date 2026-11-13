import 'package:flutter_test/flutter_test.dart';
import 'package:kit_mobile/gapplan/gap_plan.dart';

/// R35.5: a gap-plan clause may only come from a FRESH source; window
/// text parses only when the SW really printed a pair; a passed gap is
/// history, never a plan.
void main() {
  final d = DateTime(2026, 11, 13);
  final now = DateTime(2026, 11, 13, 12, 0);

  Gap g(int sh, int sm, int eh, int em) => (
        start: DateTime(2026, 11, 13, sh, sm),
        end: DateTime(2026, 11, 13, eh, em),
      );

  test("serving windows parse only full 'H(H)-H(H) Uhr' pairs", () {
    final w = servingWindows("11-14 Uhr", d).single;
    expect((w.from.hour, w.from.minute), (11, 0));
    expect((w.to.hour, w.to.minute), (14, 0));
    expect(servingWindows("11.00 - 14.30 Uhr", d).single.from.minute, 0);
    expect(servingWindows("11.00 - 14.30 Uhr", d).single.to.minute, 30);
    // two windows on one line
    expect(servingWindows("11-14 Uhr · 17-19 Uhr", d).length, 2);
    // no pair, no window - never half a time
    expect(servingWindows("Gut & Günstig", d), isEmpty);
    expect(servingWindows("ab 11 Uhr", d), isEmpty);
    // misprints (reversed / impossible) drop, they do not clamp
    expect(servingWindows("14-11 Uhr", d), isEmpty);
    expect(servingWindows("99-100 Uhr", d), isEmpty);
    expect(servingWindows(null, d), isEmpty);
  });

  test("gaps below 45 min and past gaps never plan", () {
    final plans = planGaps(gaps: [
      g(11, 0, 11, 40), // 40 min: too short
      g(9, 0, 11, 0), // past at 12:00
      g(13, 0, 15, 0), // the real one
    ], now: now);
    expect(plans.single.gap.start.hour, 13);
  });

  test("stale sources contribute NOTHING - not even a clause", () {
    final plans = planGaps(gaps: [g(13, 0, 15, 0)], now: now);
    expect(plans.single.clauses, isEmpty); // both sources stale
    final seatsOnly = planGaps(
        gaps: [g(13, 0, 15, 0)], now: now, seatsFree: null, mensaWindows: []);
    expect(seatsOnly.single.clauses, isEmpty);
    final zeroSeats =
        planGaps(gaps: [g(13, 0, 15, 0)], now: now, seatsFree: 0);
    expect(zeroSeats.single.clauses, isEmpty); // 0 free is honest, not a plan
  });

  test("fresh sources attach at most mensa+seats, only on overlap", () {
    final windows = servingWindows("11-14 Uhr", d);
    final hit = planGaps(
        gaps: [g(13, 0, 14, 30)], now: now, mensaWindows: windows, seatsFree: 12);
    expect(hit.single.clauses, ["mensa", "seats"]);
    final miss = planGaps(
        gaps: [g(15, 0, 18, 0)], now: now, mensaWindows: windows, seatsFree: 12);
    expect(miss.single.clauses, ["seats"]);
    // a gap starting exactly at window END has zero mensa minutes
    final edge = planGaps(gaps: [g(14, 0, 16, 0)], now: now, mensaWindows: windows);
    expect(edge.single.clauses, isEmpty);
  });

  test("sorted by start, capped at limit", () {
    final plans = planGaps(gaps: [
      g(18, 0, 20, 0),
      g(13, 0, 14, 0),
      g(16, 0, 17, 0),
      g(10, 0, 11, 0), // past
    ], now: now);
    expect(plans.map((p) => p.gap.start.hour), [13, 16, 18]);
    expect(plans.length, 3);
  });

  test("gapMinutes is the plain difference (no rounding games)", () {
    expect(gapMinutes(g(13, 0, 13, 45)), 45);
    expect(gapMinutes(g(13, 0, 13, 44)), 44);
  });

  test("deriveGaps merges overlapping chains before opening gaps", () {
    // A 09-12, B 10-11 (nested), C 13-14 at now=09:30: free is 12-13 ONLY
    final gaps = deriveGaps([
      (start: DateTime(2026, 11, 13, 9), end: DateTime(2026, 11, 13, 12)),
      (start: DateTime(2026, 11, 13, 10), end: DateTime(2026, 11, 13, 11)),
      (start: DateTime(2026, 11, 13, 13), end: DateTime(2026, 11, 13, 14)),
    ], now);
    expect(gaps.length, 1);
    expect((gaps.single.start.hour, gaps.single.end.hour), (12, 13));
  });

  test("deriveGaps: running event seals the morning, no invented tail", () {
    // running 11:30-12:30, next 14-15: gap 12:30-14, nothing after 15:00
    final gaps = deriveGaps([
      (start: DateTime(2026, 11, 13, 11, 30),
          end: DateTime(2026, 11, 13, 12, 30)),
      (start: DateTime(2026, 11, 13, 14), end: DateTime(2026, 11, 13, 15)),
    ], now);
    expect(gaps.length, 1);
    expect((gaps.single.start.hour, gaps.single.start.minute), (12, 30));
    expect(gaps.single.end.hour, 14);
    // single remaining event: zero gaps (the evening belongs to nobody)
    expect(
        deriveGaps([
          (start: DateTime(2026, 11, 13, 14),
              end: DateTime(2026, 11, 13, 15)),
        ], now),
        isEmpty);
  });
}
