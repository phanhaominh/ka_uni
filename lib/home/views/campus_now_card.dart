import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../common/data_trust.dart';
import '../../common_ui/block_container.dart';
import '../../constants/view_constants.dart';
import '../../gapplan/gap_plan.dart' show servingWindows;
import '../../l10n/l10n.dart';
import '../../library/anny_api.dart' show AnnyRoom;
import '../../library/anny_manager.dart' show AnnyManager;
import '../../library/library_page.dart';
import '../../mensa/mensa_manager.dart' show MensaManager;
import '../../mensa/models/mensa_models.dart' show MensaDay;
import '../../navigation/logic/push_page.dart';
import '../../state_management/kit_provider.dart';
import 'padded_title.dart';

/// R36.2 CAMPUS-NOW strip: the two home sections (MensaTodayCard +
/// LibraryTodayCard, both deleted) collapse into ONE compact glance
/// card - two lines, one per source, each carrying its own DataTrust
/// verdict marker (fresh: silent; aging: a subtle dot; untrusted: the
/// mensa footer's own stale word). The full cards stay reachable: the
/// library row opens exactly the page the old card's body opened; the
/// mensa card NEVER had a detail route, so its row has no chevron and
/// no tap (F-12: no dead controls, silence over filler).
///
/// Every rendered value is a SUBSET of what the deleted cards
/// certified: the mensa serving window is parsed from the SW's own
/// line stamps (the same "11-14 Uhr" sub the menu card printed), a
/// covered-but-empty day is the old "Heute keine Ausgabe.", unknowns
/// render the shared valueNone "—" - never a fabricated freshness.
/// Thresholds are the sources' own (R35.2), declared here because the
/// cards that held them are gone - NOT re-tuned:
///  * mensa: 6 h aging / 24 h untrusted (SW publish rhythm / one day),
///  * seats: 15 min and done (gap_plan_card's present-tense rule - a
///    seat count older than that is not last-known truth, it is noise,
///    so it renders "—" with the stale word, never the stale number).
/// In the strip 0 free seats IS the news (the old card printed "0
/// Plätze frei" muted) - unlike the gap planner, which drops zero
/// because "zero free" plans nothing.
class CampusNowCard extends StatefulWidget {
  const CampusNowCard({super.key});

  @override
  State<CampusNowCard> createState() => _CampusNowCardState();
}

class _CampusNowCardState extends State<CampusNowCard> {
  static const Duration _mensaTtl = Duration(hours: 6);
  static const Duration _mensaTrustHorizon = Duration(hours: 24);
  static const Duration _seatsTtl = Duration(minutes: 15);

  @override
  void initState() {
    super.initState();
    // wake-on-enable (both old cards' precedent): the boot kick skips a
    // hidden section, so mounting the strip is the first fetch for users
    // who turn the toggle ON later (the managers' source/TTL fences
    // coalesce the case where the boot kick already ran)
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final vm = context.read<KITProvider>();
      if (!vm.mensa.hasData) unawaited(vm.mensa.fetchWeek());
      if (!vm.anny.hasData) unawaited(vm.anny.refreshAnon());
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final vm = context.watch<KITProvider>();
    final DateTime now = DateTime.now();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PaddedTitle(title: L10n.t("home.campusNow")),
        BlockContainer(
          // zero inner padding so the library row's InkWell spans the
          // whole row (the ProfileDoorCard rule: padding taps must not
          // be dead zones)
          innerPadding: EdgeInsets.zero,
          child: Column(
            children: [
              _row(theme,
                  label: L10n.t("mensa.title"),
                  value: _mensaValue(vm.mensa, now),
                  trust: dataTrust(
                      fetchedAt: vm.mensa.fetchedAt,
                      now: now,
                      ttl: _mensaTtl,
                      trustHorizon: _mensaTrustHorizon)),
              _row(theme,
                  label: L10n.t("library.title"),
                  value: _libraryValue(vm.anny, now),
                  trust: dataTrust(
                      fetchedAt: vm.anny.fetchedAt,
                      now: now,
                      ttl: _seatsTtl,
                      trustHorizon: _seatsTtl),
                  // F-12: chevron + tap exist exactly where the old card
                  // had a detail route - the mensa card never had one
                  onTap: () => unawaited(pushPageOnce<void>(Navigator.of(context),
                      routeName: LibraryPage.routeName,
                      page: (_) => const LibraryPage()))),
            ],
          ),
        ),
      ],
    );
  }

  /// "Mensa" line: serving window from the plan's own sub stamps, the
  // old card's closed claim, or valueNone - cached content may paint
  // past its horizon (the old menu card did too) but the untrusted row
  // always says so in the mensa footer's own words
  String _mensaValue(MensaManager mensa, DateTime now) {
    final none = L10n.t("grades.valueNone");
    if (!mensa.hasData) return none;
    final MensaDay? day = mensa.dayFor(now);
    if (day == null || day.isEmpty) {
      // uncovered date OR covered-without-dishes: the card's own
      // "Heute keine Ausgabe." for both, footer duties = the marker
      return L10n.t("mensa.closedDay");
    }
    final windows = [
      for (final line in day.lines) ...servingWindows(line.sub, day.date)
    ];
    if (windows.isEmpty) return none; // no printed window = no claim
    // every menu line of one kitchen prints the SAME "11-14 Uhr" stamp —
    // a glance repeats nothing; equal windows collapse to one entry
    final sorted = ({for (final w in windows) (w.from, w.to)})
        .map((p) => (from: p.$1, to: p.$2))
        .toList()
      ..sort((a, b) => a.from.compareTo(b.from));
    return L10n.t("home.campusNowOpen", [
      [
        for (final w in sorted) "${_hm(w.from)}–${_hm(w.to)}"
      ].join(", ")
    ]);
  }

  /// "Library" line: the old card's favorite-room count (its own
  /// fallback chain), 0 included - but only inside the 15-minute
  /// present-tense window; beyond it the strip stays honest-quiet
  String _libraryValue(AnnyManager anny, DateTime now) {
    final none = L10n.t("grades.valueNone");
    if (!anny.hasData) return none;
    final trust = dataTrust(
        fetchedAt: anny.fetchedAt,
        now: now,
        ttl: _seatsTtl,
        trustHorizon: _seatsTtl);
    if (trust == DataTrust.untrusted) return none;
    final AnnyRoom? fav = anny.favRoom ??
        (anny.rooms.isEmpty
            ? null
            : anny.rooms.firstWhere((AnnyRoom r) => r.section == "seats",
                orElse: () => anny.rooms.first));
    final int? free = fav == null ? null : anny.freeCounts[fav.slug];
    if (free == null) return none;
    return L10n.t("library.freeNow", [free]);
  }

  Widget _row(ThemeData theme,
      {required String label,
      required String value,
      required DataTrust trust,
      VoidCallback? onTap}) {
    final scheme = theme.colorScheme;
    final Widget line = Padding(
      padding:
          const EdgeInsets.symmetric(horizontal: spaceMd, vertical: spaceSm),
      child: Row(children: [
        Text(label,
            style: theme.textTheme.bodyMedium
                ?.copyWith(fontWeight: FontWeight.w600)),
        const SizedBox(width: 6),
        Expanded(
          child: Text.rich(
            TextSpan(
                text: value,
                children: [
                  // untrusted says the WHY out loud, in the mensa
                  // footer's own words; aging names itself with the
                  // dot; fresh is silent - the fresh voice
                  if (trust == DataTrust.untrusted)
                    TextSpan(
                        text: " · ${L10n.t("mensa.stale")}",
                        style: TextStyle(color: scheme.tertiary)),
                ]),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodyMedium,
          ),
        ),
        if (trust == DataTrust.aging)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: spaceSm),
            child: Container(
              width: 7,
              height: 7,
              decoration: BoxDecoration(
                  color: scheme.tertiary, shape: BoxShape.circle),
            ),
          ),
        if (onTap != null)
          Icon(Icons.chevron_right, size: 18, color: scheme.outline),
      ]),
    );
    if (onTap == null) return line;
    return InkWell(
      borderRadius: const BorderRadius.all(appBorderRadius),
      onTap: onTap,
      child: line,
    );
  }

  static String _hm(DateTime d) =>
      "${d.hour.toString().padLeft(2, "0")}:"
      "${d.minute.toString().padLeft(2, "0")}";
}
