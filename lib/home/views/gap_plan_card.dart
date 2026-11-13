import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../common_ui/block_container.dart';
import '../../gapplan/gap_plan.dart';
import '../../l10n/l10n.dart';
import '../../state_management/kit_provider.dart';
import '../../timetable/models/webcal.dart';

/// R35.5 "Freie Stunden" home card: the remaining real gaps of today,
/// each annotated only with what the app can CERTIFY about it right now
/// - the mensa window (parsed from the SW's own "11-14 Uhr" line stamps,
/// fresh fetch only) and the library's live free-seat total (fresh
/// within 15 min only: "free NOW" on an hour-old count is a lie with
/// numbers). No gap >= 45 min or no fresh clause -> no card: silence,
/// not filler.
///
/// Self-contained like the hero: reads the ICS cache itself and
/// re-parses ONLY when the raw bytes changed (R23 UI-cost rule - vm
/// notifications rebuild home often; parsing per notify is a no-go).
class GapPlanCard extends StatefulWidget {
  const GapPlanCard({super.key});

  @override
  State<GapPlanCard> createState() => _GapPlanCardState();
}

class _GapPlanCardState extends State<GapPlanCard> {
  /// seat counts age out fast - the clause speaks in the present tense
  static const Duration _seatsTtl = Duration(minutes: 15);
  static const Duration _mensaTtl = Duration(hours: 6);

  String _rawCache = "";

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _readCache();
  }

  Future<void> _readCache() async {
    // same reader as the hero (SharedPreferencesAsync + ghost-null rule):
    // a null from the async view of the legacy writes must never latch
    // an empty plan - keep the last good cache instead
    final raw = await SharedPreferencesAsync()
        .getString(WebcalKeys.icsCache);
    if (raw == null) return;
    if (!mounted || raw == _rawCache) return;
    setState(() => _rawCache = raw);
  }

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final vm = context.watch<KITProvider>();
    final feed = WebcalFeed.parse(_rawCache);
    if (feed == null) return const SizedBox.shrink();
    final events = [
      for (final o in feed.occurrences)
        if (_isSameDay(o.start, now) && !o.end.isBefore(now))
          (start: o.start, end: o.end)
    ];
    final gaps = deriveGaps(events, now);
    if (gaps.isEmpty) return const SizedBox.shrink();

    // mensa: fresh-only serving windows of TODAY (ttl = SW publish
    // rhythm; an older page cannot certify "open now")
    final mensa = vm.mensa;
    List<({DateTime from, DateTime to})>? windows;
    final mAt = mensa.fetchedAt;
    if (mAt != null && now.difference(mAt) <= _mensaTtl) {
      final day = mensa.dayFor(now);
      if (day != null) {
        final w = [for (final l in day.lines) ...servingWindows(l.sub, now)];
        if (w.isNotEmpty) windows = w; // no printed window = no claim
      }
    }

    // library: total free seats, present tense, 15 min ceiling; the
    // favorite room alone when the user starred one
    final anny = vm.anny;
    int? seats;
    final aAt = anny.fetchedAt;
    if (aAt != null && now.difference(aAt) <= _seatsTtl) {
      final counts = anny.freeCounts;
      if (counts.isNotEmpty) {
        final fc = anny.favSlug.isEmpty ? null : counts[anny.favSlug];
        seats = fc ?? counts.values.fold<int>(0, (a, b) => a + b);
        if (seats == 0) seats = null; // "0 free" is not a plan, it is news
      }
    }

    final plans = planGaps(
        gaps: gaps, now: now, mensaWindows: windows, seatsFree: seats);
    final worth = plans.where((p) => p.clauses.isNotEmpty).toList();
    if (worth.isEmpty) return const SizedBox.shrink();

    final scheme = Theme.of(context).colorScheme;
    String hm(DateTime d) =>
        "${d.hour.toString().padLeft(2, "0")}:${d.minute.toString().padLeft(2, "0")}";
    return BlockContainer(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(L10n.t("home.gapplanTitle"),
                style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 4),
            for (final p in worth)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Text(
                  "${hm(p.gap.start)}–${hm(p.gap.end)}"
                  " · ${[
                    for (final c in p.clauses)
                      switch (c) {
                        "mensa" => L10n.t("home.gapplanMensa"),
                        _ => L10n.t("home.gapplanSeats", ["$seats"]),
                      }
                  ].join(" · ")}",
                  style:
                      TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
                ),
              ),
          ],
        ),
      ),
    );
  }

  bool _isSameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;
}
