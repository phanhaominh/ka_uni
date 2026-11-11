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

/// A side-by-side lane packing inside one overlap cluster (the classic
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

/// Duration from which a block is a BLOCK EVENT. KIT lectures run 90
/// minutes (long ones up to ~3h - they still deserve a wide box); a
/// 4-hour-plus event is a block seminar/exercise day whose hours would
/// otherwise strangle every overlapping row: it takes a narrow RIGHT
/// RAIL instead and normal rows keep a full-title width (11.20: the
/// 09:00-17:00 Seminar IC sharing half the card all afternoon cut
/// "Basics of Manufacturing Technology" to "Basics of Manufa...").
const int blockEventMinMinutes = 240;

/// One placed row: left/width as FRACTIONS of the card, zero-collision by
/// construction (non-rail rows stop exactly where the rails start).
class RowPlace {
  final double left;
  final double width;
  const RowPlace(this.left, this.width);
}

/// Rail layout of one overlap cluster (see [blockEventMinMinutes]):
/// block events take narrow RIGHT RAILS (longest outermost), normal rows
/// keep the LEFT region. With a single lane of normal rows every row owns
/// the whole left region (KIT's Fridays: tutorials/lunch/basics never
/// touch each other, only the seminar - so the 14:00 "Basics of
/// Manufacturing Technology" keeps a readable width while the 8-h
/// Seminar IC lives in its right rail). With several normal lanes they
/// tile the left region uniformly, and every normal box stays left of
/// every rail box: boxes that overlap in time ALWAYS tile horizontally,
/// no ink on ink, by construction.
List<RowPlace> placeCluster(List<NowBlock> cluster) {
  var rails = [
    for (var i = 0; i < cluster.length; i++)
      if (cluster[i].durationMin >= blockEventMinMinutes) i
  ];
  if (rails.isEmpty) {
    final lanes = packLanes(cluster);
    final n = lanes.fold<int>(1, (m, l) => l + 1 > m ? l + 1 : m);
    return [
      for (final l in lanes) RowPlace(l / n, 1 / n)
    ];
  }
  // longest block event furthest right: its text gets the outermost room
  rails.sort((a, b) =>
      cluster[b].durationMin.compareTo(cluster[a].durationMin));
  // each rail 0.30/k of the card (k = rail count) - the left region for
  // normal rows is 0.70 no matter how many block events stack up; on a
  // 316dp phone card 0.70-30padding ≈ 184dp fits a lecture title across
  // two lines, while the block event wraps inside its rail
  final rw = 0.30 / rails.length;
  final base = 1 - rails.length * rw;
  final places = List<RowPlace?>.filled(cluster.length, null);
  for (var r = 0; r < rails.length; r++) {
    places[rails[r]] = RowPlace(1 - (r + 1) * rw, rw);
  }
  final normal = [
    for (var i = 0; i < cluster.length; i++)
      if (places[i] == null) i
  ];
  final lanes = packLanes([for (final b in normal) cluster[b]]);
  final n = lanes.fold<int>(1, (m, l) => l + 1 > m ? l + 1 : m);
  for (var m = 0; m < normal.length; m++) {
    if (n == 1) {
      // no normal-vs-normal conflict: each row reclaims the rails it does
      // NOT overlap in time. Right edge = left edge of the INNERMOST
      // overlapped rail (rails[k].left = 1-(k+1)*rw falls with k, so the
      // largest index wins - counting rails would let a row that overlaps
      // only the INNER rail drive straight through the outer one's band
      // at shared minutes)
      final b = cluster[normal[m]];
      var maxRail = -1;
      for (var r = 0; r < rails.length; r++) {
        if (b.beginMin < cluster[rails[r]].endMin &&
            cluster[rails[r]].beginMin < b.endMin &&
            r > maxRail) {
          maxRail = r;
        }
      }
      places[normal[m]] = RowPlace(0, 1 - (maxRail + 1) * rw);
    } else {
      final w = base / n;
      places[normal[m]] = RowPlace(lanes[m] * w, w);
    }
  }
  return places.cast<RowPlace>();
}
