import '../utils/ics_text.dart';

/// Wave B (R24): assignment/announcement DEADLINE extraction from ILIAS.
/// The dashboard news list carries only {courseTitle, title, posting time}
/// - no body - so the parser works on ANNOUNCEMENT TITLES with high
/// precision fences: a deadline keyword AND a concrete date must both be
/// present, or nothing is emitted (a missed deadline beats a wrong one;
/// exam_synth's `NN-[A-Z]` fencing doctrine).
class DueItem {
  final int courseRefId;

  /// short course label for the SUMMARY (cleanTitle-style number prefix
  /// removed by the caller)
  final String course;

  /// announcement title, whitespace-collapsed, no line breaks
  final String announcement;

  /// resolved deadline (hasTime=false -> 23:45 local, end-of-day guess)
  final DateTime due;
  final bool hasTime;

  const DueItem(
      {required this.courseRefId,
      required this.course,
      required this.announcement,
      required this.due,
      required this.hasTime});

  String get uid =>
      "kauni-due-$courseRefId-${_keyOf(announcement)}"
      "-${due.year}${_p2(due.month)}${_p2(due.day)}@ka_uni";

  bool sameKey(DueItem o) => uid == o.uid;

  @override
  bool operator ==(Object o) =>
      o is DueItem &&
      o.uid == uid &&
      o.due == due &&
      o.hasTime == hasTime &&
      o.course == course &&
      o.announcement == announcement;
  @override
  int get hashCode => Object.hash(uid, due, hasTime, course, announcement);
}

String _p2(int v) => v.toString().padLeft(2, "0");

/// stable, readable UID seed: alphanumerics of the title, lowercase,
/// capped (no hashing: String.hashCode is not stable across runs)
String _keyOf(String t) {
  final b = StringBuffer();
  for (final c in t.toLowerCase().codeUnits) {
    final isAlnum = (c >= 0x61 && c <= 0x7a) || (c >= 0x30 && c <= 0x39);
    if (isAlnum) b.writeCharCode(c);
    if (b.length >= 24) break;
  }
  return b.isEmpty ? "ann" : b.toString();
}

/// deadline vocabulary that must appear (case-insensitive) before any
/// date in the title is trusted as a due date
final _kw = RegExp(
    r"abgabefrist|abgabe\s*frist|abgabe\b|einreichung|deadline\b|due\b|"
    r"abzugeben|hochladen bis|bis spätestens|einsendeschluss|frist\b",
    caseSensitive: false);

final _date = RegExp(
    r"(\d{1,2})\.(\d{1,2})(?:\.(\d{4}))?");
final _time = RegExp(r"(\d{1,2})[:.](\d{2})\s*uhr|(\d{1,2})[:.](\d{2})\s*Uhr",
    caseSensitive: false);

/// Parse one announcement title. Returns null unless BOTH a deadline
/// keyword and a date are present, and the date (year-inferred toward the
/// nearest future occurrence from [postedAt]) is not already in the past.
DueItem? parseDueAnnouncement(
    {required int courseRefId,
    required String course,
    required String title,
    required DateTime postedAt}) {
  final t = icsFoldable(title).trim();
  if (t.isEmpty || t.length > 160) return null;
  if (!_kw.hasMatch(t)) return null;
  final m = _date.firstMatch(t);
  if (m == null) return null;
  final day = int.parse(m.group(1)!);
  final month = int.parse(m.group(2)!);
  if (month < 1 || month > 12 || day < 1 || day > 31) return null;

  // time BEFORE the date check: a bare "18:00" also matches nothing else
  // when no "Uhr" follows - require the explicit unit to stay precise
  final tm = _time.firstMatch(t);
  int hour = 23, minute = 45;
  var hasTime = false;
  if (tm != null) {
    final h = int.parse(tm.group(1) ?? tm.group(3)!);
    final mi = int.parse(tm.group(2) ?? tm.group(4)!);
    if (h <= 23 && mi < 60) {
      hour = h;
      minute = mi;
      hasTime = true;
    }
  }

  final y = m.group(3);
  DateTime mk(int yy) => DateTime(yy, month, day, hour, minute);
  var due = y != null ? mk(int.parse(y)) : mk(postedAt.year);
  if (y == null && due.isBefore(postedAt.subtract(const Duration(days: 1)))) {
    due = mk(postedAt.year + 1); // "15.01." posted in November
  }
  if (due.isBefore(postedAt)) return null; // already-expired announcement
  // a deadline announced MORE than a term ahead is a misread (dates like
  // "01.01." recurs) - refuse rather than haunt the calendar
  if (due.isAfter(postedAt.add(const Duration(days: 210)))) return null;

  return DueItem(
      courseRefId: courseRefId,
      course: icsFoldable(course),
      announcement: t,
      due: due,
      hasTime: hasTime);
}

/// UID prefix marking synthetic deadline VEVENTs (mirrors
/// [examSynthUidPrefix]).
const dueSynthUidPrefix = "kauni-due-";

/// Deterministic VEVENT text for the deadline set (no calendar wrapper).
/// Byte-identical rebuilds are load-bearing: reapplyDueSynth's
/// merged==cached no-op depends on it (no CHANGED churn, no alarm storms).
/// DTSTAMP derives from the deadline itself, never the wall clock.
String buildDueSynthBlock(List<DueItem> items) {
  final sorted = [...items]..sort((a, b) {
    final d = a.due.compareTo(b.due);
    return d != 0 ? d : a.uid.compareTo(b.uid);
  });
  final b = StringBuffer();
  for (final it in sorted) {
    final end = it.due.add(const Duration(minutes: 15));
    b.write("BEGIN:VEVENT\r\n"
        "UID:${it.uid}\r\n"
        "DTSTAMP:${_icsUtc(DateTime(it.due.year, it.due.month, it.due.day))}"
        "\r\n"
        "DTSTART:${_icsLocal(it.due)}\r\n"
        "DTEND:${_icsLocal(end)}\r\n"
        "SUMMARY:${_esc("Due: ${it.course.isEmpty ? it.announcement : it.course} (${it.announcement})")}\r\n"
        "DESCRIPTION:${_esc("announced ${it.due.year} via ILIAS")}\r\n"
        "END:VEVENT\r\n");
  }
  return b.toString();
}

String _esc(String v) {
  final s = icsFoldable(v);
  return s
      .replaceAll(r"\", r"\\")
      .replaceAll(";", r"\;")
      .replaceAll(",", r"\,");
}

String _icsLocal(DateTime d) => "${d.year.toString().padLeft(4, "0")}"
    "${_p2(d.month)}${_p2(d.day)}T${_p2(d.hour)}${_p2(d.minute)}00";

String _icsUtc(DateTime d) => _icsLocal(d).replaceFirst(RegExp(r"\d{6}$"),
    "000000"); // content-keyed day-stamp, stable across rebuilds

/// strip the leading course-id ("3161011 - ") from a course title for
/// the SUMMARY (same shape WebcalFeed._idPrefix matches)
String shortCourse(String title) {
  final m = RegExp(r"^\d{7}\s*[–-]\s*(.+)$").firstMatch(title);
  return m != null ? m.group(1)!.trim() : title;
}
