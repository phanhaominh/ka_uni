import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kit_mobile/timetable/models/webcal.dart';

void main() {
  test('parses real KIT webcal fixture', () {
    final raw = File('test/fixtures/wc_now.ics').readAsStringSync();
    final feed = WebcalFeed.parse(raw, now: DateTime(2026, 10, 30, 18, 0));
    expect(feed, isNotNull);
    // exact occurrence count of the fixture (30 VEVENTs: weekly series
    // expanded + break singles within the horizon) — the expansion is
    // fully clamped by parse()'s reference-based horizon, so this number
    // is wall-clock-independent and drift here means a parse regression
    expect(feed!.occurrences.length, 94);

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
    expect(feed.occurrences.any((o) => o.room.contains('Carl-Benz-Hörsaal')),
        isTrue);

    // weekly template: Monday has MD Tutorial 11:30 in its block
    final weekly = feed.toWeeklyTemplate();
    final monday = weekly.days.first;
    expect(
        monday.appointments.any((a) =>
            a.title.contains('Mechanical Design A') && a.begin.hour == 11),
        isTrue,
        reason: 'monday: ${monday.appointments.map((a) => a.title)}');

    // fingerprint stable & change-sensitive - on the FIXTURE clock: the
    // real-clock day window empties once the wall date passes the fixture
    final fp1 = feed.fingerprint(at: DateTime(2026, 10, 30, 18, 0));
    expect(fp1, feed.fingerprint(at: DateTime(2026, 10, 30, 18, 0)));
    expect(
        fp1 ==
            WebcalFeed.parse(raw.replaceFirst('Carl-Benz', 'Other-Room'),
                    now: DateTime(2026, 10, 30, 18, 0))!
                .fingerprint(at: DateTime(2026, 10, 30, 18, 0)),
        isFalse);
  });

  String ics(List<String> events) =>
      "BEGIN:VCALENDAR\nVERSION:2.0\n${events.join()}"
      "END:VCALENDAR\n";

  String ev(
          String uid, String start, String end, String summary, String room) =>
      "BEGIN:VEVENT\nUID:$uid\nDTSTART:$start\nDTEND:$end\n"
      "SUMMARY:$summary\nLOCATION:$room\nEND:VEVENT\n";

  test('changesSince classifies added/removed/moved/room-change', () {
    final now = DateTime(2026, 11, 2, 8);
    final before = WebcalFeed.parse(
        ics([
          ev("1@kit", "20261102T160000", "20261102T180000", "AdM V", "HS1"),
          ev("2@kit", "20261103T080000", "20261103T100000", "MEI V", "HS31.47"),
          ev("3@kit", "20261104T140000", "20261104T160000", "MSE Ü",
              "Bldc.10.30"),
        ]),
        now: now);
    final after = WebcalFeed.parse(
        ics([
          // moved: 16:00 -> 18:00
          ev("1@kit", "20261102T180000", "20261102T200000", "AdM V", "HS1"),
          // room changed in place
          ev("2@kit", "20261103T080000", "20261103T100000", "MEI V", "HS31.48"),
          // series 3 dropped -> removed
          ev("4@kit", "20261105T100000", "20261105T120000", "Übung Design A",
              "HS50.31"),
        ]),
        now: now);
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
    expect(am.where((o) => o.start == DateTime(2026, 11, 6, 8, 0)), isNotEmpty,
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
      "BEGIN:VEVENT\nUID:$uid\nDTSTART:$dtstart\n"
      "RRULE:FREQ=WEEKLY;UNTIL=${until}T235959\n" // real ICS separates by T
      "SUMMARY:$summary\nLOCATION:HS1\nEND:VEVENT\n";
  test('fingerprint survives the midnight window roll', () {
    // the parse window slides one day per day: an occurrence aged out of
    // it used to flip the fingerprint alone -> "timetable changed" alert
    // with an empty real diff
    final raw = ics([
      ev("1@kit", "20261031T230000", "20261101T010000", "Yesterday lecture",
          "HS1"),
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

  test('date-only UNTIL really ends the series', () {
    // R22: Google/Apple/Outlook write UNTIL=YYYYMMDD without time part;
    // the old regex silently missed it and the +56 d horizon expanded the
    // series weeks past its end - phantom lectures in grid and weekly
    // card, plus T-30 alarms for sessions that will never happen
    final raw = "BEGIN:VCALENDAR\nVERSION:2.0\n"
        "BEGIN:VEVENT\nUID:8@kit\nDTSTART:20261102T160000\n"
        "RRULE:FREQ=WEEKLY;UNTIL=20261207\nSUMMARY:Lecture ends early\n"
        "LOCATION:HS1\nEND:VEVENT\nEND:VCALENDAR\n";
    final feed =
        WebcalFeed.parse(raw, now: DateTime(2026, 11, 2, 8))!;
    final days = feed.occurrences
        .where((o) => o.title.contains("ends early"))
        .map((o) => "${o.start.month}.${o.start.day}")
        .toList();
    expect(days, contains("11.2"));
    expect(days, contains("12.7"));
    expect(days.any((d) => d.startsWith("12.") && int.parse(d.split(".")[1]) > 7),
        isFalse,
        reason: '$days leaked past the date-only UNTIL');
    expect(days.any((d) => d.startsWith("1.")), isFalse);
  });

  test('UTC and VALUE=DATE EXDATE shapes cancel, not just naive stamps', () {
    // R22: EXDATE matching was raw-string equality against DTSTART's wall
    // format - UTC stamps (…T070000Z, what export tools emit for a
    // UTC-written DTSTART) and date-only stamps (EXDATE;VALUE=DATE) never
    // matched, so cancelled dates stayed on the grid AND fired alarms
    final raw = "BEGIN:VCALENDAR\nVERSION:2.0\n"
        "BEGIN:VEVENT\nUID:9@kit\nDTSTART:20261102T160000\n"
        "RRULE:FREQ=WEEKLY;UNTIL=20261231T235959\nSUMMARY:Übung U\n"
        "EXDATE:20261109T150000Z\n" // 16:00 Berlin (CET, UTC+1) = 15:00Z
        "EXDATE;VALUE=DATE:20261116\n" // cancels the WHOLE day
        "LOCATION:HS9\nEND:VEVENT\nEND:VCALENDAR\n";
    final feed =
        WebcalFeed.parse(raw, now: DateTime(2026, 11, 2, 8))!;
    final days = feed.occurrences
        .where((o) => o.title.contains("Übung U"))
        .map((o) => "${o.start.month}.${o.start.day}")
        .toList();
    expect(days, isNot(contains("11.9")), reason: '$days still has 9.11');
    expect(days, isNot(contains("11.16")), reason: '$days still has 16.11');
    expect(days, contains("11.2"));
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
    final feed = WebcalFeed.parse(
        ics([
          ev("klausur1", "20270301T173000", "20270301T190000", "Klausur: EM II",
              "AVI 105"), // +120 d
          rruleEv("lec1", "20261102T080000", "20270215", "Lecture long"),
        ]),
        now: DateTime(2026, 11, 1));
    expect(feed!.occurrences.where((o) => o.uid == "klausur1"), hasLength(1));
    final lec = feed.occurrences.where((o) => o.uid == "lec1").toList();
    final horizon = DateTime(2026, 11, 1).add(const Duration(days: 56));
    expect(lec, isNotEmpty);
    expect(lec.any((o) => o.start.isAfter(horizon)), isFalse,
        reason: 'recurring instances beyond the horizon must stay out');
    // the series genuinely extends beyond it (UNTIL 2027-02-15)
    expect(lec.last.seriesEnd!.isAfter(horizon), isTrue);
  });

  test('occurrences without DTEND carry endGuessed, with +90 default', () {
    final feed = WebcalFeed.parse(
        "BEGIN:VCALENDAR\r\n"
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
    final before = WebcalFeed.parse(
        ics([
          ev("1@kit", "20261103T080000", "20261103T100000", "AdM V", "HS1"),
        ]),
        now: now);
    final after = WebcalFeed.parse(
        ics([
          ev("1@kit", "20261103T080000", "20261103T100000",
              "Advanced Mathematics V", "HS1"),
        ]),
        now: now);
    final changes = after!.changesSince(before);
    expect(changes.length, 1);
    expect(changes.single.kind, IcsChangeKind.changed);
    expect(changes.single.title, "Advanced Mathematics V");
  });

  test('Z, UTC-offset and all-day DATE stamps parse; garbage skips', () {
    // C75: tolerant _dtOf - hand-written personal ICS variants used to
    // shift silently or drop their VEVENT entirely
    final now = DateTime(2026, 11, 2, 8);
    final feed = WebcalFeed.parse(
        ics([
          "BEGIN:VEVENT\nUID:9@kit\nDTSTART:20261103T080000Z\n"
              "DTEND:20261103T100000Z\nSUMMARY:UTC Lab\nLOCATION:HS9\n"
              "END:VEVENT\n",
          "BEGIN:VEVENT\nUID:12@kit\nDTSTART:20261104T100000+0200\n"
              "DTEND:20261104T120000+0200\nSUMMARY:Offset\nLOCATION:HS8\n"
              "END:VEVENT\n",
          "BEGIN:VEVENT\nUID:10@kit\nDTSTART;VALUE=DATE:20261105\n"
              "SUMMARY:Abgabe\nEND:VEVENT\n",
          "BEGIN:VEVENT\nUID:11@kit\nDTSTART:tBD\nSUMMARY:Ghost\nEND:VEVENT\n",
        ]),
        now: now);
    expect(feed, isNotNull);
    expect(feed!.occurrences.firstWhere((o) => o.title == "UTC Lab").start,
        DateTime.utc(2026, 11, 3, 8).toLocal());
    expect(feed.occurrences.firstWhere((o) => o.title == "Offset").start,
        DateTime.utc(2026, 11, 4, 8).toLocal());
    final allDay = feed.occurrences.firstWhere((o) => o.title == "Abgabe");
    expect(allDay.start, DateTime(2026, 11, 5));
    expect(allDay.endGuessed, isTrue); // no DTEND -> +90' default
    expect(feed.occurrences.any((o) => o.title == "Ghost"), isFalse);
  });

  test('URL parses onto occurrences but stays out of fingerprint/dedupeKey',
      () {
    const plain = "BEGIN:VCALENDAR\nVERSION:2.0\n"
        "BEGIN:VEVENT\nUID:u1@x\nDTSTART:20261102T113000\n"
        "DTEND:20261102T130000\nSUMMARY:T\nLOCATION:HS1\n"
        "END:VEVENT\nEND:VCALENDAR\n";
    const withUrl = "BEGIN:VCALENDAR\nVERSION:2.0\n"
        "BEGIN:VEVENT\nUID:u1@x\nDTSTART:20261102T113000\n"
        "DTEND:20261102T130000\nSUMMARY:T\nLOCATION:HS1\n"
        "URL:https://campus.studium.kit.edu/ev/Tok123\n"
        "END:VEVENT\nEND:VCALENDAR\n";
    final now = DateTime(2026, 11, 2, 8);
    final a = WebcalFeed.parse(plain, now: now)!;
    final b = WebcalFeed.parse(withUrl, now: now)!;
    expect(a.occurrences.single.url, isNull);
    expect(
        b.occurrences.single.url, "https://campus.studium.kit.edu/ev/Tok123");
    // fingerprint's day window must ride the FIXTURE clock: with the real
    // wall clock the fixture's Nov-2 event falls below "today's midnight"
    // the moment the real date ticks over, both fingerprints collapse to
    // '' and this test time-bombs
    expect(b.fingerprint(at: now), a.fingerprint(at: now));
    expect(b.occurrences.single.dedupeKey, a.occurrences.single.dedupeKey);
    // ...while the fingerprint keeps its byte-exact title rule
    final c = WebcalFeed.parse(withUrl.replaceFirst("SUMMARY:T", "SUMMARY:T2"),
        now: now)!;
    expect(c.fingerprint(at: now), isNot(b.fingerprint(at: now)));
  });

  test(
      'fixture: URL is the stable course token across clones and '
      're-publications', () {
    final raw = File('test/fixtures/wc_now.ics').readAsStringSync();
    final feed = WebcalFeed.parse(raw, now: DateTime(2026, 10, 30, 18))!;
    expect(
        feed.occurrences.every((o) =>
            o.url != null &&
            o.url!.startsWith("https://campus.studium.kit.edu/ev/")),
        isTrue);
    // the three Math-I clone snapshots (wc_now.ics:106/:120/:132) share
    // one token - the surviving Fri 08:00 occurrences all carry it
    final math = feed.occurrences
        .where((o) => o.title.contains('Advanced Mathematics I'))
        .toList();
    expect(math, isNotEmpty);
    expect(math.map((o) => o.url).toSet(),
        {"https://campus.studium.kit.edu/ev/NvIWCoM4QRSRN7g9qwP8gQ"});
    // the Nov-Dec one-shot chain (:223..:377) and the Jan RRULE
    // re-publication (:200) of the MatSci lecture carry the same token
    final matSci1130 = feed.occurrences
        .where((o) =>
            o.title.contains('Materials Science and Engineering I (Lecture)') &&
            o.start.hour == 11)
        .toList();
    expect(matSci1130, isNotEmpty);
    expect(matSci1130.map((o) => o.url).toSet(),
        {"https://campus.studium.kit.edu/ev/Z8LCOQf8RRm5qIWP-G30tg"});
  });

  test(
      'roomVaries: alternating feed rooms flag the block, stable rooms '
      'stay quiet', () {
    final raw = File('test/fixtures/wc_now.ics').readAsStringSync();
    final feed = WebcalFeed.parse(raw, now: DateTime(2026, 10, 30, 18))!;
    final weekly = feed.toWeeklyTemplate();
    // Thu 11:30 MatSci I lecture: the one-shots run in 40.50
    // Engler-Bunte, but 19.11. sits in 20.40 Egon-Eiermann
    // (wc_now.ics:287) -> alternating rooms
    final thursday = weekly.days[DateTime.thursday - 1];
    final matSci = thursday.appointments
        .where(
            (a) => a.title.contains('Materials Science') && a.begin.hour == 11)
        .toList();
    expect(matSci, hasLength(1));
    expect(matSci.single.roomVaries, isTrue);
    expect(matSci.single.url,
        "https://campus.studium.kit.edu/ev/Z8LCOQf8RRm5qIWP-G30tg");
    // Mon 11:30 Mechanical Design A: constant 10.21 Carl-Benz all term
    final monday = weekly.days.first;
    final mdMon = monday.appointments
        .where((a) =>
            a.title.contains('Mechanical Design A') && a.begin.hour == 11)
        .toList();
    expect(mdMon, hasLength(1));
    expect(mdMon.single.roomVaries, isFalse);
    // untouched placeholder slots never light up
    expect(
        weekly.days
            .expand((d) => d.appointments)
            .where((a) => a.isEmpty)
            .every((a) => !a.roomVaries),
        isTrue);
  });

  test('IcsChangeIndex groups by day and indexes room moves per block', () {
    final changes = [
      IcsChange(
          kind: IcsChangeKind.changed,
          title: 'A',
          when: DateTime(2026, 11, 2, 8),
          room: 'HS2',
          oldRoom: 'HS1'),
      IcsChange(
          kind: IcsChangeKind.changed,
          title: 'A2',
          when: DateTime(2026, 11, 2, 8, 30),
          room: 'HS9',
          oldRoom: 'HS9'),
      IcsChange(
          kind: IcsChangeKind.changed,
          title: 'A3',
          when: DateTime(2026, 11, 2, 8, 0, 30),
          room: 'HS3',
          oldRoom: 'HS2'),
      IcsChange(
          kind: IcsChangeKind.removed,
          title: 'B',
          when: DateTime(2026, 11, 2, 14),
          room: 'HS4'),
      IcsChange(
          kind: IcsChangeKind.moved,
          title: 'C',
          when: DateTime(2026, 11, 3, 10),
          room: 'HS5',
          oldRoom: 'HS6',
          oldWhen: DateTime(2026, 11, 2, 16)),
    ];
    final ghost = changes.byGhostDayKey();
    // moved ghosts land on the day they VACATED (oldWhen), not on the new
    // day where the lecture itself already fills the block
    expect(ghost['2026-11-02'], hasLength(5));
    expect(ghost['2026-11-02']!.last.title, 'C');
    expect(ghost['2026-11-03'], isNull);
    final blocks = changes.blockKeys(DateTime(2026, 11, 2, 23, 59));
    expect(blocks.keys, {8 * 60}); // room-unchanged "A2" excluded
    expect(blocks[8 * 60]!.room, 'HS3'); // latest delta of the block wins
    expect(changes.removedOrMovedBlocks(DateTime(2026, 11, 2)), {14 * 60});
    expect(changes.removedOrMovedBlocks(DateTime(2026, 11, 3)), {10 * 60});
    expect(changes.removedOrMovedBlocks(DateTime(2026, 11, 4)), isEmpty);
  });

  test('blockKeys: repeated edits of ONE session keep the last move', () {
    // R22: KIT re-writes the SAME occurrence twice (HS1->HS2, then
    // HS2->HS3) and both deltas carry the identical `when` (the
    // occurrence start) - isAfter could never replace, so the grid pinned
    // the stale intermediate HS2 forever; stored order is oldest-first
    // (IcsChange.decode of DATA_webcalChanges), the tie goes last-wins
    final changes = [
      IcsChange(
          kind: IcsChangeKind.changed,
          title: 'AdM V',
          when: DateTime(2026, 11, 2, 16),
          room: 'HS2',
          oldRoom: 'HS1'),
      IcsChange(
          kind: IcsChangeKind.changed,
          title: 'AdM V',
          when: DateTime(2026, 11, 2, 16),
          room: 'HS3',
          oldRoom: 'HS2'),
    ];
    expect(changes.blockKeys(DateTime(2026, 11, 2))[16 * 60]!.room, 'HS3');
    // inside ONE block the newer `when` still outranks a stored-later
    // older delta (the tie rule is >=, not blind last-wins)
    final mixed = [
      IcsChange(
          kind: IcsChangeKind.changed,
          title: 'AdM V',
          when: DateTime(2026, 11, 2, 8, 0, 30),
          room: 'HS3',
          oldRoom: 'HS2'),
      IcsChange(
          kind: IcsChangeKind.changed,
          title: 'AdM V',
          when: DateTime(2026, 11, 2, 8),
          room: 'HS2',
          oldRoom: 'HS1'),
    ];
    expect(mixed.blockKeys(DateTime(2026, 11, 2))[8 * 60]!.room, 'HS3');
  });

  test('titleKey folds export noise so delta and row titles match', () {
    // faculty number tail, leading course-id prefix, case and spacing:
    // the agenda row-emphasis gate matches deltas on this key
    expect(IcsChange.titleKey('Analysis I - 3161011'),
        IcsChange.titleKey('analysis i'));
    expect(IcsChange.titleKey('3161011 - Analysis I'),
        IcsChange.titleKey(' Analysis I '));
    expect(IcsChange.titleKey('Analysis I'),
        isNot(IcsChange.titleKey('Linear Algebra')));
  });

  test(
      'template: imported one-shots only in their real week, feed '
      'one-shot chains kept', () {
    String ev(String uid, String start, String end, String title,
            [String url = ""]) =>
        "BEGIN:VEVENT\nUID:$uid\nDTSTART;TZID=Europe/Berlin:$start\n"
        "DTEND;TZID=Europe/Berlin:$end\nSUMMARY:$title\n${url}END:VEVENT\n";
    final raw = "BEGIN:VCALENDAR\nVERSION:2.0\n" +
        // imported (URL-less) one-shot INSIDE the parsed week Mon 2.11
        ev('imp-in', '20261103T100000', '20261103T110000', 'Clinic Slot') +
        // imported one-shot far outside: a February Klausur on a Tuesday
        ev('imp-out', '20270216T100000', '20270216T120000', 'KLAUSUR X') +
        // feed one-shot far outside the week but carrying the cascampus
        // URL - KIT's Nov-Dec publication chain must survive on the grid
        ev('feed-far', '20261126T113000', '20261126T130000', 'MatSci Late',
            "URL:https://campus.studium.kit.edu/ev/Tok9\n") +
        "END:VCALENDAR\n";
    final feed = WebcalFeed.parse(raw, now: DateTime(2026, 11, 2, 8))!;
    final weekly = feed.toWeeklyTemplate();
    final tuesday = weekly.days[DateTime.tuesday - 1].appointments;
    final thursday = weekly.days[DateTime.thursday - 1].appointments;
    expect(tuesday.where((a) => a.title == 'Clinic Slot'), hasLength(1),
        reason: 'in-week imported one-shot belongs on its weekday');
    expect(
        weekly.days
            .expand((d) => d.appointments)
            .where((a) => a.title.contains('KLAUSUR')),
        isEmpty,
        reason: 'a February Klausur must not haunt every Tuesday');
    final late1130 = thursday.firstWhere((a) => a.title == 'MatSci Late');
    expect(late1130.occurrenceDates, {DateTime(2026, 11, 26)},
        reason: 'a chain member knows exactly which real date it is');
    expect(
        tuesday.firstWhere((a) => a.title == 'Clinic Slot').occurrenceDates,
        // slot union: the February Klausur sits in the SAME Tue-10:00
        // block, so that week the slot is genuinely occupied too
        {DateTime(2026, 11, 3), DateTime(2027, 2, 16)});
    expect(thursday.where((a) => a.title == 'MatSci Late'), hasLength(1),
        reason: 'feed one-shot chains stay on the repeating template');
  });

  test('weekly expansion keeps wall-clock ends across the DST flip', () {
    const raw = "BEGIN:VCALENDAR\nVERSION:2.0\n"
        "BEGIN:VEVENT\nUID:dst@x\nDTSTART:20261019T080000\n"
        "DTEND:20261019T100000\n"
        "RRULE:FREQ=WEEKLY;UNTIL=20261110T000000\n"
        "SUMMARY:DST Lecture\nEND:VEVENT\nEND:VCALENDAR\n";
    final feed = WebcalFeed.parse(raw, now: DateTime(2026, 11, 2, 8))!;
    final nov2 =
        feed.occurrences.firstWhere((o) => o.start == DateTime(2026, 11, 2, 8));
    // the pre-flip instance was 08:00-10:00 CEST (2 absolute hours);
    // re-adding THAT to the post-flip Monday printed 09:00 CET as the end
    // while geometry still spanned to 10:00. Trivially true on hosts
    // without a late-October DST flip.
    expect(nov2.end, DateTime(2026, 11, 2, 10),
        reason: 'end follows the start by wall clock');
  });
}
