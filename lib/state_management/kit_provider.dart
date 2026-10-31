import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:fuzzywuzzy/fuzzywuzzy.dart';
import 'package:kit_mobile/credentials/models/kit_credentials.dart';
import 'package:kit_mobile/geo/network/KITTopographyManager.dart';
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
  late final IliasFilesProvider iliasFileManager;
  final SignMeUpManager signMeUpManager = SignMeUpManager();

  Future<void>? _signMeUpInFlight;

  /// Resolves once the last started SignMeUp refresh (offer + own
  /// registrations + timetable injection) has finished; the agenda awaits it
  /// before rendering the first frame so assigned groups appear immediately.
  Future<void>? get signMeUpDone => _signMeUpInFlight;

  bool _signMeUpColdRetryDone = false;

  /// SignMeUp needs the campus session, so it runs after login; one failing
  /// fetch must not veto the other refreshes.
  Future<void> fetchSignMeUp() {
    final existing = _signMeUpInFlight;
    if (existing != null) {
      return existing;
    }
    final future = _doFetchSignMeUp();
    _signMeUpInFlight = future;
    return future;
  }

  Future<void> _doFetchSignMeUp() async {
    try {
      final offer = await signMeUpManager.fetch(campusManager);
      // the campus session is cookie-only and dies with the process: on the
      // FIRST refresh after a cold start the login stages may still be in
      // flight (or the token simply expired). Retry once with a delay - but
      // only once per process: fetchMine returns false for perfectly normal
      // steady states (semester break, no plus account) and an unconditional
      // 20 s sleep made every pull-to-refresh hang that long.
      var mine = await signMeUpManager.fetchMine(campusManager);
      if (!mine && !_signMeUpColdRetryDone) {
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
    } finally {
      _signMeUpInFlight = null;
    }
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
    unawaited(topographyManager.fetchPlaces()); // self-contained errors

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
    // stage0 does clearCookiesAndCache(), so anything raced against login
    // either fails outright or burns the cascampus bot-challenge quota.
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
      await campusManager
          .forceRefetchEverything(allModulesAsWell: allModulesAsWell);
      await fetchSignMeUp();
    })();
    _refetchInFlight = future;
    return future.whenComplete(() => _refetchInFlight = null);
  }

  HierarchicTableRow? fuzzyFindHierarchicTableRowSimilarTo(HierarchicTableRow exampleRow) {
    int bestMatch = 0;
    HierarchicTableRow? bestMatchRow;

    for (final row in campusManager.moduleRows) {
      final currentMatch = ratio(row.title, exampleRow.title) + ratio(row.id, exampleRow.id) + ratio(row.type, exampleRow.type);
      if (currentMatch >= bestMatch) {
        bestMatch = currentMatch;
        bestMatchRow = row;
      }
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
    return await campusManager.toggleIsFavorite(cell, inModule, anticipate: visual);
  }

  /// A fuzzywuzzy ratio below this effectively means "some other lecture".
  /// The favorite toggle POSTs to the real KIT server, so it is better to
  /// bail out with false than to add/remove a completely wrong lecture.
  static const int _minFuzzyAcceptScore = 70;

  Future<bool> toggleIsFavoriteFuzzy(String targetRowTitleCellBody, String targetTableCaption, String targetModuleTitle) async {
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
        print("Could not find module with title $targetModuleTitle, best score: $bestMatchScore");
      }
      return false;
    }

    if (kDebugMode) {
      print("Found module with title $targetModuleTitle, score: $bestMatchScore");
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
        print("Could not find table with caption $targetTableCaption, best score: $bestMatchTableScore");
      }
      return false;
    }

    if (kDebugMode) {
      print("Found table with caption $targetTableCaption, score: $bestMatchTableScore");
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
      currentScore = ratio(row.cells[titleCellIndex].body, targetRowTitleCellBody);

      if (currentScore > bestMatchRowScore && row.favoriteToggleCell != null) {
        bestMatchRowScore = currentScore;
        bestMatchCell = row.favoriteToggleCell;
      }
    }

    if (bestMatchCell == null || bestMatchRowScore < _minFuzzyAcceptScore) {
      if (kDebugMode) {
        print("Could not find row with title $targetRowTitleCellBody, score: $bestMatchRowScore");
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
}
