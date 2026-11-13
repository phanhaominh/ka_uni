// R36.1 FEED DOCTOR: the per-source verdicts the settings table renders,
// pinned from synthetic diag maps. These tests bind the three skeptic
// conditions of the lane: a missing key must NEVER read as ok, a
// rendered detail must arrive pre-scrubbed (the token URL lives inside
// DATA_webcalDiag), and the heartbeat row must degrade — not silently
// green — when the background poll never ran.
import 'package:flutter_test/flutter_test.dart';
import 'package:kit_mobile/diagnostics/feed_health.dart';
import 'package:kit_mobile/diagnostics/support_bundle.dart';
import 'package:kit_mobile/l10n/l10n.dart';

final _now = DateTime(2026, 11, 13, 12, 0);

FeedStatus _row(List<FeedStatus> rows, String source) =>
    rows.firstWhere((r) => r.source == source);

List<FeedStatus> _health(Map<String, String> diag,
        {bool granted = true, bool creds = true}) =>
    feedHealth(diag,
        notificationsPermission: granted,
        credentialsStored: creds,
        now: _now);

void main() {
  test("empty device state: every source is unknown, never ok", () {
    final rows = _health({});
    for (final source in ["webcal", "ilias", "smu", "rooms", "mensa", "grades"]) {
      final r = _row(rows, source);
      expect(r.state, FeedState.unknown, reason: "$source must not claim health");
      expect(r.state, isNot(FeedState.ok), reason: "$source unknown-not-ok");
    }
    // the row set itself is the render contract — heartbeat + 6 sources
    // + notifications
    expect(rows.map((r) => r.source),
        ["heartbeat", "webcal", "ilias", "smu", "rooms", "mensa", "grades", "notifications"]);
  });

  test("heartbeat absent = degraded with the battery hint, not unknown, never ok", () {
    final r = _row(_health({}), "heartbeat");
    expect(r.state, FeedState.degraded);
    expect(r.detailKey, "doctor.heartbeatNever");
  });

  test("heartbeat fresh ok; stale degraded with the time named; future degraded", () {
    String minutes(int ms) => (ms ~/ 60000).toString();
    final fresh = _row(
        _health({lastPollAtKey: minutes(_now.subtract(const Duration(minutes: 10)).millisecondsSinceEpoch)}),
        "heartbeat");
    expect(fresh.state, FeedState.ok);
    expect(fresh.detailKey, "doctor.heartbeatAt");
    expect(fresh.detailArg, "11:50"); // same-day clock rendering

    final stale = _row(
        _health({
          lastPollAtKey:
              minutes(_now.subtract(const Duration(days: 2)).millisecondsSinceEpoch)
        }),
        "heartbeat");
    expect(stale.state, FeedState.degraded);
    expect(stale.detailKey, "doctor.heartbeatStale");
    expect(stale.detailArg, "11.11. 12:00"); // other day -> date-prefixed clock

    final future = _row(
        _health({
          lastPollAtKey:
              minutes(_now.add(const Duration(hours: 3)).millisecondsSinceEpoch)
        }),
        "heartbeat");
    expect(future.state, FeedState.degraded, reason: "a poll from the future is not freshness");
  });

  test("webcal: fresh stamp ok; standing diag line caps to degraded; past horizon dead", () {
    final fresh = _row(_health({"DATA_webcalFetchedAt": _now.toIso8601String()}), "webcal");
    expect(fresh.state, FeedState.ok);
    expect(fresh.detailKey, "doctor.lastFetchAt");

    final failing = _row(
        _health({
          "DATA_webcalFetchedAt": _now.toIso8601String(),
          "DATA_webcalDiag": "11-13T11:55 HTTP 403",
        }),
        "webcal");
    expect(failing.state, FeedState.degraded, reason: "failure line outranks a fresh stamp");
    expect(failing.detailKey, "doctor.failing");

    final dead = _row(
        _health({
          "DATA_webcalFetchedAt":
              _now.subtract(const Duration(days: 8)).toIso8601String()
        }),
        "webcal");
    expect(dead.state, FeedState.dead);

    final corrupt = _row(_health({"DATA_webcalFetchedAt": "not-a-date"}), "webcal");
    expect(corrupt.state, FeedState.unknown);
  });

  test("scrub before render: the token URL inside a diag never reaches detailArg", () {
    const raw =
        "11-13T11:55 GET https://abc.webcal.kit.edu/webcal.ics?token=Sup3rS3cretTokenAbcdef "
        "threw (report me@stud.kit.edu)";
    final rows = _health({
      "DATA_webcalFetchedAt": _now.toIso8601String(),
      "DATA_webcalDiag": raw,
    });
    final arg = _row(rows, "webcal").detailArg!;
    expect(arg, isNot(contains("Sup3rS3cretTokenAbcdef")));
    expect(arg, isNot(contains("me@stud.kit.edu")));
    expect(arg, contains("<url>"));
    expect(arg, contains("<email>"));
    // the EXACT same redaction as the exported bundle, not a lookalike
    expect(arg, scrubDiag(raw));

    final mensaArg = _row(_health({
      "MENSA_fetchedAt": _now.toIso8601String(),
      "MENSA_diag": "11-13T11:55 threw: FormatException https://x.kit.edu/a?k=AAAAAAAABBBBBBBBCCCCCCCC",
    }), "mensa").detailArg!;
    expect(mensaArg, isNot(contains("AAAAAAAABBBBBBBBCCCCCCCC")));
    expect(mensaArg, isNot(contains("x.kit.edu")));
  });

  test("future stamps are never believed: not ok, whatever the source", () {
    final future = _now.add(const Duration(hours: 1)).toIso8601String();
    for (final entry in {
      "webcal": {"DATA_webcalFetchedAt": future},
      "mensa": {"MENSA_fetchedAt": future},
    }.entries) {
      final r = _row(_health(entry.value), entry.key);
      expect(r.state, isNot(FeedState.ok), reason: "${entry.key} on a forged stamp");
      expect(r.state, FeedState.dead, reason: "${entry.key} past-horizon-equivalent");
    }
  });

  test("mensa, rooms and ILIAS read their own stamps (rooms/ILIAS inside JSON blobs)", () {
    final ok = _row(
        _health({
          "MENSA_fetchedAt": _now.subtract(const Duration(hours: 5)).toIso8601String(),
          "ANN_rooms": '{"at":"${_now.subtract(const Duration(hours: 1)).toIso8601String()}","counts":{},"rooms":[]}',
          "DATA_iliasCardCache":
              '{"fetchedAt":"${_now.subtract(const Duration(days: 1)).toIso8601String()}"}',
        }),
        "mensa");
    expect(ok.state, FeedState.ok);
    expect(_row(_health({}), "mensa").state, FeedState.unknown);
    expect(_row(_health({}), "rooms").state, FeedState.unknown);

    final aging = _row(
        _health({
          "ANN_rooms": '{"at":"${_now.subtract(const Duration(days: 5)).toIso8601String()}"}',
        }),
        "rooms");
    expect(aging.state, FeedState.degraded); // > 3 d ttl, < 14 d horizon

    final broken = _row(
        _health({"DATA_iliasCardCache": "{corrupt json"}),
        "ilias");
    expect(broken.state, FeedState.unknown, reason: "a poisoned blob is silence, not an exception");
  });

  test("grades: no credentials = unknown-not-healthy; newest term stamp wins; junk unknown", () {
    final loggedOut = _row(_health({
      "module_cache_WS2627_last_fetch": _now.toIso8601String(),
    }, creds: false), "grades");
    expect(loggedOut.state, FeedState.unknown);
    expect(loggedOut.detailKey, "doctor.notLoggedIn");

    final newestWins = _row(_health({
      "module_cache_SS26_last_fetch":
          _now.subtract(const Duration(days: 9)).toIso8601String(),
      "module_cache_WS2627_last_fetch":
          _now.subtract(const Duration(hours: 3)).toIso8601String(),
    }), "grades");
    expect(newestWins.state, FeedState.ok);

    final aged = _row(_health({
      "module_cache_WS2627_last_fetch":
          _now.subtract(const Duration(days: 9)).toIso8601String(),
    }), "grades");
    expect(aged.state, FeedState.degraded); // > 7 d ttl, < 30 d horizon

    final junk = _row(
        _health({"module_cache_WS2627_last_fetch": "yesterday-ish"}), "grades");
    expect(junk.state, FeedState.unknown);
  });

  test("notifications: denied is degraded and actionable-shaped; granted ok", () {
    final denied = _row(_health({}, granted: false), "notifications");
    expect(denied.state, FeedState.degraded);
    expect(denied.detailKey, "doctor.notifDenied");
    expect(_row(_health({}), "notifications").state, FeedState.ok);
  });

  test("SignMeUp has no persisted fetch stamp: honestly unknown, forever", () {
    expect(_row(_health({}), "smu").state, FeedState.unknown);
    final fired = _row(_health({
      "DATA_smuOpensFired": '{"42":"2026-11-01T00:00:00.000"}',
    }), "smu");
    expect(fired.state, FeedState.unknown,
        reason: "the fired-FSM carries no time — it must not masquerade as a stamp");
    expect(fired.detailKey, "doctor.smuNoStamp");
  });

  test("every rendered key exists in BOTH l10n tables (shared != rendered guard)", () {
    // the failure mode of the whole lane is a row the pure layer emits
    // that the UI cannot name: label AND detail keys of every verdict
    // must resolve in de AND en, and a {0} template must have its arg
    final rows = _health({
      "DATA_webcalFetchedAt": _now.toIso8601String(),
      "MENSA_fetchedAt": _now.toIso8601String(),
      "MENSA_diag": "11-13T11:55 threw: X",
      lastPollAtKey: "${_now.millisecondsSinceEpoch ~/ 60000}",
      "module_cache_WS2627_last_fetch": _now.toIso8601String(),
    }, granted: false);
    for (final r in rows) {
      for (final table in [L10n.deTable, L10n.enTable]) {
        expect(table.containsKey(r.labelKey), isTrue,
            reason: "label key ${r.labelKey} missing (${r.source})");
        if (r.detailKey != null) {
          final template = table[r.detailKey!];
          expect(template, isNotNull,
              reason: "detail key ${r.detailKey} missing (${r.source})");
          final wantsArg = template!.contains("{0}");
          expect(r.detailArg != null, wantsArg,
              reason: "arg mismatch for ${r.detailKey} (${r.source})");
        }
      }
    }
  });
}
