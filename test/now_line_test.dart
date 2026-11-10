import 'package:flutter_test/flutter_test.dart';
import 'package:kit_mobile/timetable/logic/now_line.dart';

// 8:00..9:30 then 9:45..11:30 - the classic KIT blocks, minute-based.
const morning = [
  NowBlock(beginMin: 480, durationMin: 90, border: true),
  NowBlock(beginMin: 585, durationMin: 105, border: true),
];

// 1 px/min walk of [morning]: 90 + seam + 105.
const morningH = [90.0, 105.0];

void main() {
  test("before the first block there is no line", () {
    expect(
        nowLineY(blocks: morning, heights: morningH, minutesOfDay: 7 * 60 + 30),
        isNull);
  });

  test("at or after the last block's end there is no line", () {
    // last block ends at 11:30 = 690
    expect(nowLineY(blocks: morning, heights: morningH, minutesOfDay: 690),
        isNull);
    expect(nowLineY(blocks: morning, heights: morningH, minutesOfDay: 22 * 60),
        isNull);
    // one minute earlier is still inside
    expect(nowLineY(blocks: morning, heights: morningH, minutesOfDay: 689),
        closeTo(90 + 1 + 104, 1e-9));
  });

  test("inside a block the line rides its minute offset", () {
    // 8:30 = 30 min into the 90-min (90-px-high) first row
    expect(nowLineY(blocks: morning, heights: morningH, minutesOfDay: 510),
        closeTo(30, 1e-9));
    // 10:30 = 45 min into the second row, which sits below 90px + 1px seam
    expect(nowLineY(blocks: morning, heights: morningH, minutesOfDay: 630),
        closeTo(90 + 1 + 45, 1e-9));
  });

  test("a minute in a dead gap sticks to the previous block's bottom seam", () {
    // 9:40 is inside neither block (first ends 9:30, second starts 9:45)
    expect(nowLineY(blocks: morning, heights: morningH, minutesOfDay: 580),
        closeTo(91, 1e-9));
  });

  test("a minute on a block boundary belongs to the block starting there", () {
    expect(nowLineY(blocks: morning, heights: morningH, minutesOfDay: 585),
        closeTo(91, 1e-9));
  });

  test("heights (not minutes) define the walk: floors rescale the offset", () {
    // a 90-min row paid 48px: halfway in minutes is halfway in pixels
    const floored = [
      NowBlock(beginMin: 480, durationMin: 90, border: true, content: true)
    ];
    expect(nowLineY(blocks: floored, heights: const [48.0], minutesOfDay: 525),
        closeTo(24, 1e-9));
  });

  test("gap-band blocks walk the wall window their pixels cover", () {
    const withGap = [
      NowBlock(beginMin: 480, durationMin: 60, border: true, content: true),
      NowBlock(beginMin: 540, durationMin: 150, border: true),
      NowBlock(beginMin: 690, durationMin: 90, border: true, content: true),
    ];
    // gap row: 150 wall minutes paid 36px -> 10:00, i.e. 60 of the row's
    // 150, sits at 54 + seam + 36/150*60
    expect(
        nowLineY(
            blocks: withGap,
            heights: const [54.0, 36.0, 81.0],
            minutesOfDay: 10 * 60),
        closeTo(54 + 1 + 36 / 150 * 60, 1e-9));
  });

  test("empty column has no line, effort zero and ideal week scale", () {
    expect(nowLineY(blocks: const [], heights: const [], minutesOfDay: 600),
        isNull);
    expect(dayEffort(const []), 0);
    expect(
        weekPxPerMin(viewportPx: 742, days: const []), timetableIdealPxPerMin);
  });

  group("dayColumnHeights", () {
    test("long rows are exactly proportional, short rows hit the floor", () {
      const blocks = [
        NowBlock(beginMin: 480, durationMin: 90, content: true),
        NowBlock(beginMin: 600, durationMin: 20, content: true),
      ];
      final h =
          dayColumnHeights(pxPerMin: 0.9, blocks: blocks, viewportPx: 742);
      expect(h[0], closeTo(81, 1e-9));
      expect(h[1], timetableContentFloorPx);
    });

    test("free rows fold at the cap and stay honest below it", () {
      const blocks = [
        NowBlock(beginMin: 480, durationMin: 15), // 13.5 px: honest
        NowBlock(beginMin: 495, durationMin: 120), // 108 -> cap
        NowBlock(beginMin: 615, durationMin: 30), // 27: below cap
      ];
      final h =
          dayColumnHeights(pxPerMin: 0.9, blocks: blocks, viewportPx: 742);
      expect(h[0], closeTo(13.5, 1e-9));
      expect(h[1], closeTo(40 * 0.9, 1e-9));
      expect(h[2], closeTo(27, 1e-9));
    });

    test("a jammed day shrinks uniformly, never clips", () {
      // 8 content rows at floor = 384 + 7 seams > a 200px viewport
      final blocks = [
        for (var i = 0; i < 8; i++)
          NowBlock(
              beginMin: 480 + 30 * i,
              durationMin: 30,
              border: true,
              content: true)
      ];
      final h =
          dayColumnHeights(pxPerMin: 0.9, blocks: blocks, viewportPx: 200);
      final total = h.fold<double>(0, (s, v) => s + v) + 8;
      expect(total, closeTo(200, 1e-6));
      expect(h.every((v) => v > 0), isTrue);
      // uniform: all rows equal
      expect(h.toSet().length, 1);
    });

    test("empty blocks yield no heights", () {
      expect(dayColumnHeights(pxPerMin: 0.9, blocks: const [], viewportPx: 742),
          isEmpty);
    });
  });

  group("weekPxPerMin", () {
    test("the busiest day decides, light days follow the same scale", () {
      final busy = [
        NowBlock(beginMin: 480, durationMin: 90, content: true),
        NowBlock(beginMin: 570, durationMin: 510, content: true),
      ];
      final light = [
        NowBlock(beginMin: 480, durationMin: 90, content: true),
      ];
      final px = weekPxPerMin(viewportPx: 500, days: [light, busy]);
      expect(px, closeTo(500 / 600, 1e-9));
      // THE regression: equal durations, equal pixels on every day -
      // the 90-min lecture is identical on the busy and the light page
      final hBusy =
          dayColumnHeights(pxPerMin: px, blocks: busy, viewportPx: 500);
      final hLight =
          dayColumnHeights(pxPerMin: px, blocks: light, viewportPx: 500);
      expect(hBusy.first, closeTo(hLight.single, 1e-9));
      expect(hBusy.first, closeTo(90 * px, 1e-9));
    });

    test("capped gaps count as capped effort", () {
      final withVoid = [
        NowBlock(beginMin: 480, durationMin: 90, content: true),
        NowBlock(beginMin: 570, durationMin: 240), // folds at 40
      ];
      expect(dayEffort(withVoid), 90 + 40);
      // a 3h void alone must NOT squash the week below design scale
      expect(weekPxPerMin(viewportPx: 742, days: [withVoid]),
          timetableIdealPxPerMin);
    });

    test("a week fitter than the floor still clamps to 0.3", () {
      final mega = [
        NowBlock(beginMin: 0, durationMin: 1440, content: true),
      ];
      expect(weekPxPerMin(viewportPx: 200, days: [mega]), timetableMinPxPerMin);
    });
  });
}
