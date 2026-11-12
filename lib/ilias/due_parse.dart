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

  /// extra UID entropy when the announcement carries no course ref_id
  /// (the URL); empty otherwise - most items
  final String uidSalt;

  const DueItem(
      {required this.courseRefId,
      required this.course,
      required this.announcement,
      required this.due,
      required this.hasTime,
      this.uidSalt = ""});

  String get uid =>
      "kauni-due-$courseRefId-${_keyOf(announcement)}"
      // full-string checksum: two titles identical up to _keyOf's 24-char
      // cap ("Abgabe X (Nachtermin 10:00)" vs "(12:00)") used to share a
      // UID, and the publish dedupe silently dropped one deadline
      "${_hashOf(announcement)}"
      // different courses whose announcements lack a ref_id (refId 0)
      // stay distinguishable via the announcement URL the caller passes
      "$uidSalt"
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

/// FNV-1a-style rolling hash, run-stable by construction (unlike
/// String.hashCode): the UID must survive process restarts unchanged or
/// every poll sees "new" deadlines and re-arms every reminder
String _hashOf(String t) {
  var h = 0x811c9dc5;
  for (final c in t.codeUnits) {
    h = ((h ^ c) * 0x01000193) & 0x7fffffff;
  }
  return h.toRadixString(36);
}

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
    r"abzugeben|abgeben\b|hochladen bis|bis spätestens|einsendeschluss|"
    r"frist\b|abgabetermin|abgabeschluss|nachfrist",
    caseSensitive: false);

final _date = RegExp(
    r"(\d{1,2})\.(\d{1,2})(?:\.(\d{4}))?");
final _time = RegExp(r"(\d{1,2})[:.](\d{2})\s*uhr|(\d{1,2})[:.](\d{2})\s*Uhr",
    caseSensitive: false);

/// a "12.10" immediately followed by "Uhr" is a TIME (12:10) typed with a
/// dot, not 12 October - never bind it as a date
final _leadingUhr = RegExp(r"^\s*[Uu]hr\b");

/// a deadline word sitting right BEFORE a date marks it as the real due
/// date; room/building codes ("Raum 20.11") carry none of these
final _kwBefore = RegExp(
    r"(bis spu?testens|bis zum|bis|frist|deadline|due|einsendeschluss|"
    r"einreichung|sp?testens|\bam|zum)\s*[:\-]?\s*$",
    caseSensitive: false);

/// Parse one announcement title. Returns null unless BOTH a deadline
/// keyword and a date are present, and the date (year-inferred toward the
/// nearest future occurrence from [postedAt]) is not already in the past.
DueItem? parseDueAnnouncement(
    {required int courseRefId,
    required String course,
    required String title,
    required DateTime postedAt,
    String uidSalt = ""}) {
  final t = icsFoldable(title).trim();
  if (t.isEmpty || t.length > 160) return null;
  if (!_kw.hasMatch(t)) return null;

  // Never bind the FIRST date-shaped token. KIT room/building codes read
  // as valid DD.MM ("Raum 20.11") and an announcement names a room
  // alongside the real Frist, so firstMatch either grabs the room (WRONG
  // deadline + reminders on it) or dies on an invalid month ("Raum 30.20"
  // -> month 20) and loses the true date entirely. Collect every token,
  // then keep only real calendar dates, preferring one a deadline word
  // introduces. A missed deadline beats a wrong one.
  final cands = <_DateCand>[];
  for (final m in _date.allMatches(t)) {
    if (_leadingUhr.hasMatch(t.substring(m.end))) continue; // "12.10 Uhr"
    final day = int.parse(m.group(1)!), month = int.parse(m.group(2)!);
    if (month < 1 || month > 12 || day < 1 || day > 31) continue;
    final y = m.group(3);
    final window = t.substring((m.start - 12).clamp(0, m.start), m.start);
    cands.add((
      day: day,
      month: month,
      year: y == null ? null : int.parse(y),
      end: m.end,
      kw: _kwBefore.hasMatch(window),
    ));
  }
  var pool = cands.where((c) => c.kw).toList();
  if (pool.isEmpty) pool = cands;

  DueItem? best;
  for (final c in pool) {
    var yy = c.year ?? postedAt.year;
    if (DateTime(yy, c.month, c.day).day != c.day) continue; // 31.02 -> 01.03
    var due = DateTime(yy, c.month, c.day);
    if (c.year == null &&
        due.isBefore(postedAt.subtract(const Duration(days: 1)))) {
      final ny = yy + 1;
      if (DateTime(ny, c.month, c.day).day != c.day) continue;
      yy = ny; // MUST move with due: the timed rebuild below uses yy
      due = DateTime(ny, c.month, c.day); // "15.01." posted in November
    }
    if (due.isBefore(postedAt)) continue; // already-expired announcement
    // a deadline MORE than a term ahead is a misread ("01.01." recurs)
    if (due.isAfter(postedAt.add(const Duration(days: 210)))) continue;

    // a time attaches ONLY when it follows the chosen date - a "16:15 Uhr"
    // before it belongs to an event mention, not the deadline (else the
    // T-15 reminder fires hours early off a lecture start)
    int hour = 23, minute = 45;
    var hasTime = false;
    final tm = _time.firstMatch(t.substring(c.end));
    if (tm != null) {
      final h = int.parse(tm.group(1) ?? tm.group(3)!);
      final mi = int.parse(tm.group(2) ?? tm.group(4)!);
      if (h <= 23 && mi < 60) {
        hour = h;
        minute = mi;
        hasTime = true;
      }
    }
    final withTime = DateTime(yy, c.month, c.day, hour, minute);
    if (withTime.isBefore(postedAt)) continue; // timed slot already passed
    due = withTime;

    final item = DueItem(
        courseRefId: courseRefId,
        course: icsFoldable(course),
        announcement: t,
        due: due,
        hasTime: hasTime,
        uidSalt: uidSalt);
    if (best == null || due.isBefore(best.due)) best = item;
  }
  return best;
}

typedef _DateCand = ({int day, int month, int? year, int end, bool kw});

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
    // NO DTEND, ever: a deadline is a POINT in time. An emitted
    // DTEND = due+15min would (a) set endGuessed=false so the T−30
    // reminder announces the invented span "23:45–00:09" as fact and
    // (b) export a fabricated interval to every share ("guessed ends
    // never leave the app", exam_synth doctrine). Without DTEND the
    // parser applies its +90 display default with endGuessed=true and
    // every consumer renders the honest start-only form ("ab HH:MM").
    b.write("BEGIN:VEVENT\r\n"
        "UID:${it.uid}\r\n"
        "DTSTAMP:${_icsUtc(DateTime(it.due.year, it.due.month, it.due.day))}"
        "\r\n"
        // TZID like the exam family: a Berlin deadline must remind at
        // Berlin wall time on a device whose clock sits in another zone
        // (floating local time would silently shift it by the offset)
        "DTSTART;TZID=Europe/Berlin:${_icsLocal(it.due)}\r\n"
        // course empty (the news list carries no course title until the
        // caller joins it) - print the announcement ONCE, not twice
        "SUMMARY:${_esc(it.course.isEmpty ? "Due: ${it.announcement}" : "Due: ${it.course} (${it.announcement})")}\r\n"
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

String _icsUtc(DateTime d) => "${_icsLocal(d)}Z";

/// strip the leading course-id ("3161011 - ") from a course title for
/// the SUMMARY (same shape WebcalFeed._idPrefix matches)
String shortCourse(String title) {
  final m = RegExp(r"^\d{7}\s*[–-]\s*(.+)$").firstMatch(title);
  return m != null ? m.group(1)!.trim() : title;
}
