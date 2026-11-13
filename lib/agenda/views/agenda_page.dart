import 'dart:async';

import 'package:flutter/material.dart';
import 'package:kit_mobile/common_ui/max_width_body.dart';
import 'package:kit_mobile/constants/view_constants.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../l10n/l10n.dart';
import '../../exams/models/exam_list.dart';
import '../../exams/views/exams_page.dart';
import '../../agenda/logic/walk_hint.dart';
import '../../agenda/logic/cockpit.dart';
import '../../agenda/logic/next_up.dart';
import '../../agenda/logic/ninety_days.dart';
import '../../fristenbuch/fristenbuch.dart' show fristenbuchUpcoming;
import '../../agenda/logic/prep_bundle.dart';
import '../../agenda/logic/sop_alarm.dart';
import '../../grades/models/grade_book.dart';
import '../../handbook/handbook_data.dart';
import '../../timetable/logic/now_clock.dart';
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
import '../../navigation/logic/push_page.dart';
import 'chronicle_page.dart';
import 'room_change_line.dart';
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

/// Bumped when a notification tap lands on an ALREADY OPEN agenda
/// instance (deep-link dedupe suppresses the push): the mounted page
/// re-runs its full refresh, because the announced deltas would otherwise
/// stay invisible until the user happens to pull manually.
///
/// The push being suppressed, the deep link's ARRIVAL OPTIONS
/// (scrollToToday/highlightChanges, normally widget params of a fresh
/// page) can only travel out-of-band: [request] parks them on the
/// [scrollToToday]/[highlightChanges] fields and the mounted page reads
/// them when the tick fires. Each request REPLACES the pair, so a plain
/// resync never re-plays a stale scroll intent.
class AgendaResync {
  AgendaResync._();
  static final ValueNotifier<int> tick = ValueNotifier<int>(0);

  /// Intent of the most recent [request] (see class doc).
  static bool scrollToToday = false;
  static bool highlightChanges = false;

  static Future<void> request(
      {bool scrollToToday = false, bool highlightChanges = false}) async {
    AgendaResync.scrollToToday = scrollToToday;
    AgendaResync.highlightChanges = highlightChanges;
    tick.value++;
  }
}

class _AgendaLoad {
  final List<IcsOccurrence> today;
  final List<IcsOccurrence> tomorrow;
  final List<IcsChange> changes;
  // nearest occurrences AFTER tomorrow, so empty day cards can point at
  // when the silence ends instead of showing a dead "No events"
  final List<IcsOccurrence> upcoming;

  /// Raw merged-feed future pool for the deadline cockpit (the cockpit
  /// itself is rebuilt per build from live vm data; this is only the
  /// occurrence snapshot the agenda already parsed - no second parse)
  final List<IcsOccurrence> occurrences;
  final IliasUnread? unread;
  final List<IliasAnnouncement> announcements;
  final String? iliasError;
  final DateTime? fetchedAt;

  _AgendaLoad(
      {this.today = const [],
      this.tomorrow = const [],
      this.changes = const [],
      this.unread,
      this.occurrences = const [],
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

  /// last webcal failure reason (release build has no prints) - appended
  /// to the stale footer so the WHY is visible without a logcat
  String? _feedDiag;
  bool _loading = true;
  bool _iliasLoading = false;
  // R34.1: self-noted dates feeding the 90-day card, refreshed with the
  // page; plain records so this file never learns the Fristenbuch types
  List<FrbEntry> _frbRows = const [];
  // false until a cached ICS was found; drives the day-section spinner
  bool _feedCached = false;

  /// minute-heartbeat subscription state; armed while the route is visible
  bool _clockArmed = false;

  /// the today card doubles as the agenda's "now" anchor for deep links
  final GlobalKey _todaySectionKey = GlobalKey();

  /// day the visible day-sections were computed for; the minute tick
  /// detects crossing midnight so "Today" never keeps yesterday's lectures
  /// while the page sits open (the frame-level `now` rebuild alone only
  /// restyles rows, it never re-splits _load)
  DateTime _lastShownDay = DateTime.now();

  // R23: (ics cache bytes hashCode | local day) of the last full
  // _rerenderFromCache pass - see the gate there
  String _rerenderGateKey = "";

  /// armed by scrollToToday; consumed by [_scheduleTodayScroll] once the
  /// today card has rendered data-driven content
  bool _todayScrollPending = false;

  /// drives the CHANGED-band [HighlightPulse]: seeded from the widget's
  /// arrival option and re-set by a highlightChanges resync; [_pulseSeq]
  /// re-keys the pulse layer on every re-arm, because a TweenAnimationBuilder
  /// with an unchanged end value never re-animates in place
  bool _pulseArmed = false;
  int _pulseSeq = 0;

  @override
  void initState() {
    super.initState();
    _refresh();
    AgendaResync.tick.addListener(_onResync);
    // the minute heartbeat is armed in didChangeDependencies: it must
    // respect route visibility from the very first frame (C22)
    _pulseArmed = widget.highlightChanges;
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
    // re-exposes the route re-arms the heartbeat - the countdown is fresh
    // again immediately, never stale after the way back.
    if (TickerMode.valuesOf(context).enabled) {
      if (!_clockArmed) {
        _clockArmed = true;
        NowClock.arm();
        NowClock.minutesOfDay.addListener(_onMinute);
      }
    } else if (_clockArmed) {
      _clockArmed = false;
      NowClock.minutesOfDay.removeListener(_onMinute);
      NowClock.disarm();
    }
  }

  /// a deep-link tap landed while this instance stayed open: reload so the
  /// announced deltas actually render, and replay the arrival options the
  /// suppressed push could not deliver as widget params (see [AgendaResync])
  void _onResync() {
    if (!mounted) return;
    if (AgendaResync.scrollToToday) _todayScrollPending = true;
    if (AgendaResync.highlightChanges) {
      // re-key even when already armed: the second "timetable changed"
      // tap onto the same page must pulse visibly, not silently rebuild
      setState(() {
        _pulseArmed = true;
        _pulseSeq++;
      });
    }
    _refresh();
  }

  /// ONE whole-page setState per wall-minute (R12): replaces the 30 s
  /// ticker that rebuilt twice as often than needed; every build-time-now
  /// consumer (row recede/bold, hero, bands) keeps its exact behavior.
  /// On a day change the day-split itself must move: _load is built at
  /// refresh time and would otherwise pin yesterday into "Today" forever.
  void _onMinute() {
    if (!mounted) return;
    final today = DateTime.now();
    if (today.day != _lastShownDay.day ||
        today.month != _lastShownDay.month ||
        today.year != _lastShownDay.year) {
      _lastShownDay = today;
      unawaited(_rerenderFromCache(context.read<KITProvider>()));
      return; // the rerender setStates with the new split
    }
    setState(() {});
  }

  @override
  void dispose() {
    AgendaResync.tick.removeListener(_onResync);
    if (_clockArmed) {
      NowClock.minutesOfDay.removeListener(_onMinute);
      NowClock.disarm();
    }
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
    // R34.1: self-noted Fristenbuch dates for the 90-day card - read
    // off the UI path (local keychain-free DATA_* JSON, but still an
    // async prefs hop); the card shows the previous list until it lands.
    // Guarded: no frb rows is a merely poorer card, a page crash is not.
    unawaited(() async {
      try {
        final rows = await fristenbuchUpcoming();
        if (!mounted) return;
        setState(() => _frbRows = rows);
      } on Object catch (_) {
        // platform async-prefs absent (tests) or poisoned store: the
        // card simply omits self-noted rows this frame
      }
    }());
    // local data first, ALWAYS: the agenda must never sit on a spinner
    // because of network round-trips (a half-dead connection can hold the
    // SSO chain below for minutes). The live re-fetch runs after the
    // local paint - see [_refetch]

    final prefs = await SharedPreferences.getInstance();
    final feed = WebcalFeed.parse(prefs.getString(_icsCacheKey) ?? "");
    // feed cache is also the relevance source for the exam pages: exam
    // registration urgency must ignore catalogue exams of later semesters
    vm.campusManager.rememberEnrolledTitles(feed);
    var changes = IcsChange.decode(prefs.getString(_changesKey) ?? "");
    if (changes.isNotEmpty && freshChanges(changes, now).isEmpty) {
      // every stored delta concerns lectures that already took place:
      // silently consume them exactly like an invisible "Verstanden" tap
      // - a band rendering "(0 changes)" with no rows plus a permanently
      // lit home badge would lie that something is unseen
      unawaited(_dismissChanges());
      changes = const [];
    }
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
      _feedCached =
          (prefs.getString(_icsCacheKey) ?? "").contains("BEGIN:VCALENDAR");
      _load = _AgendaLoad(
          today: NextUp.onDay(feed, now),
          tomorrow:
              NextUp.onDay(feed, DateTime(now.year, now.month, now.day + 1)),
          changes: changes,
          upcoming: _upcoming(feed, now),
          occurrences: feed?.occurrences ?? const [],
          unread: iliasCached?.$1 ?? _load.unread,
          announcements: iliasCached != null && iliasCached.$2.isNotEmpty
              ? iliasCached.$2
              : _load.announcements,
          iliasError: _load.iliasError,
          fetchedAt: DateTime.tryParse(prefs.getString(_fetchedAtKey) ?? ""));
      _feedDiag = prefs.getString("DATA_webcalDiag");
      _loading = false;
    });
    // first data-driven rebuild: this, not the data-free first frame, is
    // where the deep-link scroll to the today card actually belongs
    _scheduleTodayScroll();

    IliasUnread? unread;
    var announcements = const <IliasAnnouncement>[];
    String? iliasError;
    setState(() => _iliasLoading = true);
    final gen0 = vm.signMeUpGen;
    final iliasEpoch = vm.campusManager.teardownEpoch;
    try {
      // don't race the auto-login SSO, but bound the wait: a slow SSO
      // chain may only stall the ILIAS card's first render for so long -
      // the TimeoutException lands in the existing catch below, which
      // keeps the cached card visible or shows the unreachable line
      await vm.iliasAuth.timeout(const Duration(seconds: 30));
      unread = await vm.iliasManager.fetchUnread();
      announcements = await vm.iliasManager.fetchAnnouncements();
      if (vm.campusManager.teardownEpoch != iliasEpoch) {
        // logout happened during the SSO wait: A's card snapshot and
        // announcements must NOT land in the prefs the logout sweep just
        // purged, and the watcher must not nag about A's courses to a
        // device now showing the login form
        iliasError = L10n.t("agenda.iliasUnreachable");
        unread = null;
        announcements = const [];
      } else {
        final prefs3 = await SharedPreferences.getInstance();
        await prefs3.setString(
            _iliasCacheKey, encodeIliasCard(unread, announcements));
        if (vm.campusManager.teardownEpoch != iliasEpoch) {
          // R22: the epoch above was checked BEFORE the two prefs awaits -
          // a logout landing inside this write hop re-persisted A's unread
          // counts and announcement titles into the store the sweep had
          // just purged (and the watcher would nag about A's courses).
          // Undo the write and fall into the unreachable handling.
          await prefs3.remove(_iliasCacheKey);
          iliasError = L10n.t("agenda.iliasUnreachable");
          unread = null;
          announcements = const [];
        } else {
          // fire-and-forget: the watcher swallows every failure internally
          // and must never delay or poison the agenda rebuild behind it
          IliasWatcher.diffAndNotify(announcements);
          // R24 wave B: the same proven board feeds the ILIAS deadline
          // synth (due rows land in the merged cache; contained, never
          // poisons the agenda)
          unawaited(() async {
            // the news board ships no course titles - join them from the
            // enrolment list so dues read "Due: <course> (<announcement>)"
            // instead of duplicating the announcement; a failed course
            // page only costs the label, never the deadline itself
            Map<int, String> names = const {};
            try {
              names = {
                for (final c in await vm.iliasManager.fetchCourses())
                  c.refId: c.title
              };
            } catch (_) {}
            await vm.campusManager
                .publishDueBlock(announcements, courses: names);
          }().catchError((Object _) {}));
        }
      }
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
          // R25 carry: the cockpit/prep consumers read the occurrence
          // pool; dropping it here made dues vanish the moment the
          // ILIAS fetch settled
          occurrences: _load.occurrences,
          unread: unread ?? _load.unread,
          announcements:
              announcements.isNotEmpty ? announcements : _load.announcements,
          iliasError: iliasError,
          fetchedAt: _load.fetchedAt);
    });

    // the injectors land silently behind the visible content
    unawaited(_refetch(vm));
    unawaited(_followUpInjectors(vm, gen0));
  }

  /// Pull honors the stale footer's own advice: re-fetch the feed, the
  /// exam list and the SignMeUp registration state - fire-and-forget AFTER
  /// the local paint so a dead or half-dead network (30 s socket caps
  /// behind an SSO chain) can never gate first paint or the spinner;
  /// results re-render from the caches they write. SignMeUp belongs here
  /// too: without it the "not current" card promised currency on the next
  /// pull while no pull ever retried that fetch.
  Future<void> _refetch(KITProvider vm) async {
    try {
      await vm.campusManager.fetchTimetable();
      await vm.campusManager.fetchExams();
      await vm.fetchSignMeUp();
    } on Object catch (_) {}
    if (mounted) await _rerenderFromCache(vm);
  }

  /// Bounded tail for the synthetic-event injectors: SignMeUp groups and
  /// exam sittings write into the ICS cache only after the agenda has
  /// already rendered. Deliberately NOT awaited by [_refreshOnce] — the
  /// RefreshIndicator must hide once the visible content is up, not after
  /// two further 45 s waits; the re-render lands as soon as they do.
  Future<void> _followUpInjectors(KITProvider vm, int smuGenStart) async {
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
    } else if (vm.signMeUpGen != smuGenStart) {
      // the injector COMPLETED during the ILIAS phase above - the future
      // getter is already null again; the generation moved, so its rows
      // ARE in the cache right now and the re-render must not be lost
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
    final now2 = DateTime.now();
    // R23: one pull-refresh can call this up to 4x back-to-back (after
    // _refetch + SignMeUp tail x2 + exams tail) even when neither
    // injector actually touched the ICS cache - each pass re-read and
    // re-parsed the whole feed (unfold + RRULE expansion to the 56 d
    // horizon) plus every NextUp scan. Gate on (cache bytes, local day):
    // identical cache on the same day has nothing new to render, while
    // the midnight day-cross call always slips through (day changed).
    final icsRaw = prefs2.getString(_icsCacheKey) ?? "";
    final gateKey =
        "${icsRaw.hashCode}|${now2.year}-${now2.month}-${now2.day}";
    if (gateKey == _rerenderGateKey) return;
    _rerenderGateKey = gateKey;
    final feed2 = WebcalFeed.parse(icsRaw);
    vm.campusManager.rememberEnrolledTitles(feed2);
    if (!mounted) return;
    var cachedChanges = _load.changes;
    // R22: the same consume rule _refreshOnce applies - the midnight
    // day-cross path rerenders from memory only, so fully-stale deltas
    // were never consumed there: DATA_webcalChanges survived, the background
    // poll kept re-arming timetableChanged, and the home badge stayed lit
    // for phantom changes that rendered nowhere
    if (cachedChanges.isNotEmpty && freshChanges(cachedChanges, now2).isEmpty) {
      unawaited(_dismissChanges());
      cachedChanges = const [];
    }
    setState(() {
      _feedCached = _feedCached ||
          (prefs2.getString(_icsCacheKey) ?? "").contains("BEGIN:VCALENDAR");
      _feedDiag = prefs2.getString("DATA_webcalDiag");
      _load = _AgendaLoad(
          today: NextUp.onDay(feed2, now2),
          tomorrow: NextUp.onDay(
              feed2, DateTime(now2.year, now2.month, now2.day + 1)),
          changes: cachedChanges,
          upcoming: _upcoming(feed2, now2),
          // the FRESH re-parse is exactly where re-injected due/exam
          // synth events surface to the cockpit + prep sheet
          occurrences: feed2?.occurrences ?? const [],
          unread: _load.unread,
          announcements: _load.announcements,
          iliasError: _load.iliasError,
          // re-read, do NOT carry: after a healing _refetch the stamp and
          // the diag flipped together in prefs - carrying the old stamp
          // kept the stale footer lit (with its now-fixed diag) forever
          fetchedAt: DateTime.tryParse(prefs2.getString(_fetchedAtKey) ?? "") ??
              _load.fetchedAt);
    });
    // synthetic events may have just moved the today card
    _scheduleTodayScroll();
  }

  /// Next occurrences after the end of tomorrow, soonest first (≤5).
  static List<IcsOccurrence> _upcoming(WebcalFeed? feed, DateTime now) {
    if (feed == null) return const [];
    final horizon = DateTime(now.year, now.month, now.day + 2);
    final out = feed.occurrences.where((o) => o.start.isAfter(horizon)).toList()
      ..sort((a, b) => a.start.compareTo(b.start));
    return out.take(5).toList();
  }

  static String _hm(DateTime d) => "${d.hour.toString().padLeft(2, "0")}:"
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
        occurrences: _load.occurrences,
        unread: _load.unread,
        announcements: _load.announcements,
        iliasError: _load.iliasError,
        fetchedAt: _load.fetchedAt));
  }

  @override
  Widget build(BuildContext context) {
    final vm = Provider.of<KITProvider>(context);
    final now = DateTime.now();
    final dayStart = DateTime(now.year, now.month, now.day);
    // ONE filtered list per build: header count, rows and the >6 hint all
    // read the same snapshot, and an all-stale change set must render NO
    // band at all (the old gate on raw changes produced an empty "(0)"
    // card while the home badge stayed lit for content nowhere visible)
    final bandChanges = freshChanges(_load.changes, now);
    final needAction = vm.campusManager.exams
        .where((e) =>
            e.needsAction(now) &&
            vm.campusManager.isTakingThisSemester(e) != false)
        .toList()
      ..sort((a, b) => (a.windowEnd ?? DateTime(2100))
          .compareTo(b.windowEnd ?? DateTime(2100)));

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
      // same 840dp reading column as settings/exams: on tablets the
      // agenda cards spanned edge-to-edge (Fire HD8: 929dp wide cards)
      body: MaxWidthBody(
        child: RefreshIndicator(
          onRefresh: _refresh,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, kDockClearance),
            children: [
              if (bandChanges.isNotEmpty)
                HighlightPulse(
                  key: ValueKey("pulse-$_pulseSeq"),
                  armed: _pulseArmed,
                  color: Theme.of(context).colorScheme.tertiary,
                  child: _changedBand(context, bandChanges),
                ),
              _nextUpBanner(context, now),
              _daySection(L10n.t("agenda.today"), _load.today, now,
                  day: dayStart, key: _todaySectionKey),
              _daySection(L10n.t("agenda.tomorrow"), _load.tomorrow, now,
                  day: DateTime(now.year, now.month, now.day + 1)),
              _nextExamCard(context, vm, now),
              _cockpitCard(context, vm, now),
              // R34.5: one card under the cockpit answers "what am I
              // walking into this semester" over the 90-day horizon
              _ninetyDaysCard(context, vm, now),
              _iliasSection(context),
              if (needAction.isNotEmpty)
                _examsSection(context, needAction)
              else if (vm.campusManager.ready &&
                  !vm.campusManager.examsLoaded &&
                  !vm.campusManager.examsSurfaceBroken)
                _pendingCard(context, L10n.t("agenda.examsLoading")),
              if (smuRows.isNotEmpty)
                _signMeUpSection(context, smuRows)
              else if (!vm.signMeUpManager.loadedMine &&
                  vm.signMeUpManager.procedures.isNotEmpty)
                // procedures are anonymous data; without a PROVEN "mine" fetch
                // every open one would scream "act now" at a student who long
                // registered - say it is not current instead of lying
                _pendingCard(context, L10n.t("agenda.signMeUpNotCurrent", [])),
              // my registrations + outcomes directly below the open
              // procedures: offers and results belong together
              if (myRegs.isNotEmpty) SignMeUpMineCard(rows: myRegs, now: now),
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
          child:
              CircularProgressIndicator(strokeWidth: 2, color: scheme.primary),
        ),
        const SizedBox(width: 10),
        // Expanded: the longest pending label ("Registration status
        // unavailable right now – current on next open") overflows a
        // Pixel-3-class width beside the fixed spinner; let it wrap
        // instead (soft maxLines on purpose — the notice should stay
        // fully readable)
        Expanded(
          child:
              Text(text, style: TextStyle(color: scheme.outline, fontSize: 13)),
        ),
      ]),
    );
  }

  Widget _pendingCard(BuildContext context, String text) {
    return Card(
      child: Padding(
          padding: const EdgeInsets.all(12), child: _pendingRow(context, text)),
    );
  }

  /// Stored deltas are capped newest-50 sorted oldest-first; the band may
  /// only show ones that still concern upcoming lectures, freshest first.
  static List<IcsChange> freshChanges(List<IcsChange> changes, DateTime now) {
    final today = DateTime(now.year, now.month, now.day);
    return changes
        .where((c) => !c.when.isBefore(today))
        .toList()
        .reversed
        .toList();
  }

  Widget _changedBand(BuildContext context, List<IcsChange> fresh) {
    final scheme = Theme.of(context).colorScheme;
    // the chronicle link only exists where it promises MORE than the band
    // already shows: freshChanges partitions the store on `when >= today`,
    // so store-minus-fresh is exactly "entries older than the band's set";
    // an all-fresh store has nothing older to open -> no link, no dead end
    final hasStoredOlder = _load.changes.length > fresh.length;
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
              // Expanded + single line: "Stundenplan geändert (50)" in
              // German overflowed narrow phones (same rule as _dayRow)
              Expanded(
                child: Text(L10n.t("agenda.timetableChangedN", [fresh.length]),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: scheme.onTertiaryContainer)),
              ),
            ]),
            const SizedBox(height: 6),
            // stored deltas are sorted oldest-first with a 50-entry cap:
            // show the NEWEST that still concern upcoming lectures, or the
            // freshest KIT edit hides behind months of stale ones
            for (final c in fresh.take(6))
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 1),
                child: Text(c.describe(),
                    style: TextStyle(
                        fontSize: 13, color: scheme.onTertiaryContainer)),
              ),
            if (fresh.length > 6)
              Text(L10n.t("agenda.moreChanges", [fresh.length - 6]),
                  style: TextStyle(
                      fontSize: 12,
                      fontStyle: FontStyle.italic,
                      color: scheme.onTertiaryContainer)),
            // R32.7: the band only shows deltas with `when >= today` (see
            // freshChanges — that filter stays); the chronicle shows the
            // WHOLE store, cap and all, and admits its own coverage there.
            // The link itself only renders when the store actually holds
            // entries older than the band's set (hasStoredOlder).
            // Wrap (not Row+Spacer): at Pixel-3-minus widths both German
            // labels share one line only when they fit — the 240 dp band
            // regression test stacks them instead of overflowing
            Wrap(
              alignment: WrapAlignment.end,
              spacing: 4,
              children: [
                if (hasStoredOlder)
                  TextButton(
                    onPressed: () => pushPageOnce<void>(Navigator.of(context),
                        routeName: ChroniclePage.routeName,
                        page: (_) => ChroniclePage(changes: _load.changes)),
                    child: Text(L10n.t("timetable.olderChanges")),
                  ),
                Semantics(
                  button: true,
                  child: TextButton(
                      onPressed: _dismissChanges,
                      child: Text(L10n.t("agenda.dismiss"))),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _daySection(String label, List<IcsOccurrence> occ, DateTime now,
      {Key? key, DateTime? day}) {
    final scheme = Theme.of(context).colorScheme;
    // change emphasis (R12): while the CHANGED band is un-dismissed, the
    // day rows a still-unseen change names get an emphasis marker. The
    // day's deltas go to [_dayRow] WHOLE (kind + title included): the
    // block-only IcsChangeIndex maps serve the weekly grid, but two
    // parallel lectures share one start block, and a room-delta misread
    // onto the neighbouring row sends the student to the wrong room —
    // the row match additionally requires the delta's title to name the
    // lecture (see [_dayRow])
    final d = day;
    final dayChanges = <IcsChange>[];
    if (d != null) {
      for (final c in _load.changes) {
        if (c.when.year == d.year &&
            c.when.month == d.month &&
            c.when.day == d.day) {
          dayChanges.add(c);
        }
      }
    }
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
                // tomorrow BEATS `upcoming`: that list only holds
                // lectures AFTER tomorrow, so on a free day whose next
                // day has lectures it named a later date than the one
                // where the silence actually ends
                final next = label == L10n.t("agenda.today") &&
                        _load.tomorrow.isNotEmpty
                    ? _load.tomorrow.first
                    : (_load.upcoming.isNotEmpty ? _load.upcoming.first : null);
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Text(
                      next == null
                          ? L10n.t("agenda.noEvents")
                          : L10n.t(
                              "agenda.noEventsUntil", [L10n.stamp(next.start)]),
                      style: TextStyle(color: scheme.outline, fontSize: 13)),
                );
              }),
            for (var i = 0; i < occ.length; i++) ...[
              if (i > 0) ..._walkHint(context, occ[i - 1], occ[i]),
              _dayRow(occ[i], now, dayChanges),
            ],
          ],
        ),
      ),
    );
  }

  /// One lecture row of a day section. Renders exactly like the pre-R12
  /// inline row unless a still-un-dismissed change NAMES this lecture
  /// (start block AND title — [IcsChange.titleKey]): then a tertiary dot
  /// marks it (the eye finds the row the CHANGED band describes without
  /// re-reading it; every kind the band shows — added, removed, moved,
  /// changed — arms it), and a room change additionally states the delta
  /// on its own line.
  Widget _dayRow(IcsOccurrence occ, DateTime now, List<IcsChange> dayChanges) {
    final scheme = Theme.of(context).colorScheme;
    final blockKey = occ.start.hour * 60 + occ.start.minute;
    final occKey = IcsChange.titleKey(occ.title);
    // Title gate on top of the block match: without it a room change at
    // 14:00 decorated an UNRELATED lecture also starting 14:00 (dot plus
    // "alt → neu" line), i.e. the UI actively walked students into the
    // wrong building. Latest title-matching `changed` delta wins, so the
    // row ever renders one room-diff line (mirrors blockKeys' shape).
    IcsChange? roomDelta;
    var touched = false;
    for (final c in dayChanges) {
      if (c.when.hour * 60 + c.when.minute != blockKey) continue;
      if (IcsChange.titleKey(c.title) != occKey) continue;
      touched = true;
      if (c.kind == IcsChangeKind.changed &&
          c.oldRoom != c.room &&
          // R22: successive edits of the SAME session share one `when`
          // (the occurrence start), so isAfter can never pick the newer
          // A→B vs B→C delta - the stale intermediate room was walked to.
          // Ties resolve in stored (oldest-first) order: last one wins
          (roomDelta == null || !c.when.isBefore(roomDelta.when))) {
        roomDelta = c;
      }
    }
    // a deadline is a POINT and a guessed end (+90 fallback) is no fact:
    // render start-only ("bis 18:00" for dues, "ab 08:00" for guessed
    // spans) instead of the invented "18:00–19:30" block
    final duePoint = occ.title.startsWith("Due: ");
    final String timeText;
    if (occ.endGuessed) {
      timeText = duePoint
          ? L10n.t("agenda.rowDueBy", [_hm(occ.start)])
          : L10n.t("agenda.rowFrom", [_hm(occ.start)]);
    } else {
      timeText = "${_hm(occ.start)}–${_hm(occ.end)}";
    }
    Widget title = Text(
        "$timeText  ${occ.displayTitle}",
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
            fontSize: 13,
            fontWeight:
                occ.start.isBefore(now) && occ.end.isAfter(now) && !occ.endGuessed
                    ? FontWeight.bold
                    : FontWeight.normal,
            fontFeatures: const [FontFeature.tabularFigures()]));
    if (touched) {
      title = Row(children: [
        SizedBox(
          width: 12,
          child: Container(
            width: 8,
            height: 8,
            decoration:
                BoxDecoration(color: scheme.tertiary, shape: BoxShape.circle),
          ),
        ),
        Expanded(child: title),
      ]);
    }
    // dangling-arrow guard: a lecture that merely GAINS its first room
    // carries an empty oldRoom, and "{old} → {new}" would advertise a
    // move from nowhere — the dot alone marks it (same case
    // IcsChange.describe() guards for the band)
    final showRoomDelta =
        roomDelta != null && (roomDelta.oldRoom?.isNotEmpty ?? false);
    return Opacity(
      // finished lectures recede; the live one is the anchor. A guessed
      // end must not keep a passed deadline full-brightness for 90 min:
      // point rows dim as soon as their time is over
      opacity: (occ.endGuessed ? occ.start.isBefore(now) : occ.end.isBefore(now))
          ? 0.38
          : 1.0,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            title,
            if (showRoomDelta)
              Text(
                  L10n.t("agenda.roomChangedTo",
                      [roomDelta.oldRoom!, roomDelta.room]),
                  style: TextStyle(fontSize: 12, color: scheme.tertiary)),
            // #17: a roomless personal-ICS event still needs its
            // source chip row, so the line renders for it too
            if (occ.room.isNotEmpty || occ.fromPersonalIcs)
              AgendaRoomLine(room: occ.room, ownCalendar: occ.fromPersonalIcs),
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
    return _roomCache.putIfAbsent(room, () => resolveRoomPlace(places, room));
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
  /// countdown refreshed by the minute heartbeat. Hidden when nothing is
  /// within 12 h (weekends, evenings) so it never nags. The computation
  /// and the card live in next_up.dart - the home card renders the very
  /// same hero (R12); the agenda keeps its exact look (no onTap).
  Widget _nextUpBanner(BuildContext context, DateTime now) {
    final up = NextUp.compute([..._load.today, ..._load.tomorrow], now);
    if (up == null) return const SizedBox.shrink();
    // R27: tapping the hero opens the prep bundle for exactly this lecture
    final card = NextUpCard(up: up, onTap: () => _openPrepSheet(up));
    // R32.6: a stored room swap that matches THIS hero occurrence exactly
    // (and a feed the 30 h trust rule still vouches for) strikes the old
    // room through next to the new one; anything else leaves the hero
    // byte-identical (see heroRoomDelta / RoomChangeLine)
    final delta = heroRoomDelta(
        occ: up.occ,
        changes: _load.changes,
        feedFresh: _load.fetchedAt != null &&
            now.difference(_load.fetchedAt!) < heroRoomFeedFreshness);
    if (delta == null) return card;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [card, RoomChangeLine(delta: delta)],
    );
  }

  /// Wave E (R27): bottom sheet with the lecture's certified ILIAS bind,
  /// its open deadlines and the exam registration state.
  void _openPrepSheet(NextUp up) {
    final vm = context.read<KITProvider>();
    final bundle = prepBundleFor(up.occ,
        iliasUrl: vm.campusManager.manualIliasUrlFor(up.occ.displayTitle),
        occurrences: _load.occurrences,
        exams: vm.campusManager.exams,
        now: DateTime.now());
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) {
        final scheme = Theme.of(context).colorScheme;
        final e = bundle.exam;
        final now = DateTime.now();
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(up.occ.displayTitle,
                      style: const TextStyle(
                          fontSize: 16, fontWeight: FontWeight.w700)),
                  if (up.occ.room.isNotEmpty)
                    Text(up.occ.room,
                        style: TextStyle(
                            fontSize: 12, color: scheme.onSurfaceVariant)),
                  const SizedBox(height: 12),
                  if (bundle.isEmpty)
                    Text(L10n.t("agenda.prepEmpty"),
                        style: TextStyle(
                            fontSize: 13, color: scheme.onSurfaceVariant)),
                  if (bundle.iliasUrl != null)
                    TextButton.icon(
                      icon: const Icon(Icons.school),
                      label: Text(L10n.t("agenda.prepIlias")),
                      onPressed: () =>
                          launchUrl(Uri.parse(bundle.iliasUrl!),
                              mode: LaunchMode.externalApplication),
                    ),
                  for (final d in bundle.dues.take(6))
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 3),
                      child: Row(
                        children: [
                          Icon(Icons.assignment,
                              size: 16, color: scheme.onSurfaceVariant),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              "${L10n.t("agenda.prepDue")} · ${d.what}",
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 13),
                            ),
                          ),
                          Text(L10n.dayOffset(d.when, now),
                              style: TextStyle(
                                  fontSize: 12, color: scheme.outline)),
                        ],
                      ),
                    ),
                  if (e != null)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 3),
                      child: Row(
                        children: [
                          Icon(Icons.event,
                              size: 16,
                              color: e.registered
                                  ? scheme.primary
                                  : scheme.error),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              e.registered
                                  ? "${L10n.t("agenda.prepExam")} · ${L10n.t("agenda.prepExamRegistered")}"
                                  : e.windowIsOpen(now) && e.windowEnd != null
                                      ? "${L10n.t("agenda.prepExam")} · ${L10n.t("agenda.prepExamOpen", [L10n.stamp(e.windowEnd!)])}"
                                      : L10n.t("agenda.prepExam"),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 13),
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
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
                        if ((bestTerm?.room.isNotEmpty ?? false)) bestTerm!.room
                      ].join(" · "),
                      style: TextStyle(fontSize: 12, color: scheme.outline)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Wave C (R25): one merged timeline of every date the student can miss
  /// (ILIAS dues, exam sittings, exam + SignMeUp registration windows).
  /// Pure selection lives in [cockpitPlan]; alarms for these dates are
  /// already armed by the existing families (500-600 / 700-799 id bands,
  /// T−30 lecture reminders over the merged feed) - this card only shows
  /// the view, so it never schedules anything.
  Widget _cockpitCard(BuildContext context, KITProvider vm, DateTime now) {
    final items = cockpitPlan(
        occurrences: _load.occurrences,
        exams: vm.campusManager.exams,
        procedures: vm.signMeUpManager.procedures,
        registeredProcedureIds: vm.signMeUpManager.registeredProcedureIds,
        smuProven: vm.signMeUpManager.loadedMine,
        now: now);
    final scheme = Theme.of(context).colorScheme;
    String label(CockpitKind k) => switch (k) {
          CockpitKind.due => L10n.t("agenda.cockpitDue"),
          CockpitKind.frb => L10n.t("agenda.cockpitFrist"),
          CockpitKind.examSignupOpen => L10n.t("agenda.cockpitExamSignupOpen"),
          CockpitKind.examSignupOpens =>
            L10n.t("agenda.cockpitExamSignupOpens"),
          CockpitKind.examDereg => L10n.t("agenda.cockpitDereg"),
          CockpitKind.examSitting => L10n.t("agenda.cockpitExamSitting"),
          CockpitKind.smuOpen => L10n.t("agenda.cockpitSmuOpen"),
          CockpitKind.smuOpens => L10n.t("agenda.cockpitSmuOpens"),
        };
    IconData icon(CockpitKind k) => switch (k) {
          CockpitKind.due => Icons.assignment,
          CockpitKind.frb => Icons.flag_outlined,
          CockpitKind.examSignupOpen ||
          CockpitKind.examSignupOpens =>
            Icons.how_to_reg,
          CockpitKind.examDereg => Icons.person_off,
          CockpitKind.examSitting => Icons.event,
          CockpitKind.smuOpen || CockpitKind.smuOpens => Icons.school,
        };
    // R33.5: the SOP early-warning row rides this card. The handbook is
    // the memoized asset future (same build-time idiom as the grades
    // page's Ampel card); while it has not resolved the card simply shows
    // its date rows, and a missing/corrupt asset keeps the row silent -
    // the catalogue is an enhancement, never a claim.
    return FutureBuilder<Handbook?>(
      future: Handbook.load(),
      builder: (context, snap) {
        final handbook = snap.data;
        final cm = vm.campusManager;
        final alarm = handbook == null
            ? null
            : sopEarlyWarning(
                modules: handbook.modules,
                ledger: GradeBook.fromRows(cm.moduleRows,
                        ectsAcquiredTotal: cm.student.ectsAcquired,
                        avgMark: cm.student.avgMark)
                    .modules,
                rows: cm.moduleRows,
                takingKeys: cm.enrolledLectureTitles,
                now: now);
        // clean zero state renders nothing: attempts known and nobody
        // exposed is silence, not a "all fine" line (doctrine of the
        // card's empty timeline); attempts UNKNOWN with a computable CP
        // floor is the one honest single-line warning
        final showAlarm = alarm != null &&
            (alarm.exposedModules.isNotEmpty ||
                (!alarm.attemptsKnown && alarm.cpFloor > 0));
        if (items.isEmpty && !showAlarm) return const SizedBox.shrink();
        return Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Icon(Icons.timeline, color: scheme.primary),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(L10n.t("agenda.cockpitTitle"),
                        style: TextStyle(
                            fontWeight: FontWeight.bold,
                            color: scheme.primary)),
                  ),
                ]),
                if (showAlarm)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 3),
                    child: Row(
                      children: [
                        Icon(Icons.warning_amber_rounded,
                            size: 16, color: scheme.error),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(L10n.t("agenda.sopWarnTitle"),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.w600)),
                              Text(
                                [
                                  if (alarm.cpFloor > 0)
                                    L10n.t("agenda.sopWarnCp", [alarm.cpFloor]),
                                  if (alarm.exposedModules.isNotEmpty)
                                    L10n.t("agenda.sopWarnExposed",
                                        [alarm.exposedModules.join(", ")]),
                                ].join(" · "),
                                style: TextStyle(
                                    fontSize: 12, color: scheme.error),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                for (final it in items)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 3),
                    child: Row(
                      children: [
                        Icon(icon(it.kind),
                            size: 16,
                            color: it.urgent(now)
                                ? scheme.error
                                : scheme.onSurfaceVariant),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(it.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.w600)),
                              Text(
                                "${label(it.kind)} · ${L10n.dayOffset(it.when, now)} · ${L10n.stamp(it.when)}",
                                style: TextStyle(
                                    fontSize: 12,
                                    color: it.urgent(now)
                                        ? scheme.error
                                        : scheme.outline),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// R34.5: "Nächste 90 Tage" — the semester-overview card under the
  /// cockpit. Where the cockpit answers "what acts on me in the next 4
  /// weeks", this card answers "what am I walking into this term": dues,
  /// sittings, registration windows, self-noted Fristenbuch dates and
  /// the official SignMeUp term bounds in ONE date-sorted list. Rows
  /// carry their provenance label; term rows state their source
  /// citation "(SignMeUp terms)" per row (R34.4), Fristenbuch rows say
  /// "self-noted" so a manual note never reads as scraped truth.
  /// Collapsed to 6 rows + the shared "+N mehr" caption. No tap targets:
  /// the cockpit's rows have none either, and a dead chevron is worse
  /// than no chevron (F12 rule).
  Widget _ninetyDaysCard(BuildContext context, KITProvider vm, DateTime now) {
    final merged = ninetyDays(
        now: now,
        occurrences: _load.occurrences,
        exams: vm.campusManager.exams,
        // R34.1 integration point (parent-wired): plain (title, date)
        // records from DATA_fristenbuch, refreshed with _refreshOnce
        fristenbuch: _frbRows,
        terms: vm.signMeUpManager.terms);
    final rows = nextNinetyDays(merged, now);
    if (rows.isEmpty) return const SizedBox.shrink();
    final hidden = ninetyDaysHidden(merged, now);
    final scheme = Theme.of(context).colorScheme;
    String label(NinetyKind k) => switch (k) {
          NinetyKind.due => L10n.t("agenda.cockpitDue"),
          NinetyKind.examWindowClose =>
            L10n.t("agenda.cockpitExamSignupOpen"),
          NinetyKind.examWindowOpens =>
            L10n.t("agenda.cockpitExamSignupOpens"),
          NinetyKind.examSitting => L10n.t("agenda.cockpitExamSitting"),
          NinetyKind.frb => L10n.t("agenda.ninetyFrb"),
          NinetyKind.termStart => L10n.t("agenda.ninetyTermStart"),
          NinetyKind.termEnd => L10n.t("agenda.ninetyTermEnd"),
        };
    IconData icon(NinetyKind k) => switch (k) {
          NinetyKind.due => Icons.assignment,
          NinetyKind.examWindowClose || NinetyKind.examWindowOpens =>
            Icons.how_to_reg,
          NinetyKind.examSitting => Icons.event,
          NinetyKind.frb => Icons.edit_note,
          NinetyKind.termStart || NinetyKind.termEnd => Icons.school,
        };
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Icon(Icons.calendar_month, color: scheme.primary),
              const SizedBox(width: 6),
              // Expanded like every card header: German titles overflow
              // narrow phones beside a fixed icon
              Expanded(
                child: Text(L10n.t("agenda.ninetyTitle"),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontWeight: FontWeight.bold, color: scheme.primary)),
              ),
            ]),
            for (final r in rows)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(
                  children: [
                    Icon(icon(r.kind),
                        size: 16, color: scheme.onSurfaceVariant),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(r.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  fontSize: 13, fontWeight: FontWeight.w600)),
                          Text(
                            [
                              label(r.kind),
                              if (r.kind == NinetyKind.termStart ||
                                  r.kind == NinetyKind.termEnd)
                                L10n.t("agenda.ninetySrcTerms"),
                              L10n.dayOffset(r.when, now),
                              // stamp() already drops the " 00:00" tail
                              // of the all-day rows (term bounds, notes)
                              L10n.stamp(r.when),
                            ].join(" · "),
                            style: TextStyle(
                                fontSize: 12, color: scheme.outline),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            if (hidden > 0)
              // truncation without a count reads as "this is everything"
              // — same "+N mehr" caption rule as the cockpit cards
              Text(L10n.t("agenda.signmeupMineMore", [hidden]),
                  style: TextStyle(
                      fontSize: 12,
                      fontStyle: FontStyle.italic,
                      color: scheme.outline)),
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
        ? L10n.t("agenda.staleData", ["${age.inHours} h"]) +
            (_feedDiag == null ? "" : " (${_feedDiag!})")
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
                _badge(L10n.t("agenda.nNew", [_load.unread!.notifications]),
                    scheme),
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
              // Expanded like every other card header: the German label
              // overflowed narrow phones beside the icon
              Expanded(
                child: Text(L10n.t("agenda.examsOpen"),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: scheme.onErrorContainer)),
              ),
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
            if (exams.length > 3)
              // silent truncation read as "these are all the deadlines";
              // same "+N mehr" caption rule as SignMeUpMineCard
              Text(L10n.t("agenda.signmeupMineMore", [exams.length - 3]),
                  style: TextStyle(
                      fontSize: 12,
                      fontStyle: FontStyle.italic,
                      color: scheme.onErrorContainer)),
            Align(
              alignment: Alignment.centerRight,
              // Filled CTA on the danger card: bare text hid the one
              // action that still prevents a failed attempt
              child: FilledButton(
                onPressed: () => pushPageOnce(Navigator.of(context),
                    routeName: ExamsPage.routeName,
                    page: (_) => const ExamsPage()),
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
    // without a PROVEN "mine" fetch this process cannot tell "not yet
    // registered" from "fetch failed" - stay silent, never shout
    if (!vm.signMeUpManager.loadedMine) return const [];
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
              // Expanded like every other card header
              Expanded(
                child: Text(L10n.t("agenda.signmeupTitle"),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: scheme.onTertiaryContainer)),
              ),
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
                            ? L10n.t("agenda.signmeupUntil",
                                [L10n.deadline(r.p.registrationEnd!)])
                            : L10n.t("agenda.signmeupFrom",
                                [L10n.deadline(r.p.registrationStart!)]),
                        style: TextStyle(
                            fontSize: 12,
                            color: scheme.onTertiaryContainer
                                .withValues(alpha: 0.75))),
                  ],
                ),
              ),
            if (rows.length > 3)
              // truncation without a count read as "these are all the
              // procedures" — same "+N mehr" rule as SignMeUpMineCard
              Text(L10n.t("agenda.signmeupMineMore", [rows.length - 3]),
                  style: TextStyle(
                      fontSize: 12,
                      fontStyle: FontStyle.italic,
                      color:
                          scheme.onTertiaryContainer.withValues(alpha: 0.75))),
            Align(
              alignment: Alignment.centerRight,
              // tonal CTA with action wording: the old text button merely
              // repeated the card title and read as a label, not a launch
              child: FilledButton.tonal(
                onPressed: () =>
                    _launchExternal("https://plus.campus.kit.edu/signmeup"),
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
        line =
            Text(shown, style: TextStyle(fontSize: 12, color: scheme.outline));
      }
    } else {
      line = GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => Navigator.of(context).push(MaterialPageRoute(
            builder: (context) =>
                PlaceSearchPage(initialQuery: shown, fromRoom: shown))),
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
