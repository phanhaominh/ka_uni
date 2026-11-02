import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kit_mobile/timetable/models/webcal.dart';

void main() {
  test('parses real KIT webcal fixture', () {
    final raw = File('test/fixtures/wc_now.ics').readAsStringSync();
    final feed = WebcalFeed.parse(raw, now: DateTime(2026, 10, 30, 18, 0));
    expect(feed, isNotNull);
    // 30 VEVENTs: weekly series expanded + break singles within horizon
    expect(feed!.occurrences.length, greaterThan(30));

    // no occurrence outside the horizon
    final horizon = DateTime(2026, 10, 30).add(const Duration(days: 57));
    for (final o in feed.occurrences) {
      expect(o.start.isAfter(horizon), isFalse, reason: o.title);
    }

    // EXDATE honored: Mechanical Design A Tutorial Mon 11:30 excluded 28.12.
    final mdMon = feed.occurrences
        .where((o) =>
            o.title.contains('Mechanical Design A (Tutorial)') &&
            o.start.weekday == DateTime.monday &&
            o.start.hour == 11 &&
            o.start.minute == 30)
        .map((o) => "${o.start.month}.${o.start.day}")
        .toList();
    expect(mdMon.contains('12.28'), isFalse, reason: 'EXDATE leaked: $mdMon');
    expect(mdMon.contains('11.2'), isTrue, reason: 'missing 2.11: $mdMon');

    // duplicate Math I series (3 events same start) -> not tripled same day
    final mathDays = feed.occurrences
        .where((o) =>
            o.title.contains('Advanced Mathematics I') &&
            o.start.hour == 9 &&
            o.start.minute == 0)
        .map((o) => o.start.toIso8601String().substring(0, 10))
        .toList();
    expect(mathDays.toSet().length, mathDays.length,
        reason: 'duplicate occurrences on same day: $mathDays');

    // rooms preserved
    expect(
        feed.occurrences.any((o) => o.room.contains('Carl-Benz-Hörsaal')),
        isTrue);

    // weekly template: Monday has MD Tutorial 11:30 in its block
    final weekly = feed.toWeeklyTemplate();
    final monday = weekly.days.first;
    expect(
        monday.appointments
            .any((a) => a.title.contains('Mechanical Design A') && a.begin.hour == 11),
        isTrue,
        reason: 'monday: ${monday.appointments.map((a) => a.title)}');

    // fingerprint stable & change-sensitive
    final fp1 = feed.fingerprint();
    expect(fp1, feed.fingerprint());
    expect(fp1 == WebcalFeed.parse(raw.replaceFirst('Carl-Benz', 'Other-Room'),
            now: DateTime(2026, 10, 30, 18, 0))!
        .fingerprint(), isFalse);
  });

  String ics(List<String> events) =>
      "BEGIN:VCALENDAR\nVERSION:2.0\n${events.join()}"
      "END:VCALENDAR\n";

  String ev(String uid, String start, String end, String summary,
          String room) =>
      "BEGIN:VEVENT\nUID:$uid\nDTSTART:$start\nDTEND:$end\n"
      "SUMMARY:$summary\nLOCATION:$room\nEND:VEVENT\n";

  test('changesSince classifies added/removed/moved/room-change', () {
    final now = DateTime(2026, 11, 2, 8);
    final before = WebcalFeed.parse(ics([
      ev("1@kit", "20261102T160000", "20261102T180000", "AdM V", "HS1"),
      ev("2@kit", "20261103T080000", "20261103T100000", "MEI V", "HS31.47"),
      ev("3@kit", "20261104T140000", "20261104T160000", "MSE Ü", "Bldc.10.30"),
    ]), now: now);
    final after = WebcalFeed.parse(ics([
      // moved: 16:00 -> 18:00
      ev("1@kit", "20261102T180000", "20261102T200000", "AdM V", "HS1"),
      // room changed in place
      ev("2@kit", "20261103T080000", "20261103T100000", "MEI V", "HS31.48"),
      // series 3 dropped -> removed
      ev("4@kit", "20261105T100000", "20261105T120000", "Übung Design A", "HS50.31"),
    ]), now: now);
    expect(before, isNotNull);
    expect(after, isNotNull);

    final changes = after!.changesSince(before);
    IcsChange forTitle(String t) => changes.firstWhere((c) => c.title == t);
    expect(forTitle("AdM V").kind, IcsChangeKind.moved);
    expect(forTitle("AdM V").describe(), contains("Verschoben"));
    expect(forTitle("MEI V").kind, IcsChangeKind.changed);
    expect(forTitle("MEI V").describe(), contains("HS31.47 → HS31.48"));
    expect(forTitle("MSE Ü").kind, IcsChangeKind.removed);
    expect(forTitle("Übung Design A").kind, IcsChangeKind.added);
    // sorted by new occurrence time
    for (var i = 1; i < changes.length; i++) {
      expect(changes[i - 1].when.isBefore(changes[i].when), isTrue);
    }
  });

  test('IcsChange JSON round-trips through storage encoding', () {
    final changes = [
      IcsChange(
          kind: IcsChangeKind.moved,
          title: "AdM V",
          when: DateTime(2026, 11, 2, 18),
          room: "HS1",
          oldRoom: "HS1",
          oldWhen: DateTime(2026, 11, 2, 16)),
      IcsChange(
          kind: IcsChangeKind.removed,
          title: "MSE Ü",
          when: DateTime(2026, 11, 4, 14),
          room: ""),
    ];
    final back = IcsChange.decode(IcsChange.encode(changes));
    expect(back.length, 2);
    expect(back[0].kind, IcsChangeKind.moved);
    expect(back[0].oldWhen, DateTime(2026, 11, 2, 16));
    expect(back[1].describe(), startsWith("Entfällt: MSE Ü"));
    expect(IcsChange.decode("not json"), isEmpty);
  });

  test('clone series of one course: longest-living one survives', () {
    // Real feed quirk: Advanced Mathematics I was re-registered, so the
    // calendar carries three clone series sharing SUMMARY + series DTSTART
    // while UID, LOCATION and RRULE UNTIL ALL differ (verified in fixture).
    // Two die on 30.10; one lives until 19.02.2027. Keying
    // dedup without the series end let a dead clone win, and the course
    // vanished from every date after its last past occurrence.
    final raw = File('test/fixtures/wc_now.ics').readAsStringSync();
    final feed = WebcalFeed.parse(raw, now: DateTime(2026, 10, 30, 18, 0))!;
    final am = feed.occurrences
        .where((o) => o.title.contains("Advanced Mathematics"))
        .toList();

    // the weekly instance after the dead series' end must be present...
    expect(
        am.where((o) => o.start == DateTime(2026, 11, 6, 8, 0)), isNotEmpty,
        reason: 'live series dropped behind dead clone');
    // ...and the weekly rhythm must continue well past it
    expect(am.where((o) => !o.start.isBefore(DateTime(2026, 11, 6))).length,
        greaterThanOrEqualTo(4));
    // the feed alternates rooms per snapshot (20.30 SR 1.067 / 30.95
    // Audimax / 20.40 Egon-Eiermann), so only the live series' instances
    // may appear at all: no series dead at 30.10 may leak an occurrence
    expect(
        am
            .where((o) => !o.start.isAfter(DateTime(2026, 10, 30, 23, 59)))
            .every((o) => (o.seriesEnd ?? o.end) == DateTime(2027, 2, 19, 8)),
        isTrue,
        reason: 'dead series occurrence leaked');
  });


  String rruleEv(String uid, String dtstart, String until, String summary) =>
      "BEGIN:VEVENT\nUID:$uid\nDTSTART:$dtstart\nRRULE:FREQ=WEEKLY;UNTIL=$until"
      "235959\nSUMMARY:$summary\nLOCATION:HS1\nEND:VEVENT\n";
  test('fingerprint survives the midnight window roll', () {
    // the parse window slides one day per day: an occurrence aged out of
    // it used to flip the fingerprint alone -> "timetable changed" alert
    // with an empty real diff
    final raw = ics([
      ev("1@kit", "20261031T230000", "20261101T010000", "Yesterday lecture", "HS1"),
      ev("2@kit", "20261105T080000", "20261105T100000", "Next week", "HS2"),
    ]);
    final day1 = WebcalFeed.parse(raw, now: DateTime(2026, 11, 1, 12))!;
    final day2 = WebcalFeed.parse(raw, now: DateTime(2026, 11, 2, 12))!;
    // raw occurrence sets differ (Oct-31 aged out) - the fingerprints must not
    expect(day1.occurrences.length, greaterThan(day2.occurrences.length));
    expect(day2.fingerprint(at: DateTime(2026, 11, 2, 12)),
        day1.fingerprint(at: DateTime(2026, 11, 1, 12)));
  });

  test('UNTIL re-publish of unchanged series is no change', () {
    // mid-semester re-registration re-emits the same series with a longer
    // UNTIL; pairing on the dedupe key used to report EVERY instance of
    // every other course as "Moved: X Mon 08:00 -> 08:00"
    final now = DateTime(2026, 11, 2, 8);
    final before = WebcalFeed.parse(
        ics([rruleEv("9@kit", "20261102T160000", "20261221", "AdM V")]),
        now: now)!;
    final after = WebcalFeed.parse(
        ics([rruleEv("9@kit", "20261102T160000", "20270125", "AdM V")]),
        now: now)!;
    expect(after.changesSince(before), isEmpty);
  });

  test('multi-value EXDATE line cancels every listed day', () {
    final raw = "BEGIN:VCALENDAR\nVERSION:2.0\n"
        "BEGIN:VEVENT\nUID:7@kit\nDTSTART:20261102T160000\n"
        "RRULE:FREQ=WEEKLY;UNTIL=20261231T235959\nSUMMARY:Übung B\n"
        "EXDATE:20261109T160000,20261116T160000\nLOCATION:HS9\n"
        "END:VEVENT\nEND:VCALENDAR\n";
    final feed = WebcalFeed.parse(raw, now: DateTime(2026, 11, 2, 8))!;
    final days = feed.occurrences
        .where((o) => o.title.contains("Übung B"))
        .map((o) => "${o.start.month}.${o.start.day}")
        .toList();
    expect(days.contains("11.9"), isFalse, reason: '$days still has 9.11');
    expect(days.contains("11.16"), isFalse, reason: '$days still has 16.11');
    expect(days.contains("11.2"), isTrue);
  });

  test('single-shot occurrences bypass the horizon clamp', () {
    // winter-semester Klausuren sit months out; the +56 d clamp exists to
    // bound RRULE expansion - one-off VEVENTs are fully enumerated and the
    // raw-cache export ships them, so parse must not disagree
    final feed = WebcalFeed.parse(ics([
      ev("klausur1", "20270301T173000", "20270301T190000",
          "Klausur: EM II", "AVI 105"), // +120 d
      rruleEv("lec1", "20261102T080000", "20270215", "Lecture long"),
    ]), now: DateTime(2026, 11, 1));
    expect(
        feed!.occurrences.where((o) => o.uid == "klausur1"), hasLength(1));
    final lec = feed.occurrences.where((o) => o.uid == "lec1").toList();
    final horizon = DateTime(2026, 11, 1).add(const Duration(days: 56));
    expect(lec, isNotEmpty);
    expect(lec.any((o) => o.start.isAfter(horizon)), isFalse,
        reason: 'recurring instances beyond the horizon must stay out');
    // the series genuinely extends beyond it (UNTIL 2027-02-15)
    expect(lec.last.seriesEnd!.isAfter(horizon), isTrue);
  });

  test('occurrences without DTEND carry endGuessed, with +90 default', () {
    final feed = WebcalFeed.parse("BEGIN:VCALENDAR\r\n"
            "BEGIN:VEVENT\r\nUID:noend\r\nDTSTART:20261103T080000\r\n"
            "SUMMARY:Guess me\r\nEND:VEVENT\r\n" +
            ev("realend", "20261103T100000", "20261103T120000", "Real", "HS1")
                .replaceAll("\n", "\r\n") +
            "END:VCALENDAR\r\n",
        now: DateTime(2026, 11, 1));
    final guessed = feed!.occurrences.firstWhere((o) => o.uid == "noend");
    expect(guessed.endGuessed, isTrue);
    expect(guessed.end.difference(guessed.start), const Duration(minutes: 90));
    final real = feed.occurrences.firstWhere((o) => o.uid == "realend");
    expect(real.endGuessed, isFalse);
  });

  test('changesSince flags a pure rename as changed', () {
    // C73: renamed lecture keeps UID and time - the twin pairing matches
    // it, and the comparison must not stay blind to the title
    final now = DateTime(2026, 11, 2, 8);
    final before = WebcalFeed.parse(ics([
      ev("1@kit", "20261103T080000", "20261103T100000", "AdM V", "HS1"),
    ]), now: now);
    final after = WebcalFeed.parse(ics([
      ev("1@kit", "20261103T080000", "20261103T100000",
          "Advanced Mathematics V", "HS1"),
    ]), now: now);
    final changes = after!.changesSince(before);
    expect(changes.length, 1);
    expect(changes.single.kind, IcsChangeKind.changed);
    expect(changes.single.title, "Advanced Mathematics V");
  });

  test('Z, UTC-offset and all-day DATE stamps parse; garbage skips', () {
    // C75: tolerant _dtOf - hand-written personal ICS variants used to
    // shift silently or drop their VEVENT entirely
    final now = DateTime(2026, 11, 2, 8);
    final feed = WebcalFeed.parse(ics([
      "BEGIN:VEVENT\nUID:9@kit\nDTSTART:20261103T080000Z\n"
          "DTEND:20261103T100000Z\nSUMMARY:UTC Lab\nLOCATION:HS9\n"
          "END:VEVENT\n",
      "BEGIN:VEVENT\nUID:12@kit\nDTSTART:20261104T100000+0200\n"
          "DTEND:20261104T120000+0200\nSUMMARY:Offset\nLOCATION:HS8\n"
          "END:VEVENT\n",
      "BEGIN:VEVENT\nUID:10@kit\nDTSTART;VALUE=DATE:20261105\n"
          "SUMMARY:Abgabe\nEND:VEVENT\n",
      "BEGIN:VEVENT\nUID:11@kit\nDTSTART:tBD\nSUMMARY:Ghost\nEND:VEVENT\n",
    ]), now: now);
    expect(feed, isNotNull);
    expect(
        feed!.occurrences
            .firstWhere((o) => o.title == "UTC Lab")
            .start,
        DateTime.utc(2026, 11, 3, 8).toLocal());
    expect(
        feed.occurrences
            .firstWhere((o) => o.title == "Offset")
            .start,
        DateTime.utc(2026, 11, 4, 8).toLocal());
    final allDay = feed.occurrences.firstWhere((o) => o.title == "Abgabe");
    expect(allDay.start, DateTime(2026, 11, 5));
    expect(allDay.endGuessed, isTrue); // no DTEND -> +90' default
    expect(feed.occurrences.any((o) => o.title == "Ghost"), isFalse);
  });
}
