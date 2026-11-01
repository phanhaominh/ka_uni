import 'exam_list.dart';

/// UID prefix identifying synthetic exam-sitting VEVENTs (see
/// [buildExamSynthBlock]). Consumers that must tell genuine timetable
/// content apart from derived exam rows (relevance gate, weekly grid)
/// match on it.
const examSynthUidPrefix = "kauni-exam-";

/// VEVENT text (no calendar wrapper) for every concrete sitting of every
/// REGISTERED exam, so sittings appear in the merged webcal cache exactly
/// like the SignMeUp synthetic block does for accepted tutorials: the grid,
/// the agenda, the 07:30 digest, the 30-min lecture reminders and the ICS
/// export all read the merged feed and pick the exams up unchanged.
///
/// The "Klausur: " prefix is deliberately hardcoded German: it lives inside
/// the ICS body (feed content, not UI chrome), same as the campus feed's own
/// German summaries - no l10n round-trip for a device-language-independent
/// calendar document.
String buildExamSynthBlock(List<ExamEntry> exams) {
  final out = StringBuffer();
  final now = DateTime.now();
  for (final e in exams) {
    // the catalogue also lists lectures of later semesters; only exams the
    // student actually registered for are real appointments
    if (!e.registered) continue;
    // ICS injection guard: examNumber arrives verbatim from cascampus HTML
    // and lands inside the UID line; interior CR/LF would split the
    // physical line and make Google/Apple reject or fabricate around it
    // (the export copies the cache verbatim). Anything outside the
    // conservative KIT number shape drops the ENTIRE entry - a missing
    // calendar beats a corrupt document.
    if (!_kitExamNumber.hasMatch(e.examNumber)) continue;
    for (final t in e.terms) {
      final start = t.startAt;
      // cancelled ("entfällt") and range/text-only sittings return a null
      // startAt by design - never guess when the date is not concrete
      if (start == null) continue;
      // a finished sitting is history, not an appointment: without this
      // the exported .ics would carry stale events forever. The block
      // therefore legitimately changes at the sitting's date boundary -
      // the morning after, reapplyExamSynth strips that VEVENT out.
      if (start.isBefore(now)) continue;
      final room = t.roomLabel;
      final end = _endDate(start, t.time);
      out.write("BEGIN:VEVENT\r\n"
          // UID keys the sitting, not the parser's term INDEX: the parser
          // sorts terms, so an index would flip when KIT adds a Nachtermin
          // and every exported calendar would duplicate instead of update
          "UID:$examSynthUidPrefix${e.examNumber}-${_icsLocal(start)}@ka_uni\r\n"
          // DTSTAMP is derived from the sitting, not the wall clock: two
          // rebuilds of the same data emit byte-identical blocks, which is
          // what makes reapplyExamSynth's no-change early return real
          "DTSTAMP:${_icsStamp(DateTime(start.year, start.month, start.day))}\r\n"
          "DTSTART;TZID=Europe/Berlin:${_icsLocal(start)}\r\n"
          // only REAL end times are exported; a guessed end (no second
          // time token) stays out of the document entirely
          "${end == null ? "" : "DTEND;TZID=Europe/Berlin:${_icsLocal(end)}\r\n"}"
          "SUMMARY:${_icsEscape(_icsFoldable("Klausur: ${e.title}"))}\r\n"
          "${room.isEmpty ? "" : "LOCATION:${_icsEscape(_icsFoldable(room))}\r\n"}"
          "END:VEVENT\r\n");
    }
  }
  return out.toString();
}

/// Exam end from the second time token of the sitting label
/// ("17:30 - 19:00" -> 19:00), or null when the label has none. A guessed
/// end is NEVER exported: the webcal parser applies its in-app +90-minute
/// default (the KIT standard exam length, DISPLAY-ONLY - reminders and the
/// digest key off the start, so a wrong assumption shortens a card, never
/// moves an alarm) and flags the occurrence endGuessed.
/// An end token at/before the start is an overnight span, one day later
/// (same rule the SignMeUp emitter applies); note the agenda's day rule
/// then lists such a sitting on BOTH calendar days it touches - accepted.
DateTime? _endDate(DateTime start, String time) {
  final tokens = _timeToken.allMatches(time).toList();
  if (tokens.length < 2) {
    return null;
  }
  var end = DateTime(start.year, start.month, start.day,
      int.parse(tokens[1].group(1)!), int.parse(tokens[1].group(2)!));
  if (!end.isAfter(start)) {
    end = end.add(const Duration(days: 1));
  }
  return end;
}

final _timeToken = RegExp(r"(\d{1,2}):(\d{2})");

/// Conservative KIT examination-number shape ("01-A-9001",
/// "76-T-MACH-000000"); the parser already requires the `NN-[A-Z]` prefix,
/// this additionally fence-offs any character outside that printable set.
final _kitExamNumber = RegExp(r"^[0-9]{2}-[0-9A-Za-z/.-]+$");

final _newlineRun = RegExp(r"\s*[\r\n]+\s*");

/// A CR/LF inside a property value splits the physical ICS line and
/// destroys the document; HTML-sourced room labels survive .trim() with
/// interior newlines. Collapse any whitespace run that contains a newline
/// into a single space.
String _icsFoldable(String v) => v.replaceAll(_newlineRun, " ");

String _icsStamp(DateTime d) {
  final u = d.toUtc();
  String two(int v) => v.toString().padLeft(2, "0");
  return "${u.year.toString().padLeft(4, "0")}${two(u.month)}${two(u.day)}"
      "T${two(u.hour)}${two(u.minute)}${two(u.second)}Z";
}

String _icsLocal(DateTime d) => "${d.year.toString().padLeft(4, "0")}"
    "${d.month.toString().padLeft(2, "0")}"
    "${d.day.toString().padLeft(2, "0")}T"
    "${d.hour.toString().padLeft(2, "0")}"
    "${d.minute.toString().padLeft(2, "0")}00";

String _icsEscape(String v) =>
    v.replaceAll(r"\", r"\\").replaceAll(";", r"\;").replaceAll(",", r"\,");
