import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../state_management/kit_login_manager.dart';

class SignMeUpProcedure {
  final int id;
  final String name;
  final String eventType; // Tutorial, Seminar, Kurs, ...
  final String allocationType; // FirstComeFirstServed, Optimization, ...
  final DateTime? registrationStart;
  final DateTime? registrationEnd;
  final int placesNumber;
  final int registrations;

  SignMeUpProcedure.fromJson(Map<String, dynamic> j)
      : id = j["id"] as int,
        name = j["name"] as String? ?? "?",
        eventType = j["eventType"] as String? ?? "",
        allocationType = j["allocationType"] as String? ?? "",
        registrationStart = _dt(j["registrationStart"]),
        registrationEnd = _dt(j["registrationEnd"]),
        placesNumber = j["placesNumber"] as int? ?? 0,
        registrations = j["registrations"] as int? ?? 0;

  static DateTime? _dt(Object? v) =>
      v == null ? null : DateTime.tryParse("$v")?.toLocal();

  bool isOpen(DateTime now) =>
      registrationStart != null &&
      registrationEnd != null &&
      !now.isBefore(registrationStart!) &&
      now.isBefore(registrationEnd!);

  /// Deadline-relevant: open now and the student has no registration yet.
  bool needsAction(DateTime now, Set<int> registered) =>
      isOpen(now) && !registered.contains(id);

  bool opensWithin(DateTime now, Duration window) =>
      registrationStart != null &&
      registrationStart!.isAfter(now) &&
      registrationStart!.isBefore(now.add(window));
}

/// One weekly slot parsed out of a topic's free-text description
/// ("Tuesday 15:45-17:15 / 20.40 Neuer Hörsaal Architektur").
class SignMeUpTopicSchedule {
  final int dayOfWeek; // 1 = Monday .. 7 = Sunday
  final int startMinutes;
  final int endMinutes;
  final String room;

  SignMeUpTopicSchedule(
      {required this.dayOfWeek,
      required this.startMinutes,
      required this.endMinutes,
      required this.room});
}

/// Compact outcome category derived from the server's free-text stateLabel.
enum SignMeUpOutcome { accepted, rejected, open, unknown }

class SignMeUpRegistration {
  final int id;
  final int procedureId;
  final String name;
  final String eventType;
  final int state; // 0 = open/not decided, 3 = accepted
  final String stateLabel;
  final DateTime? registrationStart;
  final DateTime? registrationEnd;
  final DateTime? confirmationDeadline;

  /// When the first draw allocates places (lottery procedures); null =
  /// the procedure has no draw scheduled.
  final DateTime? firstDrawDate;

  /// Waitlist / draw position; null = none assigned (not on a ranking).
  final int? rank;

  /// Server-side "please confirm your spot" flag.
  final bool canConfirm;
  final int placesNumber;
  final int registrationsCount;
  final String? topicName;
  final String? topicDescription; // HTML, set by the instructor
  final String? topicDisplayName;

  SignMeUpRegistration.fromJson(Map<String, dynamic> j)
      : id = j["id"] as int,
        procedureId = j["procedureId"] as int? ?? -1,
        name = j["name"] as String? ?? "?",
        eventType = j["eventType"] as String? ?? "",
        state = j["state"] as int? ?? -1,
        stateLabel = j["stateLabel"] as String? ?? "",
        registrationStart = _dt(j["registrationStart"]),
        registrationEnd = _dt(j["registrationEnd"]),
        confirmationDeadline = _dt(j["confirmationDeadline"]),
        firstDrawDate = _dtLoose(j["firstDrawDate"]),
        rank = (j["rank"] as num?)?.toInt(),
        canConfirm = j["canConfirm"] as bool? ?? false,
        placesNumber = j["placesNumber"] as int? ?? 0,
        registrationsCount = j["registrations"] as int? ?? 0,
        topicName = (j["assignedTopic"] as Map?)?["name"] as String?,
        topicDescription =
            (j["assignedTopic"] as Map?)?["description"] as String?,
        topicDisplayName =
            (j["assignedTopic"] as Map?)?["displayName"] as String?;

  static DateTime? _dt(Object? v) =>
      v == null ? null : DateTime.tryParse("$v")?.toLocal();

  /// Wire format is ISO 8601 UTC with up to seven fractional digits
  /// ("2026-10-31T11:20:02.4388606Z" - Dart truncates the seventh).
  /// Tolerates null/missing and, defensively, epoch numbers (< 1e11
  /// read as seconds, otherwise milliseconds) and numeric strings.
  static DateTime? _dtLoose(Object? v) {
    if (v == null || v == "") return null;
    final epoch = v is num ? v : num.tryParse("$v");
    if (epoch != null) {
      return DateTime.fromMillisecondsSinceEpoch(
              epoch < 100000000000 ? (epoch * 1000).round() : epoch.round())
          .toLocal();
    }
    return _dt(v);
  }

  /// Any record at all (state != open) means the student has acted.
  bool get submitted => state != 0;
  bool get accepted => state == 3;

  // Labels SignMeUp actually puts on the wire: fixture captures are
  // English lower-case ("accepted", "open"); the German portal variants
  // are mapped case-insensitively next to them. Anything else stays
  // `unknown` and renders as its raw label.
  static const _acceptedLabels = {
    "accepted", "angenommen", "zugelassen", "confirmed", "bestätigt"
  };
  static const _rejectedLabels = {
    "rejected",
    "abgelehnt",
    "nicht zugelassen",
    "nicht angenommen",
    "not accepted",
    "abgesagt",
  };
  static const _openLabels = {
    "open",
    "offen",
    "registered",
    "angemeldet",
    "waiting",
    "waitlist",
    "waiting list",
    "warteliste",
  };

  /// whitespace/underscore/hyphen are equivalent inside labels
  /// ("nicht-zugelassen" vs. "nicht zugelassen"); hoisted out of the
  /// [outcome] getter like the other static regexes (_dayAbbr)
  static final _labelSep = RegExp(r"[\s_-]+");

  /// Compact chip category; unknown labels keep their raw text in the UI.
  SignMeUpOutcome get outcome {
    final label =
        stateLabel.trim().toLowerCase().replaceAll(_labelSep, " ");
    if (_acceptedLabels.contains(label)) return SignMeUpOutcome.accepted;
    if (_rejectedLabels.contains(label)) return SignMeUpOutcome.rejected;
    if (_openLabels.contains(label)) return SignMeUpOutcome.open;
    // no label but a decision code (e.g. old cached rows) still maps
    if (label.isEmpty) {
      if (state == 3) return SignMeUpOutcome.accepted;
      if (state == 0) return SignMeUpOutcome.open;
    }
    return SignMeUpOutcome.unknown;
  }

  /// Nearest future date worth counting down to; null = nothing pending.
  DateTime? nextMilestone(DateTime now) {
    DateTime? best;
    for (final d in [confirmationDeadline, firstDrawDate]) {
      if (d != null && d.isAfter(now) && (best == null || d.isBefore(best))) {
        best = d;
      }
    }
    return best;
  }

  /// The row stays on the card until every known expiry has passed: the
  /// confirmation deadline - a row without one expires with registrationEnd,
  /// the registration phase is its horizon - and the first draw date.
  /// No dates at all means "unknown" and keeps the row; otherwise it
  /// survives while at least one known date is still ahead of now.
  bool isLive(DateTime now) {
    final cd = confirmationDeadline ?? registrationEnd, fd = firstDrawDate;
    if (cd == null && fd == null) return true;
    return (cd != null && cd.isAfter(now)) || (fd != null && fd.isAfter(now));
  }

  static const _dayNames = {
    1: ["montag", "monday"],
    2: ["dienstag", "tuesday"],
    3: ["mittwoch", "wednesday"],
    4: ["donnerstag", "thursday"],
    5: ["freitag", "friday"],
    6: ["samstag", "saturday"],
    7: ["sonntag", "sunday"],
  };

  /// two-letter codes need word boundaries: "do" inside "donnerstag" or
  /// "mi" inside room codes must not steer the day pick
  static final _dayAbbr = <int, RegExp>{
    1: RegExp(r'\bmo\.?\b', caseSensitive: false),
    2: RegExp(r'\bdi\.?\b', caseSensitive: false),
    3: RegExp(r'\bmi\.?\b', caseSensitive: false),
    4: RegExp(r'\bdo\.?\b', caseSensitive: false),
    5: RegExp(r'\bfr\.?\b', caseSensitive: false),
    6: RegExp(r'\bsa\.?\b', caseSensitive: false),
    7: RegExp(r'\bso\.?\b', caseSensitive: false),
  };

  static final _timeRange = RegExp(
      r'(\d{1,2})(?:[:.](\d{2}))?\s*(?:uhr)?\s*[-–—]\s*(\d{1,2})(?:[:.](\d{2}))?',
      caseSensitive: false);

  /// "dd.MM.yyyy, HH:mm-HH:mm" / "(dd.MM.yyyy HH:mm-HH:mm" for topics whose
  /// date lives in the display name (single appointments).
  static final _absolute = RegExp(
      r'(\d{1,2})\.(\d{1,2})\.(\d{4})[\s,]*(\d{1,2}):(\d{2})\s*[-–—]\s*(\d{1,2}):(\d{2})');

  /// Weekly slots from the HTML description; empty when the format is unknown.
  List<SignMeUpTopicSchedule> get schedules {
    final html = topicDescription;
    if (html == null || html.isEmpty) return const [];
    final text = html
        .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), "\n")
        .replaceAll(RegExp(r'<[^>]*>'), "")
        .replaceAll("&nbsp;", " ")
        .replaceAll("&amp;", "&");
    final lines = text
        .split("\n")
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList(growable: false);
    final out = <SignMeUpTopicSchedule>[];
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      final lower = line.toLowerCase();
      final ranges = _timeRange.allMatches(line).toList();
      if (ranges.isEmpty) continue;
      for (final tm in ranges) {
        // the day governing THIS range: nearest day name before it, so
        // "Dienstag 15:45-17:15 / Donnerstag 09:00-10:30, HS 10.30" (one
        // of the most common instructor formats) yields TWO weekly slots
        final before = lower.substring(0, tm.start);
        int? day;
        var bestPos = -1;
        for (final entry in _dayNames.entries) {
          for (final n in entry.value) {
            final p = before.lastIndexOf(n);
            if (p > bestPos) {
              bestPos = p;
              day = entry.key;
            }
          }
          // last match, not first: firstMatch binds the range to the
          // EARLIEST abbreviation in the prefix, so in
          // "Di 08-10 / Mi 12-14 / Di 16-18" the third range would be
          // attributed to Wednesday instead of its nearest "Di"
          final ab = _dayAbbr[entry.key]!.allMatches(before).lastOrNull;
          if (ab != null && ab.start > bestPos) {
            bestPos = ab.start;
            day = entry.key;
          }
        }
        if (day == null) continue;
        // room: the line with ALL time ranges and day words removed; if a
        // time pattern survives, the residue is schedule noise, not a room
        var room = line.replaceAllMapped(_timeRange, (_) => " ").replaceAll(
            RegExp(r'\b(?:uhr|von|bis|from|to)\b', caseSensitive: false), " ");
        for (final entry in _dayNames.entries) {
          for (final n in entry.value) {
            room = room.replaceFirst(
                RegExp("\\b$n\\b", caseSensitive: false), " ");
          }
          // abbreviations too, or "Di 14:00-16:00 20.40 Geb. 11.20"
          // leaves a stray "Di " glued to the front of the room; all
          // occurrences, since one day may govern several ranges on a
          // line and replaceFirst would spare the later ones
          room = room.replaceAll(_dayAbbr[entry.key]!, " ");
        }
        if (_timeRange.hasMatch(room)) room = "";
        room = room
            .replaceAll(RegExp(r'\s+'), " ")
            .replaceAll(RegExp(r'^[\s,/:–-]+|[\s,/:–-]+$'), "")
            .trim();
        if (room.length < 3 && i + 1 < lines.length) {
          final next = lines[i + 1];
          if (_timeRange.firstMatch(next) == null) room = next;
        }
        final sm = tm.group(2) ?? "00";
        final em = tm.group(4) ?? "00";
        out.add(SignMeUpTopicSchedule(
          dayOfWeek: day,
          startMinutes: int.parse(tm.group(1)!) * 60 + int.parse(sm),
          endMinutes: int.parse(tm.group(3)!) * 60 + int.parse(em),
          room: room,
        ));
      }
    }
    return out;
  }

  /// A dated single appointment encoded in the topic display name, if any.
  ({DateTime start, DateTime end})? get singleAppointment {
    final m = _absolute.firstMatch(topicDisplayName ?? "");
    if (m == null) return null;
    final start = DateTime(int.parse(m.group(3)!), int.parse(m.group(2)!),
        int.parse(m.group(1)!), int.parse(m.group(4)!), int.parse(m.group(5)!));
    final end = DateTime(start.year, start.month, start.day,
        int.parse(m.group(6)!), int.parse(m.group(7)!));
    if (!end.isAfter(start)) return null;
    return (start: start, end: end);
  }
}

class SignMeUpManager {
  static const _api = "https://plus.campus.kit.edu/api/signmeup";

  List<SignMeUpProcedure> procedures = [];
  List<SignMeUpRegistration> mine = [];
  DateTime? termStart;
  bool loaded = false;
  bool loadedMine = false;
  DateTime? lastFetch;

  Set<int> get registeredProcedureIds => {
        for (final r in mine)
          if (r.submitted) r.procedureId
      };

  int get acceptedCount => mine.where((r) => r.accepted).length;

  Future<bool> fetch(KITLoginManager login) async {
    final response = await login.session.get(Uri.parse("$_api/procedures"),
        headers: {"Accept": "application/json"});
    if (response.statusCode != 200) {
      if (kDebugMode) {
        print("SignMeUp fetch failed: ${response.statusCode}");
      }
      return false;
    }
    try {
      final decoded = jsonDecode(response.body);
      final list = decoded is Map<String, dynamic>
          ? (decoded["procedures"] as List<dynamic>? ?? [])
          : decoded as List<dynamic>;
      procedures = list
          .whereType<Map<String, dynamic>>()
          .map((e) => SignMeUpProcedure.fromJson(e))
          .toList();
      procedures.sort((a, b) {
        final ae = a.registrationEnd, be = b.registrationEnd;
        if (ae == null) return 1;
        if (be == null) return -1;
        return ae.compareTo(be);
      });
      loaded = true;
      lastFetch = DateTime.now();
      if (kDebugMode) {
        final open = procedures.where((p) => p.isOpen(DateTime.now())).length;
        print("SignMeUp: ${procedures.length} procedures, $open open now");
      }
      return true;
    } catch (e) {
      if (kDebugMode) {
        print("SignMeUp JSON malformed: $e");
      }
      return false;
    }
  }

  /// The student's own registrations for the current term. Requires the
  /// Campus+ session (the plain list endpoint hides user state for anon).
  Future<bool> fetchMine(KITLoginManager login) async {
    if (!await login.ensurePlusSession()) return false;
    final meta = await login.session
        .get(Uri.parse("$_api/meta"), headers: {"Accept": "application/json"});
    if (meta.statusCode != 200) return false;
    try {
      final terms =
          ((jsonDecode(meta.body) as Map)["terms"] as List?) ?? const [];
      final now = DateTime.now().toUtc();
      Map<String, dynamic>? term;
      DateTime? bestStart;
      for (final t in terms.whereType<Map<String, dynamic>>()) {
        final s = DateTime.tryParse("${t["startDate"]}");
        // the term's own endDate is unreliable (WS 26/27 says 2026-03-31);
        // pick the latest term that has already started
        if (s != null &&
            !s.isAfter(now) &&
            (bestStart == null || s.isAfter(bestStart))) {
          bestStart = s;
          term = t;
        }
      }
      if (term == null) return false;
      termStart = bestStart;
      final reg = await login.netGet(
          Uri.parse("$_api/registrations/?termId=${term["id"]}"),
          headers: {"Accept": "application/json"});
      if (reg.statusCode != 200) {
        if (kDebugMode) {
          print("SignMeUp mine failed: ${reg.statusCode}");
        }
        return false;
      }
      final list =
          ((jsonDecode(reg.body) as Map)["registrations"] as List?) ?? const [];
      mine = list
          .whereType<Map<String, dynamic>>()
          .map((e) => SignMeUpRegistration.fromJson(e))
          .toList();
      loadedMine = true;
      if (kDebugMode) {
        print("SignMeUp mine: ${mine.length} registrations "
            "(${mine.where((r) => r.accepted).length} accepted)");
      }
      return true;
    } catch (e) {
      if (kDebugMode) {
        print("SignMeUp mine malformed: $e");
      }
      return false;
    }
  }

  static String _icsStamp(DateTime d) {
    final u = d.toUtc();
    String two(int v) => v.toString().padLeft(2, "0");
    return "${u.year.toString().padLeft(4, "0")}${two(u.month)}${two(u.day)}"
        "T${two(u.hour)}${two(u.minute)}${two(u.second)}Z";
  }

  static String _icsLocal(DateTime d) => "${d.year.toString().padLeft(4, "0")}"
      "${d.month.toString().padLeft(2, "0")}"
      "${d.day.toString().padLeft(2, "0")}T"
      "${d.hour.toString().padLeft(2, "0")}"
      "${d.minute.toString().padLeft(2, "0")}00";

  /// Weekly UNTIL: lectures end mid-February (winter) / mid-August (summer);
  /// matches the UNTIL the campus feed itself uses for WS courses.
  DateTime get _lecturePeriodEnd {
    final s = termStart ?? DateTime.now();
    return s.month >= 7 ? DateTime(s.year + 1, 2, 13) : DateTime(s.year, 8, 15);
  }

  /// VEVENT block (no calendar wrapper) for every accepted registration with
  /// a machine-readable meeting time, so the agenda/timetable show tutorials
  /// the student actually got a group for - the campus webcal only contains
  /// courses registered in Campus KIT, not SignMeUp-organised appointments.
  String buildSynthBlock() {
    if (!loadedMine) return "";
    final until = _lecturePeriodEnd;
    final out = StringBuffer();
    var seq = 0;
    for (final r in mine) {
      if (!r.accepted) continue;
      final topic = (r.topicName?.trim().isNotEmpty ?? false)
          ? r.topicName!.trim()
          : null;
      final title = topic == null ? r.name : "${r.name} ($topic)";
      for (final s in r.schedules) {
        // first matching weekday at/after the term start
        var d = DateTime(termStart?.year ?? until.year, termStart?.month ?? 10,
            termStart?.day ?? 1, s.startMinutes ~/ 60, s.startMinutes % 60);
        while (d.weekday != s.dayOfWeek) {
          d = DateTime(d.year, d.month, d.day + 1, d.hour, d.minute);
        }
        // end < start with no meridiem = an overnight span, 24h later
        final end = DateTime(
                d.year, d.month, d.day, s.endMinutes ~/ 60, s.endMinutes % 60)
            .add(s.endMinutes <= s.startMinutes
                ? const Duration(days: 1)
                : Duration.zero);
        if (!end.isAfter(d)) continue;
        out.write("BEGIN:VEVENT\r\n"
            "UID:signmeup-${r.id}-${seq++}@ka_uni\r\n"
            "DTSTAMP:${_icsStamp(DateTime.now())}\r\n"
            "DTSTART;TZID=Europe/Berlin:${_icsLocal(d)}\r\n"
            "DTEND;TZID=Europe/Berlin:${_icsLocal(end)}\r\n"
            "RRULE:FREQ=WEEKLY;UNTIL=${_icsLocal(until)}\r\n"
            "SUMMARY:${_icsEscape(title)}\r\n"
            "LOCATION:${_icsEscape(s.room)}\r\n"
            "END:VEVENT\r\n");
      }
      final one = r.singleAppointment;
      if (one != null &&
          one.end.isAfter(DateTime.now().subtract(const Duration(days: 1)))) {
        out.write("BEGIN:VEVENT\r\n"
            "UID:signmeup-${r.id}-${seq++}@ka_uni\r\n"
            "DTSTAMP:${_icsStamp(DateTime.now())}\r\n"
            "DTSTART;TZID=Europe/Berlin:${_icsLocal(one.start)}\r\n"
            "DTEND;TZID=Europe/Berlin:${_icsLocal(one.end)}\r\n"
            "SUMMARY:${_icsEscape(title)}\r\n"
            "END:VEVENT\r\n");
      }
    }
    return out.toString();
  }

  static String _icsEscape(String v) =>
      v.replaceAll(r"\", r"\\").replaceAll(";", r"\;").replaceAll(",", r"\,");
}
