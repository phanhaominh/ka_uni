import 'package:flutter_test/flutter_test.dart';
import 'package:kit_mobile/exams/models/exam_list.dart';
import 'package:kit_mobile/state_management/campus/campus_manager.dart';
import 'package:kit_mobile/student/student.dart';
import 'package:kit_mobile/timetable/models/webcal.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// cascampus possibleexams lists the WHOLE degree-programme catalogue; the
/// webcal-derived enrolled-title set is what tells "Act now" exams apart
/// from later-semester catalogue noise (first-semester students were shown
/// 4 bogus registration deadlines in WS 26/27).
String _ics(List<String> summaries) {
  final b = StringBuffer("BEGIN:VCALENDAR\r\n");
  var i = 0;
  for (final s in summaries) {
    b.write("BEGIN:VEVENT\r\n"
        "UID:evt${i++}\r\n"
        "SUMMARY:$s\r\n"
        "DTSTART:20261102T080000\r\n"
        "DTEND:20261102T094500\r\n"
        "RRULE:FREQ=WEEKLY;UNTIL=20270201T000000\r\n"
        "LOCATION:10.81 HS93\r\n"
        "END:VEVENT\r\n");
  }
  b.write("END:VCALENDAR\r\n");
  return b.toString();
}

ExamEntry _entry(String title) => ExamEntry(
      examNumber: "76-T-MACH-000000",
      title: title,
      examiners: "",
      examType: "Schriftliche Prüfung",
      registered: false,
      windowStatus: ExamWindowStatus.open,
    );

void main() {
  late CampusManager cm;
  setUp(() {
    cm = CampusManager(Student.empty, () {});
  });

  test("unknown while the subscription has never been loaded", () {
    expect(cm.isTakingThisSemester(_entry("IT and Data Science")), isNull);
  });

  test("lectures on the timetable match despite markers and lecturer suffix",
      () {
    cm.rememberEnrolledTitles(WebcalFeed.parse(_ics([
      "Basics of Manufacturing Technology (V), Schulze",
      "Tutorial: AMINM",
      "Analysis I für Maschinenbauer (V), König",
    ])));

    expect(
        cm.isTakingThisSemester(_entry("Basics of Manufacturing Technology")),
        isTrue);
    expect(cm.isTakingThisSemester(_entry("AMINM")), isTrue);
    expect(
        cm.isTakingThisSemester(_entry("Tutorial: AMINM")), isTrue);
    expect(
        cm.isTakingThisSemester(_entry("Analysis I für Maschinenbauer")),
        isTrue);
  });

  test("catalogue exams of later semesters are not urgent", () {
    cm.rememberEnrolledTitles(WebcalFeed.parse(
        _ics(["Basics of Manufacturing Technology (V), Schulze"])));

    expect(cm.isTakingThisSemester(_entry("IT and Data Science")), isFalse);
    expect(
        cm.isTakingThisSemester(
            _entry("Production Operations Management-Project")),
        isFalse);
    expect(cm.isTakingThisSemester(_entry("CAE-Basics Workshop")), isFalse);
  });

  test("roman numerals never match across course numbers", () {
    cm.rememberEnrolledTitles(
        WebcalFeed.parse(_ics(["Engineering Mechanics I (V), Fidlin"])));

    expect(cm.isTakingThisSemester(_entry("Engineering Mechanics I")),
        isTrue);
    expect(cm.isTakingThisSemester(_entry("Engineering Mechanics III")),
        isFalse);
  });

    // "Materials Science I and II" is the catalogue's joined form of the
    // ICS-taken "Materials Science and Engineering I"; the number-set
    // difference must not bury the exam in the later-semester section.
    test("joined 'I and II' catalogue entry covers the taken part", () {
      cm.rememberEnrolledTitles(WebcalFeed.parse(_ics(
          ["Materials Science and Engineering I (Lecture) - 3173008"])));

      expect(cm.isTakingThisSemester(
          _entry("Materials Science I and II")), isTrue);
      // proper-subset numbers still need the noun words to agree
      expect(cm.isTakingThisSemester(
          _entry("Mechanical Design I and II")), isFalse);
    });

  test("empty or broken feed keeps relevance unknown, not wrongly false", () {
    cm.rememberEnrolledTitles(WebcalFeed.parse(_ics([])));
    cm.rememberEnrolledTitles(null);
    expect(cm.isTakingThisSemester(_entry("IT and Data Science")), isNull);
  });

  // The faculty's MEI e-mail ICS is the only source for the big
  // no-Belegung lectures; imported titles must drive BOTH the agenda and
  // the exam gate with their raw "- 0140000" / "(Tutorial - Group 4)" forms.
  group("faculty ICS import", () {
    final facultyIcs =
        '''BEGIN:VCALENDAR
PRODID:-//Fakultät für Maschinenbau//de
VERSION:2.0
BEGIN:VEVENT
UID:am1lec
SUMMARY:Advanced Mathematics I (Lecture) - 0140000
DTSTART:20261104T080000
DTEND:20261104T100000
RRULE:FREQ=WEEKLY;UNTIL=20270220T235959Z
LOCATION:Auditorium at Fasanengarten
END:VEVENT
BEGIN:VEVENT
UID:em3tut
SUMMARY:Engineering Mechanics I (Tutorial) - 3161011
DTSTART:20261106T094500
DTEND:20261106T113000
LOCATION:Gottlieb-Daimler-HS
END:VEVENT
BEGIN:VEVENT
UID:am1t4
SUMMARY:Advanced Mathematics I (Tutorial - Group 4) - 010150015
DTSTART:20261104T154500
DTEND:20261104T173000
LOCATION:Fachschaft Mathematik am KIT
END:VEVENT
END:VCALENDAR
'''.replaceAll("\n", "\r\n");

    setUp(() => SharedPreferences.setMockInitialValues({}));

    test("import survives course-number tails and group labels", () async {
      final err = await cm.setPersonalIcsFromRaw(facultyIcs);
      expect(err, isNull);
      expect(cm.personalIcs, contains("Advanced Mathematics I (Lecture)"));

      final prefs = await SharedPreferences.getInstance();
      final cache = prefs.getString("DATA_webcalIcsCache") ?? "";
      expect(cache, contains("BEGIN:VCALENDAR"));
      expect(cache, contains("X-PERSONAL-ICS-BEGIN"));
      // agenda rebuilt from the merged stub cache
      expect(CampusManager.lectureTitleKey("Advanced Mathematics I (Lecture) - 0140000"),
          "advanced mathematics i");
      expect(
          CampusManager.lectureTitleKey(
              "Advanced Mathematics I (Tutorial - Group 4) - 010150015"),
          "advanced mathematics i tutorial");
    });

    test("imported titles gate exam urgency like webcal ones", () async {
      await cm.setPersonalIcsFromRaw(facultyIcs);
      // orientation exam of the imported AM lecture must be flagged urgent
      expect(cm.isTakingThisSemester(_entry("Advanced Mathematics I")), isTrue);
      expect(cm.isTakingThisSemester(_entry("Engineering Mechanics I")),
          isTrue);
      // the group digit must NOT block the match, but must also not let a
      // different roman numeral through
      expect(cm.isTakingThisSemester(_entry("Engineering Mechanics III")),
          isFalse);
      expect(
          cm.isTakingThisSemester(_entry("IT and Data Science")), isFalse);
    });

    test("sentinels round-trip: extract, strip, re-inject stays idempotent",
        () {
      final merged = CampusManager.injectPersonalIcs(
          "BEGIN:VCALENDAR\r\nEND:VCALENDAR\r\n", "BEGIN:VEVENT\r\nEND:VEVENT\r\n");
      expect(CampusManager.extractPersonalIcs(merged),
          "BEGIN:VEVENT\r\nEND:VEVENT\r\n");
      expect(CampusManager.stripPersonalIcs(merged),
          "BEGIN:VCALENDAR\r\nEND:VCALENDAR\r\n");
      final twice =
          CampusManager.injectPersonalIcs(merged, "BEGIN:VEVENT\r\nEND:VEVENT\r\n");
      expect(twice, merged);
    });

    test("rejects non-calendar junk", () async {
      expect(await cm.setPersonalIcsFromRaw("hello ics"), "bad");
    });
  });

  group("exam-synth occurrences never self-certify", () {
    // the synthetic "Klausur: <title>" VEVENTs are derived FROM the exam
    // catalogue; if their titles flowed back through enrolledTitleKeys,
    // every registered exam would trivially pass isTakingThisSemester and
    // re-arm the suppressed needsAction badges + 24 h registration alarms
    const examEvent = "BEGIN:VEVENT\r\n"
        "UID:kauni-exam-01-A-9001-20270323T173000@ka_uni\r\n"
        "DTSTART;TZID=Europe/Berlin:20270323T173000\r\n"
        "DTEND;TZID=Europe/Berlin:20270323T190000\r\n"
        "SUMMARY:Klausur: Engineering Mechanics II\r\nEND:VEVENT\r\n";

    WebcalFeed? parse(String body) => WebcalFeed.parse(
        "BEGIN:VCALENDAR\r\n$body END:VCALENDAR\r\n",
        now: DateTime(2026, 11, 1));

    test("Klausur event alone yields an empty key set", () {
      final feed = parse(examEvent)!;
      expect(
        feed.occurrences.single.uid, startsWith("kauni-exam-"));
      expect(CampusManager.enrolledTitleKeys(feed), isEmpty);
      cm.rememberEnrolledTitles(feed);
      // unknown, not true: the gate must stay silent, not self-certify
      expect(
          cm.isTakingThisSemester(_entry("Engineering Mechanics II")), isNull);
    });

    test("SignMeUp synth events still count as genuine enrolments", () {
      const smu = "BEGIN:VEVENT\r\n"
          "UID:signmeup-42-0@ka_uni\r\n"
          "DTSTART:20261105T160000\r\nDTEND:20261105T173000\r\n"
          "SUMMARY:Analysis I (Tutorial)\r\nEND:VEVENT\r\n";
      final feed = parse(smu)!;
      expect(CampusManager.enrolledTitleKeys(feed),
          contains("analysis i tutorial"));
    });
  });
}
