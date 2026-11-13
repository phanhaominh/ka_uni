import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:kit_mobile/handbook/ampel.dart';
import 'package:kit_mobile/handbook/handbook_data.dart';
import 'package:kit_mobile/handbook/prereq_alarm.dart';

/// R32.5: pure grow-diff of the Schein-Ampel's KNOWN-block map - the
/// decisions the DATA_prereqAlarm snapshot round-trip leans on.
void main() {
  HandbookModule mod(String title) => HandbookModule(
      code: "01-X",
      title: title,
      ects: 6,
      terms: const ["WS"],
      examType: "Klausur",
      parts: const [],
      gates: const []);
  AmpelModule blocked(String title, List<String> by) =>
      AmpelModule(mod(title), AmpelState.planned, blockedBy: by);
  AmpelModule free(String title) =>
      AmpelModule(mod(title), AmpelState.planned);

  test("snapshot keeps only blocked modules, blockers sorted", () {
    final plan =
        AmpelPlan([blocked("Modul A", ["Prüfung C", "Prüfung A"]), free("Modul B")]);
    expect(prereqSnapshot(plan), {
      "Modul A": ["Prüfung A", "Prüfung C"],
    });
  });

  test("grow: a newly blocked module fires one event with its blockers", () {
    final grew = prereqAlarmDiff(
        blockedNow: {"Modul A": ["Prüfung A"]},
        snapshotRaw: jsonEncode({"Modul Z": ["Prüfung Z"]}));
    expect(grew.single.module, "Modul A");
    expect(grew.single.newBlockers, ["Prüfung A"]);
  });

  test("grow: an already-blocked module counts again only for a NEW "
      "blocker", () {
    final prev = jsonEncode({
      "Modul A": ["Prüfung A"]
    });
    // same blockers -> quiet
    expect(
        prereqAlarmDiff(
            blockedNow: {
              "Modul A": ["Prüfung A"]
            },
            snapshotRaw: prev),
        isEmpty);
    // one more prerequisite failed -> event naming ONLY the new blocker
    final grew = prereqAlarmDiff(
        blockedNow: {
          "Modul A": ["Prüfung A", "Prüfung B"]
        },
        snapshotRaw: prev);
    expect(grew.single.module, "Modul A");
    expect(grew.single.newBlockers, ["Prüfung B"],
        reason: "re-listing the known blocker would re-claim the old news");
  });

  test("shrink is silent: relief is not news", () {
    final grew = prereqAlarmDiff(
        blockedNow: {
          "Modul A": ["Prüfung A"]
        },
        snapshotRaw: jsonEncode({
          "Modul A": ["Prüfung A", "Prüfung B"]
        }));
    expect(grew, isEmpty);
    // vanishing entirely from the map is silent too
    expect(
        prereqAlarmDiff(blockedNow: {}, snapshotRaw: jsonEncode({"Modul A": ["Prüfung A"]})),
        isEmpty);
  });

  test("no-change is silent", () {
    final snap = jsonEncode({
      "Modul A": ["Prüfung A"],
      "Modul B": ["Prüfung B"],
    });
    final now = {
      "Modul A": ["Prüfung A"],
      "Modul B": ["Prüfung B"],
    };
    expect(prereqAlarmDiff(blockedNow: now, snapshotRaw: snap), isEmpty);
  });

  test("first seed (missing/empty/poisoned snapshot) announces NOTHING", () {
    final now = {
      "Modul A": ["Prüfung A"],
      "Modul B": ["Prüfung B"],
    };
    // first-ever ledger: every block looks new - announcing them would
    // replay the "30 grades as 30 news" storm mistake
    expect(prereqAlarmDiff(blockedNow: now, snapshotRaw: null), isEmpty);
    expect(prereqAlarmDiff(blockedNow: now, snapshotRaw: ""), isEmpty);
    expect(prereqAlarmDiff(blockedNow: now, snapshotRaw: "n}{ot json"),
        isEmpty);
    // valid JSON, foreign shape: still the seed path, never a re-announce
    expect(prereqAlarmDiff(blockedNow: now, snapshotRaw: '{"a": 1}'), isEmpty);
  });
}
