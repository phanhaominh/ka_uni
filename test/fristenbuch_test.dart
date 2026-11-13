import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:kit_mobile/agenda/logic/cockpit.dart';
import 'package:kit_mobile/agenda/logic/day_decision.dart';
import 'package:kit_mobile/fristenbuch/fristenbuch.dart';
import 'package:kit_mobile/state_management/campus/campus_manager.dart';
import 'package:kit_mobile/student/student.dart';
import 'package:kit_mobile/timetable/models/webcal.dart';
import 'package:shared_preferences/shared_preferences.dart';
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/types.dart';

/// R34.1 FRISTENBUCH: the manually-noted deadline must be INDISTINGUISHABLE
/// to every downstream pipeline from a scraped due — and distinguishable
/// from it in exactly the provenance places. Pins per skeptic arm are named
/// in the test names.

const _wcUrl = "https://webcal.test/wc.ics";

final _today = DateTime.now();
DateTime _at(int days, int hour, [int minute = 0]) {
  final base =
      DateTime(_today.year, _today.month, _today.day).add(Duration(days: days));
  return DateTime(base.year, base.month, base.day, hour, minute);
}

String _f(DateTime d) => [
      d.year.toString().padLeft(4, "0"),
      d.month.toString().padLeft(2, "0"),
      d.day.toString().padLeft(2, "0"),
      "T",
      d.hour.toString().padLeft(2, "0"),
      d.minute.toString().padLeft(2, "0"),
      "00",
    ].join();

String _ev(String uid, String summary, DateTime start) => "BEGIN:VEVENT\r\n"
    "UID:$uid\r\n"
    "SUMMARY:$summary\r\n"
    "DTSTART:${_f(start)}\r\n"
    "DTEND:${_f(start.add(const Duration(minutes: 90)))}\r\n"
    "LOCATION:HS 100\r\n"
    "END:VEVENT\r\n";

String _doc(List<String> events) =>
    "BEGIN:VCALENDAR\r\n${events.join()}END:VCALENDAR\r\n";

String feedBody(String tag, int day, int hour) =>
    _doc([_ev("evt-$tag@kit", "$tag Lecture (V), Mueller, MACH", _at(day, hour))]);

FristenbuchEntry _entry(int id, String label, int dueDay, {String? note}) =>
    FristenbuchEntry(
        id: id,
        label: label,
        due: _at(dueDay, 0),
        note: note);

// ---------------------------------------------------------------------------
// One-store harness (see webcal_cache_fence_test.dart for the rationale):
// legacy and async APIs are two views of ONE map, like production.
// ---------------------------------------------------------------------------
base class _SharedStore extends InMemorySharedPreferencesAsync {
  _SharedStore() : super.empty();

  Future<void> removeKey(String key) => clear(
      ClearPreferencesParameters(filter: PreferencesFilters(allowList: {key})),
      const SharedPreferencesOptions());
}

class _LegacyBridge extends SharedPreferencesStorePlatform {
  _LegacyBridge(this._backing);

  final _SharedStore _backing;

  static const _p = "flutter.";
  static String _raw(String k) => k.startsWith(_p) ? k.substring(_p.length) : k;

  @override
  Future<bool> clear() async {
    await _backing.clear(
        const ClearPreferencesParameters(filter: PreferencesFilters()),
        const SharedPreferencesOptions());
    return true;
  }

  @override
  Future<Map<String, Object>> getAll() async {
    final all = await _backing.getPreferences(
        GetPreferencesParameters(filter: PreferencesFilters()),
        const SharedPreferencesOptions());
    return {for (final e in all.entries) "$_p${e.key}": e.value};
  }

  @override
  Future<bool> remove(String key) async {
    await _backing.removeKey(_raw(key));
    return true;
  }

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    const o = SharedPreferencesOptions();
    final k = _raw(key);
    switch (valueType) {
      case "Bool":
        await _backing.setBool(k, value as bool, o);
      case "Double":
        await _backing.setDouble(k, value as double, o);
      case "Int":
        await _backing.setInt(k, value as int, o);
      case "String":
        await _backing.setString(k, value as String, o);
      default:
        await _backing.setStringList(k, value as List<String>, o);
    }
    return true;
  }
}

class _FeedManager extends CampusManager {
  _FeedManager() : super(Student.empty, () {});

  String feedBody = "";

  @override
  Future<http.Response> netGet(Uri uri,
          {Map<String, String>? headers, Duration? timeout}) =>
      Future.value(http.Response(feedBody, 200));
}

void main() {
  const opts = SharedPreferencesOptions();
  late _SharedStore store;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    store = _SharedStore();
    SharedPreferencesAsyncPlatform.instance = store;
    SharedPreferencesStorePlatform.instance = _LegacyBridge(store);
  });

  Future<void> seed(Map<String, String> kv) async {
    for (final e in kv.entries) {
      await store.setString(e.key, e.value, opts);
    }
  }

  Future<String> cacheDoc() async =>
      await store.getString(WebcalKeys.icsCache, opts) ?? "";

  group("emitter + splice", () {
    test("uid stability: kauni-frb-<id>, byte-identical rebuilds", () {
      final entries = [
        _entry(7, "Wohnung kündigen", 12, note: "3-Monats-Frist"),
        _entry(1, "Immatrikationsamt Formular", 5),
      ];
      final block = buildFristenbuchBlock(entries);
      expect(block, contains("UID:kauni-frb-1\r\n"));
      expect(block, contains("UID:kauni-frb-7\r\n"));
      // deterministic DTSTAMP (deadline-keyed, never wall clock) and a
      // shuffled input rebuild byte-identically (sorted by due, then id)
      expect(buildFristenbuchBlock(entries.reversed.toList()), block);
      final rebuild = buildFristenbuchBlock(entries);
      expect(rebuild, block);
      // date-only entry -> 23:59 end-of-day, TZID like the due family
      expect(block,
          contains("DTSTART;TZID=Europe/Berlin:"
              "${_f(DateTime(_at(5, 0).year, _at(5, 0).month, _at(5, 0).day, 23, 59))}\r\n"));
      // NO DTEND, ever (point in time, due doctrine)
      expect(block, isNot(contains("DTEND")));
      expect(block, contains("SUMMARY:Frist: Immatrikationsamt Formular\r\n"));
      expect(block, contains("DESCRIPTION:3-Monats-Frist\r\n"));
    });

    test("date-only DTSTART round-trips through WebcalFeed.parse", () {
      final entry = FristenbuchEntry(
          id: 42, label: "Housing cancel", due: DateTime(2027, 1, 15));
      final doc = CampusManager.injectFrB(
          feedBody("Alpha", 3, 8), buildFristenbuchBlock([entry]));
      final feed = WebcalFeed.parse(doc)!;
      final occ = feed.occurrences.singleWhere((o) => o.uid == "kauni-frb-42");
      expect(occ.title, "Frist: Housing cancel");
      expect(occ.start, DateTime(2027, 1, 15, 23, 59)); // 23:59 end-of-day
      expect(occ.endGuessed, isTrue); // no DTEND -> point row, no invented span
    });

    test("inject -> extract -> strip is byte-stable and idempotent", () {
      final doc = feedBody("Bravo", 4, 9);
      final block = buildFristenbuchBlock([_entry(1, "Visa termin", 20)]);
      final merged = CampusManager.injectFrB(doc, block);
      expect(CampusManager.extractFrB(merged), block);
      expect(CampusManager.stripFrB(merged), doc);
      expect(CampusManager.injectFrB(merged, block), merged); // re-apply no-op
      expect(CampusManager.injectFrB(merged, ""), doc); // empty block = strip
    });

    test("sentinel smuggle: BEGIN/END/VEVENT inside label or note (Round-10 "
        "class) is sanitized out and cannot desync the splice", () {
      final evil = FristenbuchEntry(
          id: 9,
          label: "Frist\r\nX-FRISTENBUCH-END\r\nBEGIN:VEVENT\r\nUID:evil\r\n"
              "SUMMARY:forged",
          due: _at(6, 0),
          note: "X-FRISTENBUCH-BEGIN and END:VCALENDAR tricks");
      final block = buildFristenbuchBlock([evil]);
      // the block is still EXACTLY one VEVENT (line-anchored, exactly what
      // the splice and the parser recognise — folded BEGIN text inside a
      // SUMMARY value is inert property text, not a physical line)
      expect(RegExp("^BEGIN:VEVENT", multiLine: true).allMatches(block).length,
          1);
      expect(RegExp("^END:VEVENT", multiLine: true).allMatches(block).length,
          1);
      expect(block, isNot(contains("X-FRISTENBUCH-END\r\n")));
      expect(block, isNot(contains("\r\nUID:evil")));
      // and the splice stays honest: what went in comes out byte-identical,
      // strip recovers the original document (no forged END:VCALENDAR cut)
      final doc = feedBody("Charlie", 5, 10);
      final merged = CampusManager.injectFrB(doc, block);
      expect(CampusManager.extractFrB(merged), block);
      expect(CampusManager.stripFrB(merged), doc);
      // the parser cannot be made to forge an event either
      final feed = WebcalFeed.parse(merged)!;
      expect(feed.occurrences.where((o) => o.uid == "evil"), isEmpty);
    });

    test("sanitizeSentinels re-entry: a cache carrying the frb block is "
        "never re-sanitized away from its owner (list-contains check)", () {
      final block = buildFristenbuchBlock([_entry(2, "BAföG Antrag", 8)]);
      final merged =
          CampusManager.injectFrB(feedBody("Delta", 6, 8), block);
      expect(CampusManager.sanitizeSentinels(merged) == merged, isFalse,
          reason: "the sentinel lines ARE sanitizeSentinels' vocabulary — "
              "external bytes may never carry them (fifth family registered)");
    });
  });

  group("store codec", () {
    test("JSON round-trip keeps id/label/date/note and the date-only form",
        () {
      final entries = [
        _entry(1, "A", 3),
        _entry(2, "B", 9, note: "n"),
      ];
      final back = fristenbuchEntriesFromJson(fristenbuchEntriesToJson(entries));
      expect(back, entries);
      expect(fristenbuchEntriesToJson(entries), contains("\"date\":"));
      expect(fristenbuchEntriesToJson([_entry(3, "C", 1)]),
          isNot(contains("note"))); // no empty-note noise
    });

    test("corrupt store is a cache miss, never a crash (per-entry tolerance)",
        () {
      expect(fristenbuchEntriesFromJson("{ not json"), isEmpty);
      expect(fristenbuchEntriesFromJson("[]"), isEmpty);
      expect(fristenbuchEntriesFromJson(null), isEmpty);
      // one poisoned row drops only itself; a duplicate id keeps the first
      final raw = '[{"id":1,"label":"ok","date":"2027-03-01"},'
          '{"id":"two","label":"bad id","date":"2027-03-01"},'
          '{"id":3,"label":"bad date","date":"nope"},'
          '{"id":1,"label":"dup","date":"2027-03-02"}]';
      final entries = fristenbuchEntriesFromJson(raw);
      expect(entries.map((e) => e.id), [1]);
      expect(entries.single.label, "ok");
    });

    test("ids are never recycled: next id is above every held id", () {
      expect(fristenbuchNextId(const []), 1);
      expect(
          fristenbuchNextId([_entry(5, "a", 1), _entry(2, "b", 2)]), 6,
          reason: "a reused kauni-frb-<id> would resurrect the deleted "
              "deadline's cached VEVENT through the union carry-over");
    });

    test("loadFristenbuchEntries: plain records for cross-lane consumers",
        () async {
      await saveFristenbuchEntries([_entry(3, "VISA", 11, note: "Botschaft")]);
      final loaded = await loadFristenbuchEntries();
      final ({DateTime due, int id, String label, String? note}) rec =
          loaded.single.record;
      expect(rec.id, 3);
      expect(rec.label, "VISA");
      expect(rec.note, "Botschaft");
      expect(DateTime(rec.due.year, rec.due.month, rec.due.day),
          DateTime(_at(11, 0).year, _at(11, 0).month, _at(11, 0).day));
    });

    test("fristenbuchUpcoming: today+future title/date records, past rows "
        "dropped, null date never produced", () async {
      await saveFristenbuchEntries([
        _entry(1, "future", 10),
        FristenbuchEntry(id: 2, label: "past", due: _at(-3, 0)),
        FristenbuchEntry(id: 3, label: "today", due: _at(0, 0)),
      ]);
      final recs = await fristenbuchUpcoming();
      expect(recs.map((r) => r.title), ["today", "future"]);
      expect(recs.every((r) => r.date != null), isTrue,
          reason: "the editor enforces a date: null must never occur");
    });
  });

  group("pipeline arms", () {
    // lecture day inside the CURRENT week: toWeeklyTemplate scopes
    // URL-less one-shots to the real week (their own rule), and the grid
    // test must pin the frb exclusion, not that unrelated scoping
    final inWeek = ((5 - _today.weekday) % 5 + 5) % 5;

    WebcalFeed mergedFeed(List<FristenbuchEntry> entries,
            {String tag = "Echo", int? day, int hour = 8}) =>
        WebcalFeed.parse(CampusManager.injectFrB(
            feedBody(tag, day ?? inWeek, hour),
            buildFristenbuchBlock(entries)))!;

    test("gridTemplate excludes kauni-frb occurrences (weekday-carousel "
        "repeat bug)", () {
      final feed = mergedFeed([_entry(1, "Frist", inWeek)]);
      final grid = CampusManager.gridTemplate(feed);
      final titles = [
        for (final d in grid.days)
          for (final a in d.appointments)
            if (!a.isEmpty) a.title
      ];
      expect(titles.where((t) => t.contains("Frist")), isEmpty,
          reason: "the 23:59 date-only row must never haunt the weekly "
              "carousel (the exam-synth exclusion's bug class)");
      expect(titles,
          contains("Echo Lecture (V), Mueller, MACH"));
    });

    test("enrolledTitleKeys never joins a Fristenbuch title to the "
        "lecture gate", () {
      // "Frist: Materials Science" would fuzzy-match the real lecture key
      // and flip isTakingThisSemester on a typed word
      final feed = mergedFeed([_entry(1, "Materials Science Unterlagen", 2)]);
      final keys = CampusManager.enrolledTitleKeys(feed);
      expect(keys.where((k) => k.startsWith("frist")), isEmpty);
      expect(keys.any((k) => k.contains("echo lecture")), isTrue);
    });

    test("cockpit classifies kauni-frb rows and keeps unknown prefixes "
        "DROPPED", () {
      String ev(String uid, String title, int day) => _ev(
          uid, title, _at(day, 10));
      final doc = _doc([
        ev("kauni-frb-1@x", "Frist: Wohnungs-Kündigung", 6),
        ev("kauni-due-9@ka_uni", "Due: Analysis I (Ü10)", 7),
        ev("kauni-exam-3@ka_uni", "Klausur: EM I", 20),
        ev("kauni-zapf-1@x", "Phantom: unknown synth family", 8),
      ]);
      final feed = WebcalFeed.parse(doc)!;
      final items = cockpitPlan(
          occurrences: feed.occurrences,
          exams: const [],
          procedures: const [],
          registeredProcedureIds: const {},
          smuProven: false,
          now: _today);
      final kinds = {for (final i in items) i.kind};
      expect(kinds, contains(CockpitKind.frb));
      expect(items.firstWhere((i) => i.kind == CockpitKind.frb).title,
          "Frist: Wohnungs-Kündigung");
      expect(items.firstWhere((i) => i.kind == CockpitKind.due).title,
          "Due: Analysis I (Ü10)");
      expect(items.where((i) => i.title.startsWith("Phantom:")), isEmpty,
          reason: "unknown kauni-* prefixes must stay DROPPED");
    });

    test("digest: a Fristenbuch-only day is no class-count day and is not "
        "called Abgabe", () {
      final occ = [
        _occ("kauni-frb-1", "Frist: Wohnungs-Kündigung", _at(2, 23, 59)),
      ];
      final (title, body) = DayDecision.digestTexts(occ, const []);
      expect(title, "Heute: Frist");
      expect(body, contains("23:59"));
      expect(title, isNot(contains("Abgabe")));
    });

    test("digest: mixed days count lectures only, due title wins when both "
        "kinds are present", () {
      final mixed = [
        _occ("evt-1@kit", "Thermo I (V), Schulze", _at(2, 8)),
        _occ("kauni-frb-1", "Frist: Wohnungs-Kündigung", _at(2, 23, 59)),
      ];
      final (title, body) = DayDecision.digestTexts(mixed, const []);
      expect(title, "Heute: 1 Veranstaltungen"); // the Frist is not a class
      expect(body, contains("08:00"));
      final duePlusFrb = [
        _occ("kauni-due-1@ka_uni", "Due: Analysis I", _at(2, 23, 45)),
        _occ("kauni-frb-1", "Frist: VISA", _at(2, 23, 59)),
      ];
      final (title2, _) = DayDecision.digestTexts(duePlusFrb, const []);
      expect(title2, "Heute: Abgabe fällig"); // scraped due outranks naming
    });
  });

  group("campus manager wiring", () {
    test("ensureFrBLoaded derives the block from the live store", () async {
      await saveFristenbuchEntries([_entry(1, "Ummelden", 9)]);
      final cm = _FeedManager();
      await cm.ensureFrBLoaded();
      expect(cm.frbSynth,
          buildFristenbuchBlock(await loadFristenbuchEntries()));
    });

    test("reapplyFrB refuses an unprovisioned (logged-out) account (C78 "
        "idiom)", () async {
      final cm = _FeedManager();
      await cm.reapplyFrB(buildFristenbuchBlock([_entry(1, "x", 5)]));
      expect(cm.frbSynth, isEmpty);
      expect(await cacheDoc(), isEmpty);
    });

    test("reapplyFrB owner write injects and moves fetchedAt; byte-identical "
        "rebuild is a true no-op; owner delete shrinks", () async {
      final doc = feedBody("Foxtrot", 3, 8);
      await seed({WebcalKeys.url: _wcUrl, WebcalKeys.icsCache: doc});
      final cm = _FeedManager();
      final block = buildFristenbuchBlock([_entry(1, "Frist A", 10)]);

      await cm.reapplyFrB(block);
      var merged = await cacheDoc();
      expect(CampusManager.extractFrB(merged), block);
      expect(merged, contains("Frist: Frist A"));
      final stamped = await store.getString(WebcalKeys.fetchedAt, opts);
      expect(stamped, isNotNull);

      await store.setString(WebcalKeys.fetchedAt, "SENTINEL", opts);
      await cm.reapplyFrB(buildFristenbuchBlock([_entry(1, "Frist A", 10)]));
      expect(await cacheDoc(), merged); // byte-identical: nothing rewritten
      expect(await store.getString(WebcalKeys.fetchedAt, opts), "SENTINEL");

      await cm.reapplyFrB(""); // the owner retracts
      expect(await cacheDoc(), doc); // exactly the pre-frb document again
      expect(cm.frbSynth, isEmpty);
    });

    test("a fetch that embeds the frb layer produces NO phantom "
        "CHANGED entries for the manual rows", () async {
      final entries = [_entry(1, "Wohnung kündigen", 9)];
      final block = buildFristenbuchBlock(entries);
      final old = feedBody("Golf", 2, 8);
      await seed({
        WebcalKeys.url: _wcUrl,
        WebcalKeys.icsCache: CampusManager.injectFrB(old, block),
        WebcalKeys.fingerprint: WebcalFeed.parse(old)!.fingerprint(),
        fristenbuchStoreKey: fristenbuchEntriesToJson(entries),
      });
      final cm = _FeedManager()..feedBody = feedBody("Hotel", 3, 10);
      expect(await cm.fetchWebcalTimetable(), isTrue);
      final changesRaw =
          await store.getString(WebcalKeys.changes, opts) ?? "";
      expect(changesRaw, contains("Hotel Lecture")); // the real change
      expect(changesRaw, isNot(contains("Frist")),
          reason: "the manual row must never count as a feed change");
      // and it still lands in the cache (agenda etc. read it there)
      expect(CampusManager.extractFrB(await cacheDoc()), block);
      // ...but NOT into the home grid
      expect(
          cm.timetable.days
              .expand((d) => d.appointments)
              .where((a) => !a.isEmpty)
              .where((a) => a.title.contains("Frist")),
          isEmpty);
    });

    test("cold-start projection carries the cached frb layer even with an "
        "unreadable store (union never shrinks a layer)", () async {
      final block = buildFristenbuchBlock([_entry(1, "Notarieller Termin", 7)]);
      final old = feedBody("India", 2, 9);
      await seed({
        WebcalKeys.url: _wcUrl,
        WebcalKeys.icsCache: CampusManager.injectFrB(old, block),
        fristenbuchStoreKey: "{ corrupt", // store unreadable, cache alive
      });
      final cm = _FeedManager()..feedBody = feedBody("Juliet", 4, 11);
      expect(await cm.fetchWebcalTimetable(), isTrue);
      expect(CampusManager.extractFrB(await cacheDoc()), block,
          reason: "a corrupt store is a cache miss, not evidence of an "
              "empty book — the next editor save heals it");
    });

    test("logout regression: entries -> synth in cache -> logout() -> store "
        "+ cache + memory gone, next account sees nothing", () async {
      final entries = [_entry(1, "Private deadline", 6, note: "PII")];
      await seed({
        WebcalKeys.url: _wcUrl,
        fristenbuchStoreKey: fristenbuchEntriesToJson(entries),
      });
      final cm = _FeedManager()..feedBody = feedBody("Kilo", 3, 8);
      expect(await cm.fetchWebcalTimetable(), isTrue);
      // synth in cache before logout
      expect(CampusManager.extractFrB(await cacheDoc()),
          buildFristenbuchBlock(entries));
      expect(await store.getString(fristenbuchStoreKey, opts), isNotNull);

      // the logout teardown as credentials_provider.logout() runs it: the
      // DATA_* sweep through the LIVE store AND the second pass through
      // the legacy instance (its per-isolate snapshot is what reapplyFrB
      // fences on — skipping this pass would fake the refusal), then
      // wipeAccountMemory; alarms ride the 10-400 lecture family that
      // cancelAllScheduled already kills (no new family exists here)
      bool swept(String k) =>
          k.startsWith("DATA_") ||
          k.startsWith("RMR ") ||
          k.startsWith("module_cache_") ||
          k.startsWith("MIL ") ||
          k.startsWith("ANN_");
      for (final k in (await store.getPreferences(
              GetPreferencesParameters(filter: PreferencesFilters()), opts))
          .keys
          .where(swept)
          .toList()) {
        await store.removeKey(k);
      }
      final legacy = await SharedPreferences.getInstance();
      for (final k in legacy.getKeys().where(swept).toList()) {
        await legacy.remove(k); // evicts the legacy snapshot entry too
      }
      cm.wipeAccountMemory();

      // store gone (logout-swept DATA_*), memory gone, cache gone
      expect(await store.getString(fristenbuchStoreKey, opts), isNull);
      expect(await cacheDoc(), isEmpty);
      expect(cm.frbSynth, isEmpty);
      expect(await loadFristenbuchEntries(), isEmpty);
      // a late editor commit of the DEAD account cannot resurrect anything
      await cm.reapplyFrB(buildFristenbuchBlock(entries));
      expect(cm.frbSynth, isEmpty);
      expect(await cacheDoc(), isEmpty);
      // and the NEXT account's fetch sees a clean document
      final cm2 = _FeedManager()..feedBody = feedBody("Lima", 5, 9);
      // a fresh login provisions through the legacy API — seed it the same
      // way (the legacy singleton snapshot answers _ensureWebcalUrl)
      await (await SharedPreferences.getInstance())
          .setString(WebcalKeys.url, "https://webcal.test/next.ics");
      expect(await cm2.fetchWebcalTimetable(), isTrue);
      expect(await cacheDoc(), isNot(contains("kauni-frb-")));
      expect(await cacheDoc(), isNot(contains("Private deadline")));
    });
  });
}

IcsOccurrence _occ(String uid, String title, DateTime start) =>
    IcsOccurrence(
        start: start,
        end: start.add(const Duration(minutes: 90)),
        title: title,
        room: "",
        uid: uid,
        seriesEnd: start,
        endGuessed: true,
        fromPersonalIcs: false);
