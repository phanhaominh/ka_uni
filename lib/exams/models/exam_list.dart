import 'package:html/parser.dart' as htmlparser;

enum ExamWindowStatus { closed, open, impossible, unknown }

class ExamTerm {
  final String dayLabel; // "Di, 23.03.2027"
  final String time; // "17:30 - 19:00"
  final String room;
  ExamTerm(this.dayLabel, this.time, this.room);

  static final _date = RegExp(r'(\d{2})\.(\d{2})\.(\d{4})');
  static final _startHour = RegExp(r'(\d{1,2}):(\d{2})');

  /// Cancelled sitting ("entfällt") - never count down to it.
  bool get isCancelled =>
      dayLabel.toLowerCase().contains("entfällt") ||
      time.toLowerCase().contains("entfällt");

  /// Normalized room: KIT uses "-" / "ILIAS" style placeholders.
  String get roomLabel =>
      (room == "-" || room == "--" || room.isEmpty) ? "" : room;

  /// Concrete start of this sitting, if the labels parse. Null = unknown
  /// (dates given as ranges / text only).
  DateTime? get startAt {
    if (isCancelled) return null;
    // block/range dates ("27.02.-06.03.2027"): the first token lacks a year,
    // so firstMatch would silently return the range END. Treat as unknown.
    if (dayLabel.contains("-") &&
        RegExp(r"\d{1,2}\.\d{1,2}\s*[-–]").hasMatch(dayLabel)) {
      return null;
    }
    final d = _date.firstMatch(dayLabel);
    if (d == null) return null;
    final t = _startHour.firstMatch(time);
    if (t == null) return null; // no time -> never guess midnight
    return DateTime(
      int.parse(d.group(3)!),
      int.parse(d.group(2)!),
      int.parse(d.group(1)!),
      int.parse(t.group(1)!),
      int.parse(t.group(2)!),
    );
  }
}

class ExamEntry {
  final String examNumber;
  final String title;
  final String examiners;
  final String examType; // Schriftliche Prüfung / Studienleistung / ...
  bool registered; // Anmeldestatus
  ExamWindowStatus windowStatus;
  DateTime? windowStart; // "Anmeldung ab ..."
  DateTime? windowEnd; // "Anmelden bis ..."
  final List<ExamTerm> terms = [];

  ExamEntry({
    required this.examNumber,
    required this.title,
    required this.examiners,
    required this.examType,
    required this.registered,
    required this.windowStatus,
    this.windowStart,
    this.windowEnd,
  });


  bool windowIsOpen(DateTime now) {
    switch (windowStatus) {
      case ExamWindowStatus.impossible:
        return false;
      case ExamWindowStatus.open:
        return windowEnd == null || now.isBefore(windowEnd!);
      case ExamWindowStatus.closed:
        return windowStart != null &&
            !now.isBefore(windowStart!) &&
            (windowEnd == null || now.isBefore(windowEnd!));
      case ExamWindowStatus.unknown:
        return false;
    }
  }

  /// Red flag from the UX review: registration window open but not registered.
  bool needsAction(DateTime now) => !registered && windowIsOpen(now);

  /// Earliest future sitting of a registered exam (countdown anchor).
  DateTime? nextRegisteredTerm(DateTime now) {
    if (!registered) return null;
    DateTime? best;
    for (final t in terms) {
      final s = t.startAt;
      if (s != null && !s.isBefore(now) && (best == null || s.isBefore(best))) {
        best = s;
      }
    }
    return best;
  }
}

class ExamListParser {
  static final _deDateTime = RegExp(
      r'(?:Anmeldung ab|Anmelden bis)\s+(\d{2})\.(\d{2})\.(\d{4})(?:\s+(\d{2}):(\d{2}))?');

  static List<ExamEntry> parse(String html) {
    final document = htmlparser.parse(html);
    final table = document.getElementById("EXAMLIST");
    if (table == null) {
      return [];
    }

    final result = <ExamEntry>[];
    ExamEntry? current;

    for (final tr in table.getElementsByTagName("tr")) {
      final tds = tr.getElementsByTagName("td");
      if (tds.isEmpty) {
        continue;
      }

      // exam date row of the previous exam:
      // <span class=date>Di, 23.03.2027</span><span class=time>..</span><a class=room>..</a>
      final dateSpan = tr.querySelector("span.date");
      if (dateSpan != null && current != null) {
        final time = tr.querySelector("span.time")?.text.trim() ?? "";
        final room = tr.querySelector("a.room")?.text.trim() ?? "";
        current.terms.add(ExamTerm(dateSpan.text.trim(), time, room));
        continue;
      }

      if (tds.length < 7) {
        continue;
      }

      // main row: [0]folding [1]PrNr [2]Titel [3]spacer [4]Prüfer [5]Leistungsart [6]status+reg [7]spacer
      final examNumber = tds[1].text.trim();
      if (!RegExp(r"^\d{2}-[A-Z]").hasMatch(examNumber)) {
        current = null;
        continue;
      }

      final statusText =
          tds[6].querySelector(".regstatus")?.text.trim() ?? tds[6].text.trim();
      final registerText =
          tds[6].querySelector(".reginfo")?.text.trim() ?? "";

      ExamWindowStatus status = ExamWindowStatus.unknown;
      DateTime? start, end;
      if (registerText.contains("nicht möglich")) {
        status = ExamWindowStatus.impossible;
      } else {
        final m = _deDateTime.firstMatch(registerText);
        if (m != null) {
          final date = DateTime(int.parse(m.group(3)!), int.parse(m.group(2)!),
              int.parse(m.group(1)!), int.tryParse(m.group(4) ?? "0") ?? 0,
              int.tryParse(m.group(5) ?? "0") ?? 0);
          if (registerText.contains("Anmeldung ab")) {
            status = ExamWindowStatus.closed;
            start = date;
          } else if (registerText.contains("Anmelden bis")) {
            status = ExamWindowStatus.open;
            end = date;
          }
        }
      }

      current = ExamEntry(
        examNumber: examNumber,
        // cascampus cells carry layout whitespace ("Mechanical Design  A");
        // collapse runs so titles never show doubled spaces
        title: tds[2].text.replaceAll(RegExp(r"\s+"), " ").trim(),
        examiners: tds[4].text.trim(),
        examType: tds[5].text.trim(),
        registered: statusText.toLowerCase().contains("angemeldet") &&
            !statusText.toLowerCase().contains("nicht angemeldet"),
        windowStatus: status,
        windowStart: start,
        windowEnd: end,
      );
      result.add(current);
    }
    // cascampus lists pool rooms in arbitrary order (…, E, D); sort each
    // entry's exam terms by (real date, time, room) for stable reading
    for (final e in result) {
      e.terms.sort((a, b) {
        final d = _date(a.dayLabel).compareTo(_date(b.dayLabel));
        if (d != 0) return d;
        final t = a.time.compareTo(b.time);
        return t != 0 ? t : a.room.compareTo(b.room);
      });
    }
    return result;
  }

  /// "Do, 25.03.2027" -> sortable DateTime; unparsable dates sort last
  /// without shifting otherwise-valid ones relative to each other wrongly.
  static DateTime _date(String dayLabel) {
    final m = RegExp(r"(\d{2})\.(\d{2})\.(\d{4})").firstMatch(dayLabel);
    if (m == null) return DateTime(2100);
    return DateTime(int.parse(m.group(3)!), int.parse(m.group(2)!),
        int.parse(m.group(1)!));
  }

  static String? semesterCaption(String html) {
    final document = htmlparser.parse(html);
    for (final h2 in document.getElementsByTagName("h2")) {
      if (h2.text.contains("Prüfungen")) {
        return h2.text.trim();
      }
    }
    return null;
  }
}
