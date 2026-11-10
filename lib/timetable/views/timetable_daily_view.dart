import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:kit_mobile/common_ui/block_container.dart';
import 'package:kit_mobile/constants/view_constants.dart';
import 'package:kit_mobile/l10n/l10n.dart';
import 'package:kit_mobile/module/models/module.dart';
import 'package:kit_mobile/state_management/kit_provider.dart';
import 'package:kit_mobile/timetable/logic/now_clock.dart';
import 'package:kit_mobile/timetable/logic/now_line.dart';
import 'package:kit_mobile/timetable/models/timetable_appointment.dart';
import 'package:kit_mobile/timetable/models/webcal.dart';
import 'package:kit_mobile/timetable/pages/timetable_appointment_page.dart';
import 'package:kit_mobile/tutorials/data/tutorial_manager.dart';
import 'package:kit_mobile/tutorials/models/tutorial.dart';
import 'package:provider/provider.dart';

import '../models/timetable_daily.dart';

String _hm(int minutesOfDay) =>
    "${(minutesOfDay ~/ 60).toString().padLeft(2, "0")}:${(minutesOfDay % 60).toString().padLeft(2, "0")}";

/// "1:30" / "0:45" - a duration, so no hour padding on purpose.
String _dur(int minutes) =>
    "${minutes ~/ 60}:${(minutes % 60).toString().padLeft(2, "0")}";

/// A block is "content" when it carries a lecture, tutorial OR lunch break:
/// the lunch bar reads as day structure, not as a free slot.
bool _isContent(TimetableAppointment a) =>
    !a.isEmpty || a.type == TimetableAppointmentType.lunchBreak;

int _beginMin(TimetableAppointment a) => a.begin.hour * 60 + a.begin.minute;

/// Wall span of a real row: the wall-clock difference of its endpoints,
/// NEVER the full-stamp difference (template rows mix dates). Rows whose
/// wall span would be zero or negative (all-day VALUE=DATE events, ends
/// stored past midnight) render with the parser's +90-minute default
/// length instead of a column-eating monster block.
int _spanMin(TimetableAppointment a) {
  final s = (a.end.hour * 60 + a.end.minute) - _beginMin(a);
  return s > 0 ? s : 90;
}

/// Minutes row [i] occupies on the wall clock: content rows their own
/// span; EMPTY 'Free' rows stretch from the previous content row's end
/// to the next content row's begin, so chip text, row height and the
/// now-line walk all speak about the REAL gap - the scaffold
/// placeholder's generic span (always 1:30/1:45) used to misreport it.
/// TWO rules keep the phantom bands out of the column: only the LAST
/// empty row of a consecutive run owns the gap (the scaffold hands out
/// several placeholder blocks per gap, and if every one of them counted
/// the same minutes the gap band would be 2-3x its real size and the
/// fit-factor would squash every lecture), and a run between two
/// ADJACENT classes (gap <= 0, e.g. the 90-min scaffold block sitting
/// between a class that ends and the next that begins at the same
/// minute) claims ZERO - [TimetableDailyView.build] drops such rows,
/// which used to open an invisible 90-minute void between neighbours.
int _rowMin(List<TimetableAppointment> rows, int i) {
  final a = rows[i];
  if (_isContent(a)) return _spanMin(a);
  var prev = i - 1, next = i + 1;
  while (prev >= 0 && !_isContent(rows[prev])) prev--;
  while (next < rows.length && !_isContent(rows[next])) next++;
  if (prev < 0 || next >= rows.length) return _spanMin(a);
  // not the last row of the empty run: the run's owner below claims it
  if (next != i + 1) return 0;
  final gap =
      _beginMin(rows[next]) - (_beginMin(rows[prev]) + _spanMin(rows[prev]));
  return gap > 0 ? gap : 0;
}

/// A hairline is drawn after block [i] only where it separates something:
/// after the LAST row, and anywhere inside a pure empty run (the leading
/// or trailing void of the day), a line would float over nothing. ONE
/// list built by this rule feeds both the row stack and the now-line
/// walk, so painted and measured geometry can never disagree.
List<bool> dayColumnSeams(List<TimetableAppointment> rows) => [
      for (var i = 0; i < rows.length; i++)
        i < rows.length - 1 && (_isContent(rows[i]) || _isContent(rows[i + 1]))
    ];

class TimetableDailyView extends StatelessWidget {
  final TimetableDaily tt;

  /// The WEEKLY view sets this only on the page whose concrete date is
  /// today; the model is a weekday template, so "today" can never be
  /// derived from [tt] itself. Enables the now overlay + running chips.
  final bool showNowLine;

  /// Feed deltas whose when/oldWhen land on this page's date (the weekly
  /// view filters). Rows match them by BLOCK TIME only, per the
  /// isAtTheSameBlockAs precedent - the change carries a real date, the
  /// placeholder appointments only a block minute.
  final List<IcsChange> changes;

  /// Whether this page's rows may open their detail page. The weekly view
  /// sets it ONLY for the centered page: a side page's rows used to win the
  /// tap arena over the page's centering gesture, so tapping a lecture on a
  /// not-yet-centered day opened a full-screen detail instead of gliding the
  /// carousel. When false the row detector stays silent and the page-level
  /// centering tap (in timetable_weekly_view) receives the tap.
  final bool rowTapsEnabled;

  const TimetableDailyView(
      {super.key,
      required this.tt,
      this.showNowLine = false,
      this.changes = const [],
      this.rowTapsEnabled = true});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tutorialManager = Provider.of<TutorialManager>(context);
    final kitProvider = Provider.of<KITProvider>(context);

    final modulesById = <String, KITModule>{};
    for (final module in kitProvider.campusManager.rowModules.values) {
      if (module.id.isNotEmpty) {
        modulesById[module.id] = module;
      }
    }

    final semesterString = KITProvider.currentSemesterString;
    final tutorialsList = tutorialManager
        .tutorialsForWeekday(semesterString, tt.weekday)
        .map((tutorial) {
      final module = modulesById[tutorial.moduleId];
      if (module != null && module.title.trim().isNotEmpty) {
        return tutorial.copyWith(moduleTitle: module.title.trim());
      }
      return tutorial;
    }).toList(growable: false);

    final tutorialsByBlock = <int, List<Tutorial>>{};
    for (final tutorial in tutorialsList) {
      tutorialsByBlock.putIfAbsent(tutorial.blockIndex, () => []).add(tutorial);
    }

    final appointmentsByBlock = tt.appointmentsWithTutorials(tutorialsByBlock);

    // the appointment a block actually renders: first non-empty entry, or
    // the lone placeholder when the block holds nothing else
    // The template appends non-colliding events (personal ICS, one-shot
    // feed entries) after the generic blocks, and tutorials attach by
    // generic block INDEX - so the list order must stay untouched until
    // the merge is done; only then order the rendered rows chronologically
    // (gaps, seams and the now-line all assume time order: a 10:00 own
    // appointment used to render below the 15:45 lecture).
    final rows = appointmentsByBlock
        .map((block) => block
            .whereType<TimetableAppointment>()
            .where((appointment) => !appointment.isEmpty || block.length <= 1)
            .first)
        .toList(growable: false)
      // time-OF-DAY, never the full stamp: template rows carry mixed dates
      // (feed occurrence dates vs DateTime.now()-stamped placeholders and
      // lunch rows), so a raw DateTime compare put Nov-2's 13:00 lunch
      // above Nov-5's 08:00 lecture on future carousel pages. Dart's
      // sort is stable: equal-minute rows keep their template order.
      ..sort((a, b) => (a.begin.hour * 60 + a.begin.minute)
          .compareTo(b.begin.hour * 60 + b.begin.minute));

    if (!rows.any(_isContent)) return _dayFree(context);

    // Leading/trailing scaffold voids outside the content range used to
    // eat up to half the page at full scale; only the void BETWEEN real
    // rows carries meaning (and a chip), so trim outside the range.
    final trimmed = rows.sublist(
        rows.indexWhere(_isContent), rows.lastIndexWhere(_isContent) + 1);
    // Scaffold placeholder rows with no minutes of their own (see _rowMin)
    // claim no pixels and no chip - keep them out so the column's height
    // budget is wall-clock truth only.
    final day = [
      for (var i = 0; i < trimmed.length; i++)
        if (_isContent(trimmed[i]) || _rowMin(trimmed, i) > 0) trimmed[i]
    ];

    final mins = [for (var i = 0; i < day.length; i++) _rowMin(day, i)];
    final seams = dayColumnSeams(day);
    final blocks = [
      for (var i = 0; i < day.length; i++)
        NowBlock(
            beginMin: _beginMin(day[i]), durationMin: mins[i], border: seams[i])
    ];

    return LayoutBuilder(builder: (context, constraints) {
      // ONE factor drives every row height AND the now-line walk, so the
      // line can never sit over a row it did not measure (was: a hardcoded
      // 0.9 that overflowed days with long lectures)
      final now = NowClock.timeSource();
      final nowMinutes = now.hour * 60 + now.minute;
      final factor =
          dayColumnFactor(viewportPx: constraints.maxHeight, blocks: blocks);
      // Exact column height (rows + seam hairlines). A light day (two
      // morning lectures on a Friday) must not dangle at the top of the
      // tall carousel card with a dead void under it - the whole column,
      // now-line included, centres as ONE unit; a full day measures the
      // viewport anyway and stays exactly as before.
      final columnH = blocks.fold<double>(
          0, (s, b) => s + b.durationMin * factor + (b.border ? 1 : 0));
      return Align(
        alignment: Alignment.centerLeft,
        child: SizedBox(
          width: constraints.maxWidth,
          height: columnH,
          child: Stack(
            children: [
              Column(
                children: [
                  for (var i = 0; i < day.length; i++)
                    _rowWithSeam(context, day, mins, i, factor, seams[i],
                        constraints.maxWidth)
                ],
              ),
              if (showNowLine)
                Positioned.fill(
                  // CustomPaint without hitTestSelf never absorbs taps; the
                  // label is for screen readers, the pixels speak for themselves
                  child: Semantics(
                    label: L10n.t("timetable.nowLineLabel", [_hm(nowMinutes)]),
                    child: RepaintBoundary(
                      child: CustomPaint(
                        painter: _NowLinePainter(
                          blocks: blocks,
                          pxPerMin: factor,
                          color: theme.colorScheme.primary,
                          textStyle: theme.textTheme.bodyLarge?.copyWith(
                                  color: theme.colorScheme.primary) ??
                              TextStyle(
                                  color: theme.colorScheme.primary,
                                  fontSize: 16),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      );
    });
  }

  /// One 1px hairline between consecutive blocks, inset to the text
  /// gutter so it never touches the card's rounded frame. EXACTLY 1px,
  /// drawn iff [seam] - the same flag the blocks list handed to
  /// dayColumnFactor/nowLineY, so the line only sits where a measured row is.
  Widget _rowWithSeam(BuildContext context, List<TimetableAppointment> rows,
      List<int> mins, int i, double factor, bool seam, double fullW) {
    final row = _row(context, rows, mins, i, factor, fullW);
    if (!seam) return row;
    return Column(
      children: [
        row,
        Container(
          height: 1,
          margin: const EdgeInsets.symmetric(horizontal: defaultPagePadding),
          color: Theme.of(context).dividerColor,
        ),
      ],
    );
  }

  Widget _row(BuildContext context, List<TimetableAppointment> rows,
      List<int> mins, int i, double factor, double fullW) {
    final theme = Theme.of(context);
    final appointment = rows[i];

    if (!_isContent(appointment)) {
      final ghost = _ghostFor(appointment);
      if (ghost != null) {
        return _ghostCard(context, appointment, ghost, factor, mins[i]);
      }
      // a slot between two lectures is worth naming; one at either end of
      // the day is only a seam
      final boxedIn = i > 0 &&
          i < rows.length - 1 &&
          _isContent(rows[i - 1]) &&
          _isContent(rows[i + 1]);
      return SizedBox(
        // A free block must read as empty: the placeholder dash and
        // its time badge used to render like a lecture called "-".
        height: mins[i] * factor,
        child: boxedIn
            ? Center(
                child: Text(
                  L10n.t("timetable.freeGap", [_dur(mins[i])]),
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.outline),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              )
            : null,
      );
    }

    final isTut = appointment.type == TimetableAppointmentType.tutorial;
    // lunch shows the localized word, not the raw feed/model title
    final titleText = appointment.type == TimetableAppointmentType.lunchBreak
        ? L10n.t("timetable.mittagspause")
        : appointment.displayTitle;
    // weekday suffix kills the carousel-wide duplicate Hero tags: lunch
    // rows share title AND the empty id across all five pages
    final heroSuffix = "_${tt.weekday.index}";
    final roomDelta = _roomDeltaFor(appointment);
    final hasPlace = appointment.place.title.isNotEmpty;
    final deltaText = roomDelta == null
        ? null
        : L10n.t(
            "timetable.changeRoomDelta", [roomDelta.oldRoom!, roomDelta.room]);

    // duration-pinned height doubles as the geometry the now-line walks,
    // so a 60-min block must give up text lines instead of pushing its
    // words over the neighbour's first row (what an unbounded text
    // column inside a fixed SizedBox did: AUDIT-test bled into KLAUSUR)
    final boxH = mins[i] * factor;
    final textScale = MediaQuery.textScalerOf(context);
    // the HH:MM rides bodyLarge and claims a line of its own at the top
    // of the column, so the title/place budget starts below it; the row
    // content is TOP-anchored (calendar convention) — centring made a
    // sparse day's short blocks float their words in mid-box and crammed
    // the place line of full ones onto the seam hairline
    const topPad = spaceSm;
    final badgeFont = theme.textTheme.bodyLarge?.fontSize ?? 16;
    final timeLineH = textScale.scale(badgeFont) * 1.45;
    final titleLineH = textScale.scale(14) * 1.45;
    final placeLineH = textScale.scale(12) * 1.45;
    final availH = boxH - timeLineH - topPad;
    // budgets are pure line math: a line renders iff its scaled height
    // is actually left over (was: a magic +24 slack that hid the place
    // line on boxes that could have shown it and still let the seam
    // graze the glyphs). A row WITHOUT any place/delta text must not
    // reserve a place line for nothing - personal-ICS rows showed a
    // one-line ellipsised title with the claimed room line never painted
    // and a whole line of dead space. The place line reserves what is
    // LEFT after the title: two lines for a long room + delta string
    // (real feeds wrap), one for the normal room, none at all when even
    // one line would not fit.
    final wantPlace = hasPlace || deltaText != null;
    final titleMaxLines =
        availH >= 2 * titleLineH + (wantPlace ? placeLineH : 0) ? 2 : 1;
    final placeRoom = availH - titleMaxLines * titleLineH;
    final placeMax = placeRoom >= 2 * placeLineH ? 2 : 1;
    final showPlace = wantPlace && placeRoom >= placeLineH;
    final placeText = Text.rich(
      TextSpan(
        children: [
          if (hasPlace) TextSpan(text: appointment.displayPlace),
          if (deltaText != null)
            TextSpan(
                text: hasPlace
                    ? deltaText
                    // no place text to hang the " · " separator on
                    : deltaText.replaceFirst(" · ", ""),
                style: TextStyle(color: theme.colorScheme.tertiary)),
        ],
      ),
      maxLines: placeMax,
      overflow: TextOverflow.ellipsis,
    );
    // lunch is day structure, not a lecture: same grid seat, muted ink
    final titleColor = appointment.type == TimetableAppointmentType.lunchBreak
        ? theme.colorScheme.outline
        : null;
    return ClipRect(
      child: SizedBox(
        height: boxH,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque, // the WHOLE row is the target
          // null on side pages: nothing enters the arena, so the page's
          // centering tap wins instead of a premature detail push
          onTap: rowTapsEnabled
              ? () {
                  Navigator.of(context).push(MaterialPageRoute(
                      builder: (context) => TimetableAppointmentPage(
                          appointment: appointment,
                          heroSuffix: "_${tt.weekday.index}")));
                }
              : null,
          child: Container(
            padding: const EdgeInsets.fromLTRB(
                defaultPagePadding, topPad, defaultPagePadding, 0),
            // short blocks (a 30-min personal feed entry measures ~27px
            // at full scale) cannot hold even one time+title column in
            // their duration-pinned height: scale the text down instead
            // of letting the Column overflow into RenderFlex stripes.
            // Normal boxes keep scale 1.0 untouched.
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: fullW - 2 * defaultPagePadding,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                            child: Text(
                          _hm(appointment.begin.hour * 60 +
                              appointment.begin.minute),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyLarge
                              ?.copyWith(color: theme.colorScheme.primary),
                        )),
                        if (showNowLine)
                          // the running chip repaints on its own minute tick -
                          // the page build never waits for the clock
                          ValueListenableBuilder<int>(
                            valueListenable: NowClock.minutesOfDay,
                            builder: (context, minute, _) =>
                                _runningChip(minute, appointment, theme),
                          ),
                      ],
                    ),
                    appointment.id.isNotEmpty
                        ? Hero(
                            tag:
                                "appointmentTitle_${appointment.title}_${appointment.id}$heroSuffix",
                            child: Text(
                              isTut
                                  ? L10n.t("timetable.tutorialPrefix",
                                      [appointment.displayTitle])
                                  : titleText,
                              style: theme.textTheme.titleSmall?.copyWith(
                                  fontWeight: FontWeight.bold,
                                  color: titleColor),
                              maxLines: titleMaxLines,
                              overflow: TextOverflow.ellipsis,
                            ))
                        : Text(
                            titleText,
                            style: theme.textTheme.titleSmall?.copyWith(
                                fontWeight: FontWeight.bold, color: titleColor),
                            maxLines: titleMaxLines,
                            overflow: TextOverflow.ellipsis,
                          ),
                    if ((hasPlace || deltaText != null) && showPlace)
                      appointment.id.isNotEmpty
                          ? Hero(
                              tag:
                                  "appointmentPlace_${appointment.title}_${appointment.id}$heroSuffix",
                              child: _placeSlot(
                                  theme, placeText, appointment.roomVaries))
                          : _placeSlot(theme, placeText, appointment.roomVaries)
                    else
                      const SizedBox(height: 0),
                    isTut &&
                            boxH >= 140 &&
                            appointment is Tutorial &&
                            (appointment.notes ?? "").isNotEmpty
                        ? Text(
                            appointment.notes!,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          )
                        : const SizedBox.shrink(),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _placeSlot(ThemeData theme, Widget placeText, bool roomVaries) {
    if (!roomVaries) return placeText;
    return Row(
      children: [
        Expanded(child: placeText),
        Container(
          margin: const EdgeInsets.only(left: spaceXs),
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
          decoration: BoxDecoration(
            color: theme.colorScheme.tertiaryContainer,
            borderRadius: BorderRadius.circular(chipRadiusDouble),
          ),
          child: Text(
            L10n.t("timetable.roomVaries"),
            style: theme.textTheme.labelSmall
                ?.copyWith(color: theme.colorScheme.onTertiaryContainer),
          ),
        ),
      ],
    );
  }

  /// begin <= now < end on the WALL CLOCK only: appointment begin/end carry
  /// stale parse-time dates, so their absolute difference is meaningless -
  /// compare hour+minute minutes-of-day.
  Widget _runningChip(
      int minute, TimetableAppointment appointment, ThemeData theme) {
    final beginMin = appointment.begin.hour * 60 + appointment.begin.minute;
    final endMin = appointment.end.hour * 60 + appointment.end.minute;
    if (beginMin > minute || minute >= endMin) return const SizedBox.shrink();
    return BlockContainer(
        padding: const EdgeInsets.only(left: spaceSm),
        innerPadding: const EdgeInsets.fromLTRB(6, 3, 6, 3),
        child: Text(
          L10n.t("agenda.nowRunning", [_hm(endMin)]),
          style: theme.textTheme.labelSmall?.copyWith(
              fontWeight: FontWeight.bold, color: theme.colorScheme.primary),
        ));
  }

  /// removed/moved over an EMPTY block: the lecture a student scheduled
  /// this slot around is gone - show the ghost of what was cancelled. A
  /// moved delta surfaces on the day it VACATED (webcal byGhostDayKey), so
  /// its vacated time (oldWhen), not the new one, names the empty block.
  IcsChange? _ghostFor(TimetableAppointment block) {
    for (final c in changes) {
      if (c.kind != IcsChangeKind.removed && c.kind != IcsChangeKind.moved) {
        continue;
      }
      final vacated = c.kind == IcsChangeKind.moved ? c.oldWhen! : c.when;
      if (vacated.hour == block.begin.hour &&
          vacated.minute == block.begin.minute) {
        return c;
      }
    }
    return null;
  }

  /// the live card this change touched, room-wise (changed kind with a real
  /// old→new room pair, matching block minute), else null
  IcsChange? _roomDeltaFor(TimetableAppointment appointment) {
    for (final c in changes) {
      if (c.kind != IcsChangeKind.changed) continue;
      final oldRoom = c.oldRoom;
      if (oldRoom == null || oldRoom.isEmpty || c.room.isEmpty) continue;
      if (c.when.hour == appointment.begin.hour &&
          c.when.minute == appointment.begin.minute) {
        return c;
      }
    }
    return null;
  }

  Widget _ghostCard(BuildContext context, TimetableAppointment block,
      IcsChange change, double factor, int min) {
    final theme = Theme.of(context);
    return Opacity(
      opacity: deadContentOpacity,
      child: SizedBox(
        height: min * factor,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
              defaultPagePadding, spaceSm, defaultPagePadding, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                change.title,
                style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                    decoration: TextDecoration.lineThrough),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              Text(
                L10n.t("timetable.ghostCancelled"),
                style: theme.textTheme.bodySmall,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Nothing lecture-shaped all day: the weekly weekend idiom, own words.
  Widget _dayFree(BuildContext context) {
    final theme = Theme.of(context);
    final size = MediaQuery.of(context).size;
    return Padding(
        padding: EdgeInsets.symmetric(vertical: size.height * 0.15),
        child: Stack(
          alignment: Alignment.center,
          children: [
            SizedBox(
              width: size.width * 0.8,
              height: size.height * 0.4,
            ),
            Column(
              children: [
                Icon(
                  CupertinoIcons.zzz,
                  color: theme.colorScheme.primary,
                  size: 64,
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: spaceSm),
                  child: Text(
                    L10n.t("timetable.dayFree"),
                    style: theme.textTheme.bodyLarge,
                  ),
                )
              ],
            )
          ],
        ));
  }
}

class _NowLinePainter extends CustomPainter {
  final List<NowBlock> blocks;
  final double pxPerMin;
  final Color color;
  final TextStyle textStyle;

  _NowLinePainter(
      {required this.blocks,
      required this.pxPerMin,
      required this.color,
      required this.textStyle})
      : super(repaint: NowClock.minutesOfDay);

  // RenderCustomPaint.hitTestSelf consults the PAINTER: `hitTest(pos) ??
  // true` - the default null already means "swallow", so the full-column
  // overlay would silently eat every row tap under it (measured: taps on
  // rows die with the line on, work with it off). Answer explicitly false.
  @override
  bool? hitTest(Offset position) => false;
  @override
  void paint(Canvas canvas, Size size) {
    // read the live value here - the minute arrives via the repaint
    // listenable WITHOUT any widget rebuilding
    final minute = NowClock.minutesOfDay.value;
    final y =
        nowLineY(blocks: blocks, minutesOfDay: minute, pxPerMin: pxPerMin);
    if (y == null) return;

    // the stroke stops short of the rounded card frame instead of
    // bleeding into the corners; the chip labels the line at the gutter
    canvas.drawLine(
        Offset(6, y),
        Offset(size.width - 6, y),
        Paint()
          ..color = color
          ..strokeWidth = 1.5);
    canvas.drawCircle(Offset(6, y), 2, Paint()..color = color);

    final chip = TextPainter(textDirection: TextDirection.ltr)
      ..text = TextSpan(text: _hm(minute), style: textStyle)
      ..layout();
    // above the line, unless it would climb out of the block (or the line
    // sits on a gap seam - distance 0) -> flip below
    final below = y - _topOfMinute(minute) < 26;
    chip.paint(
        canvas,
        Offset(size.width - chip.width - defaultPagePadding,
            below ? y + 6 : y - chip.height - 6));
  }

  /// y of the top edge of the block (or seam) the minute resolved into;
  /// mirrors [nowLineY]'s walk. Only consulted for painted minutes.
  double _topOfMinute(int minute) {
    double top = 0;
    for (var i = 0; i < blocks.length; i++) {
      final b = blocks[i];
      final bottom = top + b.durationMin * pxPerMin;
      if (minute >= b.beginMin) {
        if (minute < b.beginMin + b.durationMin) return top;
        if (i + 1 >= blocks.length) return top;
        if (minute < blocks[i + 1].beginMin) {
          return bottom + (b.border ? 1 : 0);
        }
      }
      top = bottom + (b.border ? 1 : 0);
    }
    return 0;
  }

  @override
  bool shouldRepaint(_NowLinePainter oldDelegate) =>
      oldDelegate.blocks != blocks ||
      oldDelegate.pxPerMin != pxPerMin ||
      oldDelegate.color != color ||
      oldDelegate.textStyle != textStyle;
}
