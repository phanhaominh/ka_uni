/// Pure geometry of the day timetable's ABSOLUTE time axis, kept free of
/// Flutter imports so the tests can drive it without a binding.
///
/// The week shares ONE time ruler: every carousel page spans the same
/// [axisStartMin]..[axisEndMin] wall window at the same px/min, a lecture
/// is Positioned at (begin - axisStart) * px and sized duration * px -
/// exactly like paper agendas and Google Calendar. Equal times therefore
/// land at equal pixels on EVERY day (the "placement is not consistent"
/// reports of 11/12.11 were every earlier stacked-row design re-flowing
/// each day on its own: fit factors, centering, folded gap rows).
library;

/// Design scale: the pixels a single wall-clock minute claims. The axis
/// only shrinks below this when the week's time range exceeds the card
/// budget - never per-day.
const double timetableIdealPxPerMin = 0.9;

/// Never scale minutes below this; an extreme range (all-day events)
/// degrades gracefully instead of vanishing.
const double timetableMinPxPerMin = 0.3;

/// The first/last wall minute of a week's shared time axis, or null when
/// no weekday carries content (weekend-only stretch, empty feed).
class TimeAxis {
  final int startMin;
  final int endMin;
  const TimeAxis(this.startMin, this.endMin);
  int get rangeMin => endMin - startMin;
}

/// One painted day-timetable block in plain values: wall-minute start and
/// length in minutes. `content` marks a real lecture/tutorial/lunch row
/// (drives the running-chip suppression of the now-line label).
class NowBlock {
  final int beginMin;
  final int durationMin;
  final bool content;

  const NowBlock(
      {required this.beginMin,
      required this.durationMin,
      this.content = false});

  int get endMin => beginMin + durationMin;
}

/// The week's shared axis: earliest content begin to latest content end,
/// rounded OUTWARD to full hours so the day's first/last gridline is a
/// round clock time (8:00..20:00, not 7:53..20:14).
TimeAxis? weekTimeAxis(List<List<NowBlock>> days) {
  int? lo, hi;
  for (final blocks in days) {
    for (final b in blocks) {
      if (lo == null || b.beginMin < lo) lo = b.beginMin;
      if (hi == null || b.endMin > hi) hi = b.endMin;
    }
  }
  if (lo == null || hi == null || hi <= lo) return null;
  return TimeAxis((lo ~/ 60) * 60, ((hi + 59) ~/ 60) * 60);
}

/// ONE px/min for the whole week: design scale unless the axis range does
/// not fit the card budget.
double axisPxPerMin({required double capPx, required int rangeMin}) {
  if (rangeMin <= 0) return timetableIdealPxPerMin;
  return (capPx / rangeMin)
      .clamp(timetableMinPxPerMin, timetableIdealPxPerMin)
      .toDouble();
}

/// y of the now-line inside the axis column, or null when the wall minute
/// lies outside the axis (the line never floats before the day's window
/// opens or after it closes). Pure linear: minute -> pixel, globally.
double? nowLineY({
  required TimeAxis axis,
  required double pxPerMin,
  required int minutesOfDay,
}) {
  if (minutesOfDay < axis.startMin || minutesOfDay >= axis.endMin) {
    return null;
  }
  return (minutesOfDay - axis.startMin) * pxPerMin;
}

/// The rectangle a block occupies on the axis column: (top, height) in px.
(double top, double height) blockRect(
        NowBlock b, TimeAxis axis, double pxPerMin) =>
    ((b.beginMin - axis.startMin) * pxPerMin, b.durationMin * pxPerMin);

/// One maximal set of mutually/touching-overlapping blocks: consecutive
/// blocks whose [endMin] reaches past the next block's begin join one
/// cluster; the cluster ENDS at the farthest end inside it (a 90-min
/// block starting before a 45-min one extends the cluster past the
/// 45-min block). Blocks that merely touch (end == next begin) are
/// neighbours, not overlapping - no side-by-side needed then.
List<List<int>> overlapClusters(List<NowBlock> blocks) {
  final out = <List<int>>[];
  var cluster = <int>[];
  int clusterEnd = 0;
  for (var i = 0; i < blocks.length; i++) {
    if (cluster.isNotEmpty && blocks[i].beginMin < clusterEnd) {
      cluster.add(i);
      if (blocks[i].endMin > clusterEnd) clusterEnd = blocks[i].endMin;
    } else {
      if (cluster.isNotEmpty) out.add(cluster);
      cluster = [i];
      clusterEnd = blocks[i].endMin;
    }
  }
  if (cluster.isNotEmpty) out.add(cluster);
  return out;
}

/// Side-by-side lane packing inside one overlap cluster (the classic
/// calendar algorithm): each block takes the FIRST lane whose current
/// last block has ended by its begin, else a fresh lane. Greedy over
/// begin-sorted input, so lane indices are < cluster.length.
List<int> packLanes(List<NowBlock> cluster) {
  final laneEnds = <int>[];
  final laneOf = <int>[];
  for (final b in cluster) {
    var lane = -1;
    for (var l = 0; l < laneEnds.length; l++) {
      if (laneEnds[l] <= b.beginMin) {
        lane = l;
        break;
      }
    }
    if (lane == -1) {
      lane = laneEnds.length;
      laneEnds.add(b.endMin);
    } else {
      laneEnds[lane] = b.endMin;
    }
    laneOf.add(lane);
  }
  return laneOf;
}
