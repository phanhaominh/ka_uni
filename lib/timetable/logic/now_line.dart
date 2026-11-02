/// Pure geometry of the "now" overlay, kept free of Flutter imports so the
/// test can drive it without a binding.

/// One painted day-timetable block in plain values: wall-minute start,
/// length in minutes, and whether the row draws its 1px bottom border
/// (begin.hour < 17 by today's convention).
class NowBlock {
  final int beginMin;
  final int durationMin;
  final bool border;

  const NowBlock(
      {required this.beginMin, required this.durationMin, this.border = false});
}

/// y of the now-line inside the painted day Column, or null when the wall
/// minute lies outside the block column (before the first block, at/after
/// the last block's end).
///
/// Walks exactly like the Column: block i occupies content height
/// durationMin*pxPerMin and, if [NowBlock.border], another 1px border strip;
/// blocks stack in list order. Minutes landing in a dead gap (block i ended,
/// block i+1 not started - zero rendered height) resolve to the previous
/// block's bottom seam y, so the line visually "sticks" to the seam instead
/// of vanishing between classes.
double? nowLineY({
  required List<NowBlock> blocks,
  required int minutesOfDay,
  required double pxPerMin,
}) {
  double top = 0;
  for (var i = 0; i < blocks.length; i++) {
    final b = blocks[i];
    final bottom = top + b.durationMin * pxPerMin;
    if (minutesOfDay >= b.beginMin) {
      if (minutesOfDay < b.beginMin + b.durationMin) {
        return top + (minutesOfDay - b.beginMin) * pxPerMin;
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

/// Height factor (minutes → pixels) applied to every row so the whole
/// column stays inside the viewport: 0.9 (the old constant look) whenever
/// it fits, else the largest factor that fits, floored at 0.3 so a jammed
/// day degrades gracefully instead of vanishing. Single source of truth
/// for BOTH the column layout and the now-line, so line and rows can
/// never disagree.
double dayColumnFactor({
  required double viewportPx,
  required List<NowBlock> blocks,
}) {
  double totalDur = 0;
  double borders = 0;
  for (final b in blocks) {
    totalDur += b.durationMin;
    if (b.border) borders += 1;
  }
  if (totalDur == 0) return 0.9; // nothing to scale (border-only column)
  if (totalDur * 0.9 + borders <= viewportPx) return 0.9;
  final fit = (viewportPx - borders) / totalDur;
  return fit.clamp(0.3, 0.9).toDouble();
}
