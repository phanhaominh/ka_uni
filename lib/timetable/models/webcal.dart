import 'dart:convert';

import '../../exams/models/exam_list.dart';
import 'timetable_appointment.dart';
import 'timetable_daily.dart';
import 'timetable_weekly.dart';
import '../../geo/models/kit_place.dart';
import '../../l10n/l10n.dart';

/// SharedPreferences records of the WebCal pipeline. The foreground fetch
/// (CampusManager) and the background poll isolate write the SAME records -
/// string literals copied into both only ever drift while the app is
/// closed, the hardest place to notice. Single source of truth.
class WebcalKeys {
  WebcalKeys._();

  static const url = "DATA_webcalUrl";
  static const icsCache = "DATA_webcalIcsCache";
  static const fingerprint = "DATA_webcalFingerprint";
  static const changes = "DATA_webcalChanges";

  /// fingerprint of the feed URL the cached ICS/fingerprint came from; a
  /// different source (re-provisioned token URL, test-seam build) means the
  /// stored baseline describes ANOTHER calendar - diffing across sources
  /// produced a 50-delta phantom CHAINED band during E2E runs
  static const feedSource = "DATA_webcalFeedSource";
  static const fetchedAt = "DATA_webcalFetchedAt";
}

/// One concrete dated occurrence of a calendar entry (RRULE already expanded).
class IcsOccurrence {
  final DateTime start;
  final DateTime end;
  final String title;
  final String room;
  final String uid;

  /// Last date the originating series produces, i.e. its RRULE UNTIL clamped
  /// to the expansion horizon; null for single-shot events.
  final DateTime? seriesEnd;

  /// True when the originating VEVENT had no usable DTEND and [end] is the
  /// parser's +90-minute default: the card layout stays intact, but the
  /// end time is a GUESS - consumers that would certify a real interval
  /// from it (walk feasibility, reminder bodies) must treat it as
  /// start-only instead.
  final bool endGuessed;

  /// True when the originating VEVENT came from the student's OWN imported
  /// personal/faculty ICS block, i.e. it sits between the
  /// `X-PERSONAL-ICS-BEGIN`/`END` sentinel markers CampusManager embeds in
  /// the merged cache. The agenda renders an "own calendar" chip on these
  /// rows so a feed lecture and its imported duplicate are tellable apart;
  /// display-only - matching, fingerprint and dedup ignore it.
  final bool fromPersonalIcs;

  /// Cascampus course page (`URL:` property). The feed attaches
  /// `https://campus.studium.kit.edu/ev/<token>` to EVERY VEVENT
  /// (verified wc_now.ics:38,52,66,80,94,106,120,132,146,...,377,388 — one
  /// per VEVENT; the calendar-level `URL:` at :5 sits outside any VEVENT
  /// and is never seen). The token is a stable COURSE identity: clones of
  /// one real series share it (:106/:120/:132) and so do the Nov–Dec
  /// one-shot chain and the January RRULE re-publication of a
  /// re-registered course (:223..377 == :200). It is NOT a location
  /// identity — same-URL occurrences alternate LOCATION — which is why
  /// roomVaries groups on it. Display-only today; deliberately absent
  /// from fingerprint and dedupeKey: an internal URL rotation must not
  /// move the diff baseline.
  final String? url;

  /// Set during parse: the VEVENT is a one-off (no RRULE, or an RRULE that
  /// expanded to exactly one instance) - a February Klausur, a hand-imported
  /// single appointment. The weekday template only shows these inside the
  /// real week they fall in; see toWeeklyTemplate. Mutable because it is a
  /// SERIES-level property applied after per-VEVENT construction.
  bool oneShot = false;

  IcsOccurrence(
      {required this.start,
      required this.end,
      required this.title,
      required this.room,
      required this.uid,
      this.seriesEnd,
      this.endGuessed = false,
      this.fromPersonalIcs = false,
      this.url});

  /// Faculty ICS exports append the course number to SUMMARY
  /// ("... - 3161011", "... - 2145191/2145192") and stuff duplicated tokens
  /// into LOCATION ("Gottlieb-Daimler-HS HS bldg 10.21"). Both are noise on
  /// cards and in notifications; raw strings stay authoritative for matching.
  static final _numberTail = RegExp(r"\s*-\s*\d[\d/]*$");
  static final _dupToken = RegExp(r"\b(\w{2,})\s+\1\b", caseSensitive: false);

  static String cleanTitle(String t) => t.replaceFirst(_numberTail, "");

  static String cleanRoom(String r) {
    var p = r;
    while (_dupToken.hasMatch(p)) {
      p = p.replaceAllMapped(_dupToken, (m) => m.group(1)!);
    }
    return p;
  }

  String get displayTitle => cleanTitle(title);
  String get displayRoom => cleanRoom(room);

  /// The feed re-publishes a series with a new UNTIL when a course is
  /// re-registered mid-semester (identical UID, DTSTART and time, differing
  /// only in RRULE). Keying the dedup on UID + occurrence time lets the dead,
  /// already-past series win and silently drops every later instance of the
  /// live one - observed with Advanced Mathematics I (UNTIL 20261030 vs
  /// collapsing the byte-identical clones the same feed emits for one real
  /// event, since those share their UNTIL.
  String get dedupeKey => "${uid.split('@').first}|${start.toIso8601String()}"
      "|${seriesEnd?.toIso8601String() ?? "-"}";
}

/// Minimal, dependency-free parser for the KIT WebCal feed (cascampus PRODID).
/// Handles: folded lines, VEVENT, DTSTART/DTEND with TZID, weekly RRULE with
/// naive UNTIL (RFC violation of the feed - compared as wall time), EXDATE,
/// standalone instances during break periods, and duplicate series sharing a
/// DTSTART (deduplicated per occurrence).
class WebcalFeed {
  final List<IcsOccurrence> occurrences;
  final String raw;

  /// The "now" the parse was anchored to (parse's `now` param or wall
  /// clock): the weekly template scopes one-off events against it.
  final DateTime reference;

  WebcalFeed(
      {required this.occurrences, required this.raw, DateTime? now})
      : reference = now ?? DateTime.now();

  static final _dt = RegExp(r'^(\d{4})(\d{2})(\d{2})T(\d{2})(\d{2})(\d{2})$');
  // UTC form: bare `Z` or a numeric offset (RFC 5545 writes "+0200", the
  // colon variant appears in the wild); converted to device-local below
  static final _dtUtc = RegExp(
      r'^(\d{4})(\d{2})(\d{2})T(\d{2})(\d{2})(\d{2})(?:Z|([+-]\d{2}:?\d{2}))$');
  // VALUE=DATE all-day stamp (hand-written personal ICS files)
  static final _date = RegExp(r'^(\d{4})(\d{2})(\d{2})$');

  /// Sentinel line pair around the student's own imported ICS block in the
  /// merged cache: the SAME discriminator `CampusManager.stripPersonalIcs`
  /// keys on. Literals duplicated from campus_manager.dart after the
  /// ics_export.dart precedent, keeping this parser free of the state layer.
  static const personalBegin = "X-PERSONAL-ICS-BEGIN";
  static const personalEnd = "X-PERSONAL-ICS-END";

  static List<String> _unfold(String raw) {
    final out = <String>[];
    for (final line in const LineSplitter().convert(raw)) {
      if (line.startsWith(" ") || line.startsWith("\t")) {
        if (out.isNotEmpty) {
          out[out.length - 1] += line.substring(1);
        }
      } else {
        out.add(line);
      }
    }
    return out;
  }

  static String _unescape(String v) => v
      .replaceAll(r"\,", ",")
      .replaceAll(r"\;", ";")
      .replaceAll(r"\n", " ")
      .replaceAll(r"\\", r"\");

  /// Tolerant timestamp reader: the feed's naive wall time, UTC `Z` and
  /// offset stamps (converted to device-local), and `VALUE=DATE` all-day
  /// stamps (local midnight). A value NONE of the shapes matches returns
  /// null - the caller then SKIPS the whole VEVENT explicitly rather than
  /// guessing, so a TZ-aware feed variant can no longer shift every time
  /// silently or drop all-day events on the regex.
  static DateTime? _dtOf(String v) {
    final s = v.trim();
    var m = _dt.firstMatch(s);
    if (m != null) {
      // feed is Europe/Berlin wall time; local device timezone is Berlin for us
      return DateTime(
          int.parse(m.group(1)!),
          int.parse(m.group(2)!),
          int.parse(m.group(3)!),
          int.parse(m.group(4)!),
          int.parse(m.group(5)!),
          int.parse(m.group(6)!));
    }
    m = _dtUtc.firstMatch(s);
    if (m != null) {
      final utc = DateTime.utc(
          int.parse(m.group(1)!),
          int.parse(m.group(2)!),
          int.parse(m.group(3)!),
          int.parse(m.group(4)!),
          int.parse(m.group(5)!),
          int.parse(m.group(6)!));
      final offset = m.group(7);
      if (offset == null) return utc.toLocal();
      final digits = offset.substring(1).replaceAll(":", "");
      final skew = Duration(
          hours: int.parse(digits.substring(0, 2)),
          minutes: int.parse(digits.substring(2)));
      // wall time = UTC instant minus the stamp's own offset from UTC
      return (offset.startsWith("-") ? utc.add(skew) : utc.subtract(skew))
          .toLocal();
    }
    m = _date.firstMatch(s);
    if (m != null) {
      return DateTime(int.parse(m.group(1)!), int.parse(m.group(2)!),
          int.parse(m.group(3)!));
    }
    return null;
  }

  static WebcalFeed? parse(String raw, {DateTime? now, int horizonDays = 56}) {
    if (!raw.contains("BEGIN:VCALENDAR") || !raw.contains("BEGIN:VEVENT")) {
      return null;
    }
    final lines = _unfold(raw);
    final reference = now ?? DateTime.now();
    final horizonEnd = reference.add(Duration(days: horizonDays));

    // Pass 1: parse every VEVENT into its full expanded series.
    final seriesByKey = <String, List<IcsOccurrence>>{};

    // True between the personal-ICS sentinel lines; occurrences whose
    // VEVENT started there are the student's own imported entries. The
    // sentinels only ever appear BETWEEN VEVENTs (injected blocks), so
    // latching on BEGIN:VEVENT is enough.
    var inPersonalBlock = false;
    var blockPersonal = false;
    List<String>? block;
    for (final line in lines) {
      // the cache is \r\n-terminated and LineSplitter keeps the trailing
      // \r, so sentinel codes are compared trimmed
      final code = line.trimRight();
      if (code == personalBegin) {
        inPersonalBlock = true;
        continue;
      }
      if (code == personalEnd) {
        inPersonalBlock = false;
        continue;
      }
      if (line.startsWith("BEGIN:VEVENT")) {
        block = [];
        blockPersonal = inPersonalBlock;
      } else if (line.startsWith("END:VEVENT")) {
        if (block != null) {
          final ev = _parseEvent(block, personal: blockPersonal);
          block = null;
          if (ev == null || ev.isEmpty) {
            continue;
          }
          final first = ev.first;
          final key = "${first.title}|${first.start.toIso8601String()}";
          final held = seriesByKey[key];
          if (held == null) {
            seriesByKey[key] = ev;
          } else if ((ev.last.seriesEnd ?? ev.last.end)
              .isAfter((held.last.seriesEnd ?? held.last.end))) {
            seriesByKey[key] = ev;
          }
        }
      } else if (block != null) {
        block.add(line);
      }
    }

    // The feed re-publishes one course as several weekly series sharing
    // SUMMARY + series DTSTART but differing in UID, LOCATION and RRULE
    // UNTIL (observed: Advanced Mathematics I - two snapshots dead at
    // 30.10, one alive to 19.02.2027). Only the longest-living series
    // survives its group, so a dead snapshot can neither mask future
    // instances nor leak stale past ones. Grouping is title+DTSTART only:
    // the feed alternates LOCATION between the clone snapshots of ONE real
    // series (wc_now.ics fixture), so room must NOT join the key - it
    // would split one course into parallel groups and let a dead clone win.
    final occurrences = <IcsOccurrence>[];
    for (final series in seriesByKey.values) {
      // The horizonEnd clamp exists to BOUND RRULE EXPANSION - unbounded
      // weekly series must not materialise a year of instances. Single-shot
      // occurrences (an event without RRULE, or an RRULE that expanded to
      // exactly one instance) are already fully enumerated, so a one-off
      // months out survives: every winter-semester Klausur sits beyond 56
      // days, and the raw-cache ICS export ships it - the app and the
      // export must not disagree about which events exist.
      final oneShot = series.length == 1;
      for (final occ in series) {
        occ.oneShot = oneShot;
        if (!oneShot && occ.start.isAfter(horizonEnd)) {
          continue;
        }
        if (occ.end.isBefore(reference.subtract(const Duration(days: 1)))) {
          continue; // past side stays clamped (yesterday only)
        }
        occurrences.add(occ);
      }
    }

    occurrences.sort((a, b) => a.start.compareTo(b.start));
    if (occurrences.isEmpty) {
      return null;
    }
    return WebcalFeed(occurrences: occurrences, raw: raw, now: reference);
  }

  static List<IcsOccurrence>? _parseEvent(List<String> block,
      {bool personal = false}) {
    String? uid, summary, startStr, endStr, rrule, location, url;
    final exdates = <String>{};
    for (final prop in block) {
      final semi = prop.indexOf(";");
      final colon = prop.indexOf(":");
      if (colon < 0) {
        continue;
      }
      final name = (semi >= 0 && semi < colon
              ? prop.substring(0, semi)
              : prop.substring(0, colon))
          .toUpperCase();
      final value = prop.substring(colon + 1);
      switch (name) {
        case "UID":
          uid = value;
          break;
        case "SUMMARY":
          summary = _unescape(value);
          break;
        case "DTSTART":
          startStr = value;
          break;
        case "DTEND":
          endStr = value;
          break;
        case "RRULE":
          rrule = value;
          break;
        case "LOCATION":
          location = _unescape(value);
          break;
        case "URL":
          url = value;
          break;
        case "EXDATE":
          // multi-value EXDATE lines must split into single stamps -
          // the old code stored them comma-joined, so contains(single)
          // never matched and cancelled lectures stayed in the grid
          exdates.addAll(
              value.split(",").map((s) => s.trim()).where((s) => s.isNotEmpty));
          break;
      }
    }

    final start = startStr == null ? null : _dtOf(startStr);
    if (start == null) {
      return null;
    }
    final endParsed = endStr == null ? null : _dtOf(endStr);
    final end = endParsed ?? start.add(const Duration(minutes: 90));
    final endGuessed = endParsed == null;
    final title = summary ?? "—";
    final room = location ?? "";

    if (rrule == null || !rrule.contains("FREQ=WEEKLY")) {
      return [
        IcsOccurrence(
            start: start,
            end: end,
            title: title,
            room: room,
            uid: uid ?? title,
            seriesEnd: start,
            endGuessed: endGuessed,
            fromPersonalIcs: personal,
            url: url)
      ];
    }

    // weekly expansion; UNTIL is naive wall time in the feed
    var until = horizonDefault;
    final m = RegExp(r"UNTIL=(\d{8}T\d{6}Z?)").firstMatch(rrule);
    if (m != null) {
      until = _dtOf(m.group(1)!) ?? until;
    }
    final interval = int.tryParse(
            RegExp(r"INTERVAL=(\d+)").firstMatch(rrule)?.group(1) ?? "1") ??
        1;

    final dates = <DateTime>[];
    var d = start;
    var guard = 0;
    while (!d.isAfter(until) && guard++ < 400) {
      if (!exdates.contains(_fmt(d))) {
        dates.add(d);
      }
      // wall-clock stepping: Duration(days: 7) is absolute time and slides
      // every later instance one hour early per crossed DST transition
      d = DateTime(
          d.year, d.month, d.day + 7 * interval, d.hour, d.minute, d.second);
    }
    if (dates.isEmpty) {
      return [];
    }
    // every occurrence carries the series' real end: two same-UID series
    // that differ only in UNTIL must not dedupe against each other
    final seriesEnd = dates.last;
    // the end follows the START by wall clock, not by absolute difference:
    // `day.add(end.difference(start))` re-plays the FIRST instance's UTC
    // offset, so every post-flip instance of a pre-flip series printed its
    // end one hour early (agenda, sheet, reminders, running chip) while
    // row geometry still used the true length - labels and pixels lying
    // about the same lecture. Overnight series shift the copy a day ahead.
    // (exam_synth.dart carries the identical precedent.)
    return [
      for (final day in dates)
        IcsOccurrence(
            start: day,
            end: _wallEndFor(day, end),
            title: title,
            room: room,
            uid: uid ?? title,
            seriesEnd: seriesEnd,
            endGuessed: endGuessed,
            fromPersonalIcs: personal,
            url: url)
    ];
  }

  /// Wall-clock [end] on [day]'s calendar date - never the first
  /// instance's absolute length re-added across DST boundaries; next day
  /// when the series runs past midnight.
  static DateTime _wallEndFor(DateTime day, DateTime end) {
    final sameDay = DateTime(
        day.year, day.month, day.day, end.hour, end.minute, end.second);
    return sameDay.isAfter(day)
        ? sameDay
        : DateTime(day.year, day.month, day.day + 1, end.hour, end.minute,
            end.second);
  }

  /// RRULE expansion safety ceiling; parse() clamps with its own horizon.
  /// Recomputed per access: a `static final` pinned it to first use for
  /// the whole process lifetime, so UNTIL-less weekly series stopped
  /// expanding at a stale now+365 d during long-lived sessions.
  static DateTime get horizonDefault =>
      DateTime.now().add(const Duration(days: 365));

  static String _fmt(DateTime d) =>
      "${d.year.toString().padLeft(4, "0")}${d.month.toString().padLeft(2, "0")}"
      "${d.day.toString().padLeft(2, "0")}T"
      "${d.hour.toString().padLeft(2, "0")}${d.minute.toString().padLeft(2, "0")}"
      "${d.second.toString().padLeft(2, "0")}";

  // plain "$" end anchor: inside a raw string "\$" reaches the regex
  // verbatim and matches a literal dollar sign, so the anchor form
  // silently never matched and no appointment ever got an id
  static final _idPrefix = RegExp(r"^(\d{6,7})\s*[-–]\s*(.*)$");

  TimetableAppointment _toAppointment(IcsOccurrence occ) {
    final appointment = TimetableAppointment(
        begin: occ.start, end: occ.end, type: TimetableAppointmentType.other);
    appointment.url = occ.url;
    appointment.fromPersonalIcs = occ.fromPersonalIcs;

    var title = occ.title;
    final m = _idPrefix.firstMatch(title);
    if (m != null) {
      appointment.id = m.group(1)!;
      title = m.group(2)!;
    }
    if (title.contains("(Lecture)") ||
        title.contains("(Vorlesung)") ||
        title.contains("(V)")) {
      appointment.type = TimetableAppointmentType.lecture;
    } else if (title.contains("(Tutorial)") ||
        title.contains("(Ü)") ||
        title.contains("(Exercise)")) {
      appointment.type = TimetableAppointmentType.tutorial;
    }
    appointment.title = title;

    // a placeholder LOCATION ("-", "--", "ILIAS") must not render as a
    // room name nor seed the map-CTA query (agenda gates it the same way)
    if (occ.room.isNotEmpty && !ExamTerm.isPlaceholderRoom(occ.room)) {
      appointment.place = KITPlace()
        ..title = occ.room
        ..dataUrl = "";
    }
    return appointment;
  }

  /// Weekly template for the home grid, mirroring the cascampus HTML grid
  /// semantics (7 time-block slots per weekday; same-slot events replace).
  TimetableWeekly toWeeklyTemplate() {
    final weekly = TimetableWeekly();
    for (final daily in weekly.days) {
      daily.appointments = TimetableDaily.genericAppointmentsSchedule;
    }

    // Personal-ICS one-offs (imported Klausurs, single appointments) only
    // belong to the ONE real week they sit in: the grid repeats its columns
    // every week, so an unscoped February exam would haunt every Tuesday
    // (the exam-synth feed is excluded upstream for the same reason).
    // Date-scoped consumers (agenda, exams, notifications) still see them.
    // FEED one-shots keep the full template: KIT publishes near-term
    // lectures as one-shot chains (wc_now.ics "Nov-Dec chain") that the
    // cascampus HTML grid shows across the whole horizon - they are
    // recognisable by the cascampus URL every feed VEVENT carries.
    final weekStart = DateTime(
        reference.year, reference.month, reference.day - (reference.weekday - 1));
    final weekEnd = DateTime(
        reference.year, reference.month, reference.day - (reference.weekday - 1) + 7);

    for (final occ in occurrences) {
      final weekdayIdx = occ.start.weekday - 1;
      if (weekdayIdx > 4) {
        continue; // grid is Mon-Fri only, as the cascampus one
      }
      if (occ.oneShot &&
          occ.url == null &&
          (occ.start.isBefore(weekStart) || !occ.start.isBefore(weekEnd))) {
        continue; // imported one-off from another week: grid must not show it
      }
      final daily = weekly.days[weekdayIdx];
      final appointment = _toAppointment(occ);

      var idx = -1;
      for (var i = 0; i < daily.appointments.length; i++) {
        if (daily.appointments[i].isAtTheSameBlockAs(appointment)) {
          idx = i;
          break;
        }
      }
      if (idx >= 0) {
        // same block already occupied? stack: HTML grid only shows one per
        // block; prefer keeping the first (stable ordering from sort above)
        if (daily.appointments[idx].isEmpty) {
          daily.appointments[idx] = appointment;
        }
      } else {
        daily.appointments.add(appointment);
      }
    }

    // roomVaries post-pass: the feed alternates LOCATION across the
    // occurrences of ONE course (clone snapshots + re-publications in
    // wc_now.ics), so the first-wins room on the claimed card can be a
    // lie for later dates. Mutates ONLY the new bool - the claim loop
    // above stays byte-identical (webcal/exam_synth tests pin it);
    // personal-ICS and exam-synth occurrences never join a group.
    for (var d = 0; d < weekly.days.length; d++) {
      for (final a in weekly.days[d].appointments) {
        if (a.isEmpty) continue;
        final rooms = <String>{};
        final dates = <DateTime>{};
        for (final o in occurrences) {
          if (o.start.weekday != d + 1 ||
              o.start.hour != a.begin.hour ||
              o.start.minute != a.begin.minute) {
            continue;
          }
          // SLOT-level union for the dates: the row disappears from a
          // carousel page only when NOTHING occupies this weekday+block
          // that week - hiding a lecture that really happens (wrong clone
          // won the claim, title tails differ between export and feed) is
          // far worse than one stale title on a slot another course
          // covers that week: the cascampus HTML grid shows exactly one
          // card per slot too. roomVaries keeps the strict identity match.
          dates.add(DateTime(o.start.year, o.start.month, o.start.day));
          if (!a.fromPersonalIcs && _isFeedCloneOf(o, a)) rooms.add(o.room);
        }
        if (dates.isNotEmpty) a.occurrenceDates = dates;
        if (rooms.length > 1) a.roomVaries = true;
      }
    }

    // mark the pre-seeded generic placeholders of touched days as filled-in:
    // untouched slots keep their empty placeholder look, as in the HTML grid
    return weekly;
  }

  /// Literal copy of `examSynthUidPrefix` (exams/models/exam_synth.dart),
  /// duplicated after the personal-sentinel precedent to keep this parser
  /// free of the state layer.
  static const _examSynthUidPrefix = "kauni-exam-";

  /// Whether [o] is a feed occurrence of the SAME course as claimed
  /// template card [a] (checked within one weekday+block by the caller):
  /// the cascampus URL is the group key; where either side lacks one
  /// (personal ICS imports, URL-less feeds) the title stem is the
  /// fallback - identical series share UID prefix AND title, and the
  /// stem is what parse() itself groups series by.
  static bool _isFeedCloneOf(IcsOccurrence o, TimetableAppointment a) {
    if (o.fromPersonalIcs || o.uid.startsWith(_examSynthUidPrefix)) {
      return false;
    }
    if (o.url != null && a.url != null) return o.url == a.url;
    final m = _idPrefix.firstMatch(o.title);
    return (m == null ? o.title : m.group(2)!) == a.title;
  }

  /// Stable fingerprint for the change-diff engine. Only occurrences that
  /// start at/after the beginning of TODAY count: the parse window is
  /// now-relative (yesterday drops out after 24 h, the +56 d horizon rolls),
  /// and hashing that set would change by itself daily -> phantom
  /// "timetable changed" alerts with zero actual changes.
  String fingerprint({DateTime? at}) {
    final today = at ?? DateTime.now();
    final from = DateTime(today.year, today.month, today.day);
    return occurrences
        .where((o) => !o.start.isBefore(from))
        .map((o) =>
            "${o.dedupeKey}~${o.end.toIso8601String()}~${o.title}~${o.room}")
        .join("|");
  }

  static String stamp(DateTime d) => L10n.stamp(d);

  /// Human-readable delta against an earlier snapshot of the same feed
  /// (e.g. the cached ICS). Empty when `previous` is null.
  ///
  /// Pairing ignores seriesEnd on purpose: when KIT re-publishes a series
  /// with a longer UNTIL (course re-registration), the DEDUPE key flips but
  /// nothing visible changed - pairing by it reported every untouched
  /// occurrence as "Moved: X · Mon 08:00 -> Mon 08:00".
  List<IcsChange> changesSince(WebcalFeed? previous) {
    if (previous == null) return const [];
    String series(String uid) => uid.split("@").first;
    String dk(IcsOccurrence o) =>
        "${series(o.uid)}|${o.start.toIso8601String()}";
    final oldByKey = {for (final o in previous.occurrences) dk(o): o};
    final newByKey = {for (final o in occurrences) dk(o): o};

    final changes = <IcsChange>[];
    final removedUnpaired = <IcsOccurrence>[];
    for (final o in previous.occurrences) {
      final twin = newByKey[dk(o)];
      if (twin == null) {
        removedUnpaired.add(o);
        continue;
      }
      // title included: a RENAMED lecture keeps its UID and time, so the
      // twin pairing above matches it - comparing room/end only let the
      // rename pass as "nothing happened"
      if (twin.room != o.room ||
          twin.end != o.end ||
          twin.title != o.title) {
        changes.add(IcsChange(
            kind: IcsChangeKind.changed,
            title: twin.title,
            when: twin.start,
            room: twin.room,
            oldRoom: o.room,
            oldWhen: twin.start == o.start ? null : o.start));
      }
    }
    final removedBySeries = <String, List<IcsOccurrence>>{};
    for (final o in removedUnpaired) {
      removedBySeries.putIfAbsent(series(o.uid), () => []).add(o);
    }
    final consumedRemoved = <IcsOccurrence>{};
    for (final o in occurrences) {
      if (oldByKey.containsKey(dk(o))) continue;
      // same series vanished elsewhere with the same title -> it moved
      final candidates = removedBySeries[series(o.uid)] ?? const [];
      final move = candidates
          .where((p) => p.title == o.title && !consumedRemoved.contains(p))
          .toList();
      if (move.isNotEmpty) {
        consumedRemoved.add(move.first);
        changes.add(IcsChange(
            kind: IcsChangeKind.moved,
            title: o.title,
            when: o.start,
            room: o.room,
            oldRoom: move.first.room,
            oldWhen: move.first.start));
      } else {
        changes.add(IcsChange(
            kind: IcsChangeKind.added,
            title: o.title,
            when: o.start,
            room: o.room));
      }
    }
    for (final o in removedUnpaired) {
      if (consumedRemoved.contains(o)) continue;
      changes.add(IcsChange(
          kind: IcsChangeKind.removed,
          title: o.title,
          when: o.start,
          room: o.room));
    }
    changes.sort((a, b) => a.when.compareTo(b.when));
    return changes;
  }
}

enum IcsChangeKind { added, removed, moved, changed }

/// One timetable delta, JSON-round-trippable for the agenda "CHANGED" band.
class IcsChange {
  final IcsChangeKind kind;
  final String title;
  final DateTime when;
  final String room;
  final String? oldRoom;
  final DateTime? oldWhen;

  IcsChange(
      {required this.kind,
      required this.title,
      required this.when,
      required this.room,
      this.oldRoom,
      this.oldWhen});

  String describe() {
    final t = WebcalFeed.stamp(when);
    switch (kind) {
      case IcsChangeKind.added:
        return L10n.t("timetable.changeAdded",
            [title, t, room.isNotEmpty ? " · $room" : ""]);
      case IcsChangeKind.removed:
        return L10n.t("timetable.changeRemoved", [title, t]);
      case IcsChangeKind.moved:
        return L10n.t("timetable.changeMoved", [
          title,
          WebcalFeed.stamp(oldWhen!),
          t,
          oldRoom != room && room.isNotEmpty ? " · $room" : ""
        ]);
      case IcsChangeKind.changed:
        final roomDelta = oldRoom != room &&
                oldRoom != null &&
                oldRoom!.isNotEmpty &&
                room.isNotEmpty
            ? L10n.t("timetable.changeRoomDelta", [oldRoom!, room])
            : (room.isNotEmpty ? " · $room" : "");
        return L10n.t("timetable.changeChanged", [title, t, roomDelta]);
    }
  }

  Map<String, dynamic> toJson() => {
        "k": kind.name,
        "t": title,
        "w": when.toIso8601String(),
        "r": room,
        if (oldRoom != null) "or": oldRoom,
        if (oldWhen != null) "ow": oldWhen!.toIso8601String(),
      };

  factory IcsChange.fromJson(Map<String, dynamic> j) => IcsChange(
        kind: IcsChangeKind.values.byName(j["k"] as String),
        title: j["t"] as String,
        when: DateTime.parse(j["w"] as String),
        room: j["r"] as String? ?? "",
        oldRoom: j["or"] as String?,
        oldWhen: j["ow"] == null ? null : DateTime.parse(j["ow"] as String),
      );

  static String encode(List<IcsChange> changes) =>
      jsonEncode(changes.map((c) => c.toJson()).toList());

  static List<IcsChange> decode(String raw) {
    try {
      final list = jsonDecode(raw);
      if (list is! List) return const [];
      return list
          .whereType<Map<String, dynamic>>()
          .map(IcsChange.fromJson)
          .toList();
    } on Object {
      return const [];
    }
  }
}

/// Shared index over decoded deltas for the weekly view, the agenda row
/// emphasis and the T-15 alarm re-arm: one grouping, three consumers, no
/// drifting block-key math.
extension IcsChangeIndex on List<IcsChange> {
  /// Grouped by the date a GHOST belongs to: for moved that is the slot
  /// the lecture VACATED ([IcsChange.oldWhen]) - keyed on `when` the ghost
  /// would need an empty block at the NEW time, where the lecture itself
  /// now sits, so moved deltas would render nowhere.
  Map<String, List<IcsChange>> byGhostDayKey() {
    final out = <String, List<IcsChange>>{};
    for (final c in this) {
      final d = c.kind == IcsChangeKind.moved ? c.oldWhen! : c.when;
      out.putIfAbsent(_dayKey(d), () => <IcsChange>[]).add(c);
    }
    return out;
  }

  /// Start blocks (`hour*60+minute`) of [day] whose lecture actually
  /// moved rooms (`changed` with oldRoom != room) -> the LATEST such
  /// delta wins, so a card ever renders one room-diff line.
  Map<int, IcsChange> blockKeys(DateTime day) {
    final out = <int, IcsChange>{};
    for (final c in this) {
      if (c.kind != IcsChangeKind.changed || c.oldRoom == c.room) continue;
      if (!_isOnDay(c.when, day)) continue;
      final k = c.when.hour * 60 + c.when.minute;
      final held = out[k];
      if (held == null || c.when.isAfter(held.when)) out[k] = c;
    }
    return out;
  }

  /// Start blocks of [day] whose lecture is gone or relocated: the slots
  /// for ghost cards, and where an already-armed reminder is stale.
  Set<int> removedOrMovedBlocks(DateTime day) => {
        for (final c in this)
          if ((c.kind == IcsChangeKind.removed ||
                  c.kind == IcsChangeKind.moved) &&
              _isOnDay(c.when, day))
            c.when.hour * 60 + c.when.minute,
      };

  static String _dayKey(DateTime d) =>
      "${d.year.toString().padLeft(4, "0")}-"
      "${d.month.toString().padLeft(2, "0")}-"
      "${d.day.toString().padLeft(2, "0")}";

  static bool _isOnDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;
}
