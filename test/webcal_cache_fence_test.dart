import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:kit_mobile/fristenbuch/fristenbuch.dart';
import 'package:kit_mobile/ilias/models/ilias_models.dart';
import 'package:kit_mobile/notifications/mei_notifications.dart';
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

/// R31 F-2 (brief item C) - the cache-flap repro, written BEFORE the fence:
/// DATA_webcalIcsCache is written by >=3 independent writers (R1 foreground
/// fetch, R2 WorkManager poll isolate, R3 RMW re-applies) and every one of
/// them projects its own memory/stale-view into the document. The observed
/// device flaps were which layer vector survived the LAST writer stamping.
/// T1 cold synth-drop, T2 presence-vector monotonicity, T3 personal poison,
/// T4 poll clobber race, T5 fetchedAt invariant - all five must fail on the
/// pre-fence writers and pass on the fence (union-carry + C10 re-splice).
const _wcUrl = "https://webcal.test/wc.ics";
const _facUrl = "http://127.0.0.1:8080/fac.ics";

final _today = DateTime.now();
DateTime _at(int days, int hour) {
  final base =
      DateTime(_today.year, _today.month, _today.day).add(Duration(days: days));
  return DateTime(base.year, base.month, base.day, hour);
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

// Every canned event sits in its OWN (weekday, clock) slot so the
// feed-coverage dedupe (dropSignMeUpSynthCoveredByFeed) never judges a
// carried block "covered" - the tests then assert pure layer preservation.
String feedBody(String tag, int day, int hour) =>
    _doc([_ev("evt-$tag@kit", "$tag Lecture (V), Mueller, MACH", _at(day, hour))]);

String synthBlock(String tag, int day, int hour) =>
    _ev("signmeup-$tag@ka_uni", "$tag Tutorial - Group 1", _at(day, hour));

String examBlock(String tag, int day, int hour) => "BEGIN:VEVENT\r\n"
    "UID:kauni-exam-$tag@ka_uni\r\n"
    "SUMMARY:Klausur: $tag\r\n"
    "DTSTART;TZID=Europe/Berlin:${_f(_at(day, hour))}\r\n"
    "END:VEVENT\r\n";

String personalBlock(String tag, int day, int hour) =>
    _ev("pers-$tag@faculty", "$tag (faculty calendar)", _at(day, hour));

/// Production has ONE device store behind the legacy and the async API;
/// the two APIs only diverge through per-isolate caches. The package fakes
/// would be two disjoint maps, so the fence - which reads LIVE through the
/// async API and commits legacy - could not be tested at all. This pair
/// makes both APIs views of one map (like production), and the async side
/// gains the one-shot read gate T4 uses to land a main-isolate write
/// exactly between the poll's baseline read and its commit.
base class _SharedStore extends InMemorySharedPreferencesAsync {
  _SharedStore() : super.empty();

  Future<void> Function(String key)? onRead;

  @override
  Future<String?> getString(String key, SharedPreferencesOptions options) async {
    final v = await super.getString(key, options);
    await onRead?.call(key);
    return v;
  }

  // the async platform interface has no per-key remove - clear() with an
  // allowList deletes exactly those keys
  Future<void> removeKey(String key) => clear(
      ClearPreferencesParameters(filter: PreferencesFilters(allowList: {key})),
      const SharedPreferencesOptions());
}

class _LegacyBridge extends SharedPreferencesStorePlatform {
  _LegacyBridge(this._backing);

  final _SharedStore _backing;

  // the legacy API prefixes every platform key; the async one does not
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
        const GetPreferencesParameters(filter: PreferencesFilters()),
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

/// Serves the canned webcal feed / personal body through the netGet seam
/// (same pattern as _IcsStubManager in relevant_modules_feed_test.dart);
/// a seeded DATA_webcalUrl keeps _ensureWebcalUrl off the network.
class _FeedManager extends CampusManager {
  _FeedManager() : super(Student.empty, () {});

  String feedBody = "";
  String personalBody = "";

  @override
  Future<http.Response> netGet(Uri uri,
      {Map<String, String>? headers, Duration? timeout}) =>
      Future.value(http.Response(
          uri.host == "127.0.0.1" ? personalBody : feedBody, 200));
}

void main() {
  const opts = SharedPreferencesOptions();
  late _SharedStore store;

  setUp(() {
    SharedPreferences.setMockInitialValues({}); // resets the legacy singleton
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

  group("F-2 cache fence", () {
    test("T1 cold start: a successful feed fetch keeps the cached synth block",
        () async {
      // the signMeUp layer had NO load/carry: the first R1 write of every
      // cold boot projected signMeUpSynth=="" into the cache and dropped
      // the tutorials until the next SignMeUp scrape (flap variant boot_15)
      await seed({
        WebcalKeys.url: _wcUrl,
        WebcalKeys.icsCache: CampusManager.injectSignMeUpSynth(
            feedBody("Alpha", 2, 8), synthBlock("one", 3, 9)),
      });
      final cm = _FeedManager()..feedBody = feedBody("Bravo", 4, 10);
      expect(await cm.fetchWebcalTimetable(), isTrue);
      final doc = await cacheDoc();
      expect(doc, contains("Bravo Lecture")); // fresh feed landed
      expect(CampusManager.extractSignMeUpSynth(doc),
          contains("signmeup-one@ka_uni"));
      // the F-1 memory handoff must publish what was ACTUALLY written
      expect(cm.webcalWrittenAt, isNotNull);
      expect(cm.webcalMergedFeed, isNotNull);
      expect(await store.getString(WebcalKeys.fetchedAt, opts),
          cm.webcalWrittenAt);
    });

    test("T2 presence-vector monotonicity across alternating writers",
        () async {
      final due = _ev("kauni-due-1@ka_uni", "Due: Abgabe Golf", _at(10, 18));
      final doc0 = CampusManager.injectDueSynth(
          CampusManager.injectPersonalIcs(
              CampusManager.injectSignMeUpSynth(
                  CampusManager.injectExamSynth(
                      feedBody("Golf", 2, 8), examBlock("e1", 20, 9)),
                  synthBlock("one", 3, 9)),
              personalBlock("A", 4, 10)),
          due);
      await seed({
        WebcalKeys.url: _wcUrl,
        WebcalKeys.icsCache: doc0,
        "DATA_personalIcs": personalBlock("A", 4, 10),
        "DATA_dueSynthBlock": due,
      });
      final cm = _FeedManager()..feedBody = feedBody("Hotel", 5, 11);
      Future<void> expectAllLayers(String where) async {
        final doc = await cacheDoc();
        final layers = {
          "exam": CampusManager.extractExamSynth(doc),
          "synth": CampusManager.extractSignMeUpSynth(doc),
          "personal": CampusManager.extractPersonalIcs(doc),
          "due": CampusManager.extractDueSynth(doc),
        };
        for (final e in layers.entries) {
          expect(e.value, isNotEmpty,
              reason: "$where: layer '${e.key}' vanished from the cache");
        }
      }

      await cm.fetchWebcalTimetable(); // R1 cold start
      await expectAllLayers("R1 cold start");
      await MeiNotifications.mergePollCache(feedBody("India", 6, 12)); // R2
      await expectAllLayers("R2 poll");
      await cm.reapplyExamSynth(examBlock("e2", 21, 9)); // R3 exam owner
      await expectAllLayers("reapplyExamSynth");
      await MeiNotifications.mergePollCache(feedBody("Juliet", 6, 13)); // R2
      await expectAllLayers("R2 poll after owner write");
      await cm.reapplySignMeUpSynth(synthBlock("two", 3, 14)); // R3 synth owner
      await expectAllLayers("reapplySignMeUpSynth");
      cm.feedBody = feedBody("Kilo", 5, 15);
      await cm.fetchWebcalTimetable(); // R1 warm
      await expectAllLayers("R1 warm");

      // owner-replacements wrote, untouched layers are byte-intact
      final doc = await cacheDoc();
      expect(CampusManager.extractExamSynth(doc), contains("kauni-exam-e2"));
      expect(CampusManager.extractSignMeUpSynth(doc), contains("signmeup-two"));
      expect(CampusManager.extractPersonalIcs(doc), contains("pers-A@faculty"));
      expect(CampusManager.extractDueSynth(doc), contains("kauni-due-1"));
    });

    test("T3 personal poison: a URL-refresh with fewer events may not replace",
        () async {
      final pA = personalBlock("A", 3, 8);
      final pB = personalBlock("B", 4, 10);
      final pC = personalBlock("C", 5, 9);
      await seed({
        WebcalKeys.url: _wcUrl,
        WebcalKeys.icsCache: feedBody("Echo", 2, 8),
      });
      final cm = _FeedManager();
      cm.personalBody = _doc([pA, pB]);
      expect(await cm.setPersonalIcsFromUrl(_facUrl), isNull);
      expect(cm.personalIcs, contains("pers-B@faculty"));

      // the quiet refresh serving a VALID but SMALLER calendar: poison
      final err = await cm.setPersonalIcsFromRaw(_doc([pA]),
          userInitiated: false);
      expect(err, isNotNull, reason: "subset body was accepted wholesale");
      expect(cm.personalIcs, contains("pers-B@faculty"));
      expect(CampusManager.extractPersonalIcs(await cacheDoc()),
          contains("pers-B@faculty"));

      // growth (new events, restamped existing ones) stays allowed
      expect(
          await cm.setPersonalIcsFromRaw(_doc([pA, pB, pC]),
              userInitiated: false),
          isNull);
      expect(cm.personalIcs, contains("pers-C@faculty"));

      // the user re-importing a smaller calendar IS the proof: it replaces
      expect(await cm.setPersonalIcsFromRaw(_doc([pA])), isNull);
      expect(cm.personalIcs, isNot(contains("pers-B@faculty")));
    });

    test("T3b refreshPersonalIcsFromUrl keeps the old copy on a shrunk body",
        () async {
      final pA = personalBlock("A", 3, 8);
      final pB = personalBlock("B", 4, 10);
      await seed({
        WebcalKeys.url: _wcUrl,
        // as the import left it: canonical key + block embedded in the doc
        WebcalKeys.icsCache: CampusManager.injectPersonalIcs(
            feedBody("Echo", 2, 8), pA + pB),
        "DATA_personalIcs": pA + pB,
        "DATA_personalIcsUrl": _facUrl,
      });
      final cm = _FeedManager()..personalBody = _doc([pA]);
      // production order: the fetch flow (or any settings open) loads the
      // persisted pair before the quiet refresh runs
      await cm.ensurePersonalIcsLoaded();
      await cm.refreshPersonalIcsFromUrl();
      expect(cm.personalIcs, contains("pers-B@faculty"));
      expect(CampusManager.extractPersonalIcs(await cacheDoc()),
          contains("pers-B@faculty"));
    });

    test("T4 poll clobber: a reapply landing between baseline read and "
        "commit survives the merge", () async {
      final doc0 = CampusManager.injectSignMeUpSynth(
          feedBody("Lima", 2, 8), synthBlock("one", 3, 9));
      await seed({WebcalKeys.url: _wcUrl, WebcalKeys.icsCache: doc0});
      final cm = _FeedManager();
      final parked = Completer<void>();
      final resume = Completer<void>();
      var polls = 0;
      store.onRead = (key) async {
        // stop the poll right after its baseline read of the cache
        if (key != WebcalKeys.icsCache || ++polls != 1) return;
        parked.complete();
        await resume.future;
      };
      final poll = MeiNotifications.mergePollCache(feedBody("Mike", 4, 10));
      await parked.future;
      await cm.reapplySignMeUpSynth(synthBlock("two", 3, 11)); // lands mid-poll
      resume.complete(); // poll commits
      await poll;
      store.onRead = null;
      final doc = await cacheDoc();
      expect(doc, contains("Mike Lecture"));
      expect(
          CampusManager.extractSignMeUpSynth(doc),
          contains("signmeup-two@ka_uni"),
          reason: "the poll blind-overwrote the newer synth block");
    });

    test("T5 every content-changing RMW moves DATA_webcalFetchedAt",
        () async {
      // one rule, every writer: content churn moves the stamp, so the
      // stale banner tells the truth after a poll or a reapply (F-1 tie)
      const t0 = "2026-01-01T00:00:00.000"; // ancient: any real stamp differs
      await seed({
        WebcalKeys.url: _wcUrl,
        WebcalKeys.icsCache: feedBody("Nova", 2, 8),
        WebcalKeys.fetchedAt: t0,
      });
      final cm = _FeedManager();
      Future<String?> stamp() => store.getString(WebcalKeys.fetchedAt, opts);
      Future<void> rewind() => store.setString(WebcalKeys.fetchedAt, t0, opts);

      await cm.reapplyExamSynth(examBlock("e1", 20, 9));
      expect(await stamp(), isNot(t0), reason: "reapplyExamSynth froze stamp");

      // the honest no-op must keep the stamp (byte-identity doctrine keeps
      // the alarm re-arm storm of the DTSTAMP-churn era away)
      await rewind();
      await cm.reapplyExamSynth(examBlock("e1", 20, 9));
      expect(await stamp(), t0, reason: "no-op re-write moved the stamp");

      await cm.reapplySignMeUpSynth(synthBlock("one", 3, 9));
      expect(await stamp(), isNot(t0),
          reason: "reapplySignMeUpSynth froze stamp");

      await rewind();
      await cm.setPersonalIcsFromRaw(
          _doc([personalBlock("A", 3, 8)]));
      expect(await stamp(), isNot(t0), reason: "_applyPersonalIcs froze stamp");

      await rewind();
      final due = _at(20, 18);
      await cm.publishDueBlock([
        IliasAnnouncement(
            courseRefId: 3038952,
            courseTitle: "Advanced Mathematics I",
            title: "Ubungsblatt 5 - Abgabe bis "
                "${due.day.toString().padLeft(2, "0")}."
                "${due.month.toString().padLeft(2, "0")}."
                "${due.year}, 18:00 Uhr",
            url: "https://ilias.test/goto/crs_1",
            when: _today),
      ]);
      expect(await stamp(), isNot(t0), reason: "publishDueBlock froze stamp");
      expect(await cacheDoc(), contains("X-DUE-SYNTH-BEGIN"));

      // R34.1: the Fristenbuch owner write joins the one-stamp rule
      await rewind();
      await cm.reapplyFrB(buildFristenbuchBlock([
        FristenbuchEntry(id: 1, label: "Frist", due: _at(9, 0))
      ]));
      expect(await stamp(), isNot(t0), reason: "reapplyFrB froze stamp");
      expect(await cacheDoc(), contains("X-FRISTENBUCH-BEGIN"));

      await rewind();
      await MeiNotifications.mergePollCache(feedBody("Oscar", 6, 12));
      expect(await stamp(), isNot(t0), reason: "poll froze stamp");
    });

    test("R34.1 frb writer: the fifth layer survives every other writer, "
        "the poll carries it, and the owner alone rules it", () async {
      final entries = [
        FristenbuchEntry(id: 1, label: "Wohnung kündigen", due: _at(9, 0))
      ];
      final frb = buildFristenbuchBlock(entries);
      final doc0 = CampusManager.injectFrB(
          CampusManager.injectExamSynth(
              feedBody("Papa", 2, 8), examBlock("f1", 20, 9)),
          frb);
      await seed({
        WebcalKeys.url: _wcUrl,
        WebcalKeys.icsCache: doc0,
        fristenbuchStoreKey: fristenbuchEntriesToJson(entries),
      });
      final cm = _FeedManager()..feedBody = feedBody("Quebec", 4, 10);

      // R1 foreground write: the projection union carries the layer even
      // on a cold memory copy
      expect(await cm.fetchWebcalTimetable(), isTrue);
      expect(CampusManager.extractFrB(await cacheDoc()), frb,
          reason: "R1 cold start dropped the Fristenbuch layer");

      // R2 poll merge: the frb block must ride the fresh feed exactly
      // like the other four layers (mergePollLayers injectFrB arm)
      await MeiNotifications.mergePollCache(feedBody("Romeo", 6, 12));
      expect(CampusManager.extractFrB(await cacheDoc()), frb,
          reason: "the poll dropped the Fristenbuch layer — the "
              "mergePollLayers inject/extractFrB arm is missing");

      // the owner grows it, other layers byte-intact
      await cm.reapplyFrB(buildFristenbuchBlock(
          [...entries, FristenbuchEntry(id: 2, label: "Visa Termin", due: _at(12, 0))]));
      expect(CampusManager.extractFrB(await cacheDoc()),
          contains("UID:kauni-frb-2"));
      expect(CampusManager.extractExamSynth(await cacheDoc()),
          contains("kauni-exam-f1"));

      // and the owner shrinks it — the union may never veto the owner
      await cm.reapplyFrB("");
      expect(CampusManager.extractFrB(await cacheDoc()), isEmpty);
      expect(CampusManager.extractExamSynth(await cacheDoc()),
          contains("kauni-exam-f1"));
    });
  });
}
