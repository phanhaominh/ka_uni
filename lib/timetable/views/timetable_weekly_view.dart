import 'package:carousel_slider/carousel_slider.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:kit_mobile/common_ui/block_container.dart';
import 'package:kit_mobile/extensions/theme_data_extension.dart';
import 'package:kit_mobile/l10n/l10n.dart';
import 'package:kit_mobile/timetable/models/timetable_daily.dart';
import 'package:kit_mobile/timetable/models/timetable_weekly.dart';
import 'package:kit_mobile/timetable/views/timetable_daily_view.dart';
import 'package:kit_mobile/timetable/views/ui_elements/show_today_button.dart';
import 'package:provider/provider.dart';

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
  }

  final _weekdayHeight = 90 * 7 * 0.7 + 200;
  final CarouselSliderController _carouselSliderController = CarouselSliderController();

  /// Fixed height of the date-heading band painted above the carousel
  /// viewport (top padding + titleLarge row + gap to the card).
  static const _dateBandHeight = 48.0;

  /// The carousel page currently centered; with infinite scroll "today"
  /// starts at 10000 + initial index, one step = ±1 day.
  late int _currentRealPage;

  @override
  Widget build(BuildContext context) {
    // the band's titleLarge text grows with the system font scale; a hard
    // 48px cap would paint overflow stripes across the always-visible
    // header on Large/Largest settings, so both the band and the carousel
    // subtraction scale with the very text line that sets the height
    final textScale = MediaQuery.textScalerOf(context).scale(28) / 28;
    final bandHeight = _dateBandHeight * textScale;
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
              // the header moved out of the pages into the fixed band,
              // so subtract it here: total height and card placement
              // stay exactly as before
              height: _weekdayHeight - 40 - bandHeight,
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
    final theme = Theme.of(context);

    final weekdayIdx = (w - 10000);

    final TimetableDaily? tt =
        weekdayIdx % 7 < 5 ? vm.timetable.days[weekdayIdx % 7] : null;

    // The date heading now lives in the fixed band above the carousel
    // viewport (see _dateBand); a page only paints its day blocks.
    return BlockContainer(
      innerPadding: EdgeInsets.zero,
      child: tt != null
          ? TimetableDailyView(tt: tt)
          : Padding(
              padding: EdgeInsets.symmetric(
                  vertical: MediaQuery.of(context).size.height * 0.15),
              child: Stack(
                alignment: Alignment.center,
                children: [
                  SizedBox(
                    width: MediaQuery.of(context).size.width * 0.8,
                    height: _weekdayHeight * 0.4,
                  ),
                  Column(
                    children: [
                      Icon(
                        CupertinoIcons.zzz,
                        color: theme.colorScheme.primary,
                        size: 64,
                      ),
                      Padding(
                        padding:
                            const EdgeInsets.symmetric(vertical: 5),
                        child: Text(
                          L10n.t("timetable.weekend"),
                          style: theme.textTheme.bodyLarge,
                        ),
                      )
                    ],
                  )
                ],
              )),
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
    final todayWeekdayIdx = now.weekday - 1;
    final date = now.add(Duration(days: weekdayIdx - todayWeekdayIdx));

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
        padding: EdgeInsets.only(left: 10, right: 10, top: 10),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.start,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Text(
              weekdayShortStr,
              style: theme.textTheme.titleLarge?.copyWith(color: theme.isLightMode ? Colors.black26 : Colors.white30),
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
              style: theme.textTheme.titleLarge?.copyWith(color: Colors.transparent),
            ),

            Spacer(),

            ShowTodayButton(
                relativeOffset:
                    _currentRealPage - (10000 + _initialWeekday.idx),
                onPressed: () => _showToday(_currentRealPage)),

            Padding(padding: EdgeInsets.only(right: 5)),
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

  void _showToday(int w) {
    int toPage = 10000 + _initialWeekday.index - w;
    toPage += toPage.sign;
    _carouselSliderController.animateToPage(toPage, curve: Curves.easeInOut);
  }
}
