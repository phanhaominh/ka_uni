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
import '../../ilias/models/ilias_models.dart';
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
    // live countdowns in the next-up banner
    _ticker = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() {});
    });
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

  Future<void> _refresh() async {
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
          tomorrow: _onDay(feed, now.add(const Duration(days: 1))),
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
      await vm.iliasAuth; // don't race the auto-login SSO
      unread = await vm.iliasManager.fetchUnread();
      announcements = await vm.iliasManager.fetchAnnouncements();
      final prefs3 = await SharedPreferences.getInstance();
      await prefs3.setString(
          _iliasCacheKey, encodeIliasCard(unread, announcements));
    } catch (_) {
      // a cached card stays visible instead of degrading to an error line;
      // the error only surfaces when there is nothing cached to show
      iliasError = (iliasCached == null ||
              (iliasCached.$1 == null && iliasCached.$2.isEmpty))
          ? L10n.t("agenda.iliasUnreachable")
          : null;
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

    // assigned SignMeUp groups land in the ICS cache as synthetic events;
    // wait for that injection (bounded) and re-render today/tomorrow once
    final smu = vm.signMeUpDone;
    if (smu != null) {
      try {
        // must outlast _doFetchSignMeUp's cold retry (fetch + 20 s sleep
        // + fetchMine); a 20 s cap gave up mid-retry and lost the re-render
        await smu.timeout(const Duration(seconds: 45));
      } catch (_) {}
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
            tomorrow: _onDay(feed2, now2.add(const Duration(days: 1))),
            changes: _load.changes,
            upcoming: _upcoming(feed2, now2),
            unread: _load.unread,
            announcements: _load.announcements,
            iliasError: _load.iliasError,
            fetchedAt: _load.fetchedAt);
      });
        // synthetic SignMeUp events may have just moved the today card
        _scheduleTodayScroll();
    }
  }

  static List<IcsOccurrence> _onDay(WebcalFeed? feed, DateTime day) {
    if (feed == null) return const [];
    final seen = <String>{};
    final dayStart = DateTime(day.year, day.month, day.day);
    final nextStart = dayStart.add(const Duration(days: 1));

    return feed.occurrences
        .where((o) =>
            // include a lecture that started yesterday but still runs past
            // midnight: it belongs to today's list and the running banner
            (o.start.isBefore(nextStart) && o.end.isAfter(dayStart)) &&
            // parallel groups share start+title: keep one row
            seen.add("${o.title}|${o.start.toIso8601String()}"))
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
            if (_signMeUpRows(vm, now).isNotEmpty)
              _signMeUpSection(context, _signMeUpRows(vm, now)),
            // my registrations + outcomes directly below the open
            // procedures: offers and results belong together
            if (_myRegsRows(vm, now).isNotEmpty)
              SignMeUpMineCard(rows: _myRegsRows(vm, now), now: now),
            _staleFooter(context),
            if (_loading)
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
                          : L10n.t("agenda.noEventsUntil", [
                              "${L10n.weekday(next.start.weekday)}, "
                                  "${next.start.day}."
                                  "${next.start.month}. · ${_hm(next.start)}"
                            ]),
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
                      if (occ[i].room.isNotEmpty)
                        Text(occ[i].room,
                            style: TextStyle(
                                fontSize: 12, color: scheme.outline)),
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
    final gap = next.start.difference(prev.end).inMinutes;
    if (gap <= 4 || gap > 90) return const [];
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
        bestTerm = e.terms
            .firstWhere((t) => t.startAt == at, orElse: () => e.terms.first);
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
  /// visible instead of rendering yesterday's feed as current.
  Widget _staleFooter(BuildContext context) {
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
    final stale = DateTime.now().difference(at) > const Duration(hours: 6);
    final label = stale
        ? L10n.t("agenda.staleData", ["${DateTime.now().difference(at).inHours} h"])
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
            else if (_load.iliasError != null)
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
                  trailing: const Icon(Icons.chevron_right, size: 18),
                  onTap: () => launchUrl(Uri.parse(a.url),
                      mode: LaunchMode.externalApplication),
                ),
          ],
        ),
      ),
    );
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
              child: TextButton(
                onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => const ExamsPage())),
                // default primary-green label on the red container failed
                // contrast; the container's own on-color is legible
                style: TextButton.styleFrom(
                    foregroundColor: scheme.onErrorContainer),
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
                    Text(
                        r.open
                            ? L10n.t("agenda.signmeupUntil",
                                [L10n.stamp(r.p.registrationEnd!)])
                            : L10n.t("agenda.signmeupFrom",
                                [L10n.stamp(r.p.registrationStart!)]),
                        style: TextStyle(
                            fontSize: 12,
                            color: scheme.onTertiaryContainer
                                .withValues(alpha: 0.75))),
                  ],
                ),
              ),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: () => launchUrl(
                    Uri.parse("https://plus.campus.kit.edu/"),
                    mode: LaunchMode.externalApplication),
                child: Text(L10n.t("agenda.signmeupTitle")),
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
