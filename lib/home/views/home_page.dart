import 'dart:async';

import 'dart:ui';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:kit_mobile/common_ui/block_container.dart';
import 'package:kit_mobile/common_ui/kit_progress_indicator.dart';
import 'package:kit_mobile/constants/view_constants.dart';
import 'package:kit_mobile/l10n/l10n.dart';
import 'package:kit_mobile/home/views/hierarchic_table.dart';
import 'package:kit_mobile/home/views/ka_uni_app_bar_title.dart';
import 'package:kit_mobile/home/views/padded_title.dart';
import 'package:kit_mobile/common_ui/mei_failure_banner.dart';
import 'package:kit_mobile/exams/views/exams_page.dart';
import 'package:kit_mobile/agenda/views/agenda_page.dart';
import 'package:kit_mobile/navigation/logic/push_page.dart';
import 'package:kit_mobile/agenda/logic/next_up.dart';
import 'package:kit_mobile/timetable/logic/now_clock.dart';
import 'package:kit_mobile/timetable/models/webcal.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:kit_mobile/home/views/relevant_modules.dart';
import 'package:kit_mobile/local_files_storage/views/pinned_files_list_view.dart';
import 'package:kit_mobile/mensa/views/mensa_today_card.dart';
import 'package:kit_mobile/profile/views/profile_view.dart';
import 'package:kit_mobile/settings/providers/settings_provider.dart';
import 'package:kit_mobile/timetable/pages/timetable_edit_page.dart';
import 'package:kit_mobile/timetable/views/timetable_weekly_view.dart';
import 'package:kit_mobile/toasts/models/toasts_provider.dart';
import 'package:provider/provider.dart';

import '../../local_files_storage/views/pages/files_cache_page.dart';
import '../../state_management/kit_provider.dart';

class KITHomePage extends StatefulWidget {
  const KITHomePage({super.key});

  @override
  State<KITHomePage> createState() => _KITHomePageState();
}

class _KITHomePageState extends State<KITHomePage> {
  @override
  Widget build(BuildContext context) {
    final vm = Provider.of<KITProvider>(context);
    final toastsProvider = Provider.of<ToastsProvider>(context);
    final settingsVM = Provider.of<SettingsProvider>(context);

    return Scaffold(
        appBar: AppBar(
          flexibleSpace: ClipRect(
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 7, sigmaY: 7),
              child: Container(
                color: Colors.transparent,
              ),
            ),
          ),
          // backgroundColor: Theme.of(context).colorScheme.surface,
          title: KaUniAppBarTitle(),
          centerTitle: true,
          // backgroundColor: Colors.transparent,
          // shadowColor: Colors.transparent,
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.only(
            bottomLeft: Radius.circular(10),
            bottomRight: Radius.circular(10),
          )),
          // surfaceTintColor: Colors.transparent,
          // the label names what is loading: the bare spinner is reused
          // app-wide and otherwise announces nothing at all
          leading: vm.profileReady
              ? SizedBox.shrink()
              : KITProgressIndicator(
                  semanticsLabel: L10n.t("home.profileLoading")),
          // leading: !kDebugMode
          //     ? null
          //     : CupertinoButton(
          //         child: Icon(
          //           CupertinoIcons.check_mark_circled_solid,
          //           color: Colors.red,
          //         ),
          //         onPressed: () async {
          //           await vm.prepareCachedData();
          //
          //           await credsVM.loadCredentials();
          //           await vm.setCredentials(credsVM.credentials);
          //           print(
          //               "${credsVM.credentials}, ${credsVM.credentials.valid}");
          //           if (credsVM.credentialsLoaded &&
          //               credsVM.credentials.valid) {
          //             await credsVM.login(vm);
          //             await vm.fetchSchedule();
          //             await vm.campusManager.fetchAllModules();
          //           }
          //         }),
          actions: [
            CupertinoButton(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              onPressed: () => pushPageOnce(Navigator.of(context),
                  routeName: AgendaPage.routeName,
                  page: (_) => const AgendaPage()),
              child: Tooltip(
                message: L10n.t("agenda.title"),
                child: Semantics(
                  button: true,
                  label: L10n.t("agenda.title"),
                  child: Badge(
                    isLabelVisible: vm.campusManager.timetableChanged,
                    backgroundColor: Colors.orange,
                    child: const Icon(CupertinoIcons.calendar, size: 22),
                  ),
                ),
              ),
            ),
            CupertinoButton(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              onPressed: () => pushPageOnce(Navigator.of(context),
                  routeName: ExamsPage.routeName,
                  page: (_) => const ExamsPage()),
              child: Tooltip(
                message: L10n.t("exams.title"),
                child: Semantics(
                  button: true,
                  label: L10n.t("exams.title"),
                  child: Badge(
                    isLabelVisible: vm.campusManager.exams.any((e) =>
                        e.needsAction(DateTime.now()) &&
                        vm.campusManager.isTakingThisSemester(e) != false),
                    backgroundColor: Colors.red,
                    child: const Icon(CupertinoIcons.checkmark_seal, size: 22),
                  ),
                ),
              ),
            ),
            CupertinoButton(
              onPressed: () {
                setState(() {
                  settingsVM.showingProfile.toggle();
                });
              },
              child: Semantics(
                button: true,
                label: L10n.t("settings.showProfile"),
                child: AnimatedRotation(
                  curve: defaultChevronRotationAnimationCurve,
                  turns: settingsVM.showingProfile.value ? 0 : -0.25,
                  duration: defaultChevronRotationAnimationDuration,
                  child: Icon(CupertinoIcons.chevron_down),
                ),
              ),
            )
          ],
        ),
        body: Stack(
          children: [
            RefreshIndicator(
              // a failed pull-down must toast like the button and the
              // empty-state retry do, not spin its error away silently
              onRefresh: () => vm.forceRefetchEverything().catchError((e) {
                toastsProvider.showTextToast(L10n.t("common.refreshFailed"));
              }),
              // park the disc in the header gap below the app bar; at the
              // default 40 it settled right on the profile card's name row
              // (and the agenda banner), obscuring what it covers
              displacement: 20,
              child: SingleChildScrollView(
                // pull-down works even when the page fits the screen
                physics: const AlwaysScrollableScrollPhysics(),
                child: Column(children: [
                  Column(
                    mainAxisAlignment: MainAxisAlignment.start,
                    children: <Widget>[
                      MeiFailureBanner(vm: vm),
                      const NextUpHomeCard(),
                      AnimatedSwitcher(
                        duration: Duration(milliseconds: 200),
                        child: settingsVM.showingProfile.value
                            // fake-zero guard: before profileReady the card
                            // would render Student.empty, i.e. literally
                            // "Note (⌀): 0,0" / "Leistungspunkte: 0,0",
                            // indistinguishable from real German-formatted
                            // values on a slow cold start
                            ? (!vm.profileReady
                                ? BlockContainer(
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(
                                          vertical: spaceMd),
                                      child: Row(
                                        mainAxisAlignment:
                                            MainAxisAlignment.center,
                                        children: [
                                          KITProgressIndicator(
                                              semanticsLabel: L10n.t(
                                                  "home.profileLoading")),
                                          const SizedBox(width: spaceSm),
                                          Text(L10n.t("home.profileLoading")),
                                        ],
                                      ),
                                    ),
                                  )
                                : const ProfileView())
                            : const SizedBox(),
                      ),
                      TimetableWeeklyView(),
                      const SizedBox(height: spaceMd),
                      CupertinoButton(
                          padding: const EdgeInsets.symmetric(
                              horizontal: pageGutter, vertical: spaceSm),
                          onPressed: () => pushPageOnce(Navigator.of(context),
                              routeName: "/timetableEdit",
                              page: (_) => TimetableEditPage()),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(CupertinoIcons.pencil_circle),
                              const SizedBox(width: spaceSm),
                              Text(L10n.t("settings.editTimetable")),
                            ],
                          )),
                      const SizedBox(height: spaceLg),
                      // canteen section (settings-gated, profile-card
                      // precedent): cached week paints instantly, the
                      // pull-down above refreshes it via the cascade
                      if (settingsVM.showMensa.value) ...[
                        Padding(
                          padding: const EdgeInsets.only(bottom: spaceMd),
                          child: const MensaTodayCard(),
                        ),
                        const SizedBox(height: spaceLg),
                      ],
                      Row(
                        children: [
                          PaddedTitle(
                              title: L10n.t("settings.currentModulesIn",
                                  [KITProvider.currentSemesterString])),
                          (vm.campusManager.isFetchingSchedule ||
                                  vm.campusManager.isFetchingModules)
                              ? KITProgressIndicator()
                              : SizedBox(
                                  width: 0,
                                  height: 0,
                                ),
                          Spacer(),
                          CupertinoButton(
                            onPressed: () {
                              toastsProvider.showTextToast(
                                  L10n.t("settings.reloadingModules"));
                              // fire-and-forget without a catch would swallow
                              // the failure silently behind the "reloading"
                              // toast that already vanished
                              unawaited(
                                  vm.forceRefetchEverything().catchError((e) {
                                toastsProvider.showTextToast(
                                    L10n.t("common.refreshFailed"));
                              }));
                            },
                            padding: EdgeInsets.all(10),
                            child: Tooltip(
                              message: L10n.t("settings.reloadingModules"),
                              child: Icon(CupertinoIcons.refresh),
                            ),
                          )
                        ],
                      ),
                      Container(
                        padding:
                            const EdgeInsets.symmetric(horizontal: cardGutter),
                        child: RelevantModulesView(),
                      ),
                      const SizedBox(height: spaceXl),
                      PaddedTitle(
                        title: L10n.t("settings.pinnedFiles"),
                        trailing: CupertinoButton(
                            child: Text(L10n.t("settings.viewAll")),
                            onPressed: () => pushPageOnce(Navigator.of(context),
                                routeName: "/filesCache",
                                page: (_) => FilesCachePage())),
                      ),
                      PinnedFilesListView(),
                      const SizedBox(height: spaceXl),
                      PaddedTitle(title: L10n.t("settings.myModules")),
                      HierarchicTableView(
                        rows: vm.campusManager.moduleRows,
                      ),
                      // the floating dock overlays the page: without this the
                      // last module rows sit permanently under the pill
                      const SizedBox(height: 140),
                    ],
                  )
                ]),
              ),
            ),
          ],
        ));
  }

  // Future<void> _refreshHomeView(KITProvider vm) async {
  //   await vm.forceRefetchEverything();
  // }
}

/// The agenda hero on home (R12): the SAME [NextUp.compute] and card the
/// agenda banner renders, fed by the agenda's own cache recipe. Countdown
/// updates ride a ValueListenableBuilder on the shared NowClock minute
/// heartbeat - the home page itself NEVER rebuilds per tick; the TickerMode
/// gate (agenda's C22 pattern) arms/disarms the clock so a hidden dashboard
/// or a Settings-tab visit costs zero wakeups.
class NextUpHomeCard extends StatefulWidget {
  const NextUpHomeCard({super.key});

  @override
  State<NextUpHomeCard> createState() => _NextUpHomeCardState();
}

class _NextUpHomeCardState extends State<NextUpHomeCard>
    with WidgetsBindingObserver {
  WebcalFeed? _feed;
  bool _clockArmed = false;

  /// last webcal fetch stamp rendered by this card: the campus write path
  /// stamps [WebcalKeys.fetchedAt] right after EVERY rewrite of the ICS
  /// cache, so a changed stamp means [_readCache] must run again
  String? _seenFetchedAt;
  bool _probeInFlight = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // parse ONCE on mount; a resume re-reads (background polls refresh the
    // cache while the app sits closed - the hero must not show yesterday)
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
  void didChangeDependencies() {
    super.didChangeDependencies();
    // visibility gate (C22 pattern): reading the flag HERE registers the
    // dependency, so the rebuild that re-exposes the dashboard re-arms
    final visible = TickerMode.valuesOf(context).enabled;
    if (visible && !_clockArmed) {
      _clockArmed = true;
      NowClock.arm();
    } else if (!visible && _clockArmed) {
      _clockArmed = false;
      NowClock.disarm();
    }
    // the build-side watch makes every campus refresh re-enter HERE, so
    // this is where the post-refresh cache re-read hooks in
    unawaited(_resyncIfStale());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _readCache();
  }

  /// cheap post-refresh re-read (mirrors the agenda, which reloads its
  /// cache off the same stamp key): the provider notification re-enters
  /// didChangeDependencies, this compares the fetch stamp against what the
  /// hero actually rendered, and a mismatch re-reads the ICS. Deliberately
  /// async + setState-if-changed: build must never block on prefs IO.
  Future<void> _resyncIfStale() async {
    if (_probeInFlight) return;
    _probeInFlight = true;
    try {
      // SharedPreferencesAsync is the live cross-isolate fence; the legacy
      // getInstance() snapshot would keep serving pre-refresh bytes
      final stamp =
          await SharedPreferencesAsync().getString(WebcalKeys.fetchedAt);
      if (mounted && stamp != _seenFetchedAt) await _readCache();
    } finally {
      _probeInFlight = false;
    }
  }

  Future<void> _readCache() async {
    // live async reads (see _resyncIfStale): background polls write the
    // cache from another isolate while the app sits closed, and the resume
    // re-read must see those writes too
    final prefs = SharedPreferencesAsync();
    // stamp BEFORE the ICS body: a refresh landing between the two reads
    // leaves the older stamp recorded, so the next probe re-fires (over-
    // invalidation) instead of marking fresh-looking stale bytes as seen
    final stamp = await prefs.getString(WebcalKeys.fetchedAt);
    final feed =
        WebcalFeed.parse(await prefs.getString(WebcalKeys.icsCache) ?? "");
    if (!mounted) return;
    _seenFetchedAt = stamp;
    setState(() => _feed = feed);
  }

  @override
  Widget build(BuildContext context) {
    // listen for campus refreshes: pull-to-refresh rewrites the ICS cache
    // and notifies the provider; the watch alone could NOT fix the stale
    // hero (_feed is cached state, not provider-derived) - it exists so
    // each notification re-enters didChangeDependencies, where
    // [_resyncIfStale] re-reads the cache when the fetch stamp moved
    context.watch<KITProvider>();
    return ValueListenableBuilder<int>(
      valueListenable: NowClock.minutesOfDay,
      builder: (context, _, __) {
        // one clock reading per rebuild: candidates and countdown must
        // never straddle a minute boundary between the two
        final now = NowClock.timeSource();
        final up = NextUp.compute(NextUp.heroWindow(_feed, now), now);
        if (up == null) return const SizedBox.shrink();
        return NextUpCard(
          up: up,
          onTap: () {
            final nav = Navigator.of(context);
            // with the agenda already on the stack pushPageOnce silently
            // no-oped and the hero card looked dead; nudge the open page
            // to resync + scroll to today instead
            if (ActivePages.isOpen(nav, AgendaPage.routeName)) {
              AgendaResync.request(scrollToToday: true);
              return;
            }
            pushPageOnce(nav,
                routeName: AgendaPage.routeName,
                page: (_) => const AgendaPage(scrollToToday: true));
          },
        );
      },
    );
  }
}
