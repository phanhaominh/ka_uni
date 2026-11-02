import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../l10n/l10n.dart';
import '../../exams/models/exam_list.dart';
import '../../exams/views/exams_page.dart';
import '../../agenda/logic/walk_hint.dart';
import '../../common_ui/highlight_pulse.dart';
import '../../ilias/ilias_scraper.dart';
import '../../geo/models/kit_place.dart';
import '../../geo/views/place_search_page.dart';
import '../../ilias/models/ilias_models.dart';
import '../../state_management/ilias/ilias_watcher.dart';
import '../../signmeup/signmeup_manager.dart';
import '../../signmeup/signmeup_mine_card.dart';
import '../../state_management/kit_provider.dart';
import '../../timetable/models/webcal.dart';
import '../../timetable/logic/ics_export_action.dart';

/// Merged agenda: ICS "CHANGED" band + today/tomorrow lectures + ILIAS
/// unread/announcements + open exam-registration deadlines on one screen.
class AgendaPage extends StatefulWidget {
  /// [scrollToToday]: lecture reminders deep-link straight to the today
  /// section; [highlightChanges]: a CHANGED delta push pulses the changes
  /// band for ~2 s so the eye lands on it.
  const AgendaPage(
      {super.key, this.scrollToToday = false, this.highlightChanges = false});

  final bool scrollToToday;
  final bool highlightChanges;

  static const routeName = "/agenda";

  @override
  State<AgendaPage> createState() => _AgendaPageState();
}

class _AgendaLoad {
  final List<IcsOccurrence> today;
  final List<IcsOccurrence> tomorrow;
  final List<IcsChange> changes;
  // nearest occurrences AFTER tomorrow, so empty day cards can point at
  // when the silence ends instead of showing a dead "No events"
  final List<IcsOccurrence> upcoming;
  final IliasUnread? unread;
  final List<IliasAnnouncement> announcements;
  final String? iliasError;
  final DateTime? fetchedAt;

  _AgendaLoad(
      {this.today = const [],
      this.tomorrow = const [],
      this.changes = const [],

      this.unread,
      this.announcements = const [],
      this.upcoming = const [],
      this.iliasError,
      this.fetchedAt});
}

class _AgendaPageState extends State<AgendaPage> {
  static const _icsCacheKey = "DATA_webcalIcsCache";
  static const _changesKey = "DATA_webcalChanges";
  static const _fetchedAtKey = "DATA_webcalFetchedAt";
  static const _iliasCacheKey = "DATA_iliasCardCache";

  _AgendaLoad _load = _AgendaLoad();
  bool _loading = true;
  bool _iliasLoading = false;
  // false until a cached ICS was found; drives the day-section spinner
  bool _feedCached = false;

  Timer? _ticker;
  /// the today card doubles as the agenda's "now" anchor for deep links
  final GlobalKey _todaySectionKey = GlobalKey();

  /// armed by scrollToToday; consumed by [_scheduleTodayScroll] once the
  /// today card has rendered data-driven content
  bool _todayScrollPending = false;

  @override
  void initState() {
    super.initState();
    _refresh();
    // the 30 s ticker is armed in didChangeDependencies: it must respect
    // route visibility from the very first frame (C22)
    if (widget.scrollToToday) {
      // the today card doubles as the "now" anchor, but it is NOT at its
      // final position on the first frame: the changes band and the
      // next-up banner appear only with the cached/live agenda data.
      // Arm the flag instead; [_scheduleTodayScroll] re-runs
      // ensureVisible once the first data-driven rebuild has landed
      _todayScrollPending = true;
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // C22: the overlay disables TickerMode in this subtree while the agenda
    // sits under an opaque route or is offstage. Reading the flag here (not
    // only inside the tick) both stops the countdown while the user cannot
    // see it AND registers the dependency, so the very rebuild that
    // re-exposes the route re-arms the timer - no up-to-30 s stale banner
    // after the way back.
    if (TickerMode.valuesOf(context).enabled) {
      _ticker ??= Timer.periodic(const Duration(seconds: 30), (_) {
        if (mounted) setState(() {});
      });
    } else {
      _ticker?.cancel();
      _ticker = null;
    }
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  /// Re-anchor for deep-linked scrollToToday arrivals: called after every
  /// data-driven rebuild, scrolls to the today card from a post-frame
  /// callback and then clears the flag. Stays a hard no-op for normal
  /// (scrollToToday=false) visits — the flag is never armed there.
  void _scheduleTodayScroll() {
    if (!_todayScrollPending) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_todayScrollPending) return;
      final ctx = _todaySectionKey.currentContext;
      if (ctx == null) return;
      Scrollable.ensureVisible(ctx,
          duration: const Duration(milliseconds: 300));
      // while the day card only shows its "loading" spinner the content
      // above it (banner) can still appear and move it: keep armed for
      // the next data rebuild and settle once there is real content
      if (_load.today.isNotEmpty || _feedCached) _todayScrollPending = false;
    });
  }

  /// Single-flight: drag-spam would otherwise interleave full refresh
  /// pipelines (double prefs writes, two pairs of 45 s waits) — the same
  /// guard the ICS export applies for exactly this
  Future<void>? _refreshInFlight;

  Future<void> _refresh() {
    final running = _refreshInFlight;
    if (running != null) return running;
    return _refreshInFlight =
        _refreshOnce().whenComplete(() => _refreshInFlight = null);
  }

  Future<void> _refreshOnce() async {
    final vm = context.read<KITProvider>();
    final now = DateTime.now();

    // local data first: the agenda must never sit on a spinner because of
    // the network round-trips below
    final prefs = await SharedPreferences.getInstance();
    final feed = WebcalFeed.parse(prefs.getString(_icsCacheKey) ?? "");
    // feed cache is also the relevance source for the exam pages: exam
    // registration urgency must ignore catalogue exams of later semesters
    vm.campusManager.rememberEnrolledTitles(feed);
    final changes = IcsChange.decode(prefs.getString(_changesKey) ?? "");
    // cached ILIAS card content: the live fetch hides behind SSO + two
    // dashboard round-trips (tens of seconds), so the previous snapshot
    // renders with the local data and gets replaced when the fetch lands
    final iliasCached = decodeIliasCard(prefs.getString(_iliasCacheKey));
    if (!mounted) return;
    setState(() {
      // "have we ever cached a timetable" must be judged on the RAW cache,
      // not on parse success: a well-formed calendar with zero occurrences
      // (semester break!) parses to null and used to trap the agenda in
      // "Timetable loading…" spinners forever
      _feedCached = (prefs.getString(_icsCacheKey) ?? "")
          .contains("BEGIN:VCALENDAR");
      _load = _AgendaLoad(
          today: _onDay(feed, now),
          tomorrow: _onDay(feed, DateTime(now.year, now.month, now.day + 1)),
          changes: changes,
          upcoming: _upcoming(feed, now),
          unread: iliasCached?.$1 ?? _load.unread,
          announcements:
              iliasCached != null && iliasCached.$2.isNotEmpty
                  ? iliasCached.$2
                  : _load.announcements,
          iliasError: _load.iliasError,
          fetchedAt: DateTime.tryParse(prefs.getString(_fetchedAtKey) ?? ""));
      _loading = false;
    });
    // first data-driven rebuild: this, not the data-free first frame, is
    // where the deep-link scroll to the today card actually belongs
    _scheduleTodayScroll();

    IliasUnread? unread;
    var announcements = const <IliasAnnouncement>[];
    String? iliasError;
    setState(() => _iliasLoading = true);
    try {
      // don't race the auto-login SSO, but bound the wait: a slow SSO
      // chain may only stall the ILIAS card's first render for so long -
      // the TimeoutException lands in the existing catch below, which
      // keeps the cached card visible or shows the unreachable line
      await vm.iliasAuth.timeout(const Duration(seconds: 30));
      unread = await vm.iliasManager.fetchUnread();
      announcements = await vm.iliasManager.fetchAnnouncements();
      final prefs3 = await SharedPreferences.getInstance();
      await prefs3.setString(
          _iliasCacheKey, encodeIliasCard(unread, announcements));

      // fire-and-forget: the watcher swallows every failure internally and
      // must never delay or poison the agenda rebuild behind it
      IliasWatcher.diffAndNotify(announcements);
    } catch (_) {
      // the bare error line replaces content only where nothing was ever
      // cached; with a snapshot on screen the rows stay and the section
      // adds a staleness note instead (see _iliasSection) — saved data
      // must never masquerade as live
      iliasError = L10n.t("agenda.iliasUnreachable");
    }
    if (!mounted) return;
    setState(() {
      _iliasLoading = false;
      _load = _AgendaLoad(
          today: _load.today,
          tomorrow: _load.tomorrow,
          changes: _load.changes,
          upcoming: _load.upcoming,
          unread: unread ?? _load.unread,
          announcements:
              announcements.isNotEmpty ? announcements : _load.announcements,
          iliasError: iliasError,
          fetchedAt: _load.fetchedAt);
    });

    // the injectors land silently behind the visible content
    unawaited(_followUpInjectors(vm));
  }

  /// Bounded tail for the synthetic-event injectors: SignMeUp groups and
  /// exam sittings write into the ICS cache only after the agenda has
  /// already rendered. Deliberately NOT awaited by [_refreshOnce] — the
  /// RefreshIndicator must hide once the visible content is up, not after
  /// two further 45 s waits; the re-render lands as soon as they do.
  Future<void> _followUpInjectors(KITProvider vm) async {
    // assigned SignMeUp groups land in the ICS cache as synthetic events;
    // wait for that injection (bounded) and re-render today/tomorrow once
    final smu = vm.signMeUpDone;
    if (smu != null) {
      try {
        // must outlast _doFetchSignMeUp's cold retry (fetch + 20 s sleep
        // + fetchMine); a 20 s cap gave up mid-retry and lost the re-render
        await smu.timeout(const Duration(seconds: 45));
      } catch (_) {}
      await _rerenderFromCache(vm);
    }

    // registered exam sittings land in the same cache the moment the exam
    // fetch injects their block; same bounded tolerance as SignMeUp above,
    // so today/tomorrow gain "Klausur:" rows without a manual pull
    final exams = vm.examsDone;
    if (exams != null) {
      try {
        await exams.timeout(const Duration(seconds: 45));
      } catch (_) {}
      await _rerenderFromCache(vm);
    }
  }

  /// Re-parse the ICS cache and rebuild today/tomorrow/upcoming from it;
  /// used after an in-flight synthetic-event injector (SignMeUp groups,
  /// exam sittings) has finished writing.
  Future<void> _rerenderFromCache(KITProvider vm) async {
    final prefs2 = await SharedPreferences.getInstance();
    final feed2 = WebcalFeed.parse(prefs2.getString(_icsCacheKey) ?? "");
    vm.campusManager.rememberEnrolledTitles(feed2);
    if (!mounted) return;
    final now2 = DateTime.now();
    setState(() {
      _feedCached = _feedCached ||
          (prefs2.getString(_icsCacheKey) ?? "")
              .contains("BEGIN:VCALENDAR");
      _load = _AgendaLoad(
          today: _onDay(feed2, now2),
          tomorrow:
              _onDay(feed2, DateTime(now2.year, now2.month, now2.day + 1)),
          changes: _load.changes,
          upcoming: _upcoming(feed2, now2),
          unread: _load.unread,
          announcements: _load.announcements,
          iliasError: _load.iliasError,
          fetchedAt: _load.fetchedAt);
    });
    // synthetic events may have just moved the today card
    _scheduleTodayScroll();
  }

  static List<IcsOccurrence> _onDay(WebcalFeed? feed, DateTime day) {
    if (feed == null) return const [];
    final seen = <String>{};
    final dayStart = DateTime(day.year, day.month, day.day);
    // calendar next-day (not +24h): the autumn DST day is 25 real hours
    final nextStart = DateTime(day.year, day.month, day.day + 1);

    return feed.occurrences
        .where((o) =>
            // include a lecture that started yesterday but still runs past
            // midnight: it belongs to today's list and the running banner
            (o.start.isBefore(nextStart) && o.end.isAfter(dayStart)) &&
            // one row per lecture; the room is part of the key so two
            // genuinely parallel groups of one family ("Übung X" 14:00 in
            // different rooms) keep their own rows and room lines
            seen.add(
                "${o.title}|${o.start.toIso8601String()}|${o.room}"))
        .toList()
      ..sort((a, b) => a.start.compareTo(b.start));
  }
  /// Next occurrences after the end of tomorrow, soonest first (≤5).
  static List<IcsOccurrence> _upcoming(WebcalFeed? feed, DateTime now) {
    if (feed == null) return const [];
    final horizon = DateTime(now.year, now.month, now.day + 2);
    final out = feed.occurrences
        .where((o) => o.start.isAfter(horizon))
        .toList()
      ..sort((a, b) => a.start.compareTo(b.start));
    return out.take(5).toList();
  }

  static String _hm(DateTime d) =>
      "${d.hour.toString().padLeft(2, "0")}:"
      "${d.minute.toString().padLeft(2, "0")}";
  Future<void> _dismissChanges() async {
    final vm = context.read<KITProvider>();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_changesKey);
    if (!mounted) return; // prefs I/O outlives a tab switch easily
    vm.campusManager.timetableChanged = false;
    vm.campusManager.notificationCallback(); // home badge must clear now
    setState(() => _load = _AgendaLoad(
        today: _load.today,
        tomorrow: _load.tomorrow,
        upcoming: _load.upcoming,
        unread: _load.unread,
        announcements: _load.announcements,
        iliasError: _load.iliasError,
        fetchedAt: _load.fetchedAt));
  }

  @override
  Widget build(BuildContext context) {
    final vm = Provider.of<KITProvider>(context);
    final now = DateTime.now();
    final needAction = vm.campusManager.exams
        .where((e) =>
            e.needsAction(now) &&
            vm.campusManager.isTakingThisSemester(e) != false)
        .toList()
      ..sort((a, b) =>
          (a.windowEnd ?? DateTime(2100)).compareTo(b.windowEnd ?? DateTime(2100)));

    // C21: each SignMeUp row builder runs exactly ONCE per build - the
    // old `isNotEmpty`-condition-plus-value shape sorted and filtered
    // both row sets twice per 30 s ticker tick
    final smuRows = _signMeUpRows(vm, now);
    final myRegs = _myRegsRows(vm, now);

    return Scaffold(
      appBar: AppBar(
        title: Text(L10n.t("agenda.title")),
        actions: [
          // one-tap export of exactly what the agenda renders from: the
          // merged cache (webcal + personal ICS + SignMeUp blocks); a
          // direct share button matching the file viewer's precedent,
          // not an Android-style single-item overflow menu
          IconButton(
            icon: const Icon(Icons.share),
            tooltip: L10n.t("export.timetable"),
            onPressed: () => exportMergedTimetableIcs(context),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 130),
          children: [
            if (_load.changes.isNotEmpty)
              HighlightPulse(
                armed: widget.highlightChanges,
                color: Theme.of(context).colorScheme.tertiary,
                child: _changedBand(context),
              ),
            _nextUpBanner(context, now),
            _daySection(L10n.t("agenda.today"), _load.today, now,
                key: _todaySectionKey),
            _daySection(L10n.t("agenda.tomorrow"), _load.tomorrow, now),
            _nextExamCard(context, vm, now),
            _iliasSection(context),
            if (needAction.isNotEmpty)
              _examsSection(context, needAction)
            else if (vm.campusManager.ready &&
                !vm.campusManager.examsLoaded &&
                !vm.campusManager.examsSurfaceBroken)
              _pendingCard(context, L10n.t("agenda.examsLoading")),
            if (smuRows.isNotEmpty) _signMeUpSection(context, smuRows),
            // my registrations + outcomes directly below the open
            // procedures: offers and results belong together
            if (myRegs.isNotEmpty)
              SignMeUpMineCard(rows: myRegs, now: now),
            _staleFooter(context, now),
            // tail spinner only while the cache has not proven itself: once
            // real cached content renders above, a spinner for the live
            // ILIAS/synthetic tail is pure noise
            if (_loading && !_feedCached)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Center(child: CircularProgressIndicator()),
              ),
          ],
        ),
      ),
    );
  }

  Widget _pendingRow(BuildContext context, String text) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(children: [
        SizedBox(
          width: 16,
          height: 16,
          child: CircularProgressIndicator(strokeWidth: 2, color: scheme.primary),
        ),
        const SizedBox(width: 10),
        Text(text, style: TextStyle(color: scheme.outline, fontSize: 13)),
      ]),
    );
  }

  Widget _pendingCard(BuildContext context, String text) {
    return Card(
      child: Padding(padding: const EdgeInsets.all(12), child: _pendingRow(context, text)),
    );
  }

  Widget _changedBand(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      color: scheme.tertiaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Icon(Icons.trending_up, color: scheme.onTertiaryContainer),
              const SizedBox(width: 8),
              Text(L10n.t("agenda.timetableChangedN", [_load.changes.length]),
                  style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: scheme.onTertiaryContainer)),
            ]),
            const SizedBox(height: 6),
            for (final c in _load.changes.take(6))
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 1),
                child: Text(c.describe(),
                    style: TextStyle(
                        fontSize: 13, color: scheme.onTertiaryContainer)),
              ),
            if (_load.changes.length > 6)
              Text(L10n.t("agenda.moreChanges", [_load.changes.length - 6]),
                  style: TextStyle(
                      fontSize: 12,
                      fontStyle: FontStyle.italic,
                      color: scheme.onTertiaryContainer)),
            Align(
              alignment: Alignment.centerRight,
              child: Semantics(
                button: true,
                hint: "agenda-dismiss-changes",
                child: TextButton(
                    onPressed: _dismissChanges,
                    child: Text(L10n.t("agenda.dismiss"))),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _daySection(String label, List<IcsOccurrence> occ, DateTime now,
      {Key? key}) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      key: key,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: const TextStyle(fontWeight: FontWeight.bold)),
            if (occ.isEmpty && !_feedCached)
              _pendingRow(context, L10n.t("agenda.timetableLoading"))
            else if (occ.isEmpty)
              Builder(builder: (context) {
                final next = _load.upcoming.isNotEmpty
                    ? _load.upcoming.first
                    : (label == L10n.t("agenda.today") &&
                            _load.tomorrow.isNotEmpty
                        ? _load.tomorrow.first
                        : null);
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Text(
                      next == null
                          ? L10n.t("agenda.noEvents")
                          : L10n.t("agenda.noEventsUntil",
                              [L10n.stamp(next.start)]),
                      style: TextStyle(color: scheme.outline, fontSize: 13)),
                );
              }),
            for (var i = 0; i < occ.length; i++) ...[
              if (i > 0) ..._walkHint(context, occ[i - 1], occ[i]),
              Opacity(
                // finished lectures recede; the live one is the anchor
                opacity: occ[i].end.isBefore(now) ? 0.38 : 1.0,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                          "${_hm(occ[i].start)}–${_hm(occ[i].end)}  ${occ[i].displayTitle}",
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 13,
                              fontWeight: occ[i].start.isBefore(now) &&
                                      occ[i].end.isAfter(now)
                                  ? FontWeight.bold
                                  : FontWeight.normal,
                              fontFeatures: const [
                                FontFeature.tabularFigures()
                              ])),
                      // #17: a roomless personal-ICS event still needs its
                      // source chip row, so the line renders for it too
                      if (occ[i].room.isNotEmpty || occ[i].fromPersonalIcs)
                        AgendaRoomLine(
                            room: occ[i].room,
                            ownCalendar: occ[i].fromPersonalIcs),
                    ],
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  KITPlace? _resolveRoom(KITProvider vm, String room) {
    final places = vm.topographyManager.places;
    if (_roomCacheEpoch != places.length) {
      _roomCache.clear();
      _roomCacheEpoch = places.length;
    }
    return _roomCache.putIfAbsent(
        room, () => resolveRoomPlace(places, room));
  }

  final Map<String, KITPlace?> _roomCache = {};
  int _roomCacheEpoch = -1;

  /// "Can you actually make it there": walk-time hint between two adjacent
  /// lectures once the gap is tight enough to matter.
  List<Widget> _walkHint(
      BuildContext context, IcsOccurrence prev, IcsOccurrence next) {
    final vm = Provider.of<KITProvider>(context, listen: false);
    // pairs where either side's end is only the parser's guess (exam
    // sittings export without DTEND) are skipped: no certifying a Fußweg
    // across an invented gap
    final gap = walkHintGap(prev, next);
    if (gap == null) return const [];
    final hint = computeWalkHint(
        _resolveRoom(vm, prev.room), _resolveRoom(vm, next.room), gap);
    if (hint == null) return const [];
    final scheme = Theme.of(context).colorScheme;
    final color = hint.tight ? scheme.error : scheme.outline;
    return [
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(children: [
          Icon(Icons.directions_walk, size: 15, color: color),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
                hint.tight
                    ? L10n.t("agenda.walkTight", [gap, hint.walkMinutes])
                    : L10n.t("agenda.walkOk", [hint.walkMinutes]),
                style: TextStyle(fontSize: 12, color: color)),
          ),
        ]),
      ),
    ];
  }

  /// Live "next up" hero: what is happening now / starting next, with a
  /// countdown refreshed by the 30 s ticker. Hidden when nothing is within
  /// 12 h (weekends, evenings) so it never nags.
  Widget _nextUpBanner(BuildContext context, DateTime now) {
    final scheme = Theme.of(context).colorScheme;
    final candidates = <IcsOccurrence>[..._load.today, ..._load.tomorrow]
      ..sort((a, b) => a.start.compareTo(b.start));
    IcsOccurrence? running;
    IcsOccurrence? next;
    for (final o in candidates) {
      if (!o.end.isAfter(now)) continue;
      if (running == null && !o.start.isAfter(now)) running = o;
      if (next == null && o.start.isAfter(now)) next = o;
      if (running != null && next != null) break;
    }
    final hero = running ?? next;
    if (hero == null) return const SizedBox.shrink();
    String detail;
    if (running != null) {
      detail = L10n.t("agenda.nowRunning", [_hm(hero.end)]);
    } else {
      final until = hero.start.difference(now);
      if (until.inMinutes < 3) {
        detail = L10n.t("agenda.startsSoon");
      } else if (until.inMinutes < 60) {
        detail = L10n.t("agenda.startsInMin", [until.inMinutes]);
      } else if (until.inMinutes <= 720) {
        detail = L10n.t("agenda.startsInHours", [until.inHours]);
      } else {
        return const SizedBox.shrink();
      }
    }
    return Card(
      color: scheme.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            Icon(running != null ? Icons.play_circle : Icons.directions_run,
                color: scheme.onPrimaryContainer),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(detail,
                      style: TextStyle(
                          fontWeight: FontWeight.bold,
                          color: scheme.onPrimaryContainer)),
                  Text(hero.displayTitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 13, color: scheme.onPrimaryContainer)),
                  if (hero.room.isNotEmpty)
                    Text(hero.room,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 12, color: scheme.onPrimaryContainer)),
                ],
              ),
            ),
            Text("${_hm(hero.start)}–${_hm(hero.end)}",
                style: TextStyle(
                    fontSize: 12,
                    color: scheme.onPrimaryContainer,
                    fontFeatures: const [FontFeature.tabularFigures()])),
          ],
        ),
      ),
    );
  }

  /// Countdown to the nearest registered exam sitting (dates now parsed
  /// from the term rows). Hidden if none within 45 days / none registered.
  Widget _nextExamCard(BuildContext context, KITProvider vm, DateTime now) {
    final scheme = Theme.of(context).colorScheme;
    ExamEntry? best;
    DateTime? bestAt;
    ExamTerm? bestTerm;
    for (final e in vm.campusManager.exams) {
      final at = e.nextRegisteredTerm(now);
      if (at != null && (bestAt == null || at.isBefore(bestAt))) {
        best = e;
        bestAt = at;
        // two pool sittings can share a start; showing the first match's
        // room would misattribute a sibling term — label only when the
        // best start resolves to exactly one room
        final atTerms = e.terms.where((t) => t.startAt == at).toList();
        bestTerm = atTerms.map((t) => t.room).toSet().length == 1
            ? atTerms.first
            : null;
      }
    }
    if (best == null || bestAt == null) return const SizedBox.shrink();
    final days = L10n.daysFromNow(bestAt, now);
    if (days > 45) return const SizedBox.shrink();
    final when = L10n.dayOffset(bestAt, now);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            Icon(Icons.event, color: scheme.tertiary),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text("${L10n.t("agenda.nextExam")} · $when",
                      style: const TextStyle(fontWeight: FontWeight.bold)),
                  Text(best.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 13, color: scheme.onSurfaceVariant)),
                  Text(
                      [
                        L10n.stamp(bestAt),
                        if ((bestTerm?.room.isNotEmpty ?? false))
                            bestTerm!.room
                      ].join(" · "),
                      style: TextStyle(
                          fontSize: 12, color: scheme.outline)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// "Stand: HH:MM" / orange stale warning — silent-fetch failures become
  /// visible instead of rendering yesterday's feed as current. Takes the
  /// build-level `now` (C22): one clock reading per build, never a footer
  /// disagreeing with the banner of the same frame.
  Widget _staleFooter(BuildContext context, DateTime now) {
    final scheme = Theme.of(context).colorScheme;
    final at = _load.fetchedAt;
    if (at == null) {
      // upgrade path: cached ICS predates the fetch-stamp key -> warn,
      // don't silently trust a possibly week-old feed
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Text(L10n.t("agenda.staleUnknown"),
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 11, color: scheme.error)),
      );
    }
    final age = now.difference(at);
    final stale = age > const Duration(hours: 6);
    final label = stale
        ? L10n.t("agenda.staleData", ["${age.inHours} h"])
        : L10n.t("agenda.asOf", [_hm(at)]);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Text(label,
          textAlign: TextAlign.center,
          style: TextStyle(
              fontSize: 11, color: stale ? scheme.error : scheme.outline)),
    );
  }

  Widget _iliasSection(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Text(L10n.t("agenda.ilias"),
                  style: TextStyle(fontWeight: FontWeight.bold)),
              const Spacer(),
              if (_load.unread != null && _load.unread!.notifications > 0)
                _badge(L10n.t("agenda.nNew", [_load.unread!.notifications]), scheme),
            ]),
            if (_iliasLoading &&
                _load.unread == null &&
                _load.announcements.isEmpty)
              // fresh-install-only spinner: with a cached snapshot the card
              // shows it and swaps in the live data when the fetch lands
              _pendingRow(context, L10n.t("agenda.iliasLoading"))
            else if (_load.iliasError != null &&
                _load.unread == null &&
                _load.announcements.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Text(_load.iliasError!,
                    style: TextStyle(color: scheme.error, fontSize: 13)),
              )
            else if (_load.announcements.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Text(L10n.t("agenda.iliasNone"),
                    style: TextStyle(color: scheme.outline)),
              )
            else
              for (final a in _load.announcements.take(5))
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: Text(a.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 13)),
                  subtitle: a.when == null
                      ? null
                      : Text(L10n.stamp(a.when!),
                          style: const TextStyle(fontSize: 11)),
                  // F12 rule: a non-launchable payload (malformed or a
                  // foreign scheme) gets no chevron and no tap target -
                  // the onTap gate matters as much as the chevron gate:
                  // a no-op callback still ripples and still announces
                  // the row as actionable
                  trailing: _launchableUrl(a.url) == null
                      ? null
                      : const Icon(Icons.chevron_right, size: 18),
                  onTap: _launchableUrl(a.url) == null
                      ? null
                      : () => _launchExternal(a.url),
                ),
            if (_load.iliasError != null &&
                (_load.unread != null || _load.announcements.isNotEmpty))
              // refresh failed but a cached snapshot stays on screen: keep
              // the rows and say what they are — same honesty rule as
              // _staleFooter, no silent yesterday-presented-as-today
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Text(L10n.t("agenda.iliasStale"),
                    style: TextStyle(color: scheme.error, fontSize: 12)),
              ),
          ],
        ),
      ),
    );
  }

  /// Scheme gate for scraped announcement URLs (mirrors the Raum-Finder's
  /// F12 hardening): only a well-formed http(s) URL reaches the external
  /// launcher — a malformed "http:/broken" used to throw inside the tap,
  /// and mailto:/javascript: must never reach a foreign application.
  Uri? _launchableUrl(String raw) {
    if (raw.isEmpty) return null;
    try {
      final uri = Uri.parse(raw);
      return uri.host.isNotEmpty &&
              (uri.scheme == "http" || uri.scheme == "https")
          ? uri
          : null;
    } on Object catch (_) {
      return null;
    }
  }

  /// Error-handled external launch through the gate: a launcher that is
  /// missing or refuses the URL stays a no-op instead of throwing inside
  /// the tap.
  void _launchExternal(String raw) {
    final uri = _launchableUrl(raw);
    if (uri == null) return;
    try {
      launchUrl(uri, mode: LaunchMode.externalApplication)
          .catchError((_) => false);
    } on Object catch (_) {}
  }

  Widget _examsSection(BuildContext context, List<ExamEntry> exams) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      color: scheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Icon(Icons.warning_amber, color: scheme.onErrorContainer),
              const SizedBox(width: 6),
              Text(L10n.t("agenda.examsOpen"),
                  style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: scheme.onErrorContainer)),
            ]),
            for (final e in exams.take(3))
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 1),
                child: Text(
                    // open-ended windows ("Anmeldung ab" without "bis")
                    // have a null deadline - never force-unwrap it
                    "${e.title}"
                    "${e.windowEnd != null ? " · ${L10n.until(e.windowEnd!)}" : ""}",
                    style: TextStyle(
                        fontSize: 13, color: scheme.onErrorContainer)),
              ),
            Align(
              alignment: Alignment.centerRight,
              // Filled CTA on the danger card: bare text hid the one
              // action that still prevents a failed attempt
              child: FilledButton(
                onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => const ExamsPage())),
                // label now sits on the button's own surface, so the old
                // primary-green-on-red-container contrast problem is gone
                child: Text(L10n.t("agenda.toRegistration")),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// My still-relevant registrations for the status card; the visibility
  /// filter lives in SignMeUpMineCard.activeRows (unit-tested there).
  List<SignMeUpRegistration> _myRegsRows(KITProvider vm, DateTime now) =>
      SignMeUpMineCard.activeRows(vm.signMeUpManager.mine, now);

  /// SignMeUp procedures needing action now or opening within 3 days.
  List<({SignMeUpProcedure p, bool open})> _signMeUpRows(
      KITProvider vm, DateTime now) {
    final rows = <({SignMeUpProcedure p, bool open})>[];
    final registered = vm.signMeUpManager.registeredProcedureIds;
    for (final p in vm.signMeUpManager.procedures) {
      if (p.needsAction(now, registered)) {
        rows.add((p: p, open: true));
      } else if (!registered.contains(p.id) &&
          p.registrationStart != null &&
          p.registrationStart!.isAfter(now) &&
          p.registrationStart!.isBefore(now.add(const Duration(days: 3)))) {
        rows.add((p: p, open: false));
      }
    }
    rows.sort((a, b) =>
        ((a.open ? a.p.registrationEnd : a.p.registrationStart) ??
                DateTime(2100))
            .compareTo((b.open ? b.p.registrationEnd : b.p.registrationStart) ??
                DateTime(2100)));
    return rows;
  }

  Widget _signMeUpSection(
      BuildContext context, List<({SignMeUpProcedure p, bool open})> rows) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      color: scheme.tertiaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Icon(Icons.how_to_reg, color: scheme.onTertiaryContainer),
              const SizedBox(width: 6),
              Text(L10n.t("agenda.signmeupTitle"),
                  style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: scheme.onTertiaryContainer)),
            ]),
            for (final r in rows.take(3))
              Padding(
                // name and deadline on their own lines: a long procedure
                // name used to wrap the " · until …" tail mid-phrase
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(r.p.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: scheme.onTertiaryContainer)),
                    // deadline(): registration windows are exactly the
                    // timestamps that must never drop the time - stamp()
                    // hides a real 00:00 close behind a date-only "bis"
                    Text(
                        r.open
                            ? L10n.t("agenda.signmeupUntil", [
                                L10n.deadline(r.p.registrationEnd!)])
                            : L10n.t("agenda.signmeupFrom", [
                                L10n.deadline(r.p.registrationStart!)]),
                        style: TextStyle(
                            fontSize: 12,
                            color: scheme.onTertiaryContainer
                                .withValues(alpha: 0.75))),
                  ],
                ),
              ),
            Align(
              alignment: Alignment.centerRight,
              // tonal CTA with action wording: the old text button merely
              // repeated the card title and read as a label, not a launch
              child: FilledButton.tonal(
                onPressed: () => _launchExternal(
                    "https://plus.campus.kit.edu/signmeup"),
                child: Text(L10n.t("agenda.signmeupOpen")),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _badge(String label, ColorScheme scheme) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(
            color: scheme.primaryContainer,
            borderRadius: BorderRadius.circular(10)),
        child: Text(label, style: const TextStyle(fontSize: 11)),
      );
}

/// Room line of an agenda lecture row, and the ONE entry point to the
/// Raum-Finder. Tapping pushes the room as query + distance reference —
/// the SAME string the walk hints resolve. Placeholder rooms ("-", "--",
/// "ILIAS") would open a wall of 16-89 junk rows, so they stay plain
/// Text (F1); a real room's label is tinted [ColorScheme.primary] to
/// announce that it is tappable (F2; C26 additionally announces the tap
/// target itself to screen readers as a button).
class AgendaRoomLine extends StatelessWidget {
  const AgendaRoomLine(
      {super.key, required this.room, this.ownCalendar = false});

  /// Raw ICS LOCATION of the occurrence.
  final String room;

  /// #17: the occurrence comes from the student's OWN imported ICS
  /// (IcsOccurrence.fromPersonalIcs) - renders a small "own calendar" chip
  /// so the duplicate of a feed lecture stops being an unlabeled twin.
  final bool ownCalendar;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // displayRoom (IcsOccurrence.cleanRoom) over the raw string: it only
    // folds DUPLICATED tokens ("Gottlieb-Daimler-HS HS bldg 10.21" ->
    // one HS), the exact normalization reminders already show, and a
    // de-duplicated string fuzzy-matches the directory better. No
    // behavior risk: ICS matching/dedup keep using the raw room.
    final shown = IcsOccurrence.cleanRoom(room);
    Widget? line;
    if (ExamTerm.isPlaceholderRoom(shown)) {
      // plain Text: nothing to open, nothing to tap
      if (shown.isNotEmpty) {
        line = Text(shown,
            style: TextStyle(fontSize: 12, color: scheme.outline));
      }
    } else {
      line = GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => Navigator.of(context).push(MaterialPageRoute(
            builder: (context) => PlaceSearchPage(
                initialQuery: shown, fromRoom: shown))),
        // C26: a tinted label alone is invisible to TalkBack - the tap
        // target announces itself as one button node carrying the room
        // name; ExcludeSemantics keeps the child Text from adding a
        // second node with the same words ("HS 104, HS 104")
        child: Semantics(
          button: true,
          label: shown,
          child: ExcludeSemantics(
            child: Text(shown,
                style: TextStyle(fontSize: 12, color: scheme.primary)),
          ),
        ),
      );
    }
    if (!ownCalendar) return line ?? const SizedBox.shrink();
    final chip = Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(8)),
      child: Text(L10n.t("agenda.ownCalendar"),
          style: TextStyle(fontSize: 10, color: scheme.onSurfaceVariant)),
    );
    if (line == null) return chip;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [Flexible(child: line), const SizedBox(width: 6), chip],
    );
  }
}
