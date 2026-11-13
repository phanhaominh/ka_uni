import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../agenda/logic/walk_hint.dart';
import '../../common_ui/max_width_body.dart';
import '../../constants/view_constants.dart';
import '../../geo/logic/maps_url.dart';
import '../../geo/models/kit_place.dart';
import '../../l10n/l10n.dart';
import '../../state_management/campus/campus_manager.dart';
import '../../toasts/models/toasts_provider.dart';
import '../../state_management/kit_provider.dart';
import '../logic/exam_clash.dart';
import '../logic/exam_countdown.dart';
import '../models/exam_list.dart';

/// Exam registration overview: Anmeldung windows, status, red flag for
/// "window open but not registered" (missing it = failed attempt).
class ExamsPage extends StatelessWidget {
  const ExamsPage({super.key});

  static const routeName = "/exams";

  @override
  Widget build(BuildContext context) {
    final vm = Provider.of<KITProvider>(context);
    final cm = vm.campusManager;
    if (!cm.examsLoaded &&
        !cm.isFetchingExams &&
        !cm.examsSurfaceBroken &&
        // R22: omitting offlineSuspected made the self-heal an unthrottled
        // offline loop: fetch fails -> notify -> rebuild -> condition still
        // true -> fetch again, storming cascampus (boot + scrape each cycle,
        // bot-challenge quota!) while the tab is open. The flag clears on
        // the next healthy fetch, re-arming this heal then.
        !cm.offlineSuspected) {
      // self-heal: a stale session that never ran fetchExams (e.g. login
      // predates this build) must not leave the user on an endless spinner
      // single-flight via the provider: the agenda's synthetic-exam
      // re-render joins exactly this chain through vm.examsDone
      SchedulerBinding.instance.addPostFrameCallback((_) => vm.fetchExams());
    }
    final exams = cm.exams;
    final now = DateTime.now();

    // cascampus lists the exam offers of the whole degree-programme
    // catalogue: exams of lectures that are NOT on the current timetable
    // are other semesters' business - keep them listed but never urgent.
    // C38: the relevance gate runs exactly once per exam and the
    // cross-section exclusions consult one-shot Sets - the five list
    // scans used to re-run isTakingThisSemester and O(n) list.contains
    // against the whole catalogue on every pass
    final taking = {for (final e in exams) e: cm.isTakingThisSemester(e)};
    final catalog = exams
        .where((e) => !e.registered && taking[e] == false)
        .toList()
      ..sort(byWindowEnd);
    final inCatalog = catalog.toSet();
    final open = exams
        .where((e) => e.needsAction(now) && !inCatalog.contains(e))
        .toList()
      ..sort(byWindowEnd);
    final registered = exams.where((e) => e.registered).toList()
      ..sort(byWindowEnd);
    final upcoming = exams
        .where((e) =>
            !e.registered &&
            !inCatalog.contains(e) &&
            !e.needsAction(now) &&
            e.windowStart != null &&
            now.isBefore(e.windowStart!))
        .toList()
      ..sort(byWindowStart);
    final upcomingSet = upcoming.toSet();
    final rest = exams
        .where((e) =>
            !e.registered &&
            !inCatalog.contains(e) &&
            !e.needsAction(now) &&
            !upcomingSet.contains(e))
        .toList()
      ..sort(byWindowEnd);

    return Scaffold(
      appBar: AppBar(title: Text(L10n.t("exams.title"))),
      // one refresh affordance for ALL branches (loading/error/empty/list):
      // the empty list especially needs a manual re-sync
      body: MaxWidthBody(
        child: RefreshIndicator(
          onRefresh: () => _refresh(context, vm),
          child: !cm.examsLoaded
              ? (cm.examsSurfaceBroken
                  ? ListView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      children: [
                        const SizedBox(height: 200),
                        Center(child: Text(L10n.t("exams.loadError"))),
                        const SizedBox(height: 12),
                        Center(
                          child: FilledButton(
                            // the button used to fire fetchExams() and drop
                            // its Future<bool>: a failed retry re-threw
                            // nothing, re-toasted nothing - the user just
                            // kept staring at the error. Same body as
                            // pull-to-refresh now, failure included.
                            onPressed: () => _refresh(context, vm),
                            child: Text(L10n.t("exams.retry")),
                          ),
                        ),
                      ],
                    )
                  : ListView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      children: const [
                        SizedBox(height: 240),
                        Center(child: CircularProgressIndicator()),
                      ],
                    ))
              : ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding:
                      const EdgeInsets.fromLTRB(12, 12, 12, kDockClearance),
                  children: [
                    if (exams.isEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 200),
                        child: Center(child: Text(L10n.t("exams.empty"))),
                      ),
                    // R29: counters first - "how long until each Klausur"
                    // is the page's headline question, and a real time
                    // collision outranks everything below it
                    if (registered.isNotEmpty) ...[
                      _clashCard(context, exams, now),
                      _countdownCard(context, exams, now),
                    ],
                    if (open.isNotEmpty)
                      _section(
                          context, L10n.t("exams.sectionActNow"), open, now,
                          vm: vm, danger: true),
                    if (upcoming.isNotEmpty)
                      _section(context, L10n.t("exams.sectionOpensSoon"),
                          upcoming, now,
                          vm: vm),
                    if (registered.isNotEmpty)
                      _section(context, L10n.t("exams.sectionRegistered"),
                          registered, now,
                          vm: vm),
                    if (rest.isNotEmpty)
                      _section(
                          context, L10n.t("exams.sectionOther"), rest, now,
                          vm: vm),
                    if (catalog.isNotEmpty)
                      _section(
                          context, L10n.t("exams.sectionCatalog"), catalog,
                          now,
                          vm: vm, quiet: true),
                    _freshFooter(context, cm),
                  ],
                ),
        ),
      ),
    );
  }

  /// One refresh body for pull-to-refresh AND the retry button; the toast
  /// is guarded because the fetch outlives the page pop.
  Future<void> _refresh(BuildContext context, KITProvider vm) async {
    final toasts = context.read<ToastsProvider>();
    final ok = await vm.fetchExams();
    if (!ok && context.mounted) {
      toasts.showTextToast(L10n.t("exams.loadError"));
    }
  }

  @visibleForTesting
  static int byWindowEnd(ExamEntry a, ExamEntry b) {
    final c = (a.windowEnd ?? DateTime(2100))
        .compareTo(b.windowEnd ?? DateTime(2100));
    if (c != 0) return c;
    // six exam groups of one lecture share deadline AND title; the pool
    // letter lives in the exam number ("20.21 Pool A"…) - sorting on it
    // beats the cascampus source order (…, Pool E, Pool D)
    final t = a.title.compareTo(b.title);
    return t != 0 ? t : a.examNumber.compareTo(b.examNumber);
  }

  @visibleForTesting
  static int byWindowStart(ExamEntry a, ExamEntry b) =>
      (a.windowStart ?? DateTime(2100))
          .compareTo(b.windowStart ?? DateTime(2100));

  Widget _section(BuildContext context, String title, List<ExamEntry> exams,
      DateTime now,
      {required KITProvider vm, bool danger = false, bool quiet = false}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 12, 4, 6),
          child: Text(title,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  color: danger ? Theme.of(context).colorScheme.error : null,
                  fontWeight: FontWeight.bold)),
        ),
        ...exams.map((e) =>
            _card(context, e, now, vm: vm, danger: danger, quiet: quiet)),
      ],
    );
  }

  Widget _card(BuildContext context, ExamEntry e, DateTime now,
      {required KITProvider vm, bool danger = false, bool quiet = false}) {
    // quiet = not on the current timetable: an open window here is NOT
    // something the student must act on, so no red chip
    final urgent = !quiet && e.needsAction(now);
    final scheme = Theme.of(context).colorScheme;
    final details = <String>[
      ...e.terms.map((t) => L10n.t("exams.detailExamTerm", [
            t.dayLabel,
            t.time,
            t.room.isNotEmpty ? "  •  ${t.room}" : "",
          ])),
      if (e.windowStart != null && e.windowEnd != null)
        L10n.t("exams.detailWindow",
            [L10n.deadline(e.windowStart!), L10n.deadline(e.windowEnd!)])
      else if (e.windowEnd != null)
        L10n.t("exams.detailDeadline", [L10n.deadline(e.windowEnd!)]),
      if (e.examiners.isNotEmpty)
        L10n.t("exams.detailExaminers", [e.examiners]),
      e.examType,
    ];

    // R32.8: door handoff per DESTINATION the directory can certify for
    // the non-cancelled sittings, keyed on the resolved Maps URL: several
    // seating keys name one building ("20.21 Pool A"…"Pool E" are rooms of
    // one Hörsaal-Trakt) and would otherwise stack identical rows
    final routes = <({String room, String url})>[];
    {
      final places = vm.topographyManager.places;
      final firstRoom = <String, String>{}; // url -> first room seen
      final roomKeys = <String, Set<String>>{}; // url -> seating keys
      for (final t in e.terms) {
        if (t.isCancelled) continue;
        final r = routeHandoff(places, t.room);
        if (r == null) continue;
        firstRoom.putIfAbsent(r.url, () => r.room);
        (roomKeys[r.url] ??= <String>{}).add(r.room);
      }
      // map iteration = order of first sight per URL; seating keys beyond
      // the first are disclosed as the label's "(+N)" suffix, not dropped
      for (final dest in firstRoom.entries) {
        final extra = roomKeys[dest.key]!.length - 1;
        routes.add((
          room: extra == 0 ? dest.value : "${dest.value} (+$extra)",
          url: dest.key,
        ));
      }
    }
    // R32.3: a deregistration deadline renders only while it is still
    // actionable — a passed "Abmelden bis" is history, never a live chip
    final deregRaw = e.registered ? e.deregEnd : null;
    final dereg =
        (deregRaw != null && deregRaw.isAfter(now)) ? deregRaw : null;

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: danger
            ? BorderSide(color: scheme.error, width: 1.4)
            : BorderSide.none,
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(e.title, style: const TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            Text(details.join("\n"),
                style:
                    TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant)),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              children: [
                if (e.registered)
                  _chip(L10n.t("exams.chipRegistered"), scheme.tertiary)
                else if (urgent)
                  // #11: filled - the one chip on the page meaning "act
                  // now" must not differ from its benign sibling only by
                  // a red-vs-grey tint of the same thin outline
                  _urgentChip(L10n.t("exams.chipNotRegisteredNow"), scheme)
                else
                  _chip(L10n.t("exams.chipNotRegistered"), scheme.outline),
                // R32.3: muted "abmelden bis X" on registered cards — the
                // "Register by" tier styling, quiet while there is runway
                // and error-colored once under three days remain; expired
                // deadlines render nothing at all
                if (dereg != null)
                  _chip(
                      L10n.t("exams.chipDeregUntil", [L10n.stamp(dereg)]),
                      L10n.daysFromNow(dereg, now) <= 3
                          ? scheme.error
                          : scheme.outline),
                if (e.examNumber.isNotEmpty)
                  // plain caption, not a second pill: an identical chip
                  // for the module number invites taps that do nothing
                  Text(e.examNumber,
                      style: TextStyle(fontSize: 11, color: scheme.outline)),
              ],
            ),
            // R32.8: one tappable handoff row per distinct RESOLVED
            // DESTINATION (Maps URL, not room string) — tap opens Maps
            // walking directions from wherever the student stands; the
            // first seating key seen labels the row and "(+N)" discloses
            // that N further keys share this door. Unresolved or online
            // rooms never render a row, so a miss can never send the
            // student to the wrong door.
            for (final r in routes)
              InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: () => _launchExternal(r.url),
                // minHeight 44: Material's touch-target floor — the
                // padded icon+label row measured ~25 dp, too small to
                // hit reliably one-handed (settings rows, same idiom)
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 44),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      children: [
                        Icon(Icons.directions_walk,
                            size: 15, color: scheme.primary),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                              "${r.room} · ${L10n.t("timetable.directions")}",
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  fontSize: 12.5, color: scheme.primary)),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// R32.8 seam: resolve a sitting room string through the same directory
  /// resolver the agenda's walk hints use, then build the Maps URL. Returns
  /// null whenever nothing is certified about the room (empty/online text,
  /// directory miss) — the Route line is then never rendered.
  @visibleForTesting
  static ({String room, String url})? routeHandoff(
      List<KITPlace> places, String room) {
    if (room.trim().isEmpty) return null;
    final place = _resolveRoom(places, room);
    if (place == null) return null;
    // same destination preference as the timetable's "Route here": exact
    // coordinates become precise directions, an approximate place goes to
    // Maps as a search string instead of a wrong-precise pin
    final exact = place.latLngFromList;
    return (
      room: room.trim(),
      url: exact != null
          ? mapsDirectionsUrl(exact)
          : mapsSearchUrl("${place.title} KIT Karlsruhe"),
    );
  }

  /// agenda's room-cache idiom (its `_roomCache`) — class-level here because
  /// this page is stateless: fuzzy resolution runs against the whole ~800
  /// place directory per distinct room, not per card per rebuild; the epoch
  /// is the directory size, exactly like the agenda's.
  static KITPlace? _resolveRoom(List<KITPlace> places, String room) {
    if (_roomCacheEpoch != places.length) {
      _roomCache.clear();
      _roomCacheEpoch = places.length;
    }
    return _roomCache.putIfAbsent(room, () => resolveRoomPlace(places, room));
  }

  static final Map<String, KITPlace?> _roomCache = {};
  static int _roomCacheEpoch = -1;

  /// Mirror of agenda_page's private `_launchExternal` (the signmeup card
  /// carries the same-named twin): only a well-formed http(s) URL reaches the
  /// launcher, and a missing or refusing Maps app never throws inside a tap.
  void _launchExternal(String raw) {
    try {
      final uri = Uri.parse(raw);
      if (uri.host.isEmpty ||
          (uri.scheme != "http" && uri.scheme != "https")) {
        return;
      }
      launchUrl(uri, mode: LaunchMode.externalApplication)
          .catchError((_) => false);
    } on Object catch (_) {}
  }

  /// R29: day counter for every registered sitting ("in 12 Tagen ·
  /// Analysis I · 23.03.2027 09:00"). All wording/math comes from
  /// [examCountdowns] + the app's shared relative-date helper, so the
  /// agenda's next-exam card and this list can never disagree.
  Widget _countdownCard(
      BuildContext context, List<ExamEntry> exams, DateTime now) {
    // R31 D1: registered rows first (rendered exactly as before), then
    // the "If you register" tier filling the SAME limit of 6 — it never
    // displaces a registered countdown, only shares the card.
    final list = examCountdowns(exams, now, limit: 6);
    final cond = list.length < 6
        ? conditionalCountdowns(exams, now, limit: 6 - list.length)
        : const <ExamCountdown>[];
    if (list.isEmpty && cond.isEmpty) return const SizedBox.shrink();
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(L10n.t("exams.countdownTitle"),
                style: const TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            for (final c in [...list, ...cond]) _countdownRow(context, c, now),
          ],
        ),
      ),
    );
  }

  /// One countdown row, both tiers. Registered: tertiary day counter,
  /// plain title. Conditional (R31 D1): same skeleton, MUTED day counter
  /// (this is an offer, not a commitment) plus the sub-line
  /// ``If you register · Register by <windowEnd>`` — error-colored once
  /// the window closes within 3 days (cockpit runway doctrine: warn while
  /// there is still runway, in the one color the eye already distrusts).
  Widget _countdownRow(
      BuildContext context, ExamCountdown c, DateTime now) {
    final scheme = Theme.of(context).colorScheme;
    final end = c.windowEnd;
    final subColor = c.conditional && end != null && L10n.daysFromNow(end, now) <= 3
        ? scheme.error
        : scheme.outline;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment:
            c.conditional ? CrossAxisAlignment.start : CrossAxisAlignment.center,
        children: [
          SizedBox(
            width: 96,
            child: Text(
              // room, when ambiguous, is deliberately absent:
              // two pool sittings share the start and showing
              // one room would misattribute the sibling's
              L10n.dayOffset(c.at, now),
              style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                  color: c.conditional ? scheme.onSurfaceVariant : scheme.tertiary),
            ),
          ),
          Expanded(
            child: c.conditional
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(c.exam.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 12.5,
                              color: scheme.onSurfaceVariant)),
                      Text(
                        end == null
                            ? L10n.t("exams.countdownIfRegister")
                            : "${L10n.t("exams.countdownIfRegister")} · "
                                "${L10n.t("exams.countdownRegisterBy")} "
                                "${L10n.stamp(end)}",
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 10.5, color: subColor),
                      ),
                    ],
                  )
                : Text(c.exam.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 12.5, color: scheme.onSurfaceVariant)),
          ),
          Text(L10n.stamp(c.at),
              style: TextStyle(fontSize: 11, color: scheme.outline)),
        ],
      ),
    );
  }

  /// R29 (D4): CasCampus silently registers two exams at the same hour -
  /// a collision the student only notices at the door. RED needs provable
  /// time overlap (both spans parsed, strict intersection); same-day is
  /// amber only, and unknown spans are reported as UNCHECKABLE, never
  /// folded into an "all clear" the app cannot guarantee.
  Widget _clashCard(
      BuildContext context, List<ExamEntry> exams, DateTime now) {
    // R35.4: room geometry rides the agenda's own resolver (building
    // numbers first, fuzzy names only through the token fence) - the
    // clash card and the Fußweg hint can never disagree about distance.
    final places = Provider.of<KITProvider>(context, listen: false)
        .topographyManager
        .places;
    final report = findExamClashes(exams, now, distance: (ra, rb) {
      // _resolveRoom, not raw resolveRoomPlace: the clash callback fires
      // per card pair per rebuild, and the cache doc above demands fuzzy
      // resolution run per DISTINCT room - raw calls paid the full
      // ~800-place fuzzy scan twice per card on every rebuild.
      final pa = _resolveRoom(places, ra);
      final pb = _resolveRoom(places, rb);
      return pa == null || pb == null || pa.id == pb.id
          ? null
          : roomDistanceMeters(pa, pb);
    });
    if (report.clashes.isEmpty && report.uncomparable == 0) {
      return const SizedBox.shrink();
    }
    final scheme = Theme.of(context).colorScheme;
    final red = report.clashes.any((c) =>
        c.kind == ClashKind.overlap ||
        c.kind == ClashKind.walkImpossible);
    final color = red ? scheme.error : scheme.tertiary;
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side:
            BorderSide(color: color.withValues(alpha: 0.6), width: 1.2),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(red ? Icons.error_outline : Icons.warning_amber,
                    size: 18, color: color),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                      L10n.t(report.clashes.any((c) =>
                              c.kind == ClashKind.overlap)
                          ? "exams.clashOverlapTitle"
                          : red
                              ? "exams.clashWalkTitle"
                              : "exams.clashSameDayTitle"),
                      style: TextStyle(
                          fontWeight: FontWeight.w600, color: color)),
                ),
              ],
            ),
            const SizedBox(height: 6),
            for (final c in report.clashes.take(3))
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Text(
                    c.walkMinutes == null
                        ? L10n.t("exams.clashLine",
                            [c.a.title, c.b.title, L10n.stamp(c.when)])
                        : L10n.t("exams.clashWalkLine", [
                            c.a.title,
                            c.b.title,
                            L10n.stamp(c.when),
                            c.walkMinutes!
                          ]),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 12.5, color: scheme.onSurfaceVariant)),
              ),
            if (report.uncomparable > 0)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(L10n.t("exams.clashUnknown",
                    [report.uncomparable]),
                    style: TextStyle(fontSize: 11, color: scheme.outline)),
              ),
          ],
        ),
      ),
    );
  }

  Widget _chip(String label, Color color) => Chip(
        visualDensity: VisualDensity.compact,
        // scheme-based colors keep tinted labels contrast-safe per theme
        label: Text(label,
            style: TextStyle(
                fontSize: 11, color: color, fontWeight: FontWeight.w600)),
        backgroundColor: color.withValues(alpha: 0.18),
        side: BorderSide(color: color.withValues(alpha: 0.6)),
      );

  Widget _urgentChip(String label, ColorScheme scheme) => Chip(
        visualDensity: VisualDensity.compact,
        // errorContainer is the solid M3 destructive surface - unmistakable
        // against the outline chips and contrast-safe in both brightnesses
        label: Text(label,
            style: TextStyle(
                fontSize: 11,
                color: scheme.onErrorContainer,
                fontWeight: FontWeight.w700)),
        backgroundColor: scheme.errorContainer,
        side: BorderSide(color: scheme.error),
      );

  /// "Stand: HH:MM" / orange staleness — cascampus is fetched live on every
  /// login but NOTHING else refreshes it: without this a pull at 08:00 and
  /// a pull three days later render identically (agenda footer, same rule)
  Widget _freshFooter(BuildContext context, CampusManager cm) {
    final scheme = Theme.of(context).colorScheme;
    final at = cm.examsFetchedAt;
    if (at == null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Text(L10n.t("exams.staleUnknown"),
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 11, color: scheme.error)),
      );
    }
    final age = DateTime.now().difference(at);
    final stale = age > const Duration(hours: 6);
    final label = stale
        ? L10n.t("exams.staleData", ["${age.inHours} h"])
        : L10n.t("exams.asOf", [
            "${at.hour.toString().padLeft(2, '0')}:"
                "${at.minute.toString().padLeft(2, '0')}"
          ]);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Text(label,
          textAlign: TextAlign.center,
          style: TextStyle(
              fontSize: 11, color: stale ? scheme.error : scheme.outline)),
    );
  }
}
