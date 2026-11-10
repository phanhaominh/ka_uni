/// Pure geometry of the "now" overlay, kept free of Flutter imports so the
/// test can drive it without a binding.

/// One painted day-timetable block in plain values: wall-minute start,
/// length in minutes, and whether the row draws its 1px bottom border
/// (begin.hour < 17 by today's convention).
class NowBlock {
  final int beginMin;
  final int durationMin;
  final bool border;

  /// The row is CONTENT (lecture/tutorial/lunch), i.e. it may paint a
  /// "running · until" chip in its time line right now (the chip itself
  /// is minute-live; this flag is not). The now-line skips its HH:MM
  /// label while it sits inside such a row's TOP strip - both texts
  /// share the column's right end there (measured: "08:04" painted
  /// straight onto "running · until 09:00"). Deeper in the block the
  /// label returns; free-gap rows keep it always.
  final bool content;

  const NowBlock(
      {required this.beginMin,
      required this.durationMin,
      this.border = false,
      this.content = false});
}

/// y of the now-line inside the painted day Column, or null when the wall
/// minute lies outside the block column (before the first block, at/after
/// the last block's end).
///
/// Walks exactly like the Column: block i occupies content height
/// [heights] i and, if [NowBlock.border], another 1px border strip; blocks
/// stack in list order. Minutes landing in a dead gap (block i ended,
/// block i+1 not started - zero rendered height) resolve to the previous
/// block's bottom seam y, so the line visually "sticks" to the seam instead
/// of vanishing between classes. Inside a row the minute interpolates
/// linearly across the row's PAID-FOR pixels, so floor/cap-adjusted rows
/// (see [dayColumnHeights]) can never put the line outside the row its
/// minute belongs to.
double? nowLineY({
  required List<NowBlock> blocks,
  required List<double> heights,
  required int minutesOfDay,
}) {
  double top = 0;
  for (var i = 0; i < blocks.length; i++) {
    final b = blocks[i];
    final h = heights[i];
    final bottom = top + h;
    if (minutesOfDay >= b.beginMin) {
      if (minutesOfDay < b.beginMin + b.durationMin) {
        return top + (minutesOfDay - b.beginMin) / b.durationMin * h;
      }
      if (i + 1 >= blocks.length) return null; // at/after last block end
      final next = blocks[i + 1];
      if (minutesOfDay < next.beginMin) {
        return bottom + (b.border ? 1 : 0); // dead gap → previous seam
      }
      // minutes belong to a later block; keep walking
    }
    top = bottom + (b.border ? 1 : 0);
  }
  return null; // before the first block's beginMin
}

/// Design scale: the px a single wall-clock minute claims at full size.
const double timetableIdealPxPerMin = 0.9;

/// Never scale minutes below this - a jammed day degrades gracefully
/// instead of vanishing (the fit pass below is the true last resort).
const double timetableMinPxPerMin = 0.3;

/// A CONTENT row never shrinks below one time line + one title line:
/// short personal entries (a 20-min slot = 18 px at design scale) used to
/// FittedBox their text into unreadable smears while the neighbour day,
/// scaled differently, showed it full-size - the "too tight, no breathing
/// room" half of the inconsistency report.
const double timetableContentFloorPx = 48;

/// A FREE-GAP row never claims more pixels than this many minutes design
/// scale gives: a 2 h lunch void at 0.9 px/min = 108 px of nothing while
/// lectures breathe - the "big gaps" half. The chip still names the REAL
/// gap ("2:00"); only the void is folded, agenda-calendar style.
const int timetableGapCapMin = 40;

/// ...and never collapses to zero: two rows meeting without a visible seam
/// between them read as one block.
const double timetableGapFloorPx = 10;

/// Minutes the day EFFECTIVELY claims under [dayColumnHeights] - content
/// at full worth, gaps folded at [timetableGapCapMin]. The week scale
/// (see [weekPxPerMin]) picks ONE px/min from the busiest day so every
/// carousel page shares the same rhythm; effort is the comparable measure.
double dayEffort(List<NowBlock> blocks) {
  var eff = 0.0;
  for (final b in blocks) {
    eff += b.content
        ? b.durationMin
        : (b.durationMin < timetableGapCapMin
            ? b.durationMin
            : timetableGapCapMin);
  }
  return eff;
}

/// ONE px/min for the WHOLE week: the largest scale up to design that fits
/// the busiest day into the viewport (borders are a few px, negligible -
/// and [dayColumnHeights] still fits any pathological day exactly). Days
/// swiped next to each other now share one rhythm: equal lecture duration
/// = equal height everywhere.
double weekPxPerMin({
  required double viewportPx,
  required List<List<NowBlock>> days,
}) {
  var pxPerMin = timetableIdealPxPerMin;
  for (final blocks in days) {
    final eff = dayEffort(blocks);
    if (eff == 0) continue;
    pxPerMin = (viewportPx / eff) < pxPerMin ? viewportPx / eff : pxPerMin;
  }
  return pxPerMin
      .clamp(timetableMinPxPerMin, timetableIdealPxPerMin)
      .toDouble();
}

/// The single source of row heights: the Column paints EXACTLY these and
/// the now-line walks EXACTLY these (content floor + gap cap/fold included),
/// so painted and measured geometry can never disagree. Content rows
/// [timetableContentFloorPx] floored, free rows folded into
/// [timetableGapCapMin]/[timetableGapFloorPx]; if a day STILL exceeds the
/// viewport (a floor-heavy jam no week scale could fit) every row gives
/// uniform share - never a clip, never a stripe.
List<double> dayColumnHeights({
  required double pxPerMin,
  required List<NowBlock> blocks,
  required double viewportPx,
}) {
  final heights = [
    for (final b in blocks)
      b.content
          ? (b.durationMin * pxPerMin) > timetableContentFloorPx
              ? b.durationMin * pxPerMin
              : timetableContentFloorPx
          : (b.durationMin * pxPerMin).clamp(
              b.durationMin * pxPerMin < timetableGapFloorPx
                  ? b.durationMin * pxPerMin // dead-small seam: stay honest
                  : timetableGapFloorPx,
              timetableGapCapMin * pxPerMin,
            )
  ];
  var borders = 0.0;
  var content = 0.0;
  for (var i = 0; i < blocks.length; i++) {
    if (blocks[i].border) borders += 1;
    content += heights[i];
  }
  final total = content + borders;
  if (content > 0 && total > viewportPx) {
    final k = (viewportPx - borders) / content;
    for (var i = 0; i < heights.length; i++) {
      heights[i] *= k;
    }
  }
  return heights;
}
