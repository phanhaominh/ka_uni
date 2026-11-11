import 'package:flutter_test/flutter_test.dart';
import 'package:kit_mobile/timetable/logic/now_line.dart';

// The absolute time axis of the daily timetable: every carousel page maps
// the SAME wall window onto the SAME pixels, so these tests are the
// contract "09:45 is at the same height on Monday and Friday".

const axis8to14 = TimeAxis(8 * 60, 14 * 60);

void main() {
  group("weekTimeAxis", () {
    test("spans first content begin to last content end, rounded outward",
        () {
      final days = [
        [
          NowBlock(beginMin: 8 * 60 + 15, durationMin: 90, content: true),
          NowBlock(beginMin: 13 * 60, durationMin: 30, content: true),
        ],
        [NowBlock(beginMin: 8 * 60 - 10, durationMin: 60, content: true)],
      ];
      final a = weekTimeAxis(days)!;
      // 7:50 -> 7:00 floor; 13:30 -> 14:00 ceil: round clock edges
      expect(a.startMin, 7 * 60);
      expect(a.endMin, 14 * 60);
      expect(a.rangeMin, 7 * 60);
    });

    test("empty days (or an empty column) give no axis", () {
      expect(weekTimeAxis([]), isNull);
      expect(weekTimeAxis([[], []]), isNull);
    });
  });

  group("axisPxPerMin", () {
    test("design scale while the window fits the card", () {
      // 6h window, 742px budget: 0.9 would need 324px - fits
      expect(axisPxPerMin(capPx: 742, rangeMin: 360),
          timetableIdealPxPerMin);
    });

    test("shrinks only when the window cannot fit the card", () {
      // 12h = 720 min: at 0.9 that is 648px... fits 742; 16h = 960 needs
      // 864 -> cap decides
      expect(axisPxPerMin(capPx: 742, rangeMin: 960), closeTo(742 / 960, 1e-9));
    });

    test("never below the legibility floor", () {
      expect(axisPxPerMin(capPx: 100, rangeMin: 960),
          timetableMinPxPerMin);
    });

    test("degenerate range falls back to design scale", () {
      expect(axisPxPerMin(capPx: 742, rangeMin: 0), timetableIdealPxPerMin);
    });
  });

  group("nowLineY", () {
    test("pure linear map inside the window", () {
      // 9:45 on an 8:00 axis at 1 px/min would be 105; at 0.9 -> 94.5
      expect(
          nowLineY(
              axis: axis8to14, pxPerMin: 0.9, minutesOfDay: 9 * 60 + 45),
          closeTo(105 * 0.9, 1e-9));
    });

    test("the window's first minute paints at the top, the last does not",
        () {
      expect(nowLineY(axis: axis8to14, pxPerMin: 0.9, minutesOfDay: 8 * 60),
          0.0);
      expect(nowLineY(axis: axis8to14, pxPerMin: 0.9, minutesOfDay: 14 * 60),
          isNull);
    });

    test("outside the week's window there is no line", () {
      expect(
          nowLineY(
              axis: axis8to14, pxPerMin: 0.9, minutesOfDay: 7 * 60 + 59),
          isNull);
      expect(nowLineY(axis: axis8to14, pxPerMin: 0.9, minutesOfDay: 22 * 60),
          isNull);
    });

    test("equal minutes map to equal pixels on EVERY day", () {
      // THE regression the stacked rows never stopped failing (11./12.11:
      // fit factors and folded gap rows re-flowed each page on its own):
      // one axis + one scale, and the same wall minute resolves to the
      // same y no matter how full or empty the day is.
      const px = 0.9;
      final fullDay = [
        NowBlock(beginMin: 8 * 60, durationMin: 90, content: true),
        NowBlock(beginMin: 9 * 60 + 45, durationMin: 105, content: true),
        NowBlock(beginMin: 13 * 60, durationMin: 30, content: true),
      ];
      final lightDay = [
        NowBlock(beginMin: 11 * 60, durationMin: 90, content: true),
      ];
      for (final day in [fullDay, lightDay]) {
        expect(nowLineY(axis: axis8to14, pxPerMin: px, minutesOfDay: 9 * 60 + 45),
            closeTo((9 * 60 + 45 - 8 * 60) * px, 1e-9),
            reason: 'day with ${day.length} blocks moved 09:45');
      }
      // and a lecture's rect is its duration, identical on both pages
      final b = NowBlock(beginMin: 9 * 60 + 45, durationMin: 90);
      final (top, height) = blockRect(b, axis8to14, px);
      expect(top, closeTo((9 * 60 + 45 - 8 * 60) * px, 1e-9));
      expect(height, closeTo(90 * px, 1e-9));
    });
  });

  group("overlap clusters and lanes", () {
    test("touching blocks are neighbours, not one cluster", () {
      final blocks = [
        NowBlock(beginMin: 8 * 60, durationMin: 90),
        NowBlock(beginMin: 9 * 60 + 30, durationMin: 60),
      ];
      expect(overlapClusters(blocks), [
        [0],
        [1]
      ]);
    });

    test("the Friday 11.13 chain: 8:00 tut, 9:00 seminar, 9:45 tut", () {
      // 08:00+90 overlaps 09:00; 09:00+90 reaches past 09:45 -> ONE
      // cluster; the 9:45 tutorial re-uses lane 0 (8:00 block ended at
      // 9:30) - two side-by-side columns, raw stacking printed ink on ink
      final blocks = [
        NowBlock(beginMin: 8 * 60, durationMin: 90),
        NowBlock(beginMin: 9 * 60, durationMin: 90),
        NowBlock(beginMin: 9 * 60 + 45, durationMin: 90),
      ];
      expect(overlapClusters(blocks), [
        [0, 1, 2]
      ]);
      expect(packLanes(blocks), [0, 1, 0]);
    });

    test("a disjoint day packs into one lane each", () {
      final blocks = [
        NowBlock(beginMin: 8 * 60, durationMin: 90),
        NowBlock(beginMin: 13 * 60, durationMin: 30),
      ];
      expect(overlapClusters(blocks), [
        [0],
        [1]
      ]);
      expect(packLanes([blocks[0]]), [0]);
    });
  });
}
