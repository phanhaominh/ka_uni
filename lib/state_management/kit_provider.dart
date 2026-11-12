import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:fuzzywuzzy/fuzzywuzzy.dart';
import 'package:kit_mobile/credentials/models/kit_credentials.dart';
import 'package:kit_mobile/geo/network/KITTopographyManager.dart';
import 'package:kit_mobile/mensa/mensa_manager.dart';
import 'package:kit_mobile/module_info_table/models/module_info_table_cell.dart';
import 'package:kit_mobile/state_management/ilias/ilias_manager.dart';

import '../local_files_storage/files_manager.dart';
import '../module/models/module.dart';
import '../module_info_table/models/module_info_table.dart';
import '../parsing/models/hierarchic_table_row.dart';
import '../student/student.dart';
import '../notifications/mei_notifications.dart';
import '../signmeup/signmeup_manager.dart';
import '../timetable/models/timetable_weekly.dart';
import 'campus/campus_manager.dart';

class KITProvider extends ChangeNotifier {
  Student student = Student.empty;

  void setCredentials(KITCredentials newCredentials) {
    // _credentials = newCredentials;
    campusManager.credentials = newCredentials;
    iliasManager.credentials = newCredentials;
  }

  late final CampusManager campusManager;
  late final IliasManager iliasManager;

  /// In-flight (or last) ILIAS SSO; the agenda awaits it before scraping.
  Future<void> iliasAuth = Future.value();
  late final KITTopographyManager topographyManager;

  /// SW Karlsruhe canteen menu (public feed, no login) feeding the home
  /// Mensa card
  late final MensaManager mensa;
  late final IliasFilesProvider iliasFileManager;
  final SignMeUpManager signMeUpManager = SignMeUpManager();

  Future<void>? _signMeUpInFlight;

  /// Resolves once the last started SignMeUp refresh (offer + own
  /// registrations + timetable injection) has finished; the agenda awaits it
  /// before rendering the first frame so assigned groups appear immediately.
  Future<void>? get signMeUpDone => _signMeUpInFlight;

  bool _signMeUpColdRetryDone = false;

  /// bumped whenever a SignMeUp refresh COMPLETED (success or failure):
  /// [signMeUpDone] alone goes null on completion, so a consumer that only
  /// reads it after an ILIAS round-trip cannot tell "never ran" from "ran
  /// and wrote the synthetic block" - the agenda's follow-up re-render
  /// compares this generation against a captured start value
  int signMeUpGen = 0;

  /// SignMeUp needs the campus session, so it runs after login; one failing
  /// fetch must not veto the other refreshes.
  Future<void> fetchSignMeUp() {
    final existing = _signMeUpInFlight;
    if (existing != null) {
      return existing;
    }
    final future = _doFetchSignMeUp();
    _signMeUpInFlight = future;
    // identity-bound clear: a logout may already have DROPPED this memo
    // (dropInflightFetches) while the chain still sleeps/retries, and the
    // next account's chain may have installed itself in its place - the
    // orphaned OLD chain settling must not null the NEW memo, and must not
    // bump signMeUpGen either (the agenda's follow-up re-render compares
    // generations and would fire for a refresh of the dead account)
    return future.whenComplete(() {
      if (identical(_signMeUpInFlight, future)) {
        _signMeUpInFlight = null;
        signMeUpGen++;
      }
    });
  }

  Future<void> _doFetchSignMeUp() async {
    final offer = await signMeUpManager.fetch(campusManager);
    // the campus session is cookie-only and dies with the process: on the
    // FIRST refresh after a cold start the login stages may still be in
    // flight (or the token simply expired). Retry once with a delay - but
    // only once per process: fetchMine returns false for perfectly normal
    // steady states (semester break) and an unconditional 20 s sleep
    // made every pull-to-refresh hang that long. A PROVEN missing plus
    // account is a definite miss, not a session race - skip the sleep.
    var mine = await signMeUpManager.fetchMine(campusManager);
    if (!mine && !_signMeUpColdRetryDone && !campusManager.plusAccountMissing) {
      _signMeUpColdRetryDone = true;
      await Future.delayed(const Duration(seconds: 20));
      mine = await signMeUpManager.fetchMine(campusManager);
    }
    if (mine) {
      await campusManager
          .reapplySignMeUpSynth(signMeUpManager.buildSynthBlock());
    }
    // deadline nags only with PROVEN registration state: on a failed
    // fetchMine the registered set is stale/empty and every open
    // procedure would fire a false "noch nicht angemeldet" alarm
    if (mine) {
      unawaited(MeiNotifications.scheduleSignMeUpReminders(
          signMeUpManager.procedures,
          registered: signMeUpManager.registeredProcedureIds));
    } else {
      unawaited(MeiNotifications.cancelSignMeUpReminders());
    }
    if (offer || mine) notifyListeners();
  }

  Future<bool>? _examsInFlight;

  /// Resolves once the last started exam-list fetch (incl. the synthetic
  /// exam-sitting injection into the ICS cache) has finished; the agenda
  /// awaits it exactly like [signMeUpDone] so registered sittings appear
  /// in today/tomorrow without a manual pull.
  Future<void>? get examsDone => _examsInFlight;

  /// Single-flight exam-list fetch through the provider, mirroring
  /// [fetchSignMeUp]: while one is in flight, callers join it instead of
  /// stacking fetches. UI (exams page pull) MUST go through here, not the
  /// raw manager, so [examsDone] actually represents the running chain
  /// and the agenda's synthetic-exam re-render joins it too.
  Future<bool> fetchExams() {
    final existing = _examsInFlight;
    if (existing != null) {
      return existing;
    }
    final future = campusManager.fetchExams();
    _examsInFlight = future;
    // identity-bound clear: the orphaned OLD-account chain must not null
    // the memo the NEW account's fetch has just installed
    return future.whenComplete(() {
      if (identical(_examsInFlight, future)) _examsInFlight = null;
    });
  }

  /// Logout: the memoized chains belong to the DEAD account. Their own
  /// finally-clearing runs only when the sockets settle - until then a
  /// next-account caller would JOIN account A's doomed fetch (and the
  /// agenda would await A's refresh as if it were its own).
  void dropInflightFetches() {
    _examsInFlight = null;
    _signMeUpInFlight = null;
    // the refetch cascade is account-bound too: joining A's still-running
    // forceRefetchEverything would wipe B's fresh cookies mid-cascade
    _refetchInFlight = null;
    // one-shot: A's orphan chain may have burned the cold-retry slot, so
    // B's first SignMeUp refresh would skip the session-race retry
    _signMeUpColdRetryDone = false;
    // schedule + per-row module memos live on the campus side
    campusManager.dropInFlightFetches();
  }

  bool get profileReady => campusManager.ready;

  TimetableWeekly get timetable => campusManager.timetable;

  KITProvider() {
    if (kDebugMode) {
      print("Instantiating a KITProvider...");
    }
    campusManager = CampusManager(student, notifyListeners);
    // campus-side session-expiry recovery has to go through this class'
    // single-flight; calling campusManager.forceRefetchEverything directly
    // stacked concurrent clear+cookie-wipe cascades under sibling fetches
    campusManager.forceRefetchViaOwner = forceRefetchEverything;
    campusManager.fetchJSession();

    iliasManager = IliasManager();
    iliasManager.fetchJSession();
    // fetchSchedule();

    topographyManager = KITTopographyManager();
    unawaited(topographyManager
        .fetchPlaces() // self-contained errors
        .then((_) =>
            notifyListeners())); // C18: walk hints + Raum-Finder refresh when the directory lands

    // mensa: public Studierendenwerk feed - safe to kick before login,
    // restore paints the cached week, the network only refreshes it;
    // its failures NEVER touch campusManager's surface/offline flags.
    // Not under the test harness though: 8+ suites construct a
    // KITProvider and the Studierendenwerk must not eat one GET each
    mensa = MensaManager()
      // relay: menu AND translation arrivals repaint the card the moment
      // they land (boot below only fires once; late translate results
      // would otherwise wait for the next unrelated rebuild)
      ..addListener(notifyListeners);
    if (!Platform.environment.containsKey('FLUTTER_TEST')) {
      unawaited(mensa.restore().then((_) => mensa.fetchWeek()).then((_) =>
          notifyListeners())); // flip the card from pending once settled
    }

    iliasFileManager = IliasFilesProvider();
  }

  Future<bool> tryPreloadCache(KITCredentials credentials) async {
    if (!credentials.valid) {
      return false;
    }

    await loadCachedDataAndNotify();
    await prepareCachedData();
    setCredentials(credentials);
    campusManager.ready = true;
    // (iliasAuth is kicked off by the caller AFTER credsVM.login: login's
    // clearCookiesAndCache would wipe this SSO's jar mid-redirect)
    // campus data is fetched by the caller AFTER the login stages complete:
    // stage0 resets the ilias-domain jar entries while the IdP redirect
    // chain churns, so anything raced against login either fails outright
    // or burns the cascampus bot-challenge quota.
    // SignMeUp is independent of the campus SP session and may start now.
    unawaited(fetchSignMeUp().catchError((_) {}));

    return true;
  }

  Future<void>? _refetchInFlight;

  Future<void> forceRefetchEverything({bool allModulesAsWell = true}) {
    // single-flight: home pull, empty-state button and refresh icon can
    // otherwise stack concurrent clear+fetch cascades (cookie resets while
    // sibling requests are in flight)
    final inflight = _refetchInFlight;
    if (inflight != null) return inflight;
    final future = (() async {
      await campusManager.forceRefetchEverything(
          allModulesAsWell: allModulesAsWell);
      await fetchSignMeUp();
      // the home pull-down also refreshes the canteen week - but NOT
      // awaited: fetchWeek swallows everything and can sit in its 15 s
      // transport timeout, and the pull spinner must not hang on a
      // third-party site after the campus cascade already finished
      unawaited(mensa.fetchWeek(force: true));
    })();
    _refetchInFlight = future;
    // identity-bound clear: an orphaned cascade from the previous account
    // must not null the memo its successor just installed
    return future.whenComplete(() {
      if (identical(_refetchInFlight, future)) _refetchInFlight = null;
    });
  }

  HierarchicTableRow? fuzzyFindHierarchicTableRowSimilarTo(
      HierarchicTableRow exampleRow) {
    int bestMatch = 0;
    HierarchicTableRow? bestMatchRow;

    for (final row in campusManager.moduleRows) {
      final currentMatch = ratio(row.title, exampleRow.title) +
          ratio(row.id, exampleRow.id) +
          ratio(row.type, exampleRow.type);
      // strict `>` (parity with toggleIsFavoriteFuzzy below): ratio() is 0
      // for unrelated strings, so with `>=` the FIRST candidate auto-won
      // with score 0 whenever nothing matched - returning a random
      // unrelated Studienverlauf row for the caller to refetch + re-toggle
      if (currentMatch > bestMatch) {
        bestMatch = currentMatch;
        bestMatchRow = row;
      }
    }

    // the score sums three ratios, so the single-ratio acceptance threshold
    // scales by 3: below this it is "some other lecture", and re-toggling a
    // wrong row on the server is exactly what this path must never do
    if (bestMatchRow == null || bestMatch < 3 * _minFuzzyAcceptScore) {
      if (kDebugMode) {
        print(
            "Could not find a row similar to ${exampleRow.title}, best score: $bestMatch");
      }
      return null;
    }

    return bestMatchRow;
  }

  String overlayHtmlData = "";
  void dismissOverlayHtml() {
    overlayHtmlData = "";
    notifyListeners();
  }

  Future<void> loadCachedDataAndNotify() async {
    await campusManager.loadStudentData();
    await campusManager.loadCachedTimetable();
    notifyListeners();
  }

  Future<void> fetchSchedule(
      {notify = true,
      retryIfFailed = true,
      secondRetryIfFailed = true,
      refreshSession = true,
      startRefreshTimer = true}) {
    return campusManager.fetchSchedule(
        notify: notify,
        retryIfFailed: retryIfFailed,
        secondRetryIfFailed: secondRetryIfFailed,
        refreshSession: refreshSession,
        startRefreshTimer: startRefreshTimer);
  }

  Future<KITModule> getOrFetchModuleForRow(HierarchicTableRow row) async {
    return await campusManager.getOrFetchModuleForRow(row, userInitiated: true);
  }

  Future<bool> toggleIsFavorite(ModuleInfoTableCell cell, KITModule inModule,
      {visual = true}) async {
    return await campusManager.toggleIsFavorite(cell, inModule,
        anticipate: visual);
  }

  /// A fuzzywuzzy ratio below this effectively means "some other lecture".
  /// The favorite toggle POSTs to the real KIT server, so it is better to
  /// bail out with false than to add/remove a completely wrong lecture.
  static const int _minFuzzyAcceptScore = 70;

  Future<bool> toggleIsFavoriteFuzzy(String targetRowTitleCellBody,
      String targetTableCaption, String targetModuleTitle) async {
    // 1. try to find the module
    int bestMatchScore = 0, currentScore = 0;
    KITModule? bestMatchModule;

    for (final rowId in campusManager.rowModules.keys) {
      final module = campusManager.rowModules[rowId]!;
      currentScore = ratio(module.title, targetModuleTitle);
      // strict `>`: ratio() is 0 for unrelated strings, so with `>=` the
      // FIRST candidate auto-won with score 0 whenever nothing matched -
      // toggling a random wrong lecture on the server
      if (currentScore > bestMatchScore) {
        bestMatchScore = currentScore;
        bestMatchModule = module;
      }
    }

    if (bestMatchModule == null || bestMatchScore < _minFuzzyAcceptScore) {
      if (kDebugMode) {
        print(
            "Could not find module with title $targetModuleTitle, best score: $bestMatchScore");
      }
      return false;
    }

    if (kDebugMode) {
      print(
          "Found module with title $targetModuleTitle, score: $bestMatchScore");
    }

    // 2. try to find the table
    int bestMatchTableScore = 0;
    ModuleInfoTable? bestMatchTable;

    for (final table in bestMatchModule.tables) {
      currentScore = ratio(table.caption, targetTableCaption);

      if (currentScore > bestMatchTableScore) {
        bestMatchTableScore = currentScore;
        bestMatchTable = table;
      }
    }

    if (bestMatchTable == null || bestMatchTableScore < _minFuzzyAcceptScore) {
      if (kDebugMode) {
        print(
            "Could not find table with caption $targetTableCaption, best score: $bestMatchTableScore");
      }
      return false;
    }

    if (kDebugMode) {
      print(
          "Found table with caption $targetTableCaption, score: $bestMatchTableScore");
    }

    // 3. try to find the cell
    int bestMatchRowScore = 0;
    ModuleInfoTableCell? bestMatchCell;

    final titleCellIndex = bestMatchTable.titleCellIndex;

    for (final row in bestMatchTable.rows) {
      if (row.cells.length <= titleCellIndex) {
        if (kDebugMode) {
          print("Unexpected behavior: row.cells.length <= titleCellIndex");
        }

        continue;
      }
      currentScore =
          ratio(row.cells[titleCellIndex].body, targetRowTitleCellBody);

      if (currentScore > bestMatchRowScore && row.favoriteToggleCell != null) {
        bestMatchRowScore = currentScore;
        bestMatchCell = row.favoriteToggleCell;
      }
    }

    if (bestMatchCell == null || bestMatchRowScore < _minFuzzyAcceptScore) {
      if (kDebugMode) {
        print(
            "Could not find row with title $targetRowTitleCellBody, score: $bestMatchRowScore");
      }
      return false;
    }

    return await toggleIsFavorite(bestMatchCell, bestMatchModule);
  }

  static String get currentSemesterString {
    final now = DateTime.now();

    // Winter (handles year transition)
    if ([10, 11, 12].contains(now.month)) {
      return "WS ${now.year % 100}/${(now.year + 1) % 100}";
    }

    if ([1, 2, 3].contains(now.month)) {
      return "WS ${(now.year - 1) % 100}/${now.year % 100}";
    }

    // Summer
    return "SS ${now.year}";
  }

  // TODO: RENAME
  Future<void> clearCookiesAndCache() async {
    await campusManager.clearCookiesAndCache();
    await iliasManager.clearCookiesAndCache();
  }

  Future<void> prepareCachedData() async {
    await campusManager.prepareRelevantModuleRows();
    notifyListeners();
  }

  @override
  void dispose() {
    // unwind the mensa relay chain: a late translate arrival after this
    // provider is gone would notify a dead ChangeNotifier (audit 2026-11-12;
    // latent while the root provider never unmounts - a future remount or
    // logout-recreates-provider change would make it a live assert)
    mensa.removeListener(notifyListeners);
    mensa.dispose();
    super.dispose();
  }
}
