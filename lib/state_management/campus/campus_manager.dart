import 'dart:async';
import 'dart:convert';

import 'package:fuzzywuzzy/fuzzywuzzy.dart';
import 'package:async_locks/async_locks.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:html/parser.dart';
import 'package:http/http.dart' as http;
import 'package:kit_mobile/module_info_table/models/module_info_table.dart';
import 'package:kit_mobile/state_management/kit_login_manager.dart';
import 'package:kit_mobile/state_management/kit_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../module/models/module.dart';
import '../../module_info_table/models/module_info_table_cell.dart';
import '../../parsing/models/hierarchic_table_row.dart';
import '../../student/name.dart';
import '../../student/student.dart';
import '../../timetable/models/timetable_weekly.dart';
import '../../notifications/mei_notifications.dart';
import '../../timetable/models/webcal.dart';
import '../../exams/models/exam_list.dart';
import '../../exams/models/exam_synth.dart';

const _studentDataKey = "DATA_student";

class CampusManager extends KITLoginManager {
  List<HierarchicTableRow> moduleRows = [];
  Map<String, KITModule> rowModules = {}; // INDEXING AS row_id: module
  final Set<String> _moduleRefreshInProgress = {};

  TimetableWeekly timetable = TimetableWeekly();

  List<ExamEntry> exams = [];
  bool examsLoaded = false;
  bool isFetchingExams = false;

  Student student;

  Function() notificationCallback;

  // i don't like this but it kinda does its job (~_~)
  bool isFetchingSchedule = false;
  bool isFetchingModules = false;
  bool allModulesFetched = false;
  bool mostImportantModulesFetched = false;

  /// The session-expiry recovery in [fetchModule] must join KITProvider's
  /// single-flight forceRefetchEverything instead of running its own
  /// clear+refetch cascade concurrently with sibling fetches (which wiped
  /// the session cookies out from under them). Set by KITProvider's ctor;
  /// the fallback stays for unwired (test) owners.
  Future<void> Function({bool allModulesAsWell})? forceRefetchViaOwner;

  Timer? scheduleFetchingTimer;
  DateTime? lastModuleFetchTime;

  String get _timetableSrcCurrentSemesterKey =>
      "DATA_timetableSrc_${KITProvider.currentSemesterString}";

  String get _moduleCacheNamespace =>
      "module_cache_${KITProvider.currentSemesterString}";

  // String _moduleCacheEntryKey(String rowId) {
  //   final encodedRowId = base64Url.encode(utf8.encode(rowId));
  //   return "${_moduleCacheNamespace}_$encodedRowId";
  // }

  String get _moduleCacheLastFetchKey => "${_moduleCacheNamespace}_last_fetch";

  Future<void> loadStudentData() async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getString(_studentDataKey);
    if (stored != null && stored.isNotEmpty) {
      student.copyFrom(Student.fromJson(jsonDecode(stored)));
    }
  }

  Future<void> writeStudentData() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_studentDataKey, jsonEncode(student.toJson()));
  }

  Future<void> clearStudentData() async {
    student.copyFrom(Student.empty);
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_studentDataKey);
  }

  void _updateLastModuleFetchTime(DateTime timestamp) {
    if (lastModuleFetchTime == null ||
        lastModuleFetchTime!.isBefore(timestamp)) {
      lastModuleFetchTime = timestamp;
    }
  }

  // NOTE: such caching is deprecated! TBR:

  // Future<KITModule?> _loadModuleFromCache(HierarchicTableRow row) async {
  //   final prefs = await SharedPreferences.getInstance();
  //   final cached = prefs.getString(_moduleCacheEntryKey(row.id));
  //   if (cached == null) {
  //     return null;
  //   }
  //
  //   try {
  //     final Map<String, dynamic> decoded = jsonDecode(cached);
  //     final html = decoded["html"] as String?;
  //     final fetchedAtStr = decoded["fetchedAt"] as String?;
  //     if (html == null || fetchedAtStr == null) {
  //       return null;
  //     }
  //
  //     final module = KITModule();
  //     module.parseModulePage(html);
  //     module.hierarchicalTableRowId = row.id;
  //     module.row = row;
  //
  //     if (module.grade == "0,0" && row.grade.isNotEmpty) {
  //       module.grade = row.grade;
  //     }
  //
  //     if (module.title.trim().isEmpty) {
  //       module.title = row.title;
  //     }
  //
  //     final fetchedAt = DateTime.tryParse(fetchedAtStr);
  //     if (fetchedAt != null) {
  //       module.lastUpdated = fetchedAt;
  //       _updateLastModuleFetchTime(fetchedAt);
  //     }
  //
  //     rowModules[row.id] = module;
  //     return module;
  //   } catch (error) {
  //     if (kDebugMode) {
  //       print("Failed to load module ${row.id} from cache: $error");
  //     }
  //     return null;
  //   }
  // }

  // NOTE: such caching is deprecated! TBR:

  // Future<void> _saveModuleToCache(
  //     String rowId, String rawHtml, DateTime fetchedAt) async {
  //   final prefs = await SharedPreferences.getInstance();
  //   final payload = jsonEncode({
  //     "html": rawHtml,
  //     "fetchedAt": fetchedAt.toIso8601String(),
  //   });
  //   await prefs.setString(_moduleCacheEntryKey(rowId), payload);
  //   await prefs.setString(
  //       _moduleCacheLastFetchKey, fetchedAt.toIso8601String());
  //   _updateLastModuleFetchTime(fetchedAt);
  // }

  Future<void> _clearModuleCacheForCurrentSemester() async {
    final prefs = await SharedPreferences.getInstance();
    final keys = prefs
        .getKeys()
        .where((key) => key.startsWith(_moduleCacheNamespace))
        .toList(growable: false);
    for (final key in keys) {
      await prefs.remove(key);
    }
    lastModuleFetchTime = null;
  }

  void _triggerBackgroundRefreshIfStale(
      HierarchicTableRow row, KITModule module) {
    if (!module.requiresUpdate) {
      return;
    }

    if (_moduleRefreshInProgress.contains(row.id)) {
      return;
    }

    _moduleRefreshInProgress.add(row.id);
    fetchModule(row, recursiveRetry: false).catchError((error, stackTrace) {
      if (kDebugMode) {
        print("Background refresh failed for ${row.id}: $error");
      }
      return rowModules[row.id] ?? KITModule();
    }).whenComplete(() {
      _moduleRefreshInProgress.remove(row.id);
    });
  }

  bool _isModuleReady(KITModule? module) => module != null && !module.isEmpty;

  List<String> relevantModuleRowIDs = [];
  String get _relevantModuleRowsStorageKey =>
      "RMR ${KITProvider.currentSemesterString}";

  CampusManager(this.student, this.notificationCallback);

  Future<void> forceRefetchEverything({bool allModulesAsWell = true}) async {
    await clearEverything();
    await fetchSchedule();
    await fetchTimetable();
    await fetchExams();
    if (allModulesAsWell) {
      await fetchAllModules();
    }
  }

  Future<void> clearEverything() async {
    scheduleFetchingTimer?.cancel();
    scheduleFetchingTimer = null;
    await _clearModuleCacheForCurrentSemester();
    rowModules.clear();
    _moduleRefreshInProgress.clear();
    await clearCookiesAndCache();
  }

  /// Drops every piece of account-derived in-memory state. CampusManager
  /// (via KITProvider) is created once and SURVIVES logout, so anything not
  /// listed here keeps rendering the previous student's data to the next
  /// account on a shared device until every refetch happens to succeed.
  void wipeAccountMemory() {
    scheduleFetchingTimer?.cancel();
    scheduleFetchingTimer = null;
    moduleRows = [];
    rowModules.clear();
    _moduleRefreshInProgress.clear();
    timetable = TimetableWeekly();
    timetableChanged = false;
    timetableSurfaceBroken = false;
    exams = [];
    examsLoaded = false;
    examsSurfaceBroken = false;
    isFetchingExams = false;
    allModulesFetched = false;
    mostImportantModulesFetched = false;
    // A's accepted tutorials must not ride into B's cache/agenda/pushes:
    // every later fetch injects whatever block is held here, and a failed
    // fetchMine for B (break, plus session) would never replace it
    signMeUpSynth = "";
    examSynth = ""; // registered sittings are account data too
    personalIcs = "";
    personalIcsUrl = "";
    _personalIcsLoaded = false;
  }

  Future<http.Response?> _fetchScheduleStage3ObtainSchedule(
      http.Response previousResponse) async {
    const url =
        "https://cascampus.studium.kit.edu/campus/student/contractview.asp";

    if (tguid == null) {
      await bootTguid();
    }
    if (!cascampusReady) {
      await bootCascampusSession();
    }

    var response = await guardedCasGet("$url?tguid=${tguid ?? ""}");

    if (response.statusCode == 200 && sessionExpired(response.body)) {
      // cascampus SP session died (TTL is ~1h) - re-bootstrap once and refetch
      if (kDebugMode) {
        print("Stage 3: cascampus session expired, re-bootstrapping...");
      }
      cascampusReady = false;
      if (await bootCascampusSession()) {
        response = await guardedCasGet("$url?tguid=${tguid ?? ""}");
      }
    }

    if (isManualRedirectRequired(response)) {
      if (kDebugMode) {
        print("Stage 3: manual redirect is required");
      }
      final currentResponse = await handleNoJSResponse(response.body);
      if (currentResponse == null) {
        if (kDebugMode) {
          print("Failed to handle NO-JS RelayState response!");
        }
        return null;
      }

      response = currentResponse;
    }

    return response;
  }

  Future<void> fetchSchedule(
      {notify = true,
      retryIfFailed = true,
      secondRetryIfFailed = true,
      refreshSession = true,
      startRefreshTimer = true}) async {
    if (isFetchingSchedule) {
      await HapticFeedback.lightImpact();
      Future.delayed(Duration(milliseconds: 200))
          .whenComplete(HapticFeedback.mediumImpact);
      if (kDebugMode) {
        print("Rejected fetchSchedule call: already being fetched");
      }
      return;
    }

    // isFetchingSchedule must be cleared on EVERY exit: the login flow
    // (login -> fetchSchedule) and every retry run INSIDE this call stack,
    // so a held flag deadlocks the login future forever (the reported
    // "app is not responding" freeze). No re-entrancy is possible anyway.
    isFetchingSchedule = true;
    try {
      await _fetchScheduleInner(
        notify: notify,
        retryIfFailed: retryIfFailed,
        secondRetryIfFailed: secondRetryIfFailed,
        refreshSession: refreshSession,
        startRefreshTimer: startRefreshTimer,
      );
    } finally {
      isFetchingSchedule = false;
    }
  }

  Future<void> _fetchScheduleInner({
    required bool notify,
    required bool retryIfFailed,
    required bool secondRetryIfFailed,
    required bool refreshSession,
    required bool startRefreshTimer,
  }) async {
    if (refreshSession) {
      await clearCookiesAndCache();
    }

    final stage0 = await fetchStage0_Init(
        notify: notify,
        retryIfFailed: retryIfFailed,
        secondRetryIfFailed: secondRetryIfFailed);
    if (stage0 < 0) {
      // invalid credentials / no JSESSIONID: posting stage 1-2 credentials
      // against a sessionless jar would only churn the IdP
      if (kDebugMode) print("Stage 0 returned $stage0 - aborting schedule");
      return;
    }
    http.Response currentResponse = await fetchStage1_TryToOpenLoginPage(
        "https://campus.studium.kit.edu/Shibboleth.sso/Login?target=https://campus.studium.kit.edu/exams/registration.php?login=1");

    // stage 2
    final stage2Response = await fetchStage2_(currentResponse);
    if (stage2Response == null) {
      if (kDebugMode) {
        print("Stage 2 failed!");
      }
    } else {
      currentResponse = stage2Response;
    }

    // stage 3
    final stage3Response =
        await _fetchScheduleStage3ObtainSchedule(currentResponse);
    if (stage3Response == null) {
      if (kDebugMode) {
        print("Stage 3 failed!");
      }
      return;
    }
    currentResponse = stage3Response;

    // parse the response
    var document = parse(currentResponse.body);

    String firstName = "", lastName = "", matrn = "";
    String degreeProgram = "";
    String ectsAcquired = "";

    // parsing name and matrikelnummer (contained in a div.pagination)
    document.getElementsByClassName("pagination").forEach((element) {
      final divs = element.getElementsByTagName("div");
      if (divs.isNotEmpty) {
        var nameAndMatrn = divs[0].innerHtml;
        nameAndMatrn = nameAndMatrn
            .replaceAll("\n", "")
            .replaceAll(" ", "")
            .replaceAll("(", ",")
            .replaceAll(")", "");
        final nameAndMatrnSplit = nameAndMatrn.split(",");
        if (nameAndMatrnSplit.isNotEmpty) {
          lastName = nameAndMatrnSplit.removeAt(0);
        }

        if (nameAndMatrnSplit.isNotEmpty) {
          firstName = nameAndMatrnSplit.removeAt(0);
        }

        if (nameAndMatrnSplit.isNotEmpty) {
          matrn = nameAndMatrnSplit.removeAt(0);
        }
      }
    });

    Map<int, List<HierarchicTableRow>> rowsSorted = {};

    document.getElementsByClassName("hierarchy1").forEach((element) {
      try {
        HierarchicTableRow.parseTr(element, rowsSorted);
      } catch (exc) {
        if (kDebugMode) {
          print(exc);
        }
      }
    });

    _clearRows(clearRelevants: student.name.firstName.isEmpty);
    document.getElementsByClassName("tablecontent").forEach((tbody) {
      tbody.getElementsByTagName("tr").forEach((tr) {
        try {
          final row = HierarchicTableRow.parseTr(tr, rowsSorted);
          if (row != null) {
            moduleRows.add(row);
          }
        } catch (exc) {
          if (kDebugMode) {
            print(exc);
          }
        }
      });
    });

    // empty/odd table shape (rowsSorted[1] unset) - not necessarily an error:
    // a freshly enrolled student legitimately has no grades row yet
    if (rowsSorted[1]?.first.grade.replaceAll(",", ".") == null) {
      if (kDebugMode) {
        print(rowsSorted);
        print("No grade row; profile fields left as-is. Retrying once...");
      }
      if (retryIfFailed) {
        // Retry in the inner directly: the public entry is unreachable from
        // here (isFetchingSchedule is held by *this* frame, so its guard
        // rejected every retry and made this path a no-op haptic twitch).
        // Direct recursion is safe now - the flag stays owned by this frame
        // and the inner call is awaited.
        await _fetchScheduleInner(
            notify: true,
            retryIfFailed: secondRetryIfFailed,
            secondRetryIfFailed: false,
            refreshSession: false,
            startRefreshTimer: false);
        // the inner fetch parsed its own fresh page and owns ready/notify
        if (ready) return;
      }
      // Still no grades row after the retry: that is the NORMAL state of a
      // freshly enrolled student, not an error. Bailing out here used to
      // leave ready=false forever, so login() bounced correct credentials
      // every single time for first-semester users. Continue with the data
      // that does exist; cleanCell() covers the missing grade cell.
    }

    degreeProgram = rowsSorted[1]?.first.title ?? "";
    ectsAcquired = rowsSorted[1]?.first.pointsAcquired ?? "";

    String cleanCell(String? raw) {
      final cleaned = (raw ?? "")
          .replaceAll("&nbsp;", " ")
          .replaceAll(RegExp(r"\s+"), " ")
          .trim();
      return cleaned.isEmpty ? "0,0" : cleaned;
    }

    student.set(
        name: Name(firstName: firstName, lastName: lastName),
        matriculationNumber: matrn,
        degreeProgram: degreeProgram,
        avgMark: cleanCell(rowsSorted[1]?.first.grade),
        ectsAcquired: ectsAcquired);

    await writeStudentData();

    // fetchTimetable().then((_) {
    //   fetchAllModules();
    // });

    ready = true;
    notificationCallback();

    if (kDebugMode) {
      print("Got profile data!");
    }

    // TODO: reenable
    // tmp: create a lock or something to prevent interface glitches
    if (startRefreshTimer) {
      // scheduleFetchingTimer ??= Timer(const Duration(minutes: 1), forceRefetchEverything);
    }
  }

  Future<void> fetchModulesForRows(List<HierarchicTableRow> rowsToFetch,
      {inParallel = true}) async {
    if (rowsToFetch.isEmpty) {
      return;
    }

    if (inParallel) {
      List<Future<KITModule>> newModuleFutures = [];

      for (final row in rowsToFetch) {
        if (row.level < 4) {
          continue;
        }

        final newModuleFuture =
            getOrFetchModuleForRow(row, retryIfFailed: false);
        newModuleFutures.add(newModuleFuture);
      }
      // one timeout/socket failure must not reject Future.wait and leave
      // isFetchingModules stuck true with all sibling results lost
      final newModules = (await Future.wait(newModuleFutures.map(
              (f) => f.then<KITModule?>((m) => m).catchError((_) => null))))
          .whereType<KITModule>();

      // Admission (current-feed title, else the legacy ILIAS link) is
      // decided inside addRelevantModuleRow; a link gate here is what hid
      // "Advanced Mathematics I", whose CampusKIT page has no ILIAS course
      // while the lecture IS on the WS timetable.
      for (final newModule in newModules) {
        if (newModule.row != null) {
          addRelevantModuleRow(newModule.row!);
        }
      }
    } else {
      for (final row in rowsToFetch) {
        if (row.level < 4) {
          continue;
        }

        await getOrFetchModuleForRow(row, retryIfFailed: false)
            .catchError((_) => KITModule());
        addRelevantModuleRow(row);
      }
    }
  }

  Future<void> fetchAllModules(
      {inParallel = true, onlyMostImportantOnes = false}) async {
    isFetchingModules = true;
    // "all fetched" must not survive a re-fetch: it is only ever set true
    // below, so a stale true from an earlier run made everything gated on
    // it skip the modules this run failed to load
    allModulesFetched = false;
    mostImportantModulesFetched = false;

    if (kDebugMode) {
      print("Fetching all modules");
    }

    await prepareRelevantModuleRows();
    List<HierarchicTableRow> rowsToFetch = [], lessImportantRows = [];
    List<HierarchicTableRow> preSort =
        List<HierarchicTableRow>.from(moduleRows);
    preSort.sort((row1, row2) {
      return -(row1.relevancyRank - row2.relevancyRank);
    });

    for (final row in preSort) {
      if (relevantModuleRowIDs.contains(row.id)) {
        rowsToFetch.add(row);
      } else {
        lessImportantRows.add(row);
      }
    }


    if (rowsToFetch.isEmpty) {
      rowsToFetch = lessImportantRows;
      lessImportantRows = [];
    }

    if (kDebugMode) {
      for (final row in rowsToFetch) {
        print("Fethcing ${row.title}");
      }
    }

    try {
      await fetchModulesForRows(rowsToFetch, inParallel: inParallel);
      mostImportantModulesFetched = true;
      if (!onlyMostImportantOnes) {
        await fetchModulesForRows(lessImportantRows, inParallel: inParallel);
        allModulesFetched = true;
      }
    } finally {
      // the flag is what every spinner waits on; it may never outlive the fetch
      isFetchingModules = false;
    }
    if (kDebugMode) {
      print("Finished fetching modules!");
    }
  }

  Future<KITModule> fetchModule(HierarchicTableRow row,
      {recursiveRetry = true, userInitiated = false}) async {
    final url = row.href;

    final response = await guardedCasGet(url);

    // An expired cascampus session answers with a 200 "Sitzung abgelaufen"
    // page. parseModulePage keeps every field whose DOM node is absent, so
    // parsing it INTO the cached instance wiped its good tables and stamped
    // lastUpdated=now (fresh for 2 days) - silent data loss instead of a
    // visible failure. Detect first, re-boot, retry once, and parse into a
    // fresh instance that only replaces the cache when non-empty.
    if (response.statusCode == 200 && sessionExpired(response.body)) {
      if (cascampusReady) {
        cascampusReady = false;
        await bootCascampusSession();
        return fetchModule(row,
            recursiveRetry: recursiveRetry, userInitiated: userInitiated);
      }
    }

    var module = KITModule();
    module.parseModulePage(response.body);

    final cached = rowModules[row.id];
    if (module.isEmpty && cached != null && !cached.isEmpty) {
      // dead/changed page against a live cache: keep the cache authoritative
      module = cached;
    } else if (!module.isEmpty) {
      module.row = row;
      module.hierarchicalTableRowId = row.id;
      rowModules[row.id] = module;
    }

    if (module.title.trim().isEmpty) {
      module.title = row.title;
    }

    module.row = row;
    module.hierarchicalTableRowId = row.id;

    // NOTE: such caching is deprecated! TBR

    // try {
    //   await _saveModuleToCache(row.id, response.body, module.lastUpdated);
    // } catch (error) {
    //   if (kDebugMode) {
    //     print("Failed to persist module ${row.id}: $error");
    //   }
    // }

    _updateLastModuleFetchTime(module.lastUpdated);

    final prevModuleData = rowModules[module.hierarchicalTableRowId];
    if (prevModuleData != null && module.isEmpty && !prevModuleData.isEmpty) {
      addRelevantModuleRow(row);
      return prevModuleData;
    }

    if (module.isEmpty && recursiveRetry) {
      if (kDebugMode) {
        print(
            "Failed to fetch the module. Possible reason: session expired. Retrying...");
      }
      // join the owner's single-flight when wired: calling
      // forceRefetchEverything directly cleared cookies while sibling
      // fetches of a concurrent refresh cascade were still in flight
      await (forceRefetchViaOwner?.call(allModulesAsWell: !userInitiated) ??
          forceRefetchEverything(allModulesAsWell: !userInitiated));
      return fetchModule(row, recursiveRetry: false);
    }

    rowModules[module.hierarchicalTableRowId] = module;

    addRelevantModuleRow(row);
    _extractUsefulDataFromModule(module);
    return module;
  }

  Future<KITModule> getOrFetchModuleForRow(HierarchicTableRow row,
      {retryIfFailed = true, userInitiated = false}) async {
    var module = rowModules[row.id];

    if (_isModuleReady(module)) {
      final readyModule = module!;
      _triggerBackgroundRefreshIfStale(row, readyModule);
      return readyModule;
    }


    final fetchedModule = await fetchModule(row,
        recursiveRetry: retryIfFailed, userInitiated: userInitiated);
    return fetchedModule;
  }

  /// Best module title known for a row id: fetched page title first, then
  /// the Studienverlauf row's own title; null while neither is loaded
  /// (nothing known => the feed gate must not prune the entry).
  String? _knownModuleTitle(String rowId) {
    final title = _moduleFeedTitle(rowModules[rowId]);
    if (title != null) return title;
    for (final row in moduleRows) {
      if (row.id == rowId && row.title.trim().isNotEmpty) return row.title;
    }
    return null;
  }

  String? _moduleFeedTitle(KITModule? module, [HierarchicTableRow? row]) {
    final title = module?.title.trim() ?? "";
    if (title.isNotEmpty) return title;
    final rowTitle = (row ?? module?.row)?.title.trim() ?? "";
    return rowTitle.isEmpty ? null : rowTitle;
  }

  Future<void> prepareRelevantModuleRows() async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getStringList(_relevantModuleRowsStorageKey);
    if (kDebugMode) {
      print("Stored $stored");
    }
    var ids = stored ?? relevantModuleRowIDs;
    // legacy "RMR <semester>" lists were admitted by the ILIAS-link
    // heuristic and can name future-semester modules; once the feed has
    // spoken, drop every stored id whose title is known not to be on the
    // current timetable (EM-III-era entries self-heal on the first
    // refetch). Unknown titles stay: missing information must never
    // empty the card.
    final keys = enrolledLectureTitles;
    if (keys.isNotEmpty) {
      final kept = ids.where((id) {
        final title = _knownModuleTitle(id);
        return title == null ||
            moduleKeyMatchesLectureKey(lectureTitleKey(title), keys);
      }).toList();
      if (kept.length != ids.length) {
        ids = kept;
        await prefs.setStringList(_relevantModuleRowsStorageKey, kept);
      }
    }
    // duplicates were admitted before admission was de-duplicated by title
    // (the on-device card showed "Mechanical Design A" twice); a stored
    // pair collapses through the same tie-break a live duplicate gets
    final deduped = _dedupeRelevantIds(ids);
    if (deduped.length != ids.length) {
      ids = deduped;
      await prefs.setStringList(_relevantModuleRowsStorageKey, ids);
    }
    relevantModuleRowIDs = ids;

    final lastFetchRaw = prefs.getString(_moduleCacheLastFetchKey);
    final lastFetchParsed =
        lastFetchRaw != null ? DateTime.tryParse(lastFetchRaw) : null;
    if (lastFetchParsed != null) {
      lastModuleFetchTime = lastFetchParsed;
    }
  }

  Future<void> storeRelevantModuleRows() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
        _relevantModuleRowsStorageKey, relevantModuleRowIDs);
  }

  Future<void> resetRelevantModules() async {
    relevantModuleRowIDs = [];
    // remove, don't persist an empty list: the key is user data too
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_relevantModuleRowsStorageKey);
    if (kDebugMode) {
      print("Done resetting relevant modules!");
    }
  }

  /// An ILIAS course link only counts when it is actually there: freshly
  /// parsed module pages leave `iliasLink` empty.
  static bool _hasIliasLink(KITModule? module) =>
      module?.iliasLink?.isNotEmpty ?? false;

  /// Normalized feed title of an admitted card entry, or null while nothing
  /// is known about that row yet (no title -> no title rule may judge it).
  String? _relevantRowKey(String rowId) {
    final title = _knownModuleTitle(rowId);
    return title == null ? null : lectureTitleKey(title);
  }

  /// Already-admitted row whose normalized title denotes the same lecture as
  /// [key] (see [moduleKeysDenoteSameModule]); null when the card has no
  /// such entry.
  String? _clashingRelevantRowId(String key, {required String exceptId}) {
    if (key.isEmpty) return null;
    for (final id in relevantModuleRowIDs) {
      if (id == exceptId) continue;
      final other = _relevantRowKey(id);
      if (other != null && moduleKeysDenoteSameModule(key, other)) return id;
    }
    return null;
  }

  /// Collapse card entries naming the same module twice - legacy stores
  /// written before admission was de-duplicated (see
  /// [moduleKeysDenoteSameModule]). Keeps the position of the first copy and
  /// the copy that carries the ILIAS link, which is the same tie-break
  /// [addRelevantModuleRow] applies to an arriving duplicate.
  List<String> _dedupeRelevantIds(List<String> ids) {
    final kept = <String>[];
    final keptKeys = <String?>[];
    for (final id in ids) {
      if (kept.contains(id)) continue; // the very same row listed twice
      final key = _relevantRowKey(id);
      var clashAt = -1;
      if (key != null) {
        for (var i = 0; i < kept.length; i++) {
          if (moduleKeysDenoteSameModule(key, keptKeys[i] ?? "")) {
            clashAt = i;
            break;
          }
        }
      }
      if (clashAt < 0) {
        kept.add(id);
        keptKeys.add(key);
      } else if (!_hasIliasLink(rowModules[kept[clashAt]]) &&
          _hasIliasLink(rowModules[id])) {
        kept[clashAt] = id;
        keptKeys[clashAt] = key;
      }
    }
    return kept;
  }

  final Lock _addRelevantModuleLock = Lock();

  /// A module belongs to the "current modules" card iff its normalized
  /// title is on the CURRENT merged timetable feed: the Studienverlauf
  /// source tree is CampusKIT's whole-programme list, so the old
  /// ILIAS-link heuristic admitted future-semester modules (EM III in
  /// WS 26/27) while hiding current ones whose page carries no ILIAS
  /// course ("Advanced Mathematics I"). Until the first successful feed
  /// parse there are no lecture keys at all - then the legacy ILIAS-link
  /// rule still admits, so a fresh or offline first start never leaves
  /// the card spuriously dead-empty.
  ///
  /// Admission is also the single place that keeps ONE card per module:
  /// the tree can carry the same module under two headings, and each copy
  /// has its own row id (see [moduleKeysDenoteSameModule]).
  Future<void> addRelevantModuleRow(HierarchicTableRow row,
      {keepSorted = true}) async {
    await _addRelevantModuleLock.run(() async {
      final module = rowModules[row.id];
      if (module == null) {
        if (kDebugMode) print("Somehow module is null :(");
        return;
      }

      // normalized feed title of THIS row: both the feed gate and the
      // duplicate-card guard below judge nothing but this key
      final moduleKey = lectureTitleKey(_moduleFeedTitle(module, row) ?? "");
      final keys = enrolledLectureTitles;
      if (keys.isEmpty) {
        // no feed yet: double-check the legacy way (there must be an
        // ilias-course link)
        if (module.iliasLink == null || module.iliasLink!.isEmpty) {
          if (kDebugMode) print("${module.title} ilias link is not there :(");
          return;
        }
      } else if (!moduleKeyMatchesLectureKey(moduleKey, keys)) {
        // double-check the feed rule (the fetch call sites pass every
        // fetched row through here)
        if (kDebugMode) {
          print("${module.title} is not on the current timetable feed");
        }
        return;
      }

      // One card per module, not per Studienverlauf row: the tree can carry
      // the same module twice (two section headings -> two rows, and level
      // plus the module-code year are part of the id, so both got a card).
      final clash = _clashingRelevantRowId(moduleKey, exceptId: row.id);
      if (clash != null) {
        // which copy of a duplicate arrives first is up to the parallel
        // fetch, so the tie-break is data quality and not arrival order:
        // the card keeps the copy whose page carries the ILIAS course
        if (_hasIliasLink(rowModules[clash]) || !_hasIliasLink(module)) {
          if (kDebugMode) {
            print("${module.title} is already on the card as $clash");
          }
          return;
        }
        relevantModuleRowIDs.remove(clash);
      }
      // there is not so many of them
      while (relevantModuleRowIDs.remove(row.id)) {
        if (kDebugMode) print("There already exists this module");
      }

      if (keepSorted) {
        bool hasNumber = false;
        for (final num in [0, 1, 2, 3, 4, 5, 6, 7, 8, 9]) {
          if (row.grade.contains("$num")) {
            hasNumber = true;
            break;
          }
        }

        if (hasNumber) {
          relevantModuleRowIDs.add(row.id);
        } else {
          int insertAt = 0;
          while (insertAt < relevantModuleRowIDs.length &&
              !module.hasFavoriteChild &&
              (rowModules[relevantModuleRowIDs[insertAt]]?.hasFavoriteChild ??
                  false)) {
            insertAt++;
          }
          relevantModuleRowIDs.insert(insertAt, row.id);
        }
      } else {
        relevantModuleRowIDs.add(row.id);
      }

      storeRelevantModuleRows();
      notificationCallback();
    });
  }

  void _extractUsefulDataFromModule(KITModule module) {}

  Future<bool> toggleIsFavorite(ModuleInfoTableCell cell, KITModule inModule,
      {anticipate = true}) async {
    if (cell.objectValue.isEmpty) {
      if (kDebugMode) {
        print("Failed to toggle a non-toggable cell ${cell.body}");
      }
      return false;
    }

    String action =
        cell.isFavorite ? "removeeventfavorite" : "addeventfavorite";
    bool newSupposedValue = !cell.isFavorite;
    if (anticipate) {
      cell.isFavorite = newSupposedValue;
      notificationCallback();
    }

    // const url =
    //     "https://campus.kit.edu/sp/campus/student/specificModuleView.asp";
    const url =
        "https://cascampus.studium.kit.edu/campus/student/specificBrickView.asp";

    final response = await guardedCasPost(url, {action: cell.objectValue});
    final isOk =
        !response.body.toLowerCase().contains("sitzung ist abgelaufen");

    for (final row in moduleRows) {
      if (row.id == inModule.hierarchicalTableRowId) {
        fetchModule(row, userInitiated: true).then((_) => fetchTimetable());
        break;
      }
    }

    if (!isOk) {
      cell.isFavorite = !cell.isFavorite;
    }

    notificationCallback();

    return isOk;
  }

  // Rows:
  void _clearRows({clearRelevants = false}) {
    moduleRows = [];
    if (clearRelevants) {
      relevantModuleRowIDs = [];
    }
  }
  // ---- WebCal ICS timetable source (primary; token URL, no bot wall) ----

  static const _webcalUrlKey = "DATA_webcalUrl";
  static const _webcalIcsCacheKey = "DATA_webcalIcsCache";
  static const _webcalFingerprintKey = "DATA_webcalFingerprint";
  static const _webcalChangesKey = "DATA_webcalChanges";
  // fingerprint of the feed URL the cached ICS/fingerprint came from; a
  // different source (re-provisioned token URL, test-seam build) means the
  // stored baseline describes ANOTHER calendar - diffing across sources
  // produced a 50-delta phantom CHAINED band during E2E runs
  static const _webcalFeedSourceKey = "DATA_webcalFeedSource";

  bool timetableChanged = false;

  // ---- SignMeUp synthetic events (tutorials the webcal does not carry) ----
  // VEVENT text merged into the cached feed at every write, bracketed by
  // sentinel lines so re-injection is idempotent and change detection can
  // strip it again.
  static const synthBegin = "X-SIGNMEUP-SYNTH-BEGIN";
  static const synthEnd = "X-SIGNMEUP-SYNTH-END";
  String signMeUpSynth = "";

  static String stripSignMeUpSynth(String raw) {
    final b = raw.indexOf(synthBegin);
    if (b < 0) return raw;
    final e = raw.indexOf(synthEnd);
    if (e < 0) return raw.substring(0, b);
    return raw.substring(0, b) + raw.substring(e + synthEnd.length + 2);
  }

  /// The sentinel-wrapped block currently embedded in [raw] ("" if none);
  /// lets the background isolate carry the student's tutorials across a
  /// fresh feed fetch.
  static String extractSignMeUpSynth(String raw) {
    final b = raw.indexOf(synthBegin);
    if (b < 0) return "";
    final e = raw.indexOf(synthEnd);
    if (e < 0 || e < b) return "";
    return raw.substring(b + synthBegin.length + 2, e);
  }

  static String injectSignMeUpSynth(String raw, String block) {
    final base = stripSignMeUpSynth(raw);
    if (block.isEmpty) return base;
    final wrapped = "$synthBegin\r\n$block$synthEnd\r\n";
    final at = base.lastIndexOf("END:VCALENDAR");
    if (at < 0) return "$base$wrapped";
    return base.replaceRange(at, at, wrapped);
  }

  // ---- Exam synthetic events (registered sittings from the exam list) ----
  // Same sentinel-bracketed VEVENT text as the SignMeUp block above: built
  // whenever the exam list parses successfully (exam_synth.dart, see
  // _fetchExamsInner) and re-merged at every cache write, so grid, agenda,
  // digest, reminders and the ICS export treat registered exams like
  // ordinary feed events without knowing where they came from.
  static const examSynthBegin = "X-EXAM-SYNTH-BEGIN";
  static const examSynthEnd = "X-EXAM-SYNTH-END";
  String examSynth = "";

  static String stripExamSynth(String raw) {
    final b = raw.indexOf(examSynthBegin);
    if (b < 0) return raw;
    final e = raw.indexOf(examSynthEnd);
    if (e < 0) return raw.substring(0, b);
    return raw.substring(0, b) + raw.substring(e + examSynthEnd.length + 2);
  }

  /// The sentinel-wrapped exam block embedded in [raw] ("" if none); lets
  /// the background isolate carry the sittings across a fresh feed fetch
  /// (mirrors extractSignMeUpSynth).
  static String extractExamSynth(String raw) {
    final b = raw.indexOf(examSynthBegin);
    if (b < 0) return "";
    final e = raw.indexOf(examSynthEnd);
    if (e < 0 || e < b) return "";
    return raw.substring(b + examSynthBegin.length + 2, e);
  }

  static String injectExamSynth(String raw, String block) {
    final base = stripExamSynth(raw);
    if (block.isEmpty) return base;
    final wrapped = "$examSynthBegin\r\n$block$examSynthEnd\r\n";
    final at = base.lastIndexOf("END:VCALENDAR");
    if (at < 0) return "$base$wrapped";
    return base.replaceRange(at, at, wrapped);
  }

  // ---- personal / faculty timetable ICS ----
  // The faculty sends first-semester MEI a timetable ICS by e-mail because
  // the big lectures (AM I, EM I, MSE I, MD A) carry no Belegungspflicht
  // and therefore NEVER appear in the CampusKIT webcal feed. Without this
  // the agenda showed one real lecture out of a 14-event week. Merged into
  // the same cache as the subscription so agenda, change detection, lecture
  // reminders and the exam relevance gate treat those events equally.
  static const personalBegin = "X-PERSONAL-ICS-BEGIN";
  static const personalEnd = "X-PERSONAL-ICS-END";
  static const _personalIcsKey = "DATA_personalIcs";
  static const _personalIcsUrlKey = "DATA_personalIcsUrl";
  String personalIcs = "";
  String personalIcsUrl = "";
  bool _personalIcsLoaded = false;

  static String stripPersonalIcs(String raw) {
    final b = raw.indexOf(personalBegin);
    if (b < 0) return raw;
    final e = raw.indexOf(personalEnd);
    if (e < 0) return raw.substring(0, b);
    return raw.substring(0, b) + raw.substring(e + personalEnd.length + 2);
  }

  static String extractPersonalIcs(String raw) {
    final b = raw.indexOf(personalBegin);
    if (b < 0) return "";
    final e = raw.indexOf(personalEnd);
    if (e < 0 || e < b) return "";
    return raw.substring(b + personalBegin.length + 2, e);
  }

  static String injectPersonalIcs(String raw, String block) {
    final base = stripPersonalIcs(raw);
    if (block.isEmpty) return base;
    final wrapped = "$personalBegin\r\n$block$personalEnd\r\n";
    final at = base.lastIndexOf("END:VCALENDAR");
    if (at < 0) return "$base$wrapped";
    return base.replaceRange(at, at, wrapped);
  }

  /// Reads the persisted block once per process (settings screen can open
  /// before any feed work has run).
  Future<void> ensurePersonalIcsLoaded() async {
    if (_personalIcsLoaded) return;
    _personalIcsLoaded = true;
    final prefs = await SharedPreferences.getInstance();
    personalIcs = prefs.getString(_personalIcsKey) ?? "";
    personalIcsUrl = prefs.getString(_personalIcsUrlKey) ?? "";
  }

  /// Accepts a full ICS file body; keeps only the VEVENT blocks (calendar
  /// headers would be invalid inside the subscription's VCALENDAR).
  /// Returns null on success, "bad"/"fetch" for user-facing errors.
  Future<String?> setPersonalIcsFromRaw(String ics) async {
    final blocks = RegExp("BEGIN:VEVENT.*?END:VEVENT", dotAll: true)
        .allMatches(ics)
        .map((m) => m.group(0)!);
    var block = blocks.join("\r\n");
    if (block.isEmpty) return "bad";
    if (!block.endsWith("\r\n")) block = "$block\r\n";
    if (WebcalFeed.parse("BEGIN:VCALENDAR\r\n$block END:VCALENDAR\r\n") ==
        null) {
      return "bad";
    }
    _personalIcsLoaded = true;
    personalIcs = block;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_personalIcsKey, block);
    await _applyPersonalIcs(prefs);
    return null;
  }

  Future<String?> setPersonalIcsFromUrl(String url) async {
    final trimmed = url.trim();
    if (!trimmed.startsWith("http")) return "bad";
    final response = await netGet(Uri.parse(trimmed));
    if (response.statusCode != 200 ||
        !response.body.contains("BEGIN:VEVENT")) {
      return "fetch";
    }
    final err = await setPersonalIcsFromRaw(response.body);
    if (err == null) {
      personalIcsUrl = trimmed;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_personalIcsUrlKey, trimmed);
    }
    return err;
  }

  static DateTime? _lastPersonalIcsRefresh;

  /// An ICS imported from a URL is a snapshot; this quietly re-fetches it
  /// (bounded, at most once per 30 min) so calendars on reachable hosts
  /// pick up new events without a manual re-import. Errors are swallowed:
  /// the previous copy always stays in force.
  Future<void> refreshPersonalIcsFromUrl() async {
    final url = personalIcsUrl;
    if (url.isEmpty) return;
    final last = _lastPersonalIcsRefresh;
    if (last != null &&
        DateTime.now().difference(last) < const Duration(minutes: 30)) {
      return;
    }
    _lastPersonalIcsRefresh = DateTime.now();
    try {
      final response =
          await netGet(Uri.parse(url)).timeout(const Duration(seconds: 20));
      if (response.statusCode != 200 ||
          !response.body.contains("BEGIN:VEVENT")) {
        return;
      }
      final blocks = RegExp("BEGIN:VEVENT.*?END:VEVENT", dotAll: true)
          .allMatches(response.body)
          .map((m) => m.group(0)!);
      var block = blocks.join("\r\n");
      if (!block.endsWith("\r\n")) block = "$block\r\n";
      if (block.isEmpty || block == personalIcs) return;
      final err = await setPersonalIcsFromRaw(response.body);
      if (err != null && kDebugMode) {
        print("Personal ICS refresh rejected: $err");
      }
    } catch (_) {}
  }

  Future<void> clearPersonalIcs() async {
    _personalIcsLoaded = true;
    personalIcs = "";
    personalIcsUrl = "";
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_personalIcsKey);
    await prefs.remove(_personalIcsUrlKey);
    await _applyPersonalIcs(prefs);
  }

  /// Re-embeds the block into whatever feed cache exists (or a stub
  /// VCALENDAR when the subscription has not been fetched yet, so an
  /// offline import is still visible immediately) and rebuilds everything
  /// derived from the cache.
  Future<void> _applyPersonalIcs(SharedPreferences prefs) async {
    var cached = prefs.getString(_webcalIcsCacheKey) ?? "";
    if (!cached.contains("BEGIN:VCALENDAR")) {
      cached = "";
      if (personalIcs.isEmpty) {
        notificationCallback();
        return;
      }
    }
    final base =
        cached.isEmpty ? "BEGIN:VCALENDAR\r\nEND:VCALENDAR\r\n" : cached;
    final merged = injectPersonalIcs(base, personalIcs);
    await prefs.setString(_webcalIcsCacheKey, merged);
    final feed = WebcalFeed.parse(merged);
    if (feed != null) {
      timetable = gridTemplate(feed);
      rememberEnrolledTitles(feed);
      unawaited(MeiNotifications.scheduleLectureReminders(feed));
      unawaited(MeiNotifications.scheduleMorningDigest(feed));
    }
    notificationCallback();
  }

  /// Called after a SignMeUp refresh: rebuilds the cached feed and the
  /// in-memory weekly template so the grid shows assigned groups at once.
  Future<void> reapplySignMeUpSynth(String block) async {
    if (block == signMeUpSynth) return;
    signMeUpSynth = block;
    final prefs = await SharedPreferences.getInstance();
    final cached = prefs.getString(_webcalIcsCacheKey);
    if (cached == null || !cached.contains("BEGIN:VCALENDAR")) return;
    final synth = injectSignMeUpSynth(cached, block);
    await prefs.setString(_webcalIcsCacheKey, synth);
    final feed = WebcalFeed.parse(synth);
    if (feed != null) {
      timetable = gridTemplate(feed);
      rememberEnrolledTitles(feed);
      unawaited(MeiNotifications.scheduleLectureReminders(feed));
      // digest must see the injected tutorials too: without this, the
      // "Today: N classes · First at ..." body kept the pre-SignMeUp set
      unawaited(MeiNotifications.scheduleMorningDigest(feed));
      notificationCallback();
    }
  }

  /// Called after a successful exam-list fetch: rebuilds the cached feed
  /// (and everything derived from it) with the registered exam sittings
  /// merged in - the exact path reapplySignMeUpSynth uses for tutorials.
  ///
  /// The no-op guard compares against the PERSISTED cache, not just the
  /// in-memory copy: after a restart both are empty while the cache still
  /// embeds last run's block - returning early on `block == examSynth`
  /// there would let stale Klausur events live forever. `merged == cached`
  /// is the honest "nothing to do", and because the emitter is fully
  /// deterministic (DTSTAMP derived from the sitting, exam_synth.dart) it
  /// still fires on every routine refetch.
  Future<void> reapplyExamSynth(String block) async {
    final prefs = await SharedPreferences.getInstance();
    final cached = prefs.getString(_webcalIcsCacheKey);
    if (cached == null || !cached.contains("BEGIN:VCALENDAR")) {
      examSynth = block;
      return;
    }
    final merged = injectExamSynth(cached, block);
    examSynth = block;
    if (merged == cached) return;
    await prefs.setString(_webcalIcsCacheKey, merged);
    final feed = WebcalFeed.parse(merged);
    if (feed != null) {
      timetable = gridTemplate(feed);
      rememberEnrolledTitles(feed);
      unawaited(MeiNotifications.scheduleLectureReminders(feed));
      unawaited(MeiNotifications.scheduleMorningDigest(feed));
      notificationCallback();
    }
  }

  /// Home grid template WITHOUT the exam-synth occurrences: toWeeklyTemplate
  /// is a per-(weekday, block) ONE-appointment template - a one-off exam
  /// would repeat on every same-weekday carousel page, lose block collisions
  /// to the recurring lectures and vanish on weekends entirely. The sittings
  /// live in agenda / digest / reminders / ICS export, which read
  /// feed.occurrences and the raw cache directly.
  @visibleForTesting
  static TimetableWeekly gridTemplate(WebcalFeed feed) => WebcalFeed(
          occurrences: feed.occurrences
              .where((o) => !o.uid.startsWith(examSynthUidPrefix))
              .toList(),
          raw: feed.raw)
      .toWeeklyTemplate();

  /// Cold-start carry-over, mirroring [ensurePersonalIcsLoaded]'s
  /// tri-state: until this process has PROVEN the exam list (a successful
  /// fetchExams) it has no veto over the block - the in-memory copy is
  /// empty on every fresh start, and writing THAT into the cache would
  /// delete last run's sittings (and cancel their alarms) with nothing
  /// restoring them once the exam fetch then fails.
  @visibleForTesting
  Future<void> carryExamSynthFromCache() async {
    if (examsLoaded || examSynth.isNotEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    final carried =
        extractExamSynth(prefs.getString(_webcalIcsCacheKey) ?? "");
    if (carried.isNotEmpty) examSynth = carried;
  }

  // Loud-failure flags: parser returned nothing on a page that fetched fine
  // (= KIT changed the markup) as opposed to a dead session (auto-recovered).
  bool timetableSurfaceBroken = false;
  bool examsSurfaceBroken = false;

  // The cascampus `possibleexams` view lists the exam offers of the
  // student's ENTIRE degree-programme catalogue: a first-semester student
  // gets "Act now" + deadline notifications for exams of lectures they
  // will attend two years later (verified live: 4 false alarms in WS 26/27
  // for IT&DS / ProdOps / EM III / CAE). The webcal subscription is the
  // only current-semester ground truth the app has, so registration
  // urgency is gated on the exam's lecture appearing on the timetable.
  Set<String> enrolledLectureTitles = {};

  static String lectureTitleKey(String raw) {
    var t = raw.toLowerCase();
    final comma = t.indexOf(", ");
    if (comma > 10) {
      t = t.substring(0, comma); // "Title (V), Schulze" -> drop lecturer
    }
    t = t.replaceAll(
        RegExp(r'^(vorlesung|tutorial|tu|uebung|ubung|übung|seminar|praktikum|klausur)\s*[:\-–]\s*'),
        "");
    // faculty ICS exports carry "- 3161010" / "- 2145191/2145192" course
    // number tails and "(Tutorial - Group 4)" labels; neither belongs in a
    // title key (the digits would poison the roman-numeral guard below)
    t = t.replaceAll(RegExp(r"\s*-\s*[\d/]{4,}\s*$"), "");
    t = t.replaceAll(RegExp(r"group\s+[a-z0-9]+\s*"), " ");
    t = t.replaceAll(
        RegExp(r'\((v|ue|ü|v u ue|v/u|course|exercise|lecture)\)'), " ");
    t = t.replaceAll(RegExp(r"[^a-z0-9äöüß]+"), " ").trim();
    return t;
  }

  /// "I"/"III"/"2" tokens: "Engineering Mechanics I" and "... III" share a
  /// 90+ fuzzy ratio but are different modules - never match across them.
  static final _numToken = RegExp(r"^(?:\d+|[ivx]+)$");
  static Set<String> _numericTokens(String key) =>
      key.split(" ").where((w) => _numToken.hasMatch(w)).toSet();

  /// The exam catalogue joins course sequences into one entry
  /// ("Materials Science I and II") while timetables list the single
  /// module taken this term ("Materials Science and Engineering I").
  /// Equal number sets already matched; a proper subset (i ⊂ {i, ii})
  /// may also match, but ONLY if the noun words still align - "i" vs
  /// "iii" sets never intersect, so EM I can never match EM III here.
  static bool _numSetsCompatible(Set<String> e, Set<String> t) {
    if (e.length == t.length) return e.containsAll(t);
    if (e.isEmpty || t.isEmpty) return false;
    return e.containsAll(t) || t.containsAll(e);
  }

  static String _nounWords(String key) =>
      key.split(" ").where((w) => !_numToken.hasMatch(w)).join(" ");

  static Set<String> enrolledTitleKeys(WebcalFeed feed) {
    final out = <String>{};
    for (final occ in feed.occurrences) {
      // synthetic exam sittings are derived FROM the exam catalogue:
      // feeding their "Klausur: <title>" summaries back into the gate
      // self-matches isTakingThisSemester and re-arms suppressed
      // needsAction badges + 24 h registration alarms. SignMeUp UIDs
      // stay - an accepted tutorial IS a genuine enrolment.
      if (occ.uid.startsWith(examSynthUidPrefix)) continue;
      final k = lectureTitleKey(occ.title);
      if (k.length >= 4) out.add(k);
    }
    return out;
  }

  /// Kept in sync at every point a feed is parsed (fetch, SignMeUp synth
  /// re-injection, agenda cache loads) so relevance stays correct offline.
  Future<void> rememberEnrolledTitles(WebcalFeed? feed) async {
    final next = feed == null ? const <String>{} : enrolledTitleKeys(feed);
    if (next.isEmpty) return; // unreadable feed: keep yesterday's truth
    enrolledLectureTitles = next;
    // the "current modules" card tracks the feed, not the whole-SPO
    // Studienverlauf: re-prune + re-admit whenever the keys move
    await _reevaluateRelevantModuleRows();
  }

  /// Feed-refresh hook for the "current modules" card. Modules fetched but
  /// previously rejected (no ILIAS link, e.g. "Advanced Mathematics I")
  /// become eligible once their title shows up on the feed, and modules
  /// admitted earlier that are NOT on the feed (future-semester ones like
  /// EM III) drop out; the pruned list is persisted through the normal
  /// storage path. Never runs with an empty key set.
  Future<void> _reevaluateRelevantModuleRows() async {
    final keys = enrolledLectureTitles;
    if (keys.isEmpty) return;
    var pruned = false;
    await _addRelevantModuleLock.run(() async {
      final before = relevantModuleRowIDs.length;
      relevantModuleRowIDs.removeWhere((id) {
        final title = _knownModuleTitle(id);
        // stored-but-never-fetched ids whose row is unknown too stay:
        // the rule is about titles and there is no title to judge yet
        return title != null &&
            !moduleKeyMatchesLectureKey(lectureTitleKey(title), keys);
      });
      pruned = relevantModuleRowIDs.length != before;
      if (pruned) storeRelevantModuleRows();
    });
    // re-admission goes through addRelevantModuleRow so ordering,
    // de-duplication and persistence stay in the one place that owns them
    for (final module in rowModules.values.toList()) {
      if (module.isEmpty) continue;
      final row = module.row;
      if (row == null || relevantModuleRowIDs.contains(row.id)) continue;
      final title = _moduleFeedTitle(module, row);
      if (title != null &&
          moduleKeyMatchesLectureKey(lectureTitleKey(title), keys)) {
        await addRelevantModuleRow(row);
      }
    }
    if (pruned) notificationCallback();
  }

  /// The single matching rule shared by [isTakingThisSemester] and the
  /// "current modules" card admission ([addRelevantModuleRow]): does the
  /// normalized [moduleKey] correspond to any lecture key in
  /// [lectureKeys]?
  ///
  /// Exact key equality always matches. Every fuzzy path (mutual
  /// substring, fuzzy ratio, joined-sequence noun words) first has to
  /// survive the numeric-token guard: "Engineering Mechanics I" (number
  /// set {i}) and "... III" ({iii}) have equal-size, different sets and
  /// are rejected before substring containment or the ratio could pair
  /// them. The ratio >= 70 path is kept (parity with the exam gate)
  /// because feed titles differ from CampusKIT spellings by more than a
  /// substring can cover (faculty prefixes, German wording); the guard
  /// already eliminates the I/II/III collisions fuzzy matching is known
  /// for, so dropping ratio would only lose true matches.
  static bool moduleKeyMatchesLectureKey(
      String moduleKey, Set<String> lectureKeys) {
    if (moduleKey.isEmpty || lectureKeys.isEmpty) return false;
    final tNums = _numericTokens(moduleKey);
    for (final ev in lectureKeys) {
      if (ev == moduleKey) return true;
      final eNums = _numericTokens(ev);
      if (!_numSetsCompatible(eNums, tNums)) continue;
      if (ev.length >= 6 &&
          (ev.contains(moduleKey) || moduleKey.contains(ev))) {
        return true;
      }
      // same threshold kit_provider uses before POSTing a favourite toggle
      if (ratio(moduleKey, ev) >= 70) return true;
      // joined-sequence match ("I and II" ⊃ "I"): full-string ratio can sit
      // below threshold because of the extra words, so require the noun
      // words to align closely instead.
      if (eNums.length != tNums.length) {
        final ne = _nounWords(ev), nt = _nounWords(moduleKey);
        if (ne.length >= 6 && nt.length >= 6 &&
            (ne.contains(nt) || nt.contains(ne) || ratio(ne, nt) >= 80)) {
          return true;
        }
      }
    }
    return false;
  }

  /// Do two normalized module titles name the SAME lecture?
  ///
  /// The Studienverlauf tree lists some modules under two section headings,
  /// and each copy has its own row id, so the card showed the identical
  /// module twice. Keeps the numeric-token guard of
  /// [moduleKeyMatchesLectureKey] ("Engineering Mechanics I" vs "... III"
  /// are two modules) and is deliberately stricter than the feed gate: no
  /// fuzzy ratio, because there a one-character difference means a
  /// DIFFERENT module ("Mechanical Design A" vs "... B", "Analysis 1" vs
  /// "Analysis 2") that one-card-per-module must never hide.
  static bool moduleKeysDenoteSameModule(String a, String b) {
    if (a.isEmpty || b.isEmpty) return false;
    if (a == b) return true;
    if (!_numSetsCompatible(_numericTokens(a), _numericTokens(b))) {
      return false;
    }
    return a.length >= 6 && b.length >= 6 && (a.contains(b) || b.contains(a));
  }

  /// Tri-state: null = subscription never loaded (unknown -> stay loud),
  /// true = lecture on the current timetable, false = catalogue-only exam
  /// of a later semester (no registration duty this term).
  bool? isTakingThisSemester(ExamEntry e) {
    if (enrolledLectureTitles.isEmpty) return null;
    final t = lectureTitleKey(e.title);
    if (t.isEmpty) return null;
    return moduleKeyMatchesLectureKey(t, enrolledLectureTitles);
  }

  Future<String?> _ensureWebcalUrl() async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getString(_webcalUrlKey);
    if (stored != null && stored.isNotEmpty) {
      return stored;
    }

    final page =
        "https://cascampus.studium.kit.edu/campus/student/webcal.asp?tguid=${tguid ?? ""}";
    var response = await guardedCasGet(page);
    if (response.statusCode != 200 || sessionExpired(response.body)) {
      cascampusReady = false;
      await bootCascampusSession();
      response = await guardedCasGet(page);
    }

    var m =
        RegExp('value="(https?://cascampus\\.studium\\.kit\\.edu/webcal/[^"]+)')
            .firstMatch(response.body);
    if (m == null) {
      // not activated yet - submit the enable form hosted on the page
      final g = RegExp('name="gguid" value="(0x[0-9A-Fa-f]+)"')
          .firstMatch(response.body);
      if (g != null && tguid != null) {
        final enabled = await guardedCasPost(page,
            {"gguid": g.group(1)!, "tguid": tguid!, "enable": "Aktivieren"});
        m = RegExp(
                'value="(https?://cascampus\\.studium\\.kit\\.edu/webcal/[^"]+)')
            .firstMatch(enabled.body);
      }
    }

    if (m == null) {
      if (kDebugMode) {
        print("WebCal provisioning FAILED (no token URL on webcal.asp)");
      }
      return null;
    }

    final url = m.group(1)!.split("?").first;
    await prefs.setString(_webcalUrlKey, url);
    if (kDebugMode) {
      print("WebCal token provisioned");
    }
    return url;
  }

  /// E2E test seam: `--dart-define=TEST_WEBCAL_URL=<url>` redirects the
  /// whole webcal pipeline (foreground fetch + background poll) at a
  /// controlled feed. Empty in every normal build - zero production effect.
  static const testWebcalUrl =
      String.fromEnvironment("TEST_WEBCAL_URL");

  Future<bool> fetchWebcalTimetable() async {
    await ensurePersonalIcsLoaded();
    await carryExamSynthFromCache();
    // Contain EVERY failure (incl. TimeoutException from _ensureWebcalUrl /
    // netGet): when this threw, fetchTimetable's HTML fallback never ran and
    // forceRefetchEverything aborted mid-pipeline *after* clearEverything()
    // had already wiped the caches - half-reset app, no error shown.
    try {
      final url = testWebcalUrl.isNotEmpty
          ? testWebcalUrl
          : await _ensureWebcalUrl();
      if (url == null) {
        return false;
      }

      final response = await netGet(Uri.parse(url));
      if (response.statusCode != 200 ||
          !response.body.contains("BEGIN:VCALENDAR")) {
        if (kDebugMode) {
          print(
              "WebCal fetch failed: ${response.statusCode} len ${response.body.length}");
        }
        return false;
      }

      final feed = WebcalFeed.parse(response.body);
      if (feed == null) {
        if (kDebugMode) {
          print("WebCal parse produced no occurrences!");
        }
        return false;
      }

      final prefs = await SharedPreferences.getInstance();
      // source switch (test seam on/off, re-provisioned webcal token URL):
      // reseed the baseline instead of diffing two different calendars
      final previousSource = prefs.getString(_webcalFeedSourceKey);
      if (previousSource != null && previousSource != url) {
        await prefs.remove(_webcalFingerprintKey);
      }
      await prefs.setString(_webcalFeedSourceKey, url);
      final previousFingerprint = prefs.getString(_webcalFingerprintKey);
      final fingerprint = feed.fingerprint();
      if (previousFingerprint != null && previousFingerprint != fingerprint) {
        final changes = feed.changesSince(WebcalFeed.parse(stripPersonalIcs(
            stripSignMeUpSynth(stripExamSynth(
                prefs.getString(_webcalIcsCacheKey) ?? "")))));
        if (changes.isNotEmpty) {
          // an empty diff under a changed fingerprint is the rolling parse
          // window, not a real change - flagging it stuck the tab badge with
          // an undismissable CHANGED band (agenda only renders non-empty)
          timetableChanged = true;
          await prefs.setString(
              _webcalChangesKey,
              IcsChange.encode(mergeIcsChanges(
                  IcsChange.decode(prefs.getString(_webcalChangesKey) ?? ""),
                  changes)));
        }
        if (kDebugMode) {
          print("WebCal feed CHANGED: ${changes.length} deltas");
        }
      }
      await prefs.setString(_webcalFingerprintKey, fingerprint);
      await prefs.setString(
          _webcalIcsCacheKey,
          injectPersonalIcs(
              injectSignMeUpSynth(
                  injectExamSynth(feed.raw, examSynth), signMeUpSynth),
              personalIcs));
      // age stamp for the agenda stale-data footer (also written by the
      // background poll after it rewrites the cache)
      await prefs.setString(
          "DATA_webcalFetchedAt", DateTime.now().toIso8601String());

      final merged = WebcalFeed.parse(injectPersonalIcs(
          injectSignMeUpSynth(
              injectExamSynth(feed.raw, examSynth), signMeUpSynth),
          personalIcs));
      timetable = gridTemplate(merged ?? feed);
      rememberEnrolledTitles(merged ?? feed);

      // webcal is healthy again: a one-off HTML false alarm used to pin the
      // red "surface broken" banner for the whole process (only write site),
      // and background polls advance the fingerprint without touching
      // timetableChanged - a foreground fetch after a background-detected
      // change used to silently un-light the home badge the push announced.
      timetableSurfaceBroken = false;
      timetableChanged =
          (prefs.getString(_webcalChangesKey) ?? "").isNotEmpty ||
              timetableChanged;
      notificationCallback();
      unawaited(MeiNotifications.scheduleLectureReminders(merged ?? feed));
      unawaited(MeiNotifications.scheduleMorningDigest(merged ?? feed));

      // the subscription is fresh; give the personal calendar its quiet
      // top-up (throttled internally, keeps the old copy on any failure)
      unawaited(refreshPersonalIcsFromUrl());
      if (kDebugMode) {
        print("Timetable from WebCal: ${feed.occurrences.length} occurrences");
      }
      return true;
    } catch (e) {
      if (kDebugMode) print("WebCal fetch threw, falling back to HTML: $e");
      return false;
    }
  }

  Future<void> fetchTimetable({retryIfFailed = true}) async {
    if (kDebugMode) {
      print("Fetching timetable...");
    }
    if (await fetchWebcalTimetable()) {
      return;
    }

    if (tguid == null) {
      await bootTguid();
    }
    if (!cascampusReady) {
      await bootCascampusSession();
    }
    final url =
        "https://cascampus.studium.kit.edu/campus/student/timetable.asp?tguid=${tguid ?? ""}";
    final response = await guardedCasGet(url);

    final ok = await updateTimetableFromStrSrc(response.body);

    if (!ok && retryIfFailed) {
      // probably an expired cascampus session page - re-bootstrap, then retry once
      cascampusReady = false;
      await bootCascampusSession();
      return fetchTimetable(retryIfFailed: false);
    }
    timetableSurfaceBroken = !ok;
    if (!ok) {
      notificationCallback();
    }
  }

  Future<bool>? _examsInFlight;

  Future<bool> fetchExams({retryIfFailed = true}) {
    // memoize the in-flight fetch: a pull right after login's automatic
    // fetch must await the SAME request, not get a bogus instant false
    final inflight = _examsInFlight;
    if (inflight != null) return inflight;
    final future = _fetchExamsGuarded(retryIfFailed: retryIfFailed);
    _examsInFlight = future;
    return future.whenComplete(() => _examsInFlight = null);
  }

  Future<bool> _fetchExamsGuarded({required bool retryIfFailed}) async {
    isFetchingExams = true;
    try {
      return await _fetchExamsInner(retryIfFailed: retryIfFailed);
    } on Object {
      // timeouts / socket errors must land in the same failure funnel as a
      // malformed response, or the memoized future rejects every caller
      // (exams page: endless spinner, refresh toast never fires)
      if (retryIfFailed) {
        cascampusReady = false;
        if (await bootCascampusSession()) {
          return _fetchExamsGuarded(retryIfFailed: false);
        }
      }
      examsSurfaceBroken = true;
      notificationCallback();
      return false;
    } finally {
      isFetchingExams = false;
    }
  }

  Future<bool> _fetchExamsInner({required bool retryIfFailed}) async {
    if (kDebugMode) {
      print("Fetching exam registration list...");
    }
    if (tguid == null) {
      await bootTguid();
    }
    if (!cascampusReady) {
      await bootCascampusSession();
    }

    // exams can load before the agenda page ever ran (cold start -> exams
    // tab first); seed relevance from the cached ICS so the catalogue gate
    // is correct from the first frame instead of "unknown"
    if (enrolledLectureTitles.isEmpty) {
      final prefs = await SharedPreferences.getInstance();
      rememberEnrolledTitles(
          WebcalFeed.parse(prefs.getString(_webcalIcsCacheKey) ?? ""));
    }

    final response = await guardedCasGet(
        "https://cascampus.studium.kit.edu/campus/student/contractview.asp?view=possibleexams&tguid=${tguid ?? ""}");

    if (response.statusCode == 200 && !sessionExpired(response.body)) {
      final parsed = ExamListParser.parse(response.body);
      // a well-formed page with zero rows is a valid empty state, not breakage
      if (parsed.isNotEmpty || response.body.contains("EXAMLIST")) {
        examsSurfaceBroken = false;
        exams = parsed;
        examsLoaded = true;
        // mirror the registered sittings into the merged timetable feed;
        // agenda / digest / reminders / ICS export pick them up unseen
        await reapplyExamSynth(buildExamSynthBlock(parsed));
        notificationCallback();
        // deadline alarms only for exams of lectures actually on the
        // timetable - catalogue offers of later semesters must stay silent
        unawaited(MeiNotifications.scheduleExamReminders(
            parsed.where((e) => isTakingThisSemester(e) != false).toList()));
        if (kDebugMode) {
          final open = parsed
              .where((e) =>
                  e.needsAction(DateTime.now()) &&
                  isTakingThisSemester(e) != false)
              .length;
          print(
              "Exams: ${parsed.length} entries, $open need registration (taken this semester)");
        }
        return true;
      }
    }

    if (retryIfFailed) {
      cascampusReady = false;
      await bootCascampusSession();
      // bypass fetchExams(): its in-flight memo still holds THIS future -
      // awaiting it deadlocks the fetch (and every spinner on it) forever
      return _fetchExamsGuarded(retryIfFailed: false);
    }
    if (kDebugMode) {
      print("Exams fetch FAILED (session dead or EXAMLIST markup changed)");
    }
    examsSurfaceBroken = true;
    notificationCallback();
    return false;
  }

  Future<bool> updateTimetableFromStrSrc(String src, {cacheSrc = true}) async {
    final timetableUpdate = TimetableWeekly.parseFromHtmlString(src);
    if (timetableUpdate == null) {
      if (kDebugMode) {
        print("Failed to update the timetable!");
      }

      return false;
    }

    if (cacheSrc) {
      await _cacheTimetableSrc(src);
    }

    timetable = timetableUpdate;
    notificationCallback();

    return true;
  }

  Future<void> _cacheTimetableSrc(String src) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_timetableSrcCurrentSemesterKey, src);
  }

  Future<String?> _readCachedTimetableSrc() async {
    final prefs = await SharedPreferences.getInstance();
    final cached = prefs.getString(_timetableSrcCurrentSemesterKey);
    return cached;
  }

  Future<bool> loadCachedTimetable() async {
    final cached = await _readCachedTimetableSrc();
    if (cached == null || cached.isEmpty) {
      return false;
    } else {
      return updateTimetableFromStrSrc(cached);
    }
  }

  Future<void> clearCachedTimetableData() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_timetableSrcCurrentSemesterKey);
  }

  Map<String, List<ModuleInfoTable>> get moduleInfoTablesWithAppointments {
    final result = <String, List<ModuleInfoTable>>{};

    for (final rowId in rowModules.keys) {
      final module = rowModules[rowId];

      if (module == null || module.isEmpty) {
        continue;
      }

      result.putIfAbsent(module.hierarchicalTableRowId, () => []);

      for (final table in module.tables) {
        for (final row in table.rows) {
          if (row.favoriteToggleCell == null) {
            continue;
          }

          // Bingo! We've found a module with an appointment that should be
          // displayed on the TimetableEditPage

          assert(result[module.hierarchicalTableRowId] != null);
          bool shouldAdd = true;

          // ensure we do not insert duplicates
          for (final existingTable in result[module.hierarchicalTableRowId]!) {
            if (existingTable.caption.trim() == table.caption.trim()) {
              shouldAdd = false;
              break;
            }
          }

          if (shouldAdd) {
            result[module.hierarchicalTableRowId]?.add(table);
          }
        }
      }
    }

    return result;
  }
}
