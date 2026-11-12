import 'package:flutter_test/flutter_test.dart';
import 'package:kit_mobile/agenda/logic/prep_bundle.dart';
import 'package:kit_mobile/exams/models/exam_list.dart';
import 'package:kit_mobile/timetable/models/webcal.dart';

/// Wave E R27: prep-bundle matching rides the guarded lecture-key rule —
/// EM I must never borrow EM III's deadlines.
void main() {
  final now = DateTime(2026, 11, 12, 9);

  IcsOccurrence occ(String uid, DateTime start, String title) => IcsOccurrence(
      start: start,
      end: start.add(const Duration(hours: 1)),
      title: title,
      room: "",
      uid: uid);

  IcsOccurrence due(DateTime when, String course, String what) =>
      occ("kauni-due-3038952-x", when, "Due: $course ($what)");

  test("summary wrapper parses both ways", () {
    const s = "Due: Advanced Mathematics I (Übungsblatt 3 – Abgabe bis …)";
    expect(dueCourseOf(s), "Advanced Mathematics I");
    expect(dueWhatOf(s), "Übungsblatt 3 – Abgabe bis …");
    expect(dueCourseOf("Vorlesung EM I"), isNull);
    expect(dueWhatOf("Due: Mech I (Blatt 5)"), "Blatt 5");
  });

  test("dues match same course only - numeric guard holds", () {
    final lecture = occ("em1@kit", DateTime(2026, 11, 12, 10),
        "Engineering Mechanics I (V) - 3161010");
    final bundle = prepBundleFor(lecture,
        iliasUrl: null,
        occurrences: [
          due(DateTime(2026, 11, 20, 18), "Engineering Mechanics I",
              "Übungsblatt 4"),
          due(DateTime(2026, 11, 21, 18), "Engineering Mechanics III",
              "Übungsblatt 7"),
          due(DateTime(2026, 11, 1), "Engineering Mechanics I", "blatt 0"),
        ],
        exams: [],
        now: now);
    expect(bundle.dues.length, 1);
    expect(bundle.dues.single.what, "Übungsblatt 4");
    expect(bundle.isEmpty, isFalse); // dues present -> not empty
  });

  test("certified ILIAS bind passes through; exam entry attaches", () {
    final lecture =
        occ("am1@kit", DateTime(2026, 11, 12, 12), "Advanced Mathematics I");
    final exam = ExamEntry(
        examNumber: "01-AM",
        title: "Advanced Mathematics I",
        examiners: "",
        examType: "",
        registered: true,
        windowStatus: ExamWindowStatus.closed);
    final bundle = prepBundleFor(lecture,
        iliasUrl: "https://ilias.studium.kit.edu/goto.php?target=crs_1",
        occurrences: const [],
        exams: [exam],
        now: now);
    expect(bundle.iliasUrl, isNotNull);
    expect(bundle.exam, same(exam));
  });

  test("nothing at all -> isEmpty", () {
    final lecture =
        occ("x@kit", DateTime(2026, 11, 12, 14), "Some Elective X");
    final bundle = prepBundleFor(lecture,
        iliasUrl: null,
        occurrences: const [],
        exams: const [],
        now: now);
    expect(bundle.isEmpty, isTrue);
  });
}
