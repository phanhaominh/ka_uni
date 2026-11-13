import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:kit_mobile/handbook/ampel.dart';
import 'package:kit_mobile/handbook/handbook_data.dart';
import 'package:kit_mobile/handbook/prereq_alarm.dart';

/// R32.5: pure grow-diff of the Schein-Ampel's KNOWN-block map - the
/// decisions the DATA_prereqAlarm snapshot round-trip leans on. Snapshot
/// keys are module CODES and blocker entries part CODES (R32 audit: a
/// handbook title reword must never masquerade as a new block); seeded-
/// ness is the "v2:" tag, so a tagged EMPTY map is live "no blocks" and
/// the first real block IS news.
void main() {
  HandbookModule mod(String code, String title, {List<HandbookPart> parts = const []}) =>
      HandbookModule(
          code: code,
          title: title,
          ects: 6,
          terms: const ["WS"],
          examType: "Klausur",
          parts: parts,
          gates: const []);
  HandbookPart part(String code, String title) => HandbookPart(
      code: code, title: title, ects: 0, type: "Prüfungsvorleistung", attendsTo: "01-C");

  AmpelPlan planWith(List<AmpelModule> items) => AmpelPlan(items);
  AmpelModule blocked(HandbookModule m, List<String> by) =>
      AmpelModule(m, AmpelState.planned, blockedBy: by);
  AmpelModule free(HandbookModule m) => AmpelModule(m, AmpelState.planned);

  final partA = part("01-C-P1", "Übungsschein C");
  final partB = part("01-C-P2", "Prüfungsschein C");

  String snap(Map<String, List<String>> m) =>
      prereqSnapshotTag + jsonEncode(m);

  test("snapshot keys by code and maps blocker titles to part codes", () {
    final plan = planWith([
      blocked(mod("01-A", "Modul A"), ["Übungsschein C", "Unbekanntes Teil"]),
      free(mod("01-B", "Modul B")),
      free(mod("01-C", "Modul C", parts: [partA, partB])),
    ]);
    // resolved part -> its code; unmatched blocker title survives verbatim
    expect(prereqSnapshot(plan), {
      "01-A": ["01-C-P1", "Unbekanntes Teil"],
    });
  });

  test("titles resolve codes from the fresh plan (modules AND parts)", () {
    final plan = planWith([free(mod("01-C", "Modul C", parts: [partA, partB]))]);
    final t = prereqTitles(plan);
    expect(t["01-C"], "Modul C");
    expect(t["01-C-P1"], "Übungsschein C");
    expect(t["01-C-P2"], "Prüfungsschein C");
  });

  test("grow: a newly blocked module fires one event with its blockers", () {
    final grew = prereqAlarmDiff(
        blockedNow: {"01-A": ["01-C-P1"]}, snapshotRaw: snap({"01-Z": ["01-Y-P9"]}));
    expect(grew.single.moduleCode, "01-A");
    expect(grew.single.newBlockerCodes, ["01-C-P1"]);
  });

  test("grow from the LIVE-EMPTY snapshot announces the first real block "
      "(the audit MAJOR: '{}' is news, not seed)", () {
    final grew = prereqAlarmDiff(
        blockedNow: {"01-A": ["01-C-P1"]}, snapshotRaw: snap({}));
    expect(grew.single.moduleCode, "01-A");
    expect(grew.single.newBlockerCodes, ["01-C-P1"]);
  });

  test("an already-blocked module counts again only for a NEW blocker", () {
    final grew = prereqAlarmDiff(
        blockedNow: {"01-A": ["01-C-P1", "01-C-P2"]},
        snapshotRaw: snap({"01-A": ["01-C-P1"]}));
    expect(grew.single.moduleCode, "01-A");
    expect(grew.single.newBlockerCodes, ["01-C-P2"]);
  });

  test("same code, reworded titles: silent (handbook bump is not a block)", () {
    // snapshot stored codes; the fresh plan re-resolves the SAME codes
    // (titles in the handbook asset changed) - no event may fire.
    final grew = prereqAlarmDiff(
        blockedNow: {"01-A": ["01-C-P1"]}, snapshotRaw: snap({"01-A": ["01-C-P1"]}));
    expect(grew, isEmpty);
  });

  test("shrink is silent: relief is not news", () {
    final grew = prereqAlarmDiff(
        blockedNow: {}, snapshotRaw: snap({"01-A": ["01-C-P1"]}));
    expect(grew, isEmpty);
  });

  test("no-change is silent", () {
    final grew = prereqAlarmDiff(
        blockedNow: {"01-A": ["01-C-P1"]}, snapshotRaw: snap({"01-A": ["01-C-P1"]}));
    expect(grew, isEmpty);
  });

  test("unseeded (null, empty, or pre-v2 untagged JSON) announces NOTHING", () {
    for (final raw in [null, "", jsonEncode({"Modul A": ["irgendwas"]})]) {
      final grew = prereqAlarmDiff(
          blockedNow: {"01-A": ["01-C-P1"]}, snapshotRaw: raw);
      expect(grew, isEmpty, reason: "raw=${raw == null ? "null" : "untagged"}");
    }
  });

  test("poisoned v2 payload is a seed run, not spam", () {
    final grew = prereqAlarmDiff(
        blockedNow: {"01-A": ["01-C-P1"]},
        snapshotRaw: prereqSnapshotTag + "{not json");
    expect(grew, isEmpty);
  });
}
