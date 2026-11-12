import 'package:flutter_test/flutter_test.dart';
import 'package:kit_mobile/ilias/due_parse.dart';
import 'package:kit_mobile/state_management/campus/campus_manager.dart';

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
}
