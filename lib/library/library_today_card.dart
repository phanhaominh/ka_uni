import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../common_ui/block_container.dart';
import '../common_ui/kit_progress_indicator.dart';
import '../constants/view_constants.dart';
import '../home/views/padded_title.dart';
import '../l10n/l10n.dart';
import 'anny_api.dart';
import 'anny_manager.dart';
import 'library_page.dart';
import '../navigation/logic/push_page.dart';
import '../state_management/kit_provider.dart';
import '../toasts/models/toasts_provider.dart';

/// Home "Bibliothek" section: favorite room's free seats, open/closed,
/// next-free time and the ACTIVE BOOKING check-in countdown. Data arrives
/// via [AnnyManager] — cached-first like every other card: the persisted
/// rooms/counts paint instantly, the network only refreshes them.
///
/// Failure dialect identical to the mensa card: the spinner means a fetch
/// is genuinely in flight, failure lands on a visible retry button, the
/// retry toasts, and good cached data is NEVER replaced by an error state.
class LibraryTodayCard extends StatefulWidget {
  const LibraryTodayCard({super.key});

  @override
  State<LibraryTodayCard> createState() => _LibraryTodayCardState();
}

class _LibraryTodayCardState extends State<LibraryTodayCard> {
  /// drives the check-in countdown ("expires15") without provider events
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    // wake-on-enable (mensa precedent): the boot kick skips a disabled
    // section, so mounting the card is the first fetch for late enablers
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final anny = context.read<KITProvider>().anny;
      if (!anny.hasData) unawaited(anny.refreshAnon());
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  Future<void> _refresh(AnnyManager anny, ToastsProvider toasts) async {
    await anny.refreshAnon(force: true);
    if (anny.error != AnnyErrorKind.none && mounted) {
      toasts.showTextToast(L10n.t("common.refreshFailed"));
    }
  }

  void _openPage() {
    unawaited(pushPageOnce<void>(Navigator.of(context),
        routeName: "/library", page: (_) => const LibraryPage()));
  }

  /// the KIT library's 15-minute check-in rule (live capture + room
  /// description): from slot start the booking is in its death window
  static bool _inLapseWindow(AnnyBooking b, DateTime now) =>
      !b.start.isAfter(now) &&
      now.isBefore(b.start.add(const Duration(minutes: 15)));

  static bool _beforeStart(AnnyBooking b, DateTime now) => b.start.isAfter(now);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final vm = context.watch<KITProvider>();
    final AnnyManager anny = vm.anny;
    final toasts = context.read<ToastsProvider>();

    final DateTime now = DateTime.now();
    final AnnyBooking? active = anny.activeBooking;

    // the countdown only ticks while a booking is pre-start or lapsing —
    // and so does the BANNER: past start+15 the booking is lost, keeping
    // "check in now!" lit on a dead booking for the rest of the day was
    // the opposite of the alarm's point (R21)
    final bool showBanner = active != null &&
        (_inLapseWindow(active, now) || _beforeStart(active, now));
    final counting = showBanner;
    if (counting && _ticker == null) {
      _ticker = Timer.periodic(const Duration(seconds: 30), (_) {
        if (mounted) setState(() {});
      });
    } else if (!counting && _ticker != null) {
      _ticker!.cancel();
      _ticker = null;
    }

    final Widget body;
    if (!anny.hasData && anny.isFetching) {
      // ONLY a genuinely in-flight fetch spins (mensa discipline)
      body = BlockContainer(
        child: Padding(
          padding: const EdgeInsets.all(spaceMd),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              KITProgressIndicator(semanticsLabel: L10n.t("library.title")),
              const SizedBox(width: spaceSm),
              Text(L10n.t("library.title"), style: theme.textTheme.bodyMedium),
            ],
          ),
        ),
      );
    } else if (!anny.hasData) {
      body = BlockContainer(
        child: Padding(
          padding: const EdgeInsets.all(spaceMd),
          child: Column(
            children: [
              Icon(Icons.cloud_off, size: 32, color: theme.colorScheme.outline),
              const SizedBox(height: spaceSm),
              Text(L10n.t("library.loadFailed"),
                  style: theme.textTheme.bodyMedium),
              const SizedBox(height: spaceMd),
              FilledButton.tonal(
                onPressed: () => _refresh(anny, toasts),
                child: Text(L10n.t("library.retry")),
              ),
            ],
          ),
        ),
      );
    } else {
      body = BlockContainer(
        child: InkWell(
          onTap: _openPage,
          child: Padding(
            padding: const EdgeInsets.all(spaceMd),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (showBanner) _bookingBanner(theme, active, now),
                if (showBanner) const SizedBox(height: spaceSm),
                _favLine(theme, anny, now),
                const SizedBox(height: spaceSm),
                if (anny.fetchedAt case final DateTime at)
                  Padding(
                    padding: const EdgeInsets.only(bottom: spaceXs),
                    child: Text(
                      L10n.t("library.updatedAt", [
                        "${at.hour.toString().padLeft(2, "0")}:"
                            "${at.minute.toString().padLeft(2, "0")}"
                      ]),
                      style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.outline),
                    ),
                  ),
                if (!anny.signedIn)
                  FilledButton.tonal(
                    onPressed: () => showLibrarySignInDialog(context),
                    child: Text(L10n.t("library.loginKit")),
                  )
                else
                  Text(
                    L10n.t("library.signedInAs", [
                      anny.bookings.isNotEmpty
                          ? '${L10n.t("library.myBookings")} '
                              '· ${anny.bookings.length}'
                          : L10n.t("library.neverBooked")
                    ]),
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.outline),
                  ),
              ],
            ),
          ),
        ),
      );
    }

    final Widget trailing = Row(mainAxisSize: MainAxisSize.min, children: [
      Tooltip(
        message: L10n.t("library.refresh"),
        child: CupertinoButton(
          padding: const EdgeInsets.all(10),
          onPressed: () => _refresh(anny, toasts),
          child: const Icon(CupertinoIcons.arrow_clockwise),
        ),
      ),
      const SizedBox(width: spaceSm),
    ]);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PaddedTitle(title: L10n.t("library.title"), trailing: trailing),
        body,
      ],
    );
  }

  /// ACTIVE BOOKING banner. RED inside the 15-minute check-in death
  /// window ("expires15"), a plain "upcoming" line before the start.
  Widget _bookingBanner(ThemeData theme, AnnyBooking b, DateTime now) {
    if (_inLapseWindow(b, now)) {
      final left =
          b.start.add(const Duration(minutes: 15)).difference(now).inMinutes;
      return Row(
        children: [
          Icon(CupertinoIcons.exclamationmark_circle,
              color: theme.colorScheme.error, size: 20),
          const SizedBox(width: spaceSm),
          Expanded(
            child: Text(
              "${L10n.t("library.expires15", [left < 0 ? 0 : left])} · "
              "${b.resource}",
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.colorScheme.error),
            ),
          ),
        ],
      );
    }
    return Row(
      children: [
        Icon(CupertinoIcons.calendar,
            color: theme.colorScheme.primary, size: 20),
        const SizedBox(width: spaceSm),
        Expanded(
          child: Text(
            "${b.resource} · ${L10n.stamp(b.start)}",
            style: theme.textTheme.bodyMedium,
          ),
        ),
      ],
    );
  }

  /// favorite room: name + "{n} Plätze frei" + open/closed + next-free
  Widget _favLine(ThemeData theme, AnnyManager anny, DateTime now) {
    final AnnyRoom? fav = anny.favRoom ??
        (anny.rooms.isEmpty
            ? null
            : anny.rooms.firstWhere((AnnyRoom r) => r.section == "seats",
                orElse: () => anny.rooms.first));
    if (fav == null) {
      return Text(L10n.t("library.loadFailed"),
          style: theme.textTheme.bodyMedium);
    }
    final int? free = anny.freeCounts[fav.slug];
    final String openTxt = _openText(fav, now);
    final DateTime? next = _nextFree(anny, now);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(fav.name, style: theme.textTheme.titleSmall),
        const SizedBox(height: spaceXs),
        Text(
          free == null
              ? fav.quantity == 0
                  ? openTxt
                  : L10n.t("library.capacity", [fav.quantity])
              : L10n.t("library.freeNow", [free]),
          style: theme.textTheme.bodyMedium?.copyWith(
              color:
                  free == null || free == 0 ? theme.colorScheme.outline : null),
        ),
        if (openTxt.isNotEmpty)
          Text(openTxt,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.outline)),
        if (next != null)
          Padding(
            padding: const EdgeInsets.only(top: spaceXs),
            child: Text(L10n.t("library.nextFree", [L10n.stamp(next)]),
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.primary)),
          ),
      ],
    );
  }

  static DateTime? _nextFree(AnnyManager anny, DateTime now) {
    for (final AnnySlot s in anny.favSlots) {
      if (s.available && !s.start.isBefore(now)) return s.start;
    }
    return null;
  }

  /// "Geöffnet bis HH:mm" / "Geschlossen · öffnet …" from the room's own
  /// opening window (Anny sends "HH:mm:ss"); empty when no window known
  static String _openText(AnnyRoom r, DateTime now) {
    final from = _hhmmOf(r.openFrom);
    final to = _hhmmOf(r.openTo);
    if (from == null || to == null) return "";
    final open = DateTime(now.year, now.month, now.day, from.$1, from.$2);
    final close = DateTime(now.year, now.month, now.day, to.$1, to.$2);
    final bool isOpen = !now.isBefore(open) && now.isBefore(close);
    if (isOpen) return L10n.t("library.openUntil", [_fmt(to)]);
    if (now.isBefore(open)) {
      return L10n.t("library.closedOpens", [_fmt(from)]);
    }
    final tomorrow = DateTime(now.year, now.month, now.day + 1, from.$1,
        from.$2); // literal day+N (DST guard, next_up convention)
    return L10n.t("library.closedOpens",
        ["${L10n.dayOffset(tomorrow, now)} ${_fmt(from)}"]);
  }

  /// "HH:mm:ss"/"HH:mm" → (h, m); null on junk/absent
  static (int, int)? _hhmmOf(String s) {
    final m = RegExp(r"^(\d{1,2}):(\d{2})").firstMatch(s.trim());
    if (m == null) return null;
    return (int.parse(m.group(1)!), int.parse(m.group(2)!));
  }

  static String _fmt((int, int) t) =>
      "${t.$1.toString().padLeft(2, "0")}:${t.$2.toString().padLeft(2, "0")}";
}
