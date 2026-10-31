import 'package:flutter_test/flutter_test.dart';
import 'package:kit_mobile/exams/models/exam_list.dart';
import 'package:kit_mobile/exams/views/exams_page.dart';

ExamEntry _e(String number,
        {String title = "Basics of Manufacturing Technology"}) =>
    ExamEntry(
      examNumber: number,
      title: title,
      examiners: "",
      examType: "",
      registered: false,
      windowStatus: ExamWindowStatus.open,
      windowEnd: DateTime(2027, 2, 7),
    );

// cascampus serves the pools in the order …, E, D and the pool rooms arrive
// as term lines inside ONE card in DOM order
const _html = '''
<table id="EXAMLIST">
<tr><td></td><td>35-M-01</td><td>Basics  of Manufacturing Technology</td><td></td>
<td>Schilp</td><td>Studienleistung</td>
<td><span class="regstatus">Anmeldung erforderlich</span>
<span class="reginfo">Anmelden bis 07.02.2027 23:59</span></td><td></td></tr>
<tr><td colspan=8><span class="date">Do, 25.03.2027</span><span class="time">13:00 - 14:00</span><a class="room">20.21 Pool E</a></td></tr>
<tr><td colspan=8><span class="date">Do, 25.03.2027</span><span class="time">13:00 - 14:00</span><a class="room">20.21 Pool A</a></td></tr>
<tr><td colspan=8><span class="date">Fr, 20.03.2027</span><span class="time">10:00 - 11:00</span><a class="room">20.21 Pool C</a></td></tr>
<tr><td colspan=8><span class="date">Do, 25.03.2027</span><span class="time">13:00 - 14:00</span><a class="room">20.21 Pool D</a></td></tr>
</table>''';

void main() {
  test("same deadline + same title sorts by exam number, not source order",
      () {
    final exams = [
      _e("20.21 Pool A"),
      _e("20.21 Pool E"),
      _e("20.21 Pool D"),
      _e("20.21 Pool B"),
      _e("20.21 Pool C")
    ];
    exams.sort(ExamsPage.byWindowEnd);
    expect(
        exams.map((e) => e.examNumber).toList(),
        [
          "20.21 Pool A",
          "20.21 Pool B",
          "20.21 Pool C",
          "20.21 Pool D",
          "20.21 Pool E"
        ]);
  });

  test("different deadlines still dominate", () {
    final exams = [
      _e("20.21 Pool A", title: "Z"),
      ExamEntry(
          examNumber: "10.11 Pool Z",
          title: "A",
          examiners: "",
          examType: "",
          registered: false,
          windowStatus: ExamWindowStatus.open,
          windowEnd: DateTime(2027, 1, 1)),
    ];
    exams.sort(ExamsPage.byWindowEnd);
    expect(exams.first.examNumber, "10.11 Pool Z");
  });

  test("terms sort by date, then time, then room", () {
    final exams = ExamListParser.parse(_html);
    expect(exams, hasLength(1));
    expect(exams.single.terms.map((t) => t.room).toList(), [
      "20.21 Pool C", // earlier DATE first
      "20.21 Pool A",
      "20.21 Pool D",
      "20.21 Pool E",
    ]);
  });

  test("title whitespace collapsed while parsing", () {
    final exams = ExamListParser.parse(_html);
    expect(exams.single.title, "Basics of Manufacturing Technology");
  });
}
