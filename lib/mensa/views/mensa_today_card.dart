import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:kit_mobile/common_ui/block_container.dart';
import 'package:kit_mobile/common_ui/kit_progress_indicator.dart';
import 'package:kit_mobile/constants/view_constants.dart';
import 'package:kit_mobile/home/views/padded_title.dart';
import 'package:kit_mobile/l10n/l10n.dart';
import 'package:kit_mobile/mensa/mensa_manager.dart';
import 'package:kit_mobile/mensa/models/mensa_models.dart';
import 'package:kit_mobile/state_management/kit_provider.dart';
import 'package:kit_mobile/timetable/logic/now_clock.dart';
import 'package:kit_mobile/toasts/models/toasts_provider.dart';

/// Home "Mensa" section: today's (or tomorrow's) dishes from the SW
/// Karlsruhe canteen. Data arrives via [MensaManager] - cached-first
/// like every other card: the week snapshot paints instantly, the
/// network only refreshes it.
///
/// The whole week is cached, so the today/tomorrow flip never waits.
/// Every state is ACTIONABLE: a spinner means a fetch is genuinely in
/// flight (never a permanent one), failure always lands on a visible
/// retry button plus a toast, and a cache too old to trust says so in
/// its footer even when it still paints a menu or a "closed" line.
class MensaTodayCard extends StatefulWidget {
  const MensaTodayCard({super.key});

  @override
  State<MensaTodayCard> createState() => _MensaTodayCardState();
}

class _MensaTodayCardState extends State<MensaTodayCard> {
  /// 0 = today, 1 = tomorrow (the whole week is cached; nothing deeper
  /// answers "what do I eat NOW / do I need to bring lunch tomorrow")
  int _offset = 0;
  bool _expanded = false;

  /// the home card is a glance, the full 40-dish list is one tap away
  static const int _collapsedMax = 12;

  DateTime? _seenDay;

  @override
  void initState() {
    super.initState();
    // wake-on-enable: the boot kick skips a hidden/disabled section, so
    // a user who turns the toggle ON later gets their first fetch the
    // moment the card mounts (the TTL/source fence coalesces the case
    // where the boot kick already ran)
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final mensa = context.read<KITProvider>().mensa;
      if (!mensa.hasData) {
        unawaited(mensa.fetchWeek());
      }
    });
  }

  Future<void> _refresh(MensaManager mensa, ToastsProvider toasts) async {
    final ok = await mensa.fetchWeek(force: true);
    if (!ok && mounted) {
      toasts.showTextToast(L10n.t("common.refreshFailed"));
    }
  }

  @override
  Widget build(BuildContext context) {
    // NowClock's shared heartbeat publishes the calendar day; when it
    // flips at midnight, drop back to "today" (a stale _offset would
    // otherwise silently show the day-after-tomorrow)
    return ValueListenableBuilder<DateTime>(
      valueListenable: NowClock.dateOfDay,
      builder: (context, day, _) {
        final seen = _seenDay;
        if (seen != null && !_sameDay(seen, day) && _offset != 0) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) {
              setState(() {
                _offset = 0;
                _expanded = false;
              });
            }
          });
        }
        _seenDay = day;
        return _card(context);
      },
    );
  }

  static bool _sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  Widget _card(BuildContext context) {
    final theme = Theme.of(context);
    final vm = context.watch<KITProvider>();
    final MensaManager mensa = vm.mensa;
    final toasts = context.read<ToastsProvider>();

    final DateTime now = DateTime.now();
    final DateTime today = DateTime(now.year, now.month, now.day);
    // literal day+N (documented DST bug guard, next_up.dart convention)
    final DateTime shown =
        DateTime(today.year, today.month, today.day + _offset);
    final DateTime tomorrow =
        DateTime(today.year, today.month, today.day + 1);
    final MensaDay? day = mensa.dayFor(shown);
    final bool hasTomorrow = mensa.dayFor(tomorrow) != null;

    final Widget trailing = Row(mainAxisSize: MainAxisSize.min, children: [
      if (hasTomorrow || _offset > 0)
        CupertinoButton(
          padding: const EdgeInsets.symmetric(
              horizontal: spaceSm, vertical: spaceXs),
          onPressed: () => setState(() {
            _offset = _offset == 0 ? 1 : 0;
            _expanded = false;
          }),
          child: Text(_offset == 0
              ? L10n.t("mensa.nextDay")
              : L10n.t("mensa.backToday")),
        ),
      CupertinoButton(
        padding: const EdgeInsets.all(10),
        onPressed: () => _refresh(mensa, toasts),
        child: const Icon(CupertinoIcons.arrow_clockwise),
      ),
      const SizedBox(width: spaceSm),
    ]);

    final Widget body;
    if (day != null && !day.isEmpty) {
      body = _menuCard(theme, mensa, day);
    } else if (day != null) {
      // a real plan day without a single dish: canteen closed
      body = _closedCard(theme, mensa);
    } else if (!mensa.hasData && mensa.isFetching) {
      // ONLY a genuinely in-flight fetch shows the spinner - a failed
      // or legitimately-empty first fetch must offer the retry button,
      // not spin at the user forever (fresh install in Semesterferien)
      body = BlockContainer(
        child: Padding(
          padding: const EdgeInsets.all(spaceMd),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              KITProgressIndicator(semanticsLabel: L10n.t("mensa.title")),
              const SizedBox(width: spaceSm),
              Text(L10n.t("mensa.empty"),
                  style: theme.textTheme.bodyMedium),
            ],
          ),
        ),
      );
    } else if (!mensa.hasData) {
      // tried before (or the very first frame before the kick lands):
      // empty + retry, same dialect as the modules card; a failing
      // retry now actually toasts (fetchWeek reports its outcome)
      body = BlockContainer(
        child: Padding(
          padding: const EdgeInsets.all(spaceMd),
          child: Column(
            children: [
              Icon(Icons.cloud_off,
                  size: 32, color: theme.colorScheme.outline),
              const SizedBox(height: spaceSm),
              Text(L10n.t("mensa.empty"),
                  style: theme.textTheme.bodyMedium),
              const SizedBox(height: spaceMd),
              FilledButton.tonal(
                onPressed: () => _refresh(mensa, toasts),
                child: Text(L10n.t("mensa.emptyBtn")),
              ),
            ],
          ),
        ),
      );
    } else {
      // cached week does not cover this date: weekend/break OR a cache
      // that outlived the week - the footer tells them apart
      body = _closedCard(theme, mensa);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PaddedTitle(title: L10n.t("mensa.title"), trailing: trailing),
        body,
      ],
    );
  }

  /// "closed" card - with the stale/diag footer whenever the cache
  /// behind the claim is too old to trust (otherwise a Friday cache
  /// seen on a dead-network Monday lies "no meals today" to a canteen
  /// that is serving lunch right now)
  Widget _closedCard(ThemeData theme, MensaManager mensa) {
    final Duration? age = mensa.age;
    final bool stale = age == null || age > const Duration(hours: 24);
    return BlockContainer(
      child: Padding(
        padding: const EdgeInsets.all(spaceMd),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _offset == 0
                  ? L10n.t("mensa.closedDay")
                  : L10n.t("mensa.closedDayTomorrow"),
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.colorScheme.outline),
            ),
            if (stale) ...[
              const SizedBox(height: spaceSm),
              _footer(theme, mensa, forcedStale: age == null),
            ],
          ],
        ),
      ),
    );
  }

  Widget _menuCard(ThemeData theme, MensaManager mensa, MensaDay day) {
    final List<MensaLine> withMeals =
        day.lines.where((MensaLine l) => l.meals.isNotEmpty).toList();
    final int total =
        withMeals.fold(0, (int n, MensaLine l) => n + l.meals.length);
    final bool cut = !_expanded && total > _collapsedMax;

    final List<Widget> rows = [
      Text(
        "${L10n.weekday(day.date.weekday)}, ${day.date.day}."
        "${day.date.month}.",
        style: theme.textTheme.titleSmall,
      ),
      const SizedBox(height: spaceSm),
    ];

    int seen = 0;
    for (final MensaLine line in withMeals) {
      if (cut && seen >= _collapsedMax) break;
      rows.add(Padding(
        padding: const EdgeInsets.only(top: spaceXs, bottom: 2),
        child: Text.rich(TextSpan(children: [
          TextSpan(
              text: line.name,
              style: theme.textTheme.labelLarge
                  ?.copyWith(color: theme.colorScheme.primary)),
          if (line.sub != null)
            TextSpan(
                text: "  ${line.sub}",
                style: theme.textTheme.labelSmall
                    ?.copyWith(color: theme.colorScheme.outline)),
        ])),
      ));
      for (final MensaMeal meal in line.meals) {
        if (cut && seen >= _collapsedMax) break;
        seen++;
        rows.add(_mealRow(theme, meal));
      }
    }
    if (cut) {
      rows.add(TextButton(
        onPressed: () => setState(() => _expanded = true),
        child: Text(L10n.t("mensa.more", [total - seen])),
      ));
    } else if (_expanded && total > _collapsedMax) {
      rows.add(TextButton(
        onPressed: () => setState(() => _expanded = false),
        child: Text(L10n.t("mensa.less")),
      ));
    }

    if (mensa.fetchedAt != null) {
      rows.add(Padding(
        padding: const EdgeInsets.only(top: spaceSm),
        child: _footer(theme, mensa),
      ));
    }

    return BlockContainer(
      child: Padding(
        padding: const EdgeInsets.all(spaceMd),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: rows,
        ),
      ),
    );
  }

  /// staleness footer, exams/agenda dialect: "Stand: HH:MM" and, when
  /// the cache outlived the SW publish rhythm, an orange warning plus
  /// the persisted diag one-liner (release builds have no other channel)
  Widget _footer(ThemeData theme, MensaManager mensa,
      {bool forcedStale = false}) {
    final Duration? age = mensa.age;
    final bool stale =
        forcedStale || (age != null && age > const Duration(hours: 6));
    final DateTime f = mensa.fetchedAt ?? DateTime.now();
    return Text(
      L10n.t("mensa.updatedAt", [
        "${f.hour.toString().padLeft(2, "0")}:"
            "${f.minute.toString().padLeft(2, "0")}"
      ]) +
          (stale ? " · ${L10n.t("mensa.stale")}" : "") +
          (stale && mensa.diag != null ? " · ${mensa.diag}" : ""),
      style: theme.textTheme.bodySmall?.copyWith(
          color:
              stale ? theme.colorScheme.tertiary : theme.colorScheme.outline),
    );
  }

  /// normal scale: one line [badge] name ....... price
  /// large text scale (>=1.4x): name keeps the FULL width on its own
  /// lines, badge+price share a compact second line - at 2.0x the
  /// one-line variant shrank the name to ~4 readable characters
  Widget _mealRow(ThemeData theme, MensaMeal meal) {
    final double scale =
        MediaQuery.textScalerOf(context).scale(14) / 14;
    final Widget badge = _badge(theme, meal);
    final Widget price = Text(meal.priceText,
        style: theme.textTheme.bodyMedium
            ?.copyWith(fontWeight: FontWeight.w600));

    if (scale < 1.4) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            badge,
            const SizedBox(width: spaceSm),
            Expanded(
              child: Text(meal.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium),
            ),
            const SizedBox(width: spaceSm),
            price,
          ],
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(meal.name,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium),
          const SizedBox(height: 2),
          Row(children: [badge, const SizedBox(width: spaceSm), price]),
        ],
      ),
    );
  }

  /// the badge carries no layout width at large scale beyond its text;
  /// it stays out of the name's way (semantics = the word itself)
  Widget _badge(ThemeData theme, MensaMeal meal) {
    final String label = meal.isVegan
        ? L10n.t("mensa.vegan")
        : meal.isVegetarian
            ? L10n.t("mensa.vegetarian")
            : "";
    if (label.isEmpty) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: meal.isVegan
            ? theme.colorScheme.primaryContainer
            : theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(label,
          style: theme.textTheme.labelSmall?.copyWith(
              color: meal.isVegan
                  ? theme.colorScheme.onPrimaryContainer
                  : theme.colorScheme.onSurfaceVariant)),
    );
  }
}
