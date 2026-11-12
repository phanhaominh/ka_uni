import '../../exams/models/exam_list.dart';

/// R29: the countdown pool. Every registered exam with a concrete sitting
/// today or later, nearest first — anchored by the same rules as the
/// agenda's next-exam card (single-room discipline, "entfällt" never
/// counts down) but returned as plain data, so a list UI can format it
/// without duplicating doctrine that today lives inside a widget.
///
/// Pure logic: no prefs, no context, no l10n — `now` is injected and the
/// German relative wording ("heute" / "in 5 Tagen") is L10n.dayOffset's
/// job at render time.
class ExamCountdown {
  final ExamEntry exam;

  /// Start of the exam's earliest eligible sitting (the anchor).
  final DateTime at;

  /// Whole calendar days from today to the sitting ("today" = 0) —
  /// [L10n.daysFromNow] convention mirrored, not called: an exam at
  /// 08:00 seen at 23:00 is still "today", a sitting yesterday at 23:00
  /// is over.
  final int days;

  /// Room of the anchor sitting when it is unambiguous. Two pool sittings
  /// can share a start; showing the first match's room would
  /// misattribute a sibling's — null then. A placeholder room ("-",
  /// "--", "") is no location either, while "ILIAS" stays (roomLabel
  /// doctrine: for an online Klausur it IS the place).
  final String? room;

  const ExamCountdown({
    required this.exam,
    required this.at,
    required this.days,
    this.room,
  });
}

/// Build the countdowns, one per exam. Cancelled ("entfällt"), range-only
/// and time-less labels have no `startAt` and can never be counted down
/// to; a sitting whose start DAY passed is over even when its clock time
/// has not, and today still counts (days == 0). Sorted by sitting, ties
/// by title; capped at [limit] inside [horizonDays] — further-out exams
/// simply are not on the countdown card yet.
List<ExamCountdown> examCountdowns(
  List<ExamEntry> exams,
  DateTime now, {
  int limit = 6,
  int horizonDays = 90,
}) {
  final today = DateTime(now.year, now.month, now.day);
  final out = <ExamCountdown>[];
  for (final e in exams) {
    if (!e.registered) continue;
    DateTime? at;
    for (final t in e.terms) {
      final s = t.startAt;
      if (s == null) continue; // entfällt / range / no time: nothing to count to
      if (DateTime(s.year, s.month, s.day).isBefore(today)) continue;
      if (at == null || s.isBefore(at)) at = s;
    }
    if (at == null) continue;
    final days = DateTime(at.year, at.month, at.day).difference(today).inDays;
    if (days > horizonDays) continue;
    final atTerms = e.terms.where((t) => t.startAt == at).toList();
    String? room;
    if (atTerms.map((t) => t.room).toSet().length == 1) {
      final label = atTerms.first.roomLabel.trim();
      room = label.isEmpty ? null : label;
    }
    out.add(ExamCountdown(exam: e, at: at, days: days, room: room));
  }
  out.sort((a, b) {
    final d = a.at.compareTo(b.at);
    return d != 0 ? d : a.exam.title.compareTo(b.exam.title);
  });
  return out.length > limit ? out.sublist(0, limit) : out;
}
