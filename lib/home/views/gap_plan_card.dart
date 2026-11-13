import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../common_ui/block_container.dart';
import '../../gapplan/gap_plan.dart';
import '../../l10n/l10n.dart';
import '../../state_management/kit_provider.dart';
import '../../timetable/logic/now_clock.dart';
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

class _GapPlanCardState extends State<GapPlanCard>
    with WidgetsBindingObserver {
  /// seat counts age out fast - the clause speaks in the present tense
  static const Duration _seatsTtl = Duration(minutes: 15);
  static const Duration _mensaTtl = Duration(hours: 6);

  WebcalFeed? _feed;
  String _seenFetchedAt = "";
  bool _probeInFlight = false;
  bool _clockArmed = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _readCache();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (_clockArmed) {
      _clockArmed = false;
      NowClock.disarm();
    }
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // R37: resume re-reads like the hero - background polls refresh the
    // cache while the app sits closed, and without a clock/heartbeat the
    // card showed 11:00's plan at 18:00 (nothing rebuilt it)
    if (state == AppLifecycleState.resumed) _resyncIfStale(force: true);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // minute heartbeat (hero idiom): gaps and TTLs are time-derived, a
    // KITProvider notify alone goes stale for hours on an idle home
    final visible = TickerMode.valuesOf(context).enabled;
    if (visible && !_clockArmed) {
      _clockArmed = true;
      NowClock.arm();
    } else if (!visible && _clockArmed) {
      _clockArmed = false;
      NowClock.disarm();
    }
    _resyncIfStale();
  }

  /// R37 (R31 F-1 doctrine, hero precedent): memory handoff FIRST - a
  /// foreground fetch publishes the exact feed on CampusManager, adopting
  /// it is synchronous with the refresh notify and immune to the async/
  /// legacy prefs split documented on real devices; the async probe is the
  /// poll-isolate fallback only, guarded against notify-burst stacking.
  /// (The card previously was an async-ONLY reader with no guard: never
  /// saw foreground fetches on healthy devices, nothing at all on ghost
  /// devices, and stacked a full ICS prefs read per dependency change.)
  Future<void> _resyncIfStale({bool force = false}) async {
    final cm = context.read<KITProvider>().campusManager;
    final memStamp = cm.webcalWrittenAt;
    final memFeed = cm.webcalMergedFeed;
    if (memStamp != null && memFeed != null && memStamp != _seenFetchedAt) {
      _seenFetchedAt = memStamp;
      if (mounted) setState(() => _feed = memFeed);
      return;
    }
    if (_probeInFlight) return;
    _probeInFlight = true;
    try {
      final stamp =
          await SharedPreferencesAsync().getString(WebcalKeys.fetchedAt);
      if (!mounted) return;
      if (stamp != _seenFetchedAt || force) await _readCache();
      if (stamp != null) _seenFetchedAt = stamp;
    } finally {
      _probeInFlight = false;
    }
  }

  Future<void> _readCache() async {
    // same reader as the hero (SharedPreferencesAsync + ghost-null rule):
    // a null from the async view of the legacy writes must never latch
    // an empty plan - keep the last good cache instead
    final raw = await SharedPreferencesAsync()
        .getString(WebcalKeys.icsCache);
    if (raw == null) return;
    if (!mounted) return;
    // Feed object memoized against the raw bytes (R23 UI-cost rule):
    // parse ONLY when the bytes moved, never per build/notify.
    final feed = WebcalFeed.parse(raw);
    if (feed == null) return;
    setState(() => _feed = feed);
  }

  @override
  Widget build(BuildContext context) {
    final vm = context.watch<KITProvider>();
    if (_feed == null) return const SizedBox.shrink();
    // R37: minute heartbeat (hero pattern - the card never rebuilds on a
    // tick unless the shared clock publishes; gaps END and TTLs EXPIRE on
    // wall time, and a KITProvider-notify-only card kept rendering an
    // expired plan for hours on an idle home screen). The expensive parse
    // stays in _readCache: a tick only re-runs derive/planGaps.
    return ValueListenableBuilder<int>(
      valueListenable: NowClock.minutesOfDay,
      builder: (context, _, __) => _body(context, vm),
    );
  }

  Widget _body(BuildContext context, KITProvider vm) {
    final now = DateTime.now();
    final feed = _feed;
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
    // R37: future stamps (NTP/timezone corrections) are NOT fresh -
    // dataTrust and MensaManager.isFresh both veto a negative age; this
    // row used to accept it while the sibling glance card honestly
    // printed "evtl. veraltet" off the same stamp
    final mAge = mAt == null ? null : now.difference(mAt);
    if (mAge != null && mAge >= Duration.zero && mAge <= _mensaTtl) {
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
    final aAge = aAt == null ? null : now.difference(aAt);
    if (aAge != null && aAge >= Duration.zero && aAge <= _seatsTtl) {
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
