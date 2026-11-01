import 'package:flutter_test/flutter_test.dart';
import 'package:kit_mobile/exams/models/exam_list.dart';
import 'package:kit_mobile/exams/models/exam_synth.dart';
import 'package:kit_mobile/state_management/campus/campus_manager.dart';
import 'package:kit_mobile/timetable/models/webcal.dart';
import 'package:kit_mobile/student/student.dart';
import 'package:shared_preferences/shared_preferences.dart';

ExamEntry _exam({
  String num = "01-A-9001",
  String title = "Analysis I",
  bool registered = true,
  List<ExamTerm> terms = const [],
}) {
  final e = ExamEntry(
    examNumber: num,
    title: title,
    examiners: "Muster",
    examType: "Schriftliche Prüfung",
    registered: registered,
    windowStatus: ExamWindowStatus.unknown,
  );
  e.terms.addAll(terms);
  return e;
}

ExamTerm _term(String day, String time, [String room = "AVI 105"]) =>
    ExamTerm(day, time, room);

List<String> _uids(String block) => RegExp(r"UID:(kauni-exam-[^\r\n]+)")
    .allMatches(block)
    .map((m) => m.group(1)!)
    .toList();

void main() {
  group("buildExamSynthBlock", () {
    test("registered sitting emits a VEVENT with room and parsed end", () {
      final block =
          buildExamSynthBlock([_exam(terms: [_term("Di, 23.03.2027", "17:30 - 19:00")])]);
      expect(block, contains("BEGIN:VEVENT"));
      expect(block, contains("UID:kauni-exam-01-A-9001-20270323T173000@ka_uni"));
      expect(block, contains("DTSTAMP:"));
      expect(block, contains("DTSTART;TZID=Europe/Berlin:20270323T173000"));
      expect(block, contains("DTEND;TZID=Europe/Berlin:20270323T190000"));
      expect(block, contains("SUMMARY:Klausur: Analysis I"));
      expect(block, contains("LOCATION:AVI 105"));
      expect(block, endsWith("END:VEVENT\r\n"));
    });

    test("unregistered entries emit nothing", () {
      final block = buildExamSynthBlock([
        _exam(num: "01-A-1111", registered: false, terms: [_term("Di, 23.03.2027", "17:30 - 19:00")]),
        _exam(num: "01-A-2222", title: "Analysis II", terms: [_term("Fr, 16.04.2027", "09:00 - 11:00")]),
      ]);
      expect(block, isNot(contains("01-A-1111")));
      expect(block, isNot(contains("Klausur: Analysis I\r\n")));
      expect(block, contains("UID:kauni-exam-01-A-2222-20270416T090000@ka_uni"));
    });

    test("cancelled sittings are skipped", () {
      final block = buildExamSynthBlock([
        _exam(terms: [
          _term("Mo, 15.03.2027 (entfällt)", "10:00 - 12:00", "-"),
          _term("Di, 23.03.2027", "17:30 - 19:00"),
        ]),
      ]);
      expect(RegExp("BEGIN:VEVENT").allMatches(block).length, 1);
      expect(block, contains("20270323T173000"));
      expect(block, isNot(contains("20270315")));
    });

    test("range-date and time-less sittings (null startAt) are skipped", () {
      // the model yields a null startAt for block-range dates ("12.04 -
      // 30.04.2027" hits the guard in ExamTerm.startAt) and for sittings
      // without a time token; the emitter trusts startAt and never guesses
      final range = _term("12.04 - 30.04.2027", "09:00 - 11:00");
      expect(range.startAt, isNull);
      final noTime = _term("Di, 23.03.2027", "");
      expect(noTime.startAt, isNull);
      final block = buildExamSynthBlock([
        _exam(num: "01-A-3333", terms: [range]),
        _exam(num: "01-A-4444", terms: [noTime]),
      ]);
      expect(block, isEmpty);
    });

    test("missing end token omits DTEND (never export a guessed end)", () {
      final block =
          buildExamSynthBlock([_exam(terms: [_term("Di, 23.03.2027", "10:00")])]);
      expect(block, contains("DTSTART;TZID=Europe/Berlin:20270323T100000"));
      expect(block, isNot(contains("DTEND")));
      // the webcal parser restores the in-app +90 default and marks the
      // occurrence endGuessed, so no consumer treats the end as a fact
      final feed = WebcalFeed.parse(CampusManager.injectExamSynth(
          "BEGIN:VCALENDAR\r\nEND:VCALENDAR\r\n", block))!;
      final occ = feed.occurrences.first;
      expect(occ.end.difference(occ.start), const Duration(minutes: 90));
      expect(occ.endGuessed, isTrue);
    });

    test("overnight end token rolls to the next day", () {
      final block =
          buildExamSynthBlock([_exam(terms: [_term("Di, 23.03.2027", "22:00 - 01:00")])]);
      expect(block, contains("DTEND;TZID=Europe/Berlin:20270324T010000"));
    });

    test("UIDs are stable across rebuilds", () {
      final a = buildExamSynthBlock([
        _exam(terms: [
          _term("Di, 23.03.2027", "17:30 - 19:00"),
          _term("Fr, 16.04.2027", "09:00 - 11:00"),
        ]),
      ]);
      final b = buildExamSynthBlock([
        _exam(terms: [
          _term("Di, 23.03.2027", "17:30 - 19:00"),
          _term("Fr, 16.04.2027", "09:00 - 11:00"),
        ]),
      ]);
      expect(_uids(b), _uids(a));
      expect(_uids(a), [
        "kauni-exam-01-A-9001-20270323T173000@ka_uni",
        "kauni-exam-01-A-9001-20270416T090000@ka_uni",
      ]);
    });

    test("commas and semicolons in titles are escaped", () {
      final block = buildExamSynthBlock([
        _exam(title: "Angewandte Informatik, Vertiefung; II",
            terms: [_term("Di, 23.03.2027", "17:30 - 19:00", "Geb. 50.20, HS")]),
      ]);
      expect(
          block,
          contains(
              r"SUMMARY:Klausur: Angewandte Informatik\, Vertiefung\; II"));
      expect(block, contains(r"LOCATION:Geb. 50.20\, HS"));
    });

    test("placeholder room '-' omits LOCATION", () {
      final block = buildExamSynthBlock([
        _exam(terms: [_term("Di, 23.03.2027", "17:30 - 19:00", "-")]),
      ]);
      expect(block, isNot(contains("LOCATION")));
    });

    test("empty input -> empty string", () {
      expect(buildExamSynthBlock([]), isEmpty);
      expect(buildExamSynthBlock([_exam(registered: false)]), isEmpty);
      expect(buildExamSynthBlock([_exam(terms: [_term("", "", "")])]), isEmpty);
    });

    test("emitted events survive the webcal parser", () {
      // sit seven days out so the parser's 56-day horizon always contains it
      final d = DateTime.now().add(const Duration(days: 7));
      String two(int v) => v.toString().padLeft(2, "0");
      final label =
          "Mo, ${two(d.day)}.${two(d.month)}.${d.year}";
      final block =
          buildExamSynthBlock([_exam(terms: [_term(label, "17:30 - 19:00")])]);
      final raw = CampusManager.injectExamSynth(
          "BEGIN:VCALENDAR\r\nEND:VCALENDAR\r\n", block);
      final feed = WebcalFeed.parse(raw)!;
      final occ = feed.occurrences
          .firstWhere((o) => o.title == "Klausur: Analysis I");
      expect(occ.start, DateTime(d.year, d.month, d.day, 17, 30));
      expect(occ.end.difference(occ.start), const Duration(hours: 1, minutes: 30));
      expect(occ.room, "AVI 105");
      final stamp = "${d.year}${two(d.month)}${two(d.day)}T173000";
      expect(occ.uid, "kauni-exam-01-A-9001-$stamp@ka_uni");
      expect(occ.endGuessed, isFalse);
    });

    test("block is byte-identical across rebuilds (deterministic emitter)", () {
      // DTSTAMP is derived from the sitting, not the wall clock - this is
      // what makes reapplyExamSynth's `merged == cached` early return real
      final terms = [
        _term("Di, 23.03.2027", "17:30 - 19:00"),
        _term("Fr, 16.04.2027", "09:00"), // guessed-end variant included
      ];
      expect(buildExamSynthBlock([_exam(terms: terms)]),
          buildExamSynthBlock([_exam(terms: terms)]));
    });

    test("past sittings are skipped (block rolls at the date boundary)", () {
      final past = DateTime.now().subtract(const Duration(days: 30));
      String two(int v) => v.toString().padLeft(2, "0");
      final label = "Di, ${two(past.day)}.${two(past.month)}.${past.year}";
      expect(
          buildExamSynthBlock([_exam(terms: [_term(label, "17:30 - 19:00")])]),
          isEmpty);
    });

    test("interior newlines in room/title collapse to one space", () {
      // HTML cells survive .trim() with interior CR/LF; a physical line
      // break inside SUMMARY/LOCATION destroys the exported document
      final block = buildExamSynthBlock([
        _exam(
            title: "A\r\nB",
            terms: [_term("Di, 23.03.2027", "17:30 - 19:00", "A\nB")]),
      ]);
      expect(block, contains("SUMMARY:Klausur: A B\r\n"));
      expect(block, contains("LOCATION:A B\r\n"));
      expect(block.split("\r\n").where((l) => l.startsWith("LOCATION")).length,
          1);
      expect(block.split("\n").where((l) => l == "B").length, 0);
    });

    test("examNumber violating the KIT shape drops the whole entry", () {
      // ICS injection: the raw value lands inside the UID line
      expect(
          buildExamSynthBlock([
            _exam(
                num: "23-TEST\nBEGIN:VEVENT",
                terms: [_term("Di, 23.03.2027", "17:30 - 19:00")]),
          ]),
          isEmpty);
      // genuine compound shapes must not be collateral damage
      final ok = buildExamSynthBlock([
        _exam(
            num: "82-804-H-2024",
            terms: [_term("Di, 23.03.2027", "17:30 - 19:00")]),
      ]);
      expect(
          ok, contains("UID:kauni-exam-82-804-H-2024-20270323T173000@ka_uni"));
    });

    test("grid template excludes exam occurrences, keeps lectures", () {
      // toWeeklyTemplate is a per-(weekday, block) one-appointment
      // template: one-off sittings would repeat on every carousel page -
      // the grid must never see them (agenda/digest/export read the feed)
      const lecture = "BEGIN:VCALENDAR\r\n"
          "BEGIN:VEVENT\r\nUID:evt1\r\nSUMMARY:Analysis I (V)\r\n"
          "DTSTART:20261102T080000\r\nDTEND:20261102T094500\r\n"
          "RRULE:FREQ=WEEKLY;UNTIL=20270201T000000\r\nEND:VEVENT\r\n"
          "END:VCALENDAR\r\n";
      final exam = buildExamSynthBlock(
          [_exam(terms: [_term("Di, 23.03.2027", "17:30 - 19:00")])]);
      final feed =
          WebcalFeed.parse(CampusManager.injectExamSynth(lecture, exam))!;
      expect(feed.occurrences.any((o) => o.title.startsWith("Klausur:")),
          isTrue);
      final titles = CampusManager.gridTemplate(feed)
          .days
          .expand((d) => d.appointments)
          .map((a) => a.title)
          .toList();
      expect(titles.any((t) => t.contains("Klausur")), isFalse);
      expect(titles.any((t) => t.contains("Analysis I")), isTrue);
    });
  });

  group("campus_manager exam synth sentinels", () {
    const stub = "BEGIN:VCALENDAR\r\nEND:VCALENDAR\r\n";
    const block = "BEGIN:VEVENT\r\nUID:kauni-exam-1-0@ka_uni\r\nEND:VEVENT\r\n";

    test("extract returns the embedded block", () {
      final merged = CampusManager.injectExamSynth(stub, block);
      expect(merged, contains("X-EXAM-SYNTH-BEGIN"));
      expect(merged, contains("X-EXAM-SYNTH-END"));
      expect(CampusManager.extractExamSynth(merged), block);
    });

    test("strip removes block and sentinels", () {
      final merged = CampusManager.injectExamSynth(stub, block);
      expect(CampusManager.stripExamSynth(merged), stub);
      // no sentinels: no-ops
      expect(CampusManager.stripExamSynth(stub), stub);
      expect(CampusManager.extractExamSynth(stub), isEmpty);
    });

    test("re-injecting is idempotent, empty block removes the old one", () {
      final merged = CampusManager.injectExamSynth(stub, block);
      expect(CampusManager.injectExamSynth(merged, block), merged);
      expect(CampusManager.injectExamSynth(merged, ""), stub);
    });

    test("exam and signmeup blocks coexist and strip independently", () {
      const smBlock = "BEGIN:VEVENT\r\nUID:signmeup-7-0@ka_uni\r\nEND:VEVENT\r\n";
      final merged = CampusManager.injectSignMeUpSynth(
          CampusManager.injectExamSynth(stub, block), smBlock);
      expect(CampusManager.extractExamSynth(merged), block);
      expect(CampusManager.extractSignMeUpSynth(merged), smBlock);
      expect(
          CampusManager.stripSignMeUpSynth(CampusManager.stripExamSynth(merged)),
          stub);
    });
  });

  group("reapplyExamSynth / cold start", () {
    const stub = "BEGIN:VCALENDAR\r\nEND:VCALENDAR\r\n";
    const stale = "BEGIN:VEVENT\r\n"
        "UID:kauni-exam-01-A-9001-20270323T173000@ka_uni\r\n"
        "DTSTART;TZID=Europe/Berlin:20270323T173000\r\n"
        "DTEND;TZID=Europe/Berlin:20270323T190000\r\n"
        "SUMMARY:Klausur: Analysis I\r\nEND:VEVENT\r\n";

    late CampusManager cm;
    var notified = 0;
    setUp(() {
      notified = 0;
      cm = CampusManager(Student.empty, () => notified++);
    });

    test("empty rebuild scrubs the stale embedded block", () async {
      // F4: on restart block==examSynth=="" while the PERSISTED cache still
      // embeds last run's events - the no-op guard must not spare them
      SharedPreferences.setMockInitialValues({
        "DATA_webcalIcsCache": CampusManager.injectExamSynth(stub, stale),
      });
      await cm.reapplyExamSynth("");
      final prefs = await SharedPreferences.getInstance();
      final cache = prefs.getString("DATA_webcalIcsCache")!;
      expect(cache, isNot(contains("X-EXAM-SYNTH-BEGIN")));
      expect(cache, isNot(contains("kauni-exam-")));
    });

    test("deterministic identical block re-injection is a true no-op", () async {
      SharedPreferences.setMockInitialValues({"DATA_webcalIcsCache": stub});
      final block = buildExamSynthBlock(
          [_exam(terms: [_term("Di, 23.03.2027", "17:30 - 19:00")])]);
      await cm.reapplyExamSynth(block);
      expect(cm.examSynth, block);
      expect(notified, 1);
      await cm.reapplyExamSynth(block); // byte-identical rebuild
      expect(notified, 1); // early return fired: nothing rewritten
    });

    test("cold start carries the persisted block over", () async {
      // F3: nothing proven yet - the empty in-memory block must NOT
      // delete last run's sittings from the cache
      SharedPreferences.setMockInitialValues({
        "DATA_webcalIcsCache": CampusManager.injectExamSynth(stub, stale),
      });
      await cm.carryExamSynthFromCache();
      expect(cm.examSynth, stale);
    });

    test("a proven exam list is the block's single source of truth", () async {
      SharedPreferences.setMockInitialValues({
        "DATA_webcalIcsCache": CampusManager.injectExamSynth(stub, stale),
      });
      cm.examsLoaded = true; // this process fetched the list itself
      await cm.carryExamSynthFromCache();
      expect(cm.examSynth, isEmpty);
    });

    test("this process's freshly built block outranks the cache", () async {
      SharedPreferences.setMockInitialValues({
        "DATA_webcalIcsCache": CampusManager.injectExamSynth(stub, stale),
      });
      cm.examSynth = "BEGIN:VEVENT\r\nEND:VEVENT\r\n";
      await cm.carryExamSynthFromCache();
      expect(cm.examSynth, "BEGIN:VEVENT\r\nEND:VEVENT\r\n");
    });
  });
}
