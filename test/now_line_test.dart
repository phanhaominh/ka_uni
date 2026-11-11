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

  group("placeCluster rails", () {
    // Friday 20.11 data: tutorials 8:00/9:45, the 09:00-17:00 block
    // seminar, lunch, and a 3¼h afternoon lecture (195 min: long, but
    // under the 240 rail threshold - long lectures keep wide boxes).
    // The block seminar may not gut-cut the normal rows: it lives in a
    // right rail, the rest keeps the left region.
    final friday = [
      NowBlock(beginMin: 8 * 60, durationMin: 90, content: true),
      NowBlock(beginMin: 9 * 60, durationMin: 480, content: true),
      NowBlock(beginMin: 9 * 60 + 45, durationMin: 90, content: true),
      NowBlock(beginMin: 13 * 60, durationMin: 30, content: true),
      NowBlock(beginMin: 14 * 60, durationMin: 195, content: true),
    ];

    test("block seminar takes a right rail, basics keeps the left", () {
      final p = placeCluster(friday);
      expect(p[1].left, greaterThan(0.5),
          reason: 'the 8h seminar belongs in the right rail');
      expect(p[4].left, 0.0,
          reason: '"Basics of Manufacturing Technology" reads from the '
              'left edge - the 50/50 lane split truncated its title');
      expect(p[4].width, greaterThan(0.5),
          reason: 'full lecture titles need > half the card');
      // zero collision at every shared minute (basics 14:00-17:15 vs
      // seminar 09:00-17:00): the boxes tile, never overlap
      for (var i = 0; i < p.length; i++) {
        for (var j = i + 1; j < p.length; j++) {
          final timeOverlap = friday[i].beginMin < friday[j].endMin &&
              friday[j].beginMin < friday[i].endMin;
          final xOverlap = p[i].left < p[j].left + p[j].width - 1e-9 &&
              p[j].left < p[i].left + p[i].width - 1e-9;
          if (timeOverlap) {
            expect(xOverlap, isFalse,
                reason: 'rows $i and $j share minutes AND pixels');
          }
        }
      }
    });

    test("two rails: a row overlapping ONLY the inner rail stops at it",
        () {
      // begin-sorted cluster: 8:30 lecture, 8:00-12:00 block (4h),
      // 13:00-20:00 block (7h). Longest goes outermost, so the 8-12
      // block is the INNER rail - the lecture may not reach into its
      // x-band at shared minutes even though it overlaps only ONE rail
      final p = placeCluster([
        NowBlock(beginMin: 8 * 60 + 30, durationMin: 30, content: true),
        NowBlock(beginMin: 8 * 60, durationMin: 240, content: true),
        NowBlock(beginMin: 13 * 60, durationMin: 420, content: true),
      ]);
      final twoRails = [
        [p[0], p[1], p[2]],
      ].first;
      for (final pair in [
        [0, 1],
        [0, 2],
        [1, 2]
      ]) {
        final a = twoRails[pair[0]], b = twoRails[pair[1]];
        final xOverlap =
            a.left < b.left + b.width - 1e-9 && b.left < a.left + a.width - 1e-9;
        expect(xOverlap, isFalse,
            reason: 'rails ${pair} share horizontal space');
      }
    });

    test("a cluster without block events still splits 50/50 by lanes", () {
      final p = placeCluster([
        NowBlock(beginMin: 8 * 60, durationMin: 90),
        NowBlock(beginMin: 9 * 60, durationMin: 90),
      ]);
      expect([p[0].left, p[0].width], [0.0, 0.5]);
      expect([p[1].left, p[1].width], [0.5, 0.5]);
    });
  });
}
