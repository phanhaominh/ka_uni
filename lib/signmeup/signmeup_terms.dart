/// R34.4: the OFFICIAL term calendar as SignMeUp (Campus+) publishes it.
///
/// Ground truth is the live `GET $_api/meta` capture (anonymous 200,
/// 2026-11-13, pinned as test/fixtures/smumeta.json): every term carries
/// `id` (uuid string), `name` ("WS 26/27"), `fullName`,
/// `startDate`/`endDate` stamped as pseudo-UTC instants
/// ("2026-10-01T00:00:00Z"), the campus GUID and EN variants. NO
/// cancellation bound exists on this wire today — [cancelEnd] stays null
/// and the model reads the plausible key spellings so a server-side
/// addition lights up without a code change; a missing bound is NEVER
/// guessed.
///
/// Two wire hazards, both pinned in test/term_calendar_test.dart:
///  * the `Z` is pseudo-precision — KIT defines terms by DATE, and
///    shifting "2026-03-31T23:59:59Z" into Berlin would print the term
///    ending 01.04. The R21/Anny lesson applies: date-ish fields are
///    keyed by the DATE PREFIX AS WRITTEN, never by the shifted instant.
///  * the winter-term `endDate` year is broken server-side (WS 26/27
///    says 2026-03-31 — five months BEFORE its own start; the existing
///    fetchMine comment "term's own endDate is unreliable" saw exactly
///    this). One deterministic repair: bump the month/day by a single
///    year when that makes it fall after the start. If even the bumped
///    date is broken, the end is UNKNOWN (null) — a corrected calendar
///    may be derived, an invented one may not.
library;

class SignMeUpTerm {
  final String id;

  /// Short wire label, e.g. "WS 26/27"; empty only for unnamed terms
  /// (which [listFromJson] drops — "?" is not a milestone title).
  final String name;

  /// Long wire label, e.g. "Wintersemester 2026/27"; may be empty.
  final String fullName;

  /// Term bounds as local wall-clock midnights of the dates AS WRITTEN.
  /// Null when the wire sent nothing parseable — callers must not draw
  /// a milestone for a null bound.
  final DateTime? start;
  final DateTime? end;

  /// Course/registration cancellation deadline IF the wire names one.
  /// Absent on the current payload (verified against the live capture);
  /// parsed defensively so the row appears the day KIT starts shipping
  /// it, without this fork ever inventing one.
  final DateTime? cancelEnd;

  const SignMeUpTerm({
    required this.id,
    required this.name,
    required this.fullName,
    required this.start,
    required this.end,
    required this.cancelEnd,
  });

  /// One entry of the `terms` array; entries without any name or without
  /// a usable id are dropped (an unnamed milestone row renders "?").
  factory SignMeUpTerm.fromJson(Map<String, dynamic> j) {
    final name = (j["name"] as String?)?.trim() ?? "";
    final full = (j["fullName"] as String?)?.trim() ?? "";
    final start = _wallDate(j["startDate"]);
    return SignMeUpTerm(
      id: j["id"]?.toString() ?? "",
      name: name.isNotEmpty ? name : full,
      fullName: full.isNotEmpty ? full : name,
      start: start,
      end: _repairEnd(start, _wallDate(j["endDate"])),
      cancelEnd: _wallDate(_firstPresent(j, const [
        "cancelEnd",
        "cancelEndDate",
        "cancellationEndDate",
        "courseCancellationEndDate",
      ])),
    );
  }

  /// The whole `meta` response: `{ "terms": [ ... ], "headings": ..., ... }`.
  /// A non-map body, a missing list or junk entries yield `[]` — the
  /// card then simply has no term rows.
  static List<SignMeUpTerm> listFromJson(Object? decoded) {
    final raw = decoded is Map ? decoded["terms"] : null;
    if (raw is! List) return const [];
    final out = <SignMeUpTerm>[];
    for (final e in raw.whereType<Map<String, dynamic>>()) {
      final t = SignMeUpTerm.fromJson(e);
      if (t.id.isEmpty || t.name.isEmpty) continue;
      out.add(t);
    }
    return out;
  }

  /// Date prefix as written (everything before the "T", or the bare
  /// "yyyy-MM-dd" prefix of an ISO instant). Never DateTime.parse().year:
  /// that reads the UTC-shifted calendar date (Anny W5 bug class).
  static DateTime? _wallDate(Object? v) {
    if (v == null) return null;
    final s = "$v";
    final m = RegExp(r"^(\d{4})-(\d{2})-(\d{2})").firstMatch(s);
    if (m == null) return null;
    return DateTime(int.parse(m.group(1)!), int.parse(m.group(2)!),
        int.parse(m.group(3)!));
  }

  /// Single year bump when the printed end precedes its own start
  /// (broken winter-term year); still broken after the bump -> unknown.
  static DateTime? _repairEnd(DateTime? start, DateTime? end) {
    if (start == null || end == null || !end.isBefore(start)) return end;
    final bumped = DateTime(end.year + 1, end.month, end.day);
    return bumped.isBefore(start) ? null : bumped;
  }

  static Object? _firstPresent(Map<String, dynamic> j, List<String> keys) {
    for (final k in keys) {
      final v = j[k];
      if (v != null && "$v".isNotEmpty) return v;
    }
    return null;
  }
}
