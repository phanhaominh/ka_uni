import 'package:flutter_test/flutter_test.dart';
import 'package:kit_mobile/ilias/due_parse.dart';
import 'package:kit_mobile/state_management/campus/campus_manager.dart';
import 'package:kit_mobile/timetable/models/webcal.dart';

/// Wave B R24: announcement-title deadline extraction. The fence doctrine
/// is exam_synth's: a MISSED deadline is survivable, a WRONG one is not.
void main() {
  final posted = DateTime(2026, 11, 10, 9);

  DueItem? p(String title, {DateTime? at}) => parseDueAnnouncement(
      courseRefId: 3038952,
      course: "Advanced Mathematics I",
      title: title,
      postedAt: at ?? posted);

  test("keyword + explicit date + time parses", () {
    final d = p("Übungsblatt 3 – Abgabe bis 20.11.2026, 18:00 Uhr");
    expect(d, isNotNull);
    expect(d!.due, DateTime(2026, 11, 20, 18));
    expect(d.hasTime, isTrue);
  });

  test("no date = nothing emitted, no keyword = nothing emitted", () {
    expect(p("Abgabe nächste Woche"), isNull);
    expect(p("Übungsblatt 3 jetzt verfügbar"), isNull);
    expect(p("Sprechstunde 15.11.2026"), isNull); // date without keyword
    expect(p("Achtung! Klausur am 15.01.2027"), isNull); // no kw match
  });

  test("bare year-less dates roll to the nearest future", () {
    final d = p("Abgabefrist: 15.01., 23:59 Uhr");
    expect(d!.due, DateTime(2027, 1, 15, 23, 59));
    // already-past announcement date is a misread - drop
    expect(p("Abgabe war am 01.11.2026"), isNull);
  });

  test("absurd horizon (>210d) is refused", () {
    expect(p("Abgabefrist 30.12.2027"), isNull);
  });

  test("time needs the Uhr unit - bare numbers are section codes", () {
    final d = p("Abgabe bis 12.12.2026 in Raum 18.01");
    expect(d!.hasTime, isFalse);
    expect(d.due, DateTime(2026, 12, 12, 23, 45)); // end-of-day fallback
  });

  test("room codes never bind as the deadline (audit lens-2)", () {
    // "20.11" is a valid KIT room code AND a valid date - the keyword
    // binding must pick "Frist 05.12", never the room
    final d = p("Abgabe Übungsblatt 3, Raum 20.11, Frist 05.12.");
    expect(d!.due, DateTime(2026, 12, 5, 23, 45));
    // an invalid date-shaped token ("30.20" room) must not abort the
    // whole item - the real Frist still lands
    final e = p("Abgabe in Raum 30.20, Frist 05.12.");
    expect(e!.due, DateTime(2026, 12, 5, 23, 45));
    // "12.10 Uhr" is a time typed with a dot, not 12 October
    final f = p("Abgabe Besprechung 12.10 Uhr Frist 05.12.");
    expect(f!.due, DateTime(2026, 12, 5, 23, 45));
  });

  test("a time attaches only AFTER the chosen date", () {
    // lecture start before the deadline must not move the reminder hours
    // early (old code bound ANY "NN:NN Uhr" in the title)
    final d = p("Übung 16:15 Uhr, Abgabe bis 20.11.");
    expect(d!.due, DateTime(2026, 11, 20, 23, 45));
    expect(d.hasTime, isFalse);
    // a time after it IS the deadline's own
    final e = p("Abgabe bis 20.11., 12:00 Uhr");
    expect(e!.due, DateTime(2026, 11, 20, 12));
    expect(e.hasTime, isTrue);
  });

  test("impossible day-of-month yields no event, no ghost", () {
    // DateTime(2026,2,31) silently rolled to 01.03 and the horizon check
    // kept the phantom; strict round-trip validation refuses it
    expect(p("Abgabefrist: 31.02., 12:00 Uhr"), isNull);
    expect(p("Abgabefrist 31.04.2027"), isNull);
  });

  test("titles equal up to the key cap keep distinct UIDs", () {
    // old UID = first-24-alnums + date: two Nachtermin slots sharing the
    // prefix collided and the dedupe silently dropped one deadline
    final base = "Abgabe Grundkurs Mathematik Aufgabe 7 am 20.12.2026";
    final a = parseDueAnnouncement(
        courseRefId: 5,
        course: "K",
        title: "$base um 10:00 Uhr",
        postedAt: posted)!;
    final b = parseDueAnnouncement(
        courseRefId: 5,
        course: "K",
        title: "$base um 12:00 Uhr",
        postedAt: posted)!;
    expect(a.uid, isNot(b.uid));
    expect(a.due, DateTime(2026, 12, 20, 10));
    expect(b.due, DateTime(2026, 12, 20, 12));
    // ref_id-less announcements from DIFFERENT courses separate via salt
    final x = parseDueAnnouncement(
        courseRefId: 0,
        course: "",
        title: "Abgabe bis 20.12.2026",
        postedAt: posted,
        uidSalt: "https://ilias/goto/1")!;
    final y = parseDueAnnouncement(
        courseRefId: 0,
        course: "",
        title: "Abgabe bis 20.12.2026",
        postedAt: posted,
        uidSalt: "https://ilias/goto/2")!;
    expect(x.uid, isNot(y.uid));
  });

  test("emitter: TZID like exams; empty course prints once", () {
    final d = parseDueAnnouncement(
        courseRefId: 5,
        course: "", // the news list ships no course title pre-join
        title: "Abgabe bis 20.12.2026",
        postedAt: posted)!;
    final block = buildDueSynthBlock([d]);
    // Berlin wall time on ANY device zone (floating time shifted it)
    expect(block,
        contains("DTSTART;TZID=Europe/Berlin:20261220T234500"));
    // the announcement must appear ONCE, not duplicated in both slots
    expect(block, contains("SUMMARY:Due: Abgabe bis 20.12.2026"));
    expect(block, isNot(contains("(Abgabe bis 20.12.2026)")));
  });

  test("emitted block is deterministic and parseable", () {
    final a = p("Übungsblatt 3 - Abgabe bis 20.11.2026, 18:00 Uhr")!;
    final b = parseDueAnnouncement(
        courseRefId: 3038953,
        course: "Mechanik I",
        title: "Abgabefrist Übungsblatt 5: 04.12.2026, 12:00 Uhr",
        postedAt: posted)!;
    final block = buildDueSynthBlock([b, a]);
    expect(block, buildDueSynthBlock([a, b])); // order-independent bytes
    expect(RegExp("BEGIN:VEVENT").allMatches(block).length, 2);
    expect(block, contains("UID:kauni-due-3038952-"));
    expect(block, contains("SUMMARY:Due: Advanced Mathematics I"));
    // a rebuild from re-fetched identical announcements changes nothing
    final again = buildDueSynthBlock([
      parseDueAnnouncement(
          courseRefId: 3038952,
          course: "Advanced Mathematics I",
          title: "Übungsblatt 3 - Abgabe bis 20.11.2026, 18:00 Uhr",
          postedAt: DateTime(2026, 11, 11, 3))!,
      b
    ]);
    expect(again, block);
  });

  test("foreign newlines cannot split the emitted lines", () {
    final d = parseDueAnnouncement(
        courseRefId: 1,
        course: "Böser\r\nKurs",
        title: "Abgabe\r\nbis 20.11.2026, 18:00 Uhr",
        postedAt: posted)!;
    final block = buildDueSynthBlock([d]);
    expect(
        block
            .split("\r\n")
            .where((l) => l == "Kurs" || l.startsWith("bis "))
            .isEmpty,
        isTrue);
  });

  test("UIDs dedupe same announcement, differ per course", () {
    final a = p("Abgabe: Übungsblatt 3 bis 20.11.2026")!;
    final a2 = p("Abgabe: Übungsblatt 3 bis 20.11.2026")!;
    expect(a.sameKey(a2), isTrue);
    final other = parseDueAnnouncement(
        courseRefId: 99,
        course: "X",
        title: "Abgabe: Übungsblatt 3 bis 20.11.2026",
        postedAt: posted)!;
    expect(a.sameKey(other), isFalse);
  });

  test("shortCourse strips the course-id prefix", () {
    expect(shortCourse("3161011 – Analysis I"), "Analysis I");
    expect(shortCourse("Analysis I"), "Analysis I");
  });

  group("sentinel splice (mirrors exam/signmeup family)", () {
    const base = "BEGIN:VCALENDAR\r\nEND:VCALENDAR\r\n";
    const ev = "BEGIN:VEVENT\r\nUID:x@ka_uni\r\nEND:VEVENT\r\n";

    test("inject/extract/strip round-trip is exact and idempotent", () {
      final m = CampusManager.injectDueSynth(base, ev);
      expect(m, contains("X-DUE-SYNTH-BEGIN"));
      expect(CampusManager.extractDueSynth(m), ev); // production blocks keep their trailing CRLF
      expect(CampusManager.stripDueSynth(m), base);
      // re-inject of identical block = byte-identical (no-op guard basis)
      expect(CampusManager.injectDueSynth(m, ev), m);
      // empty block strips the previous one
      expect(CampusManager.injectDueSynth(m, ""), base);
      // and a title carrying the END sentinel cannot cut the block short
      final hostile = CampusManager.injectDueSynth(
          base, "BEGIN:VEVENT\r\nX-SYNTH:hi\r\nEND:VEVENT\r\n");
      expect(CampusManager.stripDueSynth(hostile), base);
    });
  });

  test("late deadlines round-trip start-only over the midnight edge", () {
    final d = parseDueAnnouncement(
        courseRefId: 7,
        course: "Analysis II",
        title: "Abgabe bis 20.11.2026, 23:59 Uhr",
        postedAt: posted)!;
    final block = buildDueSynthBlock([d]);
    // NO DTEND is emitted: a 23:59 deadline must not fabricate a span
    // into tomorrow; the parser's +90 display default lands next-day and
    // is flagged GUESSED, so reminder bodies stay "ab 23:59"
    expect(block, isNot(contains("DTEND")));
    final feed = WebcalFeed.parse(
        "BEGIN:VCALENDAR\r\nX-DUE-SYNTH-BEGIN\r\n$block"
        "X-DUE-SYNTH-END\r\nEND:VCALENDAR\r\n",
        now: DateTime(2026, 11, 12));
    expect(feed, isNotNull);
    final occ =
        feed!.occurrences.singleWhere((o) => o.uid.startsWith("kauni-due-"));
    expect(occ.start, DateTime(2026, 11, 20, 23, 59));
    expect(occ.endGuessed, isTrue);
    // DTSTAMP is RFC-required UTC - the Z must be there
    expect(block, contains(RegExp(r"DTSTAMP:20261120T000000Z")));
    // escaped comma in the course name must survive the parser unescape
    final tricky = parseDueAnnouncement(
        courseRefId: 8,
        course: "Mechanik, Festigkeit I",
        title: "Abgabe bis 21.11.2026",
        postedAt: posted)!;
    final f2 = WebcalFeed.parse("BEGIN:VCALENDAR\r\n"
        "${buildDueSynthBlock([tricky])}END:VCALENDAR\r\n",
        now: DateTime(2026, 11, 12));
    expect(f2!.occurrences.single.title,
        "Due: Mechanik, Festigkeit I (Abgabe bis 21.11.2026)");
  });
}
