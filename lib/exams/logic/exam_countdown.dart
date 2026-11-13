import '../../exams/models/exam_list.dart';

/// R29: the countdown pool. Every registered exam with a concrete sitting
/// today or later, nearest first — anchored by the same rules as the
/// agenda's next-exam card (single-room discipline, "entfällt" never
/// counts down) but returned as plain data, so a list UI can format it
/// without duplicating doctrine that today lives inside a widget.
///
/// R31 D1: the same type also carries the "If you register" tier — an
/// unregistered exam the student could still sign up for ([conditional],
/// [windowEnd] = registration deadline shown in the sub-line). Plain data
/// as always: no prefs, no context, no l10n — `now` is injected and the
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

  /// R31 D1: end of the registration window, shown as "register by …" on
  /// conditional rows (null on registered rows — they have no deadline
  /// left to warn about).
  final DateTime? windowEnd;

  /// R31 D1: true = unregistered "If you register" row (muted weight +
  /// sub-line at render time); false = ordinary registered countdown.
  final bool conditional;

  const ExamCountdown({
    required this.exam,
    required this.at,
    required this.days,
    this.room,
    this.windowEnd,
    this.conditional = false,
  });
}

/// Earliest future dated sitting of [e], or null when none qualifies —
/// the anchor rule shared by both countdown tiers: cancelled ("entfällt")
/// / range-only / time-less labels have no `startAt` and can never be
/// counted down to; a sitting whose start DAY passed is over even when
/// its clock time has not, and today still counts (days == 0).
DateTime? _earliestFutureSitting(ExamEntry e, DateTime today) {
  DateTime? at;
  for (final t in e.terms) {
    final s = t.startAt;
    if (s == null) continue; // entfällt / range / no time: nothing to count to
    if (DateTime(s.year, s.month, s.day).isBefore(today)) continue;
    if (at == null || s.isBefore(at)) at = s;
  }
  return at;
}

/// Room of the sittings starting exactly at [at], single-room doctrine
/// (see [ExamCountdown.room]); shared so both tiers can never disagree.
String? _anchorRoom(ExamEntry e, DateTime at) {
  final atTerms = e.terms.where((t) => t.startAt == at).toList();
  if (atTerms.map((t) => t.room).toSet().length != 1) return null;
  final label = atTerms.first.roomLabel.trim();
  return label.isEmpty ? null : label;
}

/// Build the registered countdowns, one per exam, sorted by sitting, ties
/// by title, capped at [limit] inside [horizonDays] — further-out exams
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
    final at = _earliestFutureSitting(e, today);
    if (at == null) continue;
    final days = DateTime(at.year, at.month, at.day).difference(today).inDays;
    if (days > horizonDays) continue;
    out.add(ExamCountdown(
        exam: e, at: at, days: days, room: _anchorRoom(e, at)));
  }
  out.sort((a, b) {
    final d = a.at.compareTo(b.at);
    return d != 0 ? d : a.exam.title.compareTo(b.exam.title);
  });
  return out.length > limit ? out.sublist(0, limit) : out;
}

/// R31 D1 (panel verdict): the "If you register" tier — unregistered exams
/// the student could STILL sign up for, so the countdown speaks before the
/// decision instead of only after it. Eligible per exam: not registered,
/// window not [ExamWindowStatus.impossible], a future dated sitting (the
/// very same anchor rules as the registered pool), AND the window is
/// reachable now — open, or closing within [horizonDays].
///
/// Deliberately NO `isTakingThisSemester` gate (panel: the timetable-
/// absence heuristic is exactly what hid ITDS 26.11. behind the catalog).
/// A window whose status is unknown but that carries a concrete closing
/// date counts as reachable — the date is what the sub-line shows.
/// Days/anchor math is [examCountdowns]' exact shared helpers, so a row
/// that graduates to the registered tier on success never shifts.
List<ExamCountdown> conditionalCountdowns(
  List<ExamEntry> exams,
  DateTime now, {
  int limit = 6,
  int horizonDays = 90,
}) {
  final today = DateTime(now.year, now.month, now.day);
  final horizon = now.add(Duration(days: horizonDays));
  final out = <ExamCountdown>[];
  for (final e in exams) {
    if (e.registered) continue;
    if (e.windowStatus == ExamWindowStatus.impossible) continue;
    final at = _earliestFutureSitting(e, today);
    if (at == null) continue;
    final openNow = e.windowIsOpen(now);
    // "closes within horizonDays" = it still closes at all: a stale
    // windowEnd in the past (status says open, deadline passed) means the
    // window is GONE — the row disappears with its own sub-line.
    final closesInTime = e.windowEnd != null &&
        e.windowEnd!.isAfter(now) &&
        !e.windowEnd!.isAfter(horizon);
    if (!openNow && !closesInTime) continue;
    final days = DateTime(at.year, at.month, at.day).difference(today).inDays;
    out.add(ExamCountdown(
      exam: e,
      at: at,
      days: days,
      room: _anchorRoom(e, at),
      windowEnd: e.windowEnd,
      conditional: true,
    ));
  }
  out.sort((a, b) {
    final d = a.at.compareTo(b.at);
    return d != 0 ? d : a.exam.title.compareTo(b.exam.title);
  });
  return out.length > limit ? out.sublist(0, limit) : out;
}
