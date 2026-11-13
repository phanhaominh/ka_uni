import 'dart:math' as math;

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

/// The day's content rows as now-line/axis blocks (lectures, tutorials,
/// lunch) - the ONLY rows that anchor the absolute axis; scaffold
/// placeholders carry no time semantics and never widen the week's
/// shared window.
List<NowBlock> _contentBlocks(List<TimetableAppointment> day) => [
      for (final a in day)
        if (_isContent(a))
          NowBlock(
              beginMin: _beginMin(a),
              durationMin: _spanMin(a),
              content: true)
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

  /// One px/min for the whole week (see [axisPxPerMin]): every carousel
  /// page renders the SAME time ruler - equal minutes, equal pixels.
  final double? pxPerMin;

  /// The week's shared wall window (see [weekTimeAxis]): the minute that
  /// maps to the column's top edge. Null (standalone use) derives it from
  /// this day's own content.
  final TimeAxis? axis;

  const TimetableDailyView(
      {super.key,
      required this.tt,
      this.showNowLine = false,
      this.changes = const [],
      this.rowTapsEnabled = true,
      this.pxPerMin,
      this.axis});

  /// The rows one day renders, from [tt] + tutorial attachments: first
  /// non-empty per block, chronological by TIME-OF-DAY (template rows
  /// carry mixed dates - a raw DateTime compare put Nov-2's 13:00 lunch
  /// above Nov-5's 08:00 lecture on future carousel pages; Dart's sort is
  /// stable: equal-minute rows keep their template order). Empty scaffold
  /// placeholders STAY: on the absolute axis they own no pixels, but they
  /// still carry the ghosts of cancelled lectures.
  static List<TimetableAppointment> dayRows(
      TimetableDaily tt, Map<int, List<Tutorial>> tutorialsByBlock) {
    return tt.appointmentsWithTutorials(tutorialsByBlock)
        .map((block) => block
            .whereType<TimetableAppointment>()
            .where((appointment) => !appointment.isEmpty || block.length <= 1)
            .first)
        .toList(growable: false)
      ..sort((a, b) => (a.begin.hour * 60 + a.begin.minute)
          .compareTo(b.begin.hour * 60 + b.begin.minute));
  }

  /// The axis/now-line feed of a day WITHOUT tutorials merged (the week
  /// axis picker: user-local tutorial slots must not shift the shared
  /// window for everybody else's lectures).
  static List<NowBlock> contentBlocksFor(TimetableDaily tt) =>
      _contentBlocks(dayRows(tt, const {}));

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

    final day = dayRows(tt, tutorialsByBlock);

    if (!day.any(_isContent)) {
      // R37: an all-cancelled day used to render the bare zzz placeholder
      // while the agenda's DayDecision banner names the cancellations -
      // the vacated-slot ghosts the content branch insists on rendering
      // vanished exactly where they matter most. "Free" means nothing
      // LEFT to attend, not nothing ever was; show what was cancelled.
      final ghosts = [
        for (final a in day)
          if (!_isContent(a)) _ghostFor(a)
      ].whereType<IcsChange>().toList(growable: false);
      if (ghosts.isEmpty) return _dayFree(context);
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _dayFree(context),
            const SizedBox(height: 16),
            for (final g in ghosts)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 3),
                child: _ghostCard(context, g),
              ),
          ],
        ),
      );
    }

    final contents =
        day.where(_isContent).toList(growable: false);
    final blocks = _contentBlocks(day);

    return LayoutBuilder(builder: (context, constraints) {
      // ABSOLUTE TIME GRID: one wall window ([axis], shared by every
      // carousel page of the week), one px/min, and every block POSITIONED
      // at its clock time - (begin - axis.start) * px. Nothing stacks, so
      // 09:45 sits at the same pixel on Monday and Friday, a 90-minute
      // lecture is the same height everywhere, and free time is exactly
      // as wide as it is long (the folded/stacked rows before 12.11 made
      // the SAME time land on different pages' different heights - every
      // "not consistent / not aligned" report traced back to stacking).
      final now = NowClock.timeSource();
      final nowMinutes = now.hour * 60 + now.minute;
      final axis = this.axis ??
          weekTimeAxis([blocks]) ??
          const TimeAxis(8 * 60, 14 * 60);
      final pxPerMin = this.pxPerMin ??
          axisPxPerMin(
              capPx: constraints.maxHeight, rangeMin: axis.rangeMin);
      final columnH = axis.rangeMin * pxPerMin;

      double yOf(int minute) => (minute - axis.startMin) * pxPerMin;

      // Overlapping lectures (Friday: 08:00 tutorial, 09:00-17:00 block
      // seminar, 09:45 tutorial, ...) never print ink on ink: each
      // overlap cluster lays its rows out with placeCluster - normal
      // rows keep the readable left region, 3h+ block events take
      // narrow right rails (b53 stacked them; b54/55 split the card 50/
      // 50 which gut-cut "Basics of Manufacturing Technology").
      final clusters = overlapClusters(blocks);
      final places = <int, RowPlace>{};
      final clusterEnd = <int, int>{};
      for (final c in clusters) {
        final cp = placeCluster([for (final i in c) blocks[i]]);
        for (var k = 0; k < c.length; k++) {
          places[c[k]] = cp[k];
        }
        var end = 0;
        for (final i in c) {
          if (blocks[i].endMin > end) end = blocks[i].endMin;
        }
        clusterEnd[c.first] = end;
      }

      // free time gets named, centred in its REAL band (no folded stub
      // rows any more): the band is the wall window between the END of
      // one overlap cluster and the BEGIN of the next
      final gapLineH = MediaQuery.textScalerOf(context)
              .scale(theme.textTheme.bodySmall?.fontSize ?? 12) *
          1.45;
      final gapChips = <Widget>[];
      final seams = <Widget>[];
      final fullW = constraints.maxWidth;
      for (var ci = 0; ci < clusters.length; ci++) {
        final c = clusters[ci];
        if (ci + 1 >= clusters.length) continue; // no line under the last
        final end = clusterEnd[c.first]!;
        // one hairline under each CLUSTER (a per-block line would cut
        // across the side-by-side neighbour mid-box)
        seams.add(Positioned(
          top: yOf(end),
          left: 0,
          right: 0,
          height: 1,
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: defaultPagePadding),
            color: theme.dividerColor,
          ),
        ));
        final nextBegin = blocks[clusters[ci + 1].first].beginMin;
        if (nextBegin > end) {
          final h = yOf(nextBegin) - yOf(end);
          if (h >= gapLineH) {
            gapChips.add(Positioned(
              top: yOf(end),
              height: h,
              left: 0,
              right: 0,
              child: Center(
                child: ColoredBox(
                  // mask the hour line behind the chip text
                  color: theme.cardColor,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Text(
                      L10n.t("timetable.freeGap", [_dur(nextBegin - end)]),
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: theme.colorScheme.outline),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              ),
            ));
          }
        }
      }

      // hour gridlines: the separate bars between the clock times, one at
      // every full hour of the shared axis (the axis edges are whole
      // hours by construction, so these are exactly the :00 marks).
      // Fainter than the lecture seams; drawn BELOW the rows, which paint
      // the card color behind their text - so the lines show through the
      // free bands and vanish behind events, exactly like paper agendas
      // and Google Calendar.
      final hourLines = <Widget>[];
      for (var m = axis.startMin + 60; m < axis.endMin; m += 60) {
        hourLines.add(Positioned(
          top: yOf(m),
          left: 0,
          right: 0,
          height: 1,
          child: ColoredBox(
            color: theme.dividerColor.withValues(alpha: 0.35),
          ),
        ));
      }

      return Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: constraints.maxWidth,
          height: columnH,
          child: Stack(
            children: [
              ...hourLines,
              ...gapChips,
              ...seams,
              // cancelled lectures keep their vacated slot on the axis
              for (final a in day)
                if (!_isContent(a) && _ghostFor(a) != null)
                  Positioned(
                    top: yOf(_beginMin(a)),
                    height: _spanMin(a) * pxPerMin,
                    left: 0,
                    right: 0,
                    child: _ghostCard(context, _ghostFor(a)!),
                  ),
              for (var i = 0; i < contents.length; i++)
                Positioned(
                  top: yOf(_beginMin(contents[i])),
                  height: _spanMin(contents[i]) * pxPerMin,
                  left: fullW * places[i]!.left,
                  width: fullW * places[i]!.width,
                  child: _row(context, contents[i],
                      _spanMin(contents[i]) * pxPerMin,
                      fullW * places[i]!.width),
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
                          axis: axis,
                          pxPerMin: pxPerMin,
                          columnH: columnH,
                          blocks: blocks,
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

  Widget _row(BuildContext context, TimetableAppointment appointment,
      double boxH, double fullW) {
    final theme = Theme.of(context);
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

    // the duration-pinned height doubles as the geometry the now-line
    // walks, so a 60-min block must give up text lines
    // instead of pushing its words over the neighbour's first row (what an
    // unbounded text column inside a fixed SizedBox did: AUDIT-test bled
    // into KLAUSUR)
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
    // MEASURED, not guessed: does the title fit ONE line at this box
    // width? A row whose title does NOT fit one line claims the SECOND
    // line before the place line gets anything: a 90-min box on a phone
    // card fits time+title+room or time+title x2 - and the lecture's
    // NAME outranks its room (11.20: "Basics of Manufacturing Technology
    // (Lecture)" read "Basics of Manufact..." because the budget gave
    // line 2 to the room it could only ellipsise anyway). Short titles
    // keep their room line untouched; tall boxes afford title 2 + room.
    final titleOneLine = TextPainter(
        textDirection: TextDirection.ltr, maxLines: 1)
      ..text = TextSpan(
          text: titleText,
          style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.bold,
              color: appointment.type == TimetableAppointmentType.lunchBreak
                  ? theme.colorScheme.outline
                  : null))
      ..layout(maxWidth: math.max(fullW - 2 * defaultPagePadding, 1));
    final titleMaxLines = titleOneLine.didExceedMaxLines &&
            availH >= 2 * titleLineH
        ? 2
        : 1;
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
            // the card fill behind the text: hour gridlines pass UNDER
            // event rows (calendar convention - lines own the free bands)
            color: theme.cardColor,
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
  /// compare hour+minute minutes-of-day. The END is the span the LAYOUT
  /// committed to ([_spanMin]): a 22:00→02:00 personal row renders as a
  /// 90-min block whose raw wall endMin (120) is below any evening minute,
  /// so the raw `minute >= endMin` compare hid the chip for a block the row
  /// visibly occupies.
  Widget _runningChip(
      int minute, TimetableAppointment appointment, ThemeData theme) {
    final beginMin = appointment.begin.hour * 60 + appointment.begin.minute;
    final endMin = appointment.end.hour * 60 + appointment.end.minute;
    if (beginMin > minute || minute >= beginMin + _spanMin(appointment)) {
      return const SizedBox.shrink();
    }
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

  Widget _ghostCard(BuildContext context, IcsChange change) {
    final theme = Theme.of(context);
    // same recipe as the lecture row (ClipRect + FittedBox scaleDown +
    // top-left + min-size Column) inside the Positioned's duration-pinned
    // box: a 15-min vacated slot is 13.5 px while the struck title +
    // "entfällt" line measure ~45 px, so unclipped the ghost painted
    // RenderFlex stripes over BOTH neighbouring lectures' text
    return Opacity(
      opacity: deadContentOpacity,
      child: ClipRect(
        child: FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.topLeft,
          child: ColoredBox(
            // hour gridlines end at the vacated block's text too
            color: Theme.of(context).cardColor,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(
                  defaultPagePadding, spaceSm, defaultPagePadding, 0),
              child: Column(
                mainAxisSize: MainAxisSize.min,
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
        ),
      ),
    );
  }

  /// Nothing lecture-shaped all day: the weekly weekend idiom, own words.
  /// Centred with NO screen-relative padding: the card height tracks the
  /// week's busiest day (see TimetableWeeklyView), so fixed 15%-of-screen
  /// paddings would overflow a short card into RenderFlex stripes.
  Widget _dayFree(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
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
      ),
    );
  }
}

class _NowLinePainter extends CustomPainter {
  final TimeAxis axis;
  final double pxPerMin;
  final double columnH;
  final List<NowBlock> blocks;
  final Color color;
  final TextStyle textStyle;

  _NowLinePainter(
      {required this.axis,
      required this.pxPerMin,
      required this.columnH,
      required this.blocks,
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
    // pure linear ruler: minute -> pixel, same map as the rows' Positioned
    final y = nowLineY(axis: axis, pxPerMin: pxPerMin, minutesOfDay: minute);
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

    // inside a content row the row's OWN "running · until" chip owns the
    // right end - and that chip exists for exactly as long as the minute
    // is inside the row, so the HH:MM label could only ever collide with
    // it there (measured 12.11: "12:39" painted straight onto
    // "running · until 13:00"). The chip is the better label anyway - the
    // HH:MM returns in free bands, which carry no chip.
    if (_contentAt(minute)) return;
    final chip = TextPainter(textDirection: TextDirection.ltr)
      ..text = TextSpan(text: _hm(minute), style: textStyle)
      ..layout();
    // above the line; flip below only when the line sits so near the
    // axis top that the label would climb out of the column (and still
    // fit inside it) - canvas draws below are not clipped, an overflowing
    // label invades whatever the card shows above
    final below = y - chip.height - 6 < 0 && y + 6 + chip.height <= columnH;
    chip.paint(
        canvas,
        Offset(size.width - chip.width - defaultPagePadding,
            below ? y + 6 : y - chip.height - 6));
  }

  /// Whether the minute resolves INSIDE a content block (one that may
  /// paint the running chip).
  bool _contentAt(int minute) {
    for (final b in blocks) {
      if (b.content &&
          minute >= b.beginMin &&
          minute < b.beginMin + b.durationMin) {
        return true;
      }
    }
    return false;
  }

  @override
  bool shouldRepaint(_NowLinePainter oldDelegate) =>
      oldDelegate.axis != axis ||
      oldDelegate.pxPerMin != pxPerMin ||
      oldDelegate.columnH != columnH ||
      oldDelegate.blocks != blocks ||
      oldDelegate.color != color ||
      oldDelegate.textStyle != textStyle;
}
