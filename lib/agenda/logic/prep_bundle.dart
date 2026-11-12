import '../../exams/models/exam_list.dart';
import '../../ilias/due_parse.dart';
import '../../state_management/campus/campus_manager.dart';
import '../../timetable/models/webcal.dart';

/// Wave E (R27): the PREP BUNDLE — tap the next-up hero, get everything
/// that belongs to THIS lecture: the certified ILIAS binding (manual link
/// only — an auto-guessed course page is NOT shown, a wrong deep link into
/// someone else's course is worse than no link), every open assignment
/// deadline whose course matches the lecture, and the exam entry with its
/// registration state. Pure selection; all live data is injected.
class PrepDue {
  final DateTime when;

  /// The announcement title without the "Due: <course> (...)" wrapper.
  final String what;

  /// Course name the deadline was announced under (display).
  final String course;

  const PrepDue(this.when, this.what, this.course);
}

class PrepBundle {
  final String? iliasUrl;
  final List<PrepDue> dues;

  /// The exam catalogue entry for this lecture's module, if one exists.
  final ExamEntry? exam;

  const PrepBundle({this.iliasUrl, this.dues = const [], this.exam});

  bool get isEmpty => iliasUrl == null && dues.isEmpty && exam == null;
}

/// Course name carried in a synth due event's SUMMARY
/// ("Due: <course> (<announcement>)"); null for non-due titles.
String? dueCourseOf(String summary) {
  if (!summary.startsWith("Due: ")) return null;
  final rest = summary.substring(5);
  final open = rest.lastIndexOf(" (");
  return open <= 0 ? rest : rest.substring(0, open);
}

String dueWhatOf(String summary) {
  final open = summary.lastIndexOf(" (");
  if (!summary.startsWith("Due: ") || open <= 0) return summary;
  return summary.substring(open + 2).replaceAll(RegExp(r"\)$"), "");
}

PrepBundle prepBundleFor(
  IcsOccurrence lecture, {
  required String? iliasUrl,
  required List<IcsOccurrence> occurrences,
  required List<ExamEntry> exams,
  required DateTime now,
}) {
  final lectureKey = CampusManager.lectureTitleKey(lecture.displayTitle);

  // course-keyed deadlines still ahead; match through the SAME guarded
  // rule the exam gate uses (numeric-token guard keeps EM I off EM III)
  final dues = <PrepDue>[];
  for (final o in occurrences) {
    if (!o.uid.startsWith(dueSynthUidPrefix)) continue;
    if (!o.end.isAfter(now)) continue; // past deadline: nothing to prep
    final course = dueCourseOf(o.title);
    if (course == null) continue;
    if (!CampusManager.moduleKeyMatchesLectureKey(
        CampusManager.lectureTitleKey(course), {lectureKey})) {
      continue;
    }
    dues.add(PrepDue(o.start, dueWhatOf(o.title), course));
  }
  dues.sort((a, b) => a.when.compareTo(b.when));

  ExamEntry? exam;
  for (final e in exams) {
    if (CampusManager.moduleKeyMatchesLectureKey(
        CampusManager.lectureTitleKey(e.title), {lectureKey})) {
      exam = e;
      break;
    }
  }

  return PrepBundle(iliasUrl: iliasUrl, dues: dues, exam: exam);
}
