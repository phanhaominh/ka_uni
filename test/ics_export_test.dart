import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kit_mobile/l10n/l10n.dart';
import 'package:kit_mobile/timetable/logic/ics_export.dart';
import 'package:kit_mobile/timetable/logic/ics_export_action.dart';
import 'package:kit_mobile/timetable/models/webcal.dart';
import 'package:kit_mobile/toasts/models/toasts_provider.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

String _text(IcsExport e) => utf8.decode(e.bytes);

const personalBegin = "X-PERSONAL-ICS-BEGIN\r\n";
const personalEnd = "X-PERSONAL-ICS-END\r\n";
const synthBegin = "X-SIGNMEUP-SYNTH-BEGIN\r\n";
const synthEnd = "X-SIGNMEUP-SYNTH-END\r\n";

String _ev(String uid, String summary, String dtstart) =>
    "BEGIN:VEVENT\r\nUID:$uid\r\nSUMMARY:$summary\r\n"
    "DTSTART:$dtstart\r\nEND:VEVENT\r\n";

void main() {
  final fixture3 = File('test/fixtures/webcal_e2e.ics').readAsStringSync();
  final fixture30 = File('test/fixtures/wc_now.ics').readAsStringSync();

  test("round-trip: exported bytes re-parse with the same event count", () {
    final e = buildIcsExport(fixture3, now: DateTime(2026, 10, 31))!;
    expect(e.eventCount, 3);

    // the app's own parser must accept the file and see exactly those events
    final feed =
        WebcalFeed.parse(_text(e), now: DateTime(2026, 11, 5, 8, 0));
    expect(feed, isNotNull);
    expect(feed!.occurrences.length, e.eventCount);
  });

  test("round-trip: real 30-event KIT feed survives export + re-parse", () {
    final e = buildIcsExport(fixture30, now: DateTime(2026, 10, 31))!;
    expect(e.eventCount, 30);

    final text = _text(e);
    final feed = WebcalFeed.parse(text, now: DateTime(2026, 10, 30, 18));
    expect(feed, isNotNull);
    // weekly series expand to AT LEAST one occurrence each ...
    expect(feed!.occurrences.length, greaterThanOrEqualTo(e.eventCount));
    // ... and the exported document holds exactly the reported VEVENTs
    expect(RegExp("BEGIN:VEVENT").allMatches(text).length, e.eventCount);
  });

  test("filename: deterministic yyyyMMdd suffix under a fixed clock", () {
    expect(buildIcsExport(fixture3, now: DateTime(2026, 10, 31))!.fileName,
        "mei-stundenplan-20261031.ics");
    expect(buildIcsExport(fixture3, now: DateTime(2027, 1, 5))!.fileName,
        "mei-stundenplan-20270105.ics");
    // live clock: shape only
    expect(buildIcsExport(fixture3)!.fileName,
        matches(RegExp(r"^mei-stundenplan-\d{8}\.ics$")));
  });

  test("merged cache: sentinels, URLs, tokens and PRODID never exported", () {
    final merged = fixture30.replaceFirst(
        "END:VCALENDAR",
        "$personalBegin${_ev("p1@own", "Eigene Vorlesung", "20261106T140000")}$personalEnd"
        "$synthBegin${_ev("s1@smu", "Tutorium Synth", "20261106T160000")}$synthEnd"
        "END:VCALENDAR");

    final e = buildIcsExport(merged, now: DateTime(2026, 10, 31))!;
    expect(e.eventCount, 32); // 30 feed + 1 personal + 1 synth

    final text = _text(e);
    expect(text, isNot(contains("X-PERSONAL-ICS")));
    expect(text, isNot(contains("X-SIGNMEUP-SYNTH")));
    expect(text.toLowerCase(), isNot(contains("http")));
    expect(text.toUpperCase(), isNot(contains("TOKEN")));
    expect(text, isNot(contains("PRODID")));
    // feed metadata headers are gone (the fixture carries PRODID + a
    // URL:https://campus.studium.kit.edu line); UIDs intentionally keep
    // their @domain part: RFC 2445 mandates uniqueness and stable UID
    // identity is what lets re-imports update instead of duplicate, and
    // the app's own dedupe keys on the local part only
    final header = text.substring(0, text.indexOf("BEGIN:VEVENT"));
    expect(header.toLowerCase(), isNot(contains("http")));
    expect(header, isNot(contains("cascampus")));
    expect(header, isNot(contains("campus.studium.kit.edu")));

    // the exported document holds exactly feed + injected events
    expect(RegExp("BEGIN:VEVENT").allMatches(text).length, 32);
    // and the app parser renders the injected ones like the feed's own
    final feed = WebcalFeed.parse(text, now: DateTime(2026, 10, 30, 18));
    expect(feed, isNotNull);
    expect(feed!.occurrences.any((o) => o.title == "Eigene Vorlesung"), isTrue);
    expect(feed.occurrences.any((o) => o.title == "Tutorium Synth"), isTrue);
  });

  test("webcal:// and folded non-http URLs are stripped from event bodies",
      () {
    final merged = fixture3.replaceFirst(
        "END:VCALENDAR",
        "BEGIN:VEVENT\r\n"
        "UID:w1@own\r\n"
        "SUMMARY:Personal Note\r\n"
        "DTSTART:20261106T140000\r\n"
        "DESCRIPTION:subscribe webcal://feed.example.org/private/tok123.ics\r\n"
        "ATTACH;VALUE=URI:webcal://attach.example.org/x.ics\r\n"
        "X-BENIGN:only text here\r\n"
        "END:VEVENT\r\n"
        "BEGIN:VEVENT\r\n"
        "UID:w2@own\r\n"
        "SUMMARY:Folded Trap\r\n"
        "DTSTART:20261106T150000\r\n"
        "DESCRIPTION:split across folds\r\n https://sneaky.example.org/a\r\n"
        "END:VEVENT\r\n"
        "END:VCALENDAR");

    final e = buildIcsExport(merged, now: DateTime(2026, 10, 31))!;
    expect(e.eventCount, 5); // 3 fixture + 2 injected, URL lines only

    final text = _text(e).toLowerCase();
    expect(text, isNot(contains("webcal")));
    expect(text, isNot(contains("sneaky")));
    expect(text, isNot(contains("tok123")));
    // the events themselves survive — only the URL-bearing lines drop
    expect(text, contains("personal note"));
    expect(text, contains("only text here"));
  });

  test("empty / non-exportable cache: null signal, no exception", () {
    expect(buildIcsExport(""), isNull);
    // stub calendar written by _applyPersonalIcs before any fetch
    expect(buildIcsExport("BEGIN:VCALENDAR\r\nEND:VCALENDAR\r\n"), isNull);
    // only sentinel-marked fluff left
    expect(
        buildIcsExport(
            "BEGIN:VCALENDAR\r\n$personalBegin$personalEnd\r\nEND:VCALENDAR\r\n"),
        isNull);
    // events without a VCALENDAR wrapper are rejected, too
    expect(buildIcsExport(_ev("x@y", "Orphan", "20261105T100000")), isNull);
  });

  test("over-long property lines are folded and unfold losslessly", () {
    const summary = "Sehr langes Titelformat für einen Test mit vielen "
        "Wörtern, um die RFC-5545-Zeilenbegrenzung von 75 Oktetten deutlich "
        "zu überschreiten und das Soft-Folding zu prüfen.";
    final raw = "BEGIN:VCALENDAR\r\nVERSION:2.0\r\n"
        "${_ev("f@t", summary, "20261105T080000")}END:VCALENDAR\r\n";
    final e = buildIcsExport(raw, now: DateTime(2026, 10, 31))!;

    for (final line in _text(e).split("\r\n")) {
      expect(utf8.encode(line).length, lessThanOrEqualTo(75));
    }
    final feed =
        WebcalFeed.parse(_text(e), now: DateTime(2026, 11, 5, 8));
    expect(feed!.occurrences.single.title, summary);
  });

  testWidgets("busy share: a second tap while an export runs toasts",
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final toasts = _RecordingToasts();
    late BuildContext ctx;
    await tester.pumpWidget(ChangeNotifierProvider<ToastsProvider>(
      create: (_) => toasts,
      child: Builder(builder: (b) {
        ctx = b;
        return const SizedBox.shrink();
      }),
    ));

    final first = exportMergedTimetableIcs(ctx);
    // synchronous dedupe: this tap lands while the first export is still
    // in flight - before C98 it was a silent no-op from the user's POV
    exportMergedTimetableIcs(ctx);
    await first;

    expect(toasts.shown, contains(L10n.t("export.inFlight")));
  });
}

/// records the toast texts instead of arming real hide timers
class _RecordingToasts extends ToastsProvider {
  final shown = <String>[];

  @override
  Future<void> showTextToast(String message,
      {Duration duration = Duration.zero,
      Color backgroundColor = Colors.grey,
      Color? foregroundColor}) async {
    shown.add(message);
  }
}
