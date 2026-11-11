import 'package:carousel_slider/carousel_slider.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:kit_mobile/constants/view_constants.dart';
import 'package:kit_mobile/common_ui/block_container.dart';
import 'package:kit_mobile/l10n/l10n.dart';
import 'package:kit_mobile/timetable/logic/now_clock.dart';
import 'package:kit_mobile/timetable/logic/now_line.dart';
import 'package:kit_mobile/timetable/models/timetable_appointment.dart';
import 'package:kit_mobile/timetable/models/timetable_daily.dart';
import 'package:kit_mobile/timetable/models/timetable_weekly.dart';
import 'package:kit_mobile/timetable/models/webcal.dart';
import 'package:kit_mobile/timetable/views/timetable_daily_view.dart';
import 'package:kit_mobile/timetable/views/ui_elements/show_today_button.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../state_management/kit_provider.dart';

class TimetableWeeklyView extends StatefulWidget {
  const TimetableWeeklyView({super.key});

  @override
  State<StatefulWidget> createState() {
    return _TimetableWeeklyViewState();
  }
}

class _TimetableWeeklyViewState extends State<TimetableWeeklyView> {
  Weekday _initialWeekday = Weekday.monday;

  _TimetableWeeklyViewState({Weekday? initialWeekday}) {
    _initialWeekday =
        initialWeekday ?? _initialWeekday.fromInt(DateTime.now().weekday - 1);
    _currentRealPage = 10000 + _initialWeekday.idx;
    _todayRealPage = _currentRealPage;
  }

  final _weekdayHeight = 90 * 7 * 0.7 + 200;
  final CarouselSliderController _carouselSliderController =
      CarouselSliderController();

  /// Fixed height of the date-heading band painted above the carousel
  /// viewport (top padding + titleLarge row + gap to the card).
  static const _dateBandHeight = 48.0;

  /// Floor for the content-sized card (lecture-free weeks, weekends-only
  /// stretches): the zzz placeholder gets a seat worth centring in.
  static const _minCardHeight = 320.0;

  /// Card height for this build: the shared axis window at [_weekPxPerMin]
  /// (identical on every page), clamped to [_minCardHeight]..(old fixed
  /// strip budget).
  double _cardHeight = _minCardHeight;

  /// The carousel page currently centered; with infinite scroll "today"
  /// starts at 10000 + initial index, one step = ±1 day.
  late int _currentRealPage;

  /// Today's carousel page - separate from [_currentRealPage]: it steps by
  /// one when NowClock reports a date flip even though the carousel did not
  /// move; the band label, the now-line page, the past dim and the
  /// ShowTodayButton anchor all consult it.
  late int _todayRealPage;

  /// Raw feed cache present -> the grid below is real parsed data, not the
  /// generic template. The only provable gate for the lectureFree state,
  /// the same "have we ever cached a timetable" judgement as the agenda's
  /// _feedCached (agenda_page.dart:176-182).
  bool _feedCached = false;

  /// ONE px/min for every carousel page of this week (see [axisPxPerMin]):
  /// recomputed per build from all five weekday templates so a lecture is
  /// the same height on Monday and on Friday. Swiping between days must
  /// never re-scale the wall clock - the old per-day fit made every page
  /// place its rows at different y (inconsistency report, 11.11).
  double _weekPxPerMin = timetableIdealPxPerMin;

  /// The week's shared wall window (see [weekTimeAxis]): earliest lecture
  /// begin to latest lecture end over all five weekday templates, rounded
  /// to whole hours. Every page maps it onto the same pixels, so 09:45 is
  /// the same height everywhere.
  TimeAxis? _weekAxis;

  /// Axis inputs: each weekday filtered through the SAME occurrence
  /// predicate the carousel builder applies to its page (next occurrence
  /// of that weekday as canonical - the template repeats weekly; an EXDATE
  /// week differing a little only nudges the window).
  List<List<NowBlock>> _weekBlocks(KITProvider vm) {
    final todayIdx = DateTime.now().weekday - 1;
    final out = <List<NowBlock>>[];
    for (var idx = 0; idx < 5 && idx < vm.timetable.days.length; idx++) {
      final template = vm.timetable.days[idx];
      final d = _pageDate(_todayRealPage + ((idx - todayIdx) % 7 + 7) % 7);
      final pageDate = DateTime(d.year, d.month, d.day);
      final tt = TimetableDaily(weekday: template.weekday)
        ..appointments = template.appointments
            .where((a) =>
                a.isEmpty ||
                a.type == TimetableAppointmentType.lunchBreak ||
                a.occurrenceDates == null ||
                a.occurrenceDates!.contains(pageDate))
            .toList();
      out.add(TimetableDailyView.contentBlocksFor(tt));
    }
    return out;
  }

  /// Feed deltas grouped by page date; decoded once at init - re-publishes
  /// while the carousel is open need not repaint the ghosts before the next
  /// visit (documented per contract §4).
  Map<String, List<IcsChange>> _changesByDay = const {};

  /// keeps the refcounted arm/disarm balanced across repeated
  /// didChangeDependencies runs
  bool _clockArmed = false;

  @override
  void initState() {
    super.initState();
    NowClock.dateOfDay.addListener(_onMidnight);
    // agenda_page.dart:170's recipe: the deltas live as JSON in prefs
    SharedPreferences.getInstance().then((prefs) {
      if (!mounted) return;
      setState(() {
        _feedCached = (prefs.getString(WebcalKeys.icsCache) ?? "")
            .contains("BEGIN:VCALENDAR");
        _changesByDay =
            IcsChange.decode(prefs.getString(WebcalKeys.changes) ?? "")
                .byGhostDayKey();
      });
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // TickerMode gate copied from the agenda ticker (agenda_page.dart:104-119):
    // the shared minute heartbeat runs only while this view can be seen, and
    // reading the flag here registers the dependency, so the very rebuild
    // that re-exposes the view re-arms it - no stale anchors after the way
    // back.
    if (TickerMode.valuesOf(context).enabled) {
      if (!_clockArmed) {
        _clockArmed = true;
        NowClock.arm();
      }
    } else if (_clockArmed) {
      _clockArmed = false;
      NowClock.disarm();
    }
  }

  @override
  void dispose() {
    NowClock.dateOfDay.removeListener(_onMidnight);
    if (_clockArmed) {
      _clockArmed = false;
      NowClock.disarm();
    }
    super.dispose();
  }

  /// Midnight roll: exactly ONE setState steps today forward; band, dim,
  /// now-line and button anchor all follow it - per minute nothing rebuilds.
  void _onMidnight() {
    if (mounted) setState(() => _todayRealPage += 1);
  }

  /// The concrete calendar date carousel page [w] shows. The band heading,
  /// the past-page dim and the per-page change ghosts must all date through
  /// here - they may never disagree about what day a page is.
  DateTime _pageDate(int w) {
    final now = DateTime.now();
    final weekdayIdx = w - 10000;
    final todayWeekdayIdx = now.weekday - 1;
    // calendar-day arithmetic: Duration(days:) is absolute time and lands a
    // wall-clock hour off across DST, mis-dating every page near midnight
    return DateTime(
        now.year, now.month, now.day + (weekdayIdx - todayWeekdayIdx));
  }

  /// Deltas whose ghost lands on [day] (built by IcsChangeIndex.byGhostDayKey:
  /// moved deltas key on their vacated oldWhen, everything else on when).
  List<IcsChange> _changesFor(DateTime day) {
    final key = "${day.year.toString().padLeft(4, "0")}-"
        "${day.month.toString().padLeft(2, "0")}-"
        "${day.day.toString().padLeft(2, "0")}";
    return _changesByDay[key] ?? const [];
  }

  /// carousel_slider's animateToPage is delta arithmetic at itemCount 1
  /// (getRealIndex folds every target onto the single item's index 0) and
  /// animateToClosest then shaves one step off toward zero - padding by the
  /// sign keeps the delta intact, the trick _showToday always relied on.
  void _animateDelta(int delta) {
    _carouselSliderController.animateToPage(delta + delta.sign,
        curve: Curves.easeInOut);
  }

  @override
  Widget build(BuildContext context) {
    final vm = Provider.of<KITProvider>(context);
    // the band's titleLarge text grows with the system font scale; a hard
    // 48px cap would paint overflow stripes across the always-visible
    // header on Large/Largest settings, so both the band and the carousel
    // subtraction scale with the very text line that sets the height
    final textScale = MediaQuery.textScalerOf(context).scale(28) / 28;
    final bandHeight = _dateBandHeight * textScale;
    final cap = _weekdayHeight - 40 - bandHeight;
    final blocksByDay = _weekBlocks(vm);
    // week-wide shared ruler BEFORE the pages build (itemBuilder runs
    // after): ONE window [axis.start, axis.end) and ONE px/min mapped
    // onto it - every page positions its blocks on this ruler, so equal
    // times sit at equal pixels across the whole carousel
    final axis = weekTimeAxis(blocksByDay);
    _weekAxis = axis;
    if (axis == null) {
      _weekPxPerMin = timetableIdealPxPerMin;
      _cardHeight = _minCardHeight;
    } else {
      // the px budget is the card's CONTENT area: BlockContainer wraps
      // every page in 4px gutters, and a column that eats the full strip
      // used to have its last minutes (the 17:15 basics bottom) clipped
      // by the rounded frame (11.20 report)
      final contentCap = cap - 2 * cardGutter;
      _weekPxPerMin =
          axisPxPerMin(capPx: contentCap, rangeMin: axis.rangeMin);
      final columnH = axis.rangeMin * _weekPxPerMin;
      _cardHeight = (columnH < _minCardHeight ? _minCardHeight : columnH) +
          2 * cardGutter;
    }
    return Column(
      children: [
        _dateBand(context, bandHeight),
        CarouselSlider.builder(
            itemCount: 1,
            itemBuilder: _weekdayCarouselBuilder,
            carouselController: _carouselSliderController,
            options: CarouselOptions(
              enableInfiniteScroll: true,
              initialPage: _initialWeekday.idx,
              // on a ~1280 dp tablet the 0.8 default leaves 128 dp fat peeks
              // per side: half-rendered neighbour-day glyphs and a fat band
              // where stray taps hijack page jumps; cap the peek to ~64 dp.
              // Phones keep the exact 0.8 they were designed with.
              viewportFraction: MediaQuery.sizeOf(context).width >= 900
                  ? 1.0 - 128.0 / MediaQuery.sizeOf(context).width
                  : 0.8,
              // content-sized frame (see build): the header moved out of
              // the pages into the fixed band, so the band height was
              // subtracted from the old fixed strip budget (cap)
              height: _cardHeight,
              // feeds the REAL page index to the date band - with
              // itemCount 1 the onPageChanged index is always 0 and
              // useless
              onScrolled: _onScrolled,
            )),
      ],
    );
  }

  Widget _weekdayCarouselBuilder(BuildContext context, int idx, int w) {
    final vm = Provider.of<KITProvider>(context);

    final weekdayIdx = (w - 10000);

    final TimetableDaily? template =
        weekdayIdx % 7 < 5 ? vm.timetable.days[weekdayIdx % 7] : null;

    // The template repeats its weekday columns forever (cascampus parity);
    // this carousel page has ONE real date. Rows that do not occur on it -
    // a lecture series starting in December, an EXDATE-cancelled week, a
    // one-shot chain member or a personal appointment beyond its UNTIL -
    // are dropped HERE, so every page shows what actually happens on ITS
    // date. Scaffold and lunch carry no date semantics and always stay;
    // HTML-grid fallback rows have null occurrenceDates and pass through
    // (they are all stamped "today", there is nothing to filter on).
    final TimetableDaily? tt;
    if (template == null) {
      tt = null;
    } else {
      final d = _pageDate(w);
      final pageDate = DateTime(d.year, d.month, d.day);
      tt = TimetableDaily(weekday: template.weekday)
        ..appointments = template.appointments
            .where((a) =>
                a.isEmpty ||
                a.type == TimetableAppointmentType.lunchBreak ||
                a.occurrenceDates == null ||
                a.occurrenceDates!.contains(pageDate))
            .toList();
    }

    // Lecture-free week: only ever with the provable reading - a feed
    // cache exists (so the grid is real parsed data, not the template) AND
    // no weekday slot holds more than the scaffold toWeeklyTemplate
    // pre-seeds. Anything less provable keeps the grid: keeping the grid
    // beats lying.
    final lectureFree = _feedCached &&
        vm.timetable.days
            .take(5)
            .every((d) => d.appointments.every(_slotVacant));

    // read at build time: pages rebuild on scroll/state only, so the dim
    // trails the wall clock by at most one interaction
    final now = DateTime.now();
    final todayMidnight = DateTime(now.year, now.month, now.day);

    final Widget content;
    if (tt == null) {
      content = _dayPlaceholder(context, L10n.t("timetable.weekend"));
    } else if (lectureFree) {
      content = _dayPlaceholder(context, L10n.t("timetable.lectureFree"));
    } else {
      content = TimetableDailyView(
        tt: tt,
        showNowLine: w == _todayRealPage,
        changes: _changesFor(_pageDate(w)),
        rowTapsEnabled: w == _currentRealPage,
        pxPerMin: _weekPxPerMin,
        axis: _weekAxis,
      );
    }

    // The date heading now lives in the fixed band above the carousel
    // viewport (see _dateBand); a page only paints its day blocks.
    return Opacity(
      opacity: _pageDate(w).isBefore(todayMidnight) ? deadContentOpacity : 1,
      child: GestureDetector(
        // a ghost column tap glides it to the centre; taps on the centered
        // page fall through to their own content
        onTap: () {
          if (w != _currentRealPage) {
            _animateDelta(w - _currentRealPage);
          }
        },
        child: BlockContainer(innerPadding: EdgeInsets.zero, child: content),
      ),
    );
  }

  /// A slot holds real data only once something claimed it; the empty
  /// placeholders and the pre-seeded lunch row are scaffold, not lectures.
  static bool _slotVacant(TimetableAppointment a) =>
      a.type == TimetableAppointmentType.lunchBreak || a.isEmpty;

  /// A zzz idiom, shared by the weekend page and a lecture-free week.
  /// Centred within the (content-sized) card, no screen-relative padding.
  Widget _dayPlaceholder(BuildContext context, String label) {
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
              label,
              style: theme.textTheme.bodyLarge,
            ),
          )
        ],
      ),
    );
  }

  /// The "Montag · 2. November"/"Heute, …" heading of the centered page.
  /// It paints in its OWN fixed band above the carousel viewport: the
  /// pages used to draw their headings inside the viewport, so the
  /// peeking neighbours' headings bled through behind the visible one -
  /// ghost half-letters at both carousel edges.
  Widget _dateBand(BuildContext context, double bandHeight) {
    final theme = Theme.of(context);
    final now = DateTime.now();

    final weekdayIdx = _currentRealPage - 10000;
    // the same date math the per-page ghosting runs on, from one place
    final date = _pageDate(_currentRealPage);

    final monthStr = L10n.t("timetable.month${date.month}");
    final weekdayShortStr = L10n.weekday(weekdayIdx % 7 + 1);

    String dateTitle = L10n.t("timetable.dayMonth", [date.day, monthStr]);

    if (now.day == date.day && now.month == date.month) {
      dateTitle = L10n.t("agenda.todayFull", [dateTitle]);
    } else if (now.day - date.day == 1 && now.month == date.month) {
      dateTitle = L10n.t("timetable.yesterdayFull", [dateTitle]);
    } else if (now.day - date.day == -1 && now.month == date.month) {
      dateTitle = L10n.t("agenda.tomorrowFull", [dateTitle]);
    }

    return SizedBox(
      height: bandHeight,
      child: Padding(
        padding:
            const EdgeInsets.only(left: pageGutter, right: pageGutter, top: 10),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.start,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Text(
              weekdayShortStr,
              style: theme.textTheme.titleLarge
                  ?.copyWith(color: theme.colorScheme.outline),
            ),

            Padding(padding: EdgeInsets.all(5)),

            Text(
              dateTitle,
              style: theme.textTheme.titleLarge,
            ),

            Padding(padding: EdgeInsets.all(5)),

            // mirrors the faded leading weekday so the date keeps its
            // horizontal seat while the short weekday name changes width
            Text(
              weekdayShortStr,
              style: theme.textTheme.titleLarge
                  ?.copyWith(color: Colors.transparent),
            ),

            Spacer(),

            ShowTodayButton(
                relativeOffset: _currentRealPage - _todayRealPage,
                onPressed: () => _showToday(_currentRealPage)),
          ],
        ),
      ),
    );
  }

  /// Tracks which real carousel page is centered (one step = ±1 day);
  /// only rebuilds when the rounded page actually changes.
  void _onScrolled(double? page) {
    if (page == null) return;
    final centered = page.round();
    if (centered != _currentRealPage) {
      setState(() => _currentRealPage = centered);
    }
  }

  void _showToday(int w) => _animateDelta(_todayRealPage - w);
}
