import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:kit_mobile/ilias/models/ilias_models.dart';
import 'package:kit_mobile/notifications/mei_notifications.dart';
import 'package:kit_mobile/state_management/ilias/ilias_watcher.dart';
import 'package:shared_preferences/shared_preferences.dart';
// The watcher reads/writes its seen key via the LIVE async API, so the
// test store must back exactly that platform interface. Its in-memory
// fake ships with the platform-interface package (transitive dep of
// shared_preferences; importing it beats adding a pub dep for tests).
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

/// Platform store whose writes die: proves the watcher never pushes before
/// the seen-marking is durable.
base class _WriteFailingStore extends InMemorySharedPreferencesAsync {
  _WriteFailingStore.withData(Map<String, Object> data) : super.withData(data);

  @override
  Future<bool> setString(
          String key, String value, SharedPreferencesOptions options) async =>
      throw StateError("platform write died");
}

IliasAnnouncement _a(String title,
        {int ref = 4711, String course = "Analysis I", DateTime? when}) =>
    IliasAnnouncement(
        courseRefId: ref,
        courseTitle: course,
        title: title,
        url: "https://ilias.example/x",
        when: when);

void main() {
  late List<(String, String)> pushed;

  late InMemorySharedPreferencesAsync store;
  const opts = SharedPreferencesOptions();

  setUp(() {
    store = InMemorySharedPreferencesAsync.empty();
    SharedPreferencesAsyncPlatform.instance = store;
    pushed = [];
    IliasWatcher.notify = (title, body) async => pushed.add((title, body));
  });
  tearDown(() => IliasWatcher.notify = MeiNotifications.notifyChange);

  Future<void> seedRaw(String raw) =>
      store.setString(IliasWatcher.seenKey, raw, opts);

  Future<List<String>> stored() async {
    final raw = await store.getString(IliasWatcher.seenKey, opts);
    return raw == null ? [] : (jsonDecode(raw) as List).cast<String>();
  }

  test("idOf folds case and whitespace but KEEPS punctuation", () {
    expect(IliasWatcher.idOf(_a("  Übung   3 ONLINE!! ")),
        "4711|übung 3 online!!");
    expect(IliasWatcher.idOf(_a("Übung 3 online")), "4711|übung 3 online");
    // folding "Übung 3." into "Übung 3" used to silently swallow distinct
    // posts forever - punctuation is title content, never chrome here
    expect(IliasWatcher.idOf(_a("Übung 3.")),
        isNot(IliasWatcher.idOf(_a("Übung 3"))));
    // same title in another course is still a distinct announcement
    expect(IliasWatcher.idOf(_a("Übung 3", ref: 815)), "815|übung 3");
  });

  test("first run seeds silently, no notification storm", () async {
    await IliasWatcher.diffAndNotify([_a("Klausurtermin"), _a("Übung 1")]);
    expect(pushed, isEmpty);
    expect(await stored(), ["4711|klausurtermin", "4711|übung 1"]);
  });

  test("second run notifies only genuinely new entries, oldest-first, max 3",
      () async {
    await IliasWatcher.diffAndNotify([_a("alt 1"), _a("alt 2")]);
    pushed.clear();
    await IliasWatcher.diffAndNotify([
      _a("alt 2"), // seen already
      _a("neu 1"),
      _a("neu 2"),
      _a("neu 3"),
      _a("neu 4"),
      _a("neu 5"),
    ]);
    expect(pushed.map((p) => p.$2), ["neu 1", "neu 2", "neu 3"]);
    // ALL five are marked seen, not just the three pushed
    final s = await stored();
    expect(s, containsAll(["4711|neu 4", "4711|neu 5"]));
    expect(s.length, 7);
  });

  test("nothing new means no push", () async {
    await IliasWatcher.diffAndNotify([_a("Gleich")]);
    pushed.clear();
    await IliasWatcher.diffAndNotify([_a("  GLEICH ")]); // same id
    expect(pushed, isEmpty);
    expect(await stored(), ["4711|gleich"]);
  });

  test("duplicates within one fresh batch notify once", () async {
    await IliasWatcher.diffAndNotify([]); // seed past the first run
    await IliasWatcher.diffAndNotify(
        [_a("Vorlesungausfall"), _a("VORLESUNGAUSFALL "), _a("Anderes")]);
    expect(pushed.map((p) => p.$2), ["Vorlesungausfall", "Anderes"]);
    expect(await stored(), ["4711|vorlesungausfall", "4711|anderes"]);
  });

  test("seen list trims to the newest 300", () async {
    await seedRaw(jsonEncode([for (var i = 0; i < 299; i++) "9|alt$i"]));
    await IliasWatcher.diffAndNotify(
        [for (var i = 0; i < 5; i++) _a("neu $i")]);
    final s = await stored();
    expect(s.length, 300);
    expect(s.first, "9|alt4"); // four oldest dropped
    expect(s.last, "4711|neu 4");
    expect(pushed.length, 3); // and the cap still applies
  });

  test("cap trim keeps ids still on the board: no resurrection re-notify",
      () async {
    await seedRaw(jsonEncode([for (var i = 0; i < 299; i++) "9|alt$i"]));
    // "9|alt0" is the oldest id AND still announced: a plain age-trim
    // drops it, and the next batch that still carries it re-notifies it
    final board = [
      _a("alt0", ref: 9, course: "Altkurs"),
      for (var i = 0; i < 5; i++) _a("neu $i"),
    ];
    await IliasWatcher.diffAndNotify(board);
    final s = await stored();
    expect(s.length, 300);
    expect(s, contains("9|alt0"));
    expect(s, isNot(contains("9|alt1"))); // off-board oldest dropped first
    pushed.clear();
    await IliasWatcher.diffAndNotify(board);
    expect(pushed, isEmpty); // a plain trim resurrects alt0 right here
  });

  test("a failing push stays unmarked and is retried, not lost", () async {
    await IliasWatcher.diffAndNotify([]); // seed past the first run
    var down = true;
    IliasWatcher.notify = (title, body) async {
      if (down && body == "krank") throw Exception("channel down");
      pushed.add((title, body));
    };
    await IliasWatcher.diffAndNotify([_a("krank")]);
    expect(pushed, isEmpty);
    expect(await stored(), isEmpty); // the failed attempt consumed nothing
    down = false;
    await IliasWatcher.diffAndNotify([_a("krank")]);
    expect(pushed.map((p) => p.$2), ["krank"]); // late, not swallowed
  });

  test("entries whose title is pure chrome are skipped entirely", () async {
    await IliasWatcher.diffAndNotify([]); // seed past the first run
    await IliasWatcher.diffAndNotify([_a(" – !! "), _a("Echt")]);
    expect(pushed.map((p) => p.$2), ["Echt"]);
    pushed.clear();
    await IliasWatcher.diffAndNotify([_a("– …")]);
    expect(pushed, isEmpty);
  });

  test("corrupt store re-seeds silently instead of re-notifying all", () async {
    await seedRaw("{oops");
    await IliasWatcher.diffAndNotify([_a("Alles beim alten")]);
    expect(pushed, isEmpty);
    expect(await stored(), ["4711|alles beim alten"]);
  });

  test("body appends ' – dd.MM.' only when the feed stated a date", () async {
    await IliasWatcher.diffAndNotify([]); // seed past the first run
    await IliasWatcher.diffAndNotify([
      _a("Abgabe verschoben", when: DateTime(2026, 11, 3)),
      _a("Ohne Datum"),
      _a("Ohne Kurs", course: ""),
    ]);
    expect(pushed[0], ("Analysis I", "Abgabe verschoben – 03.11."));
    expect(pushed[1].$2, "Ohne Datum");
    expect(pushed[2].$1, "ILIAS"); // l10n fallback for empty courseTitle
  });

  test("first-run seed also caps at 300 ids", () async {
    await IliasWatcher.diffAndNotify(
        [for (var i = 0; i < 500; i++) _a("Ankündigung $i")]);
    expect(pushed, isEmpty);
    final s = await stored();
    expect(s.length, 300);
    expect(s.first, "4711|ankündigung 200"); // newest tail kept
  });

  test("wrong-typed store counts as corrupt: re-seeds silently", () async {
    await seedRaw(jsonEncode([1, 2, 3]));
    await IliasWatcher.diffAndNotify([_a("Übung 7")]);
    // "[1,2,3]" coerced to ids "1","2","3" would diff against never-matching
    // junk and re-notify the whole board through the back door
    expect(pushed, isEmpty);
    expect(await stored(), ["4711|übung 7"]);
  });

  test("one failing push does not swallow its siblings", () async {
    await IliasWatcher.diffAndNotify([]); // seed past the first run
    IliasWatcher.notify = (title, body) async {
      if (body == "krank") throw Exception("channel down");
      pushed.add((title, body));
    };
    await IliasWatcher.diffAndNotify([_a("ok 1"), _a("krank"), _a("ok 2")]);
    expect(pushed.map((p) => p.$2), ["ok 1", "ok 2"]);
  });

  test("concurrent calls share one pass and never double-push", () async {
    await IliasWatcher.diffAndNotify([]); // seed past the first run
    pushed.clear();
    await Future.wait([
      IliasWatcher.diffAndNotify([_a("Rennen 1"), _a("Rennen 2")]),
      IliasWatcher.diffAndNotify([_a("Rennen 1"), _a("Rennen 2")]),
    ]);
    expect(pushed.length,
        2); // each exactly once, the second call re-pushed nothing
  });

  test("logout mid-flight aborts before the remaining pushes", () async {
    final epoch = MeiNotifications.teardownEpoch;
    try {
      await seedRaw(jsonEncode(["4711|basis"]));
      IliasWatcher.notify = (title, body) async {
        pushed.add((title, body));
        // emulate the logout landing mid-loop, like cancelAllScheduled does
        MeiNotifications.teardownEpoch++;
      };
      await IliasWatcher.diffAndNotify([_a("A"), _a("B")]);
      expect(pushed.map((p) => p.$2), ["A"]); // B fenced by the epoch
    } finally {
      MeiNotifications.teardownEpoch = epoch;
    }
  });

  test("stillOurs=false aborts pushes AND the persist: late, never lost",
      () async {
    await IliasWatcher.diffAndNotify([_a("alt")]); // seed
    pushed.clear();
    var ours = false;
    await IliasWatcher.diffAndNotify([_a("alt"), _a("neu")],
        stillOurs: () async => ours);
    expect(pushed, isEmpty);
    expect(await stored(), ["4711|alt"]); // nothing marked while fenced
    ours = true; // the announcement was delayed, not swallowed
    await IliasWatcher.diffAndNotify([_a("alt"), _a("neu")],
        stillOurs: () async => ours);
    expect(pushed, [("Analysis I", "neu")]);
    expect(await stored(), contains("4711|neu"));
  });

  test("first-run seed is refused while stillOurs says not ours", () async {
    // the poll isolate right after a logout: the sweep already deleted
    // the seen key; seeding now would resurrect the OLD board's titles
    await IliasWatcher.diffAndNotify([_a("Impressum")],
        stillOurs: () async => false);
    expect(pushed, isEmpty);
    expect(await stored(), isEmpty);
  });

  test("seen-marking is durable BEFORE the first push (cross-isolate dedupe)",
      () async {
    // the ~30-min poll diffs the SAME key in its own isolate while this
    // run is mid-flight: at the instant a heads-up goes up, the ids must
    // already be claimed, or both isolates push the same announcement
    await seedRaw(jsonEncode(["4711|basis"]));
    final claimsAtPush = <List<String>>[];
    IliasWatcher.notify = (title, body) async {
      // exactly what a concurrent poll isolate would diff against NOW
      final raw = await store.getString(IliasWatcher.seenKey, opts);
      claimsAtPush.add((jsonDecode(raw!) as List).cast<String>());
      pushed.add((title, body));
    };
    await IliasWatcher.diffAndNotify([_a("basis"), _a("neu 1"), _a("neu 2")]);
    expect(pushed.map((p) => p.$2), ["neu 1", "neu 2"]);
    expect(claimsAtPush, hasLength(2));
    for (final seen in claimsAtPush) {
      expect(seen, containsAll(["4711|neu 1", "4711|neu 2"]));
    }
  });

  test("a claim that does not persist pushes nothing, retries later", () async {
    await seedRaw(jsonEncode([])); // past the first run, nothing seen
    SharedPreferencesAsyncPlatform.instance =
        _WriteFailingStore.withData({IliasWatcher.seenKey: "[]"});
    await IliasWatcher.diffAndNotify([_a("zu früh")]);
    expect(pushed, isEmpty); // show() only ever runs on a durable claim
    SharedPreferencesAsyncPlatform.instance = store;
    await IliasWatcher.diffAndNotify([_a("zu früh")]);
    expect(pushed.map((p) => p.$2), ["zu früh"]); // delayed, never lost
  });
}
