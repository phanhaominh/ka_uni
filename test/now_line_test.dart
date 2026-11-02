import 'package:flutter_test/flutter_test.dart';
import 'package:kit_mobile/timetable/logic/now_line.dart';

// 8:00..9:30 then 9:45..11:30 - the classic KIT blocks, minute-based.
const morning = [
  NowBlock(beginMin: 480, durationMin: 90, border: true),
  NowBlock(beginMin: 585, durationMin: 105, border: true),
];

void main() {
  test("before the first block there is no line", () {
    expect(
        nowLineY(blocks: morning, minutesOfDay: 7 * 60 + 30, pxPerMin: 1),
        isNull);
  });

  test("at or after the last block's end there is no line", () {
    // last block ends at 11:30 = 690
    expect(nowLineY(blocks: morning, minutesOfDay: 690, pxPerMin: 1), isNull);
    expect(nowLineY(blocks: morning, minutesOfDay: 22 * 60, pxPerMin: 1),
        isNull);
    // one minute earlier is still inside
    expect(
        nowLineY(blocks: morning, minutesOfDay: 689, pxPerMin: 1),
        closeTo(90 + 1 + 104, 1e-9));
  });

  test("inside a block the line rides its minute offset", () {
    // 8:30, 1 px/min → 30 px into the first block
    expect(
        nowLineY(blocks: morning, minutesOfDay: 8 * 60 + 30, pxPerMin: 1),
        closeTo(30, 1e-9));
  });

  test("later blocks stack content height PLUS their border", () {
    // 10:15 in block 2: block 1 paints 90 px content + 1 px border
    expect(
        nowLineY(blocks: morning, minutesOfDay: 10 * 60 + 15, pxPerMin: 1),
        closeTo(90 + 1 + 30, 1e-9));
    // without the border the seam is 1 px earlier - the walk must mirror the
    // real column where only begin.hour < 17 rows draw a bottom border
    const noBorder = [
      NowBlock(beginMin: 480, durationMin: 90),
      NowBlock(beginMin: 585, durationMin: 105),
    ];
    expect(
        nowLineY(blocks: noBorder, minutesOfDay: 10 * 60 + 15, pxPerMin: 1),
        closeTo(120, 1e-9));
  });

  test("a minute in a dead gap sticks to the previous block's bottom seam",
      () {
    // 9:35: block 1 ended at 9:30, block 2 starts at 9:45 - zero height
    // gap; the line parks on the seam INCLUDING block 1's border
    expect(
        nowLineY(blocks: morning, minutesOfDay: 9 * 60 + 35, pxPerMin: 1),
        closeTo(91, 1e-9));
    const noBorder = [
      NowBlock(beginMin: 480, durationMin: 90),
      NowBlock(beginMin: 585, durationMin: 105),
    ];
    expect(
        nowLineY(blocks: noBorder, minutesOfDay: 9 * 60 + 35, pxPerMin: 1),
        closeTo(90, 1e-9));
  });

  test("a minute on a block boundary belongs to the block starting there",
      () {
    // adjacent blocks (no gap): 9:30 = end of block 1 = first minute of 2
    const adjacent = [
      NowBlock(beginMin: 480, durationMin: 90),
      NowBlock(beginMin: 570, durationMin: 105),
    ];
    expect(
        nowLineY(blocks: adjacent, minutesOfDay: 9 * 60 + 30, pxPerMin: 1),
        closeTo(90, 1e-9));
  });

  test("pxPerMin scales content AND the gap seam, never the border", () {
    // 0.9 px/min: 30 min → 27 px inside block 1
    expect(
        nowLineY(blocks: morning, minutesOfDay: 8 * 60 + 30, pxPerMin: 0.9),
        closeTo(27, 1e-9));
    // gap seam: 90*0.9 content + the fixed 1 px border
    expect(
        nowLineY(blocks: morning, minutesOfDay: 9 * 60 + 35, pxPerMin: 0.9),
        closeTo(82, 1e-9));
  });

  test("empty column yields no line and the full 0.9 factor", () {
    expect(
        nowLineY(blocks: const [], minutesOfDay: 600, pxPerMin: 1), isNull);
    expect(
        dayColumnFactor(viewportPx: 500, blocks: const []), closeTo(0.9, 1e-9));
  });

  test("factor stays 0.9 while the natural column fits", () {
    // 100 min*0.9 + 1 border = 91 ≤ 100
    const small = [NowBlock(beginMin: 480, durationMin: 100, border: true)];
    expect(dayColumnFactor(viewportPx: 100, blocks: small), closeTo(0.9, 1e-9));
    // exactly on the nose (total == viewport) still keeps the old look
    expect(dayColumnFactor(viewportPx: 91, blocks: small), closeTo(0.9, 1e-9));
  });

  test("factor shrinks to the exact fit when the day overflows", () {
    // the generic schedule: 630 min, six <17h borders, ~545 px viewport
    const day = [
      NowBlock(beginMin: 480, durationMin: 90, border: true),
      NowBlock(beginMin: 585, durationMin: 105, border: true),
      NowBlock(beginMin: 690, durationMin: 90, border: true),
      NowBlock(beginMin: 780, durationMin: 60, border: true),
      NowBlock(beginMin: 840, durationMin: 90, border: true),
      NowBlock(beginMin: 945, durationMin: 105, border: true),
      NowBlock(beginMin: 1050, durationMin: 90), // 17:30 row: no border
    ];
    final f = dayColumnFactor(viewportPx: 545, blocks: day);
    expect(f, lessThan(0.9));
    // the fitted factor makes the column exactly fill the viewport
    expect(f * 630 + 6, closeTo(545, 1e-9));
  });

  test("factor clamps at 0.3 and never exceeds 0.9", () {
    const absurd = [NowBlock(beginMin: 0, durationMin: 10000)];
    expect(dayColumnFactor(viewportPx: 100, blocks: absurd),
        closeTo(0.3, 1e-9));
    const tiny = [NowBlock(beginMin: 480, durationMin: 10)];
    // viewport dwarfs the column: 0.9 is the cap, not (vp-borders)/dur
    expect(dayColumnFactor(viewportPx: 100000, blocks: tiny),
        closeTo(0.9, 1e-9));
  });
}
