import 'package:html/parser.dart' as htmlparser;

enum ExamWindowStatus { closed, open, impossible, unknown }

class ExamTerm {
  final String dayLabel; // "Di, 23.03.2027"
  final String time; // "17:30 - 19:00"
  final String room;
  ExamTerm(this.dayLabel, this.time, this.room);

  static final _date = RegExp(r'(\d{2})\.(\d{2})\.(\d{4})');
  static final _startHour = RegExp(r'(\d{1,2}):(\d{2})');
  // "d.m" fragments: exactly one per concrete sitting date
  static final _dayFragment = RegExp(r'\d{1,2}\.\d{1,2}');
  // ENGLISH portal locale renders every date as US M/D/YYYY ("Wed,
  // 2/24/2027") and times as "11:00 AM - 1:00 PM" (observed live on the
  // same brick whose German view says "Mi, 24.02.2027, 11:00 - 13:00"):
  // the portal language follows the STUDENT, so a MEI kid browsing in
  // English used to get "exam date unknown" everywhere while the date
  // sat on the page in plain sight. CasCampus' en locale is en-US
  // server-side, so month comes first - and "2/24" is itself proof:
  // no month exceeds 12.
  static final _usDate = RegExp(r'(\d{1,2})/(\d{1,2})/(\d{4})');

  /// Cancelled sitting ("entfällt" / EN "cancelled") - never count down.
  bool get isCancelled {
    final t = "$dayLabel $time".toLowerCase();
    return t.contains("entfällt") || t.contains("cancell") || t.contains("canceled");
  }

  /// Parse a Campus date cell under EITHER portal locale: German
  /// "24.02.2027" (also inside "Mi, 24.02.2027") or US "2/24/2027"
  /// (also inside "Wed, 2/24/2027"). Surrounding words are ignored; a
  /// label with two full dates is a range -> null (callers must never
  /// silently resolve a range to one end). Month-first for the US
  /// spelling is the CAS en-US server locale, not a guess.
  static DateTime? parseCasDate(String raw) {
    final usCount = _usDate.allMatches(raw).length;
    // "d.m" fragment count is the German range guard: "27.02.-06.03.2027"
    // holds exactly ONE full-date match but TWO fragments - counting full
    // dates alone would silently resolve the range to its END.
    final deCount = _dayFragment.allMatches(raw).length;
    if (usCount == 1 && deCount == 0) {
      final u = _usDate.firstMatch(raw)!;
      final m = int.parse(u.group(1)!);
      final d = int.parse(u.group(2)!);
      if (m < 1 || m > 12 || d < 1 || d > 31) return null;
      return DateTime(int.parse(u.group(3)!), m, d);
    }
    if (usCount == 0 && deCount == 1) {
      final de = _date.firstMatch(raw);
      if (de == null) return null; // fragment without a year -> no date
      final d = int.parse(de.group(1)!);
      final m = int.parse(de.group(2)!);
      if (m < 1 || m > 12 || d < 1 || d > 31) return null;
      return DateTime(int.parse(de.group(3)!), m, d);
    }
    return null;
  }

  /// Start hour of a "11:00 AM - 1:00 PM" / "17:30 - 19:00" span,
  /// AM/PM aware: "1:00 PM" is 13:00, and a bare first-token read would
  /// silently schedule the afternoon sitting twelve hours early.
  static int? startHourOf(String time) {
    final m = _startHour.firstMatch(time);
    if (m == null) return null;
    var hour = int.parse(m.group(1)!);
    final ampm = RegExp(r'\b([AP]M)\b', caseSensitive: false)
        .firstMatch(time.substring(0, m.end + 4 <= time.length ? m.end + 4 : time.length));
    if (ampm != null) {
      final pm = ampm.group(1)!.toUpperCase() == "PM";
      if (pm && hour < 12) hour += 12;
      if (!pm && hour == 12) hour = 0;
    } else if (hour > 23) {
      return null;
    }
    return hour;
  }

  /// KIT placeholder rooms carry no location. The FULL placeholder set
  /// is "-", "--" and "ILIAS"; this is the single place that knows it,
  /// so the agenda can gate its Raum-Finder affordance with the same
  /// normalization the exam code uses (pushing "ILIAS" as a query
  /// yielded 16-89 junk rows). Case/whitespace tolerant on purpose.
  static bool isPlaceholderRoom(String room) =>
      const {"", "-", "--", "ilias"}.contains(room.trim().toLowerCase());

  /// Normalized room: KIT uses "-" / "ILIAS" style placeholders.
  /// Deliberately NARROWER than [isPlaceholderRoom] (keeps "ILIAS"):
  /// as the LOCATION of an online Klausur in an exported calendar
  /// "ILIAS" IS information, while for a tap target it is a lie.
  String get roomLabel =>
      (room == "-" || room == "--" || room.isEmpty) ? "" : room;

  /// Concrete start of this sitting, if the labels parse. Null = unknown
  /// (dates given as ranges / text only). The guard counts day.month
  /// fragments: a concrete label holds exactly one ("Fr, 16.04.2027,
  /// 2. Termin" - "2. Termin" is no fragment), every range spelling two
  /// ("27.02.-06.03.2027", "27.02.2027 - 06.03.2027", "12.04 - 30.04.2027").
  /// A full-date-token count would NOT work: the first fragment of
  /// "27.02.-06.03.2027" lacks a year, so firstMatch would silently
  /// resolve the range to its END.
  DateTime? get startAt {
    if (isCancelled) return null;
    final t = _startHour.firstMatch(time);
    if (t == null) return null; // no time -> never guess midnight
    final hour = startHourOf(time);
    if (hour == null) return null;
    final minute = int.parse(t.group(2)!);
    final deFrags = _dayFragment.allMatches(dayLabel).length;
    final usDates = _usDate.allMatches(dayLabel).length;
    // exactly one concrete date under EITHER locale spelling; a label
    // mixing both (or holding two of one) is a range/ambiguity -> null
    if (deFrags == 1 && usDates == 0) {
      final d = _date.firstMatch(dayLabel);
      if (d == null) return null;
      return DateTime(int.parse(d.group(3)!), int.parse(d.group(2)!),
          int.parse(d.group(1)!), hour, minute);
    }
    if (usDates == 1 && deFrags == 0) {
      final u = _usDate.firstMatch(dayLabel)!;
      final month = int.parse(u.group(1)!);
      final day = int.parse(u.group(2)!);
      if (month < 1 || month > 12 || day < 1 || day > 31) return null;
      return DateTime(int.parse(u.group(3)!), month, day, hour, minute);
    }
    return null;
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

  /// R32.3: "Abmelden bis ..."/"Unregister until ..." — the deadline until
  /// which a REGISTERED exam may still be deregistered. Deliberately NOT
  /// a window bound (windowStatus/windowStart/windowEnd stay untouched by
  /// it); no serialization anywhere -> no snapshot migration.
  final DateTime? deregEnd;

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
    this.deregEnd,
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

  // The reginfo cell follows the SESSION locale: an English feed says
  // "Register until 3/31/2027 11:59 PM" / "Register from 11/15/2026
  // 12:00 AM" (all strings sampled from the live user feed, not
  // guessed). \b + no "Unregister" reach: the word-boundary keeps
  // "Unregister until" out even case-insensitively (no boundary
  // between n and r inside the word).
  static final _enDateTime = RegExp(
      r'\bRegister\s+(until|from)\s+(\d{1,2})/(\d{1,2})/(\d{4})\s+(\d{1,2}):(\d{2})\s*([AP])M\b',
      caseSensitive: false);

  // R32.3: the DEREGISTRATION deadline ("Abmelden bis 19.02.2027 23:59" /
  // EN "Unregister until 2/19/2027 11:59 PM", both verbatim live cells).
  // Deliberate non-use of \b in the EN arm: the word-boundary trick of
  // _enDateTime keeps "Unregister until" OUT of the window parse; here the
  // literal "Unregister" IS the pattern, so no boundary games are needed
  // and none belong in the code. The captured "(until)" group is NOT a
  // matcher feature - it holds the group INDICES at _enDateTime's shape
  // (month=2 ... AM/PM=7) so [enWindowDate] rehydrates unchanged.
  // _deDateTime stays untouched: "Anmelden bis" never matching
  // "Abmelden bis" (An ≠ Ab) is exactly why the window arms never saw
  // this date.
  static final _deDeregDateTime = RegExp(
      r'Abmelden bis\s+(\d{2})\.(\d{2})\.(\d{4})(?:\s+(\d{2}):(\d{2}))?');
  static final _enDeregDateTime = RegExp(
      r'Unregister\s+(until)\s+(\d{1,2})/(\d{1,2})/(\d{4})\s+(\d{1,2}):(\d{2})\s*([AP])M',
      caseSensitive: false);

  static DateTime enWindowDate(RegExpMatch em) {
    var hour = int.parse(em.group(5)!);
    final pm = em.group(7)!.toUpperCase() == "P";
    if (pm && hour < 12) hour += 12;
    if (!pm && hour == 12) hour = 0; // "12:00 AM" = 00:00, seen live
    return DateTime(int.parse(em.group(4)!), int.parse(em.group(2)!),
        int.parse(em.group(3)!), hour, int.parse(em.group(6)!));
  }

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
      final registerText = tds[6].querySelector(".reginfo")?.text.trim() ?? "";

      ExamWindowStatus status = ExamWindowStatus.unknown;
      DateTime? start, end;
      if (registerText.contains("nicht möglich") ||
          // EN session, verbatim from the same user's feed
          registerText.contains("Register not possible")) {
        status = ExamWindowStatus.impossible;
      } else if (!registerText.contains("Unregister")) {
        // "Abmelden bis"/"Unregister until" is the DEREGISTRATION
        // deadline, not a window - mirrors the German "Anmelden bis"
        // never matching "Abmelden bis"
        final m = _deDateTime.firstMatch(registerText);
        final em = _enDateTime.firstMatch(registerText);
        final date = m != null
            ? DateTime(
                int.parse(m.group(3)!),
                int.parse(m.group(2)!),
                int.parse(m.group(1)!),
                int.tryParse(m.group(4) ?? "0") ?? 0,
                int.tryParse(m.group(5) ?? "0") ?? 0)
            : em != null
                ? enWindowDate(em)
                : null;
        if (date != null) {
          if (registerText.contains("Anmeldung ab") ||
              registerText.contains("Register from")) {
            status = ExamWindowStatus.closed;
            start = date;
          } else if (registerText.contains("Anmelden bis") ||
              registerText.contains("Register until")) {
            status = ExamWindowStatus.open;
            end = date;
          }
        }
      }

      // R32.3: capture the DEREGISTRATION deadline right where it used to
      // be discarded. Window semantics above are untouched: "Unregister
      // until" never enters them (the else-if skips the whole arm), and
      // "Abmelden bis" parses to null there (see _deDeregDateTime note) -
      // this is now the ONLY consumer of that date.
      DateTime? deregEnd;
      if (registerText.contains("Abmelden bis") ||
          registerText.contains("Unregister until")) {
        final dm = _deDeregDateTime.firstMatch(registerText);
        final em = _enDeregDateTime.firstMatch(registerText);
        deregEnd = dm != null
            ? DateTime(
                int.parse(dm.group(3)!),
                int.parse(dm.group(2)!),
                int.parse(dm.group(1)!),
                int.tryParse(dm.group(4) ?? "0") ?? 0,
                int.tryParse(dm.group(5) ?? "0") ?? 0)
            : em != null
                ? enWindowDate(em)
                : null;
      }

      final statusLower = statusText.toLowerCase();
      // EN chip is NOT the obvious "Registered" - live feed says
      // "Signed in" (and "Not registered")
      final registered = (statusLower.contains("angemeldet") &&
              !statusLower.contains("nicht angemeldet")) ||
          (statusLower.contains("registered") &&
              !statusLower.contains("not registered")) ||
          statusLower.contains("signed in");

      current = ExamEntry(
        examNumber: examNumber,
        // cascampus cells carry layout whitespace ("Mechanical Design  A");
        // collapse runs so titles never show doubled spaces
        title: tds[2].text.replaceAll(RegExp(r"\s+"), " ").trim(),
        examiners: tds[4].text.trim(),
        examType: tds[5].text.trim(),
        registered: registered,
        windowStatus: status,
        windowStart: start,
        windowEnd: end,
        deregEnd: deregEnd,
      );
      result.add(current);
    }
    // cascampus lists pool rooms in arbitrary order (…, E, D); sort each
    // entry's exam terms by (real date, time, room) for stable reading
    for (final e in result) {
      e.terms.sort((a, b) {
        final d = _date(a.dayLabel).compareTo(_date(b.dayLabel));
        if (d != 0) return d;
        // AM/PM labels sort lexicographically WRONG ("11:00 AM" before
        // "2:00 PM"); prefer the locale-aware parsed start when both
        // ends resolve, keep the old text fallback for vague labels
        final sa = a.startAt, sb = b.startAt;
        if (sa != null && sb != null) {
          final s = sa.compareTo(sb);
          if (s != 0) return s;
        }
        final t = a.time.compareTo(b.time);
        return t != 0 ? t : a.room.compareTo(b.room);
      });
    }
    return result;
  }

  /// True when the page must NOT be certified as a definitively empty
  /// exam list. Two ways to earn that: the #EXAMLIST table carries
  /// data-shaped rows (a <tr> with at least two <td>s; header rows are
  /// pure <th>, "no records" notices a single colspan cell), OR the table
  /// element cannot be found at all - an id reflow (header anchors keep
  /// <a name="EXAMLIST"> alive, the table loses the id) makes [parse]
  /// read zero rows out of a still-full table, and missing evidence must
  /// never certify the empty state (examsLoaded=true + dead seal badge on
  /// a page that had data). Only a table that EXISTS with zero data rows
  /// is the valid empty state.
  static bool examListHasRows(String html) {
    final document = htmlparser.parse(html);
    final table = document.getElementById("EXAMLIST");
    if (table == null) {
      return true; // cannot prove emptiness -> the gate must not accept it
    }
    for (final tr in table.getElementsByTagName("tr")) {
      if (tr.getElementsByTagName("td").length >= 2) {
        return true;
      }
    }
    return false;
  }

  /// "Do, 25.03.2027" / "Wed, 2/24/2027" -> sortable DateTime;
  /// unparsable dates sort last without shifting otherwise-valid ones
  /// relative to each other wrongly.
  static DateTime _date(String dayLabel) =>
      ExamTerm.parseCasDate(dayLabel) ?? DateTime(2100);

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
