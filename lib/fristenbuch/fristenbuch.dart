import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../state_management/campus/campus_manager.dart'
    show CampusManager;
import '../utils/ics_text.dart';

/// R34.1 FRISTENBUCH: deadlines the app cannot scrape — the Immatrikationsamt
/// form, the housing cancel, the module registration that lives outside
/// SignMeUp. The student notes them by hand; from here on they flow through
/// the SAME pipeline as scraped deadlines: agenda rows, cockpit countdowns,
/// morning digest, T−30 reminders, ICS export — as synthetic VEVENTs (the
/// due/exam synth doctrine, [buildDueSynthBlock] is the shape template).
///
/// This module is deliberately free of widgets and of live state: it is the
/// store codec plus the deterministic emitter. The sentinel splice itself
/// belongs to CampusManager (stripFrB/extractFrB/injectFrB/reapplyFrB), the
/// editor page to fristenbuch_page.dart.

/// UID prefix marking Fristenbuch VEVENTs (mirrors [dueSynthUidPrefix] /
/// examSynthUidPrefix). The cockpit classification, the grid exclusion and
/// the enrolled-title skip-list all key on exactly this string; unknown
/// `kauni-*` prefixes stay DROPPED everywhere.
const frbSynthUidPrefix = "kauni-frb-";

/// Logout-swept store key (DATA_* prefix: Fristenbuch entries are account
/// data — a shared device must not show the last student's private
/// deadlines; the existing DATA_* sweep in credentials_provider covers it,
/// no new mechanism).
const fristenbuchStoreKey = "DATA_fristenbuch";

/// One manually noted deadline. [due] is the date the student gave, stored
/// as written (a date-only entry sits at local midnight); the emitted
/// VEVENT moves it to 23:59 — end of the day is when the deadline bites
/// (the due family's no-time default is 23:45; the hand-noted form owns
/// the round minute).
class FristenbuchEntry {
  /// stable per-store id — the UID is `kauni-frb-<id>`, so an entry's
  /// agenda row, its armed T−30 alarm and its exported VEVENT all track
  /// the same identity across rebuilds
  final int id;
  final String label;

  /// the deadline date (time-of-day ignored by the emitter)
  final DateTime due;
  final String? note;

  const FristenbuchEntry(
      {required this.id,
      required this.label,
      required this.due,
      this.note});

  String get uid => "$frbSynthUidPrefix$id";

  /// the plain record shape cross-lane consumers map over (no methods to
  /// reach through, no laziness — a synchronous snapshot of one deadline)
  ({int id, String label, DateTime due, String? note}) get record =>
      (id: id, label: label, due: due, note: note);

  Map<String, dynamic> toJson() => {
        "id": id,
        "label": label,
        "date": _dateOnly(due),
        if (note != null && note!.isNotEmpty) "note": note,
      };

  /// null when the blob carries no readable entry — callers treat that as
  /// a cache miss, never as a crash
  static FristenbuchEntry? fromJson(Map<String, dynamic> j) {
    final id = j["id"];
    final label = j["label"];
    final date = DateTime.tryParse(j["date"] as String? ?? "");
    if (id is! int || label is! String || date == null) return null;
    final note = j["note"];
    return FristenbuchEntry(
        id: id,
        label: label,
        due: date,
        note: note is String && note.isNotEmpty ? note : null);
  }

  @override
  bool operator ==(Object other) =>
      other is FristenbuchEntry &&
      other.id == id &&
      other.label == label &&
      other.due == due &&
      other.note == note;
  @override
  int get hashCode => Object.hash(id, label, due, note);
}

String _p2(int v) => v.toString().padLeft(2, "0");

/// "2027-01-15" — the ISO date form the store keeps (date-only on purpose:
/// the emitter decides the wall time itself, and a stored midnight must
/// never round-trip into a "T00:00:00.000" tail that a yearless diff would
/// treat as a different value).
String _dateOnly(DateTime d) =>
    "${d.year.toString().padLeft(4, "0")}-${_p2(d.month)}-${_p2(d.day)}";

// ---------------------------------------------------------------------------
// Store codec + IO
// ---------------------------------------------------------------------------

/// Decode the store blob. Per-entry tolerance (the R23 IcsChange.decode
/// doctrine): one unreadable row is a dropped row, a corrupt blob is an
/// empty book, never an exception that bricks the editor or the synth.
List<FristenbuchEntry> fristenbuchEntriesFromJson(String? raw) {
  if (raw == null || raw.isEmpty) return const [];
  try {
    final list = jsonDecode(raw);
    if (list is! List) return const [];
    final out = <FristenbuchEntry>[];
    for (final e in list.whereType<Map<String, dynamic>>()) {
      final entry = FristenbuchEntry.fromJson(e);
      if (entry != null && !out.any((o) => o.id == entry.id)) out.add(entry);
    }
    return out;
  } on Object {
    return const [];
  }
}

String fristenbuchEntriesToJson(List<FristenbuchEntry> entries) =>
    jsonEncode(entries.map((e) => e.toJson()).toList());

/// LIVE read through the async store (same cross-isolate freshness rule as
/// ensureDueSynthLoaded: the legacy snapshot is a per-isolate cache).
/// This is the accessor cross-lane consumers call — `Future`, entries
/// already in plain record shape via [FristenbuchEntry.record].
Future<List<FristenbuchEntry>> loadFristenbuchEntries() async {
  final raw =
      await SharedPreferencesAsync().getString(fristenbuchStoreKey);
  return fristenbuchEntriesFromJson(raw);
}

Future<void> saveFristenbuchEntries(List<FristenbuchEntry> entries) async {
  await SharedPreferencesAsync()
      .setString(fristenbuchStoreKey, fristenbuchEntriesToJson(entries));
}

/// Today-and-future entries as the plain cross-lane records
/// `({String title, DateTime? date})` — the shape the 90-day card maps.
/// The editor always requires a date, so `date` is NEVER null in practice
/// (the field is nullable only so a consumer switch can't crash on a
/// hand-edited store). Sorted by due, then id. Async because the store is
/// the live platform prefs — there is no in-memory book to read
/// synchronously off (the editor page owns the only cached copy, its
/// widget state, and must not leak it as a pseudo-truth).
Future<List<({String title, DateTime? date})>> fristenbuchUpcoming(
    {DateTime? now}) async {
  final t = now ?? DateTime.now();
  final from = DateTime(t.year, t.month, t.day);
  final entries = (await loadFristenbuchEntries())
      .where((e) =>
          !DateTime(e.due.year, e.due.month, e.due.day).isBefore(from))
      .toList()
    ..sort((a, b) {
      final d = DateTime(a.due.year, a.due.month, a.due.day)
          .compareTo(DateTime(b.due.year, b.due.month, b.due.day));
      return d != 0 ? d : a.id.compareTo(b.id);
    });
  return [for (final e in entries) (title: e.label, date: e.due)];
}

/// Id allocation: strictly above every id the book ever held in [entries].
/// Not recycling after a delete is the point: `kauni-frb-<id>` must not
/// resurrect a deleted deadline's cached VEVENT (a union carry-over keys
/// on UID — a reused id would inherit the dead event's bytes).
int fristenbuchNextId(List<FristenbuchEntry> entries) =>
    entries.isEmpty ? 1 : entries.map((e) => e.id).reduce((a, b) => a > b ? a : b) + 1;

// ---------------------------------------------------------------------------
// Deterministic VEVENT emitter
// ---------------------------------------------------------------------------

/// The end-of-day wall time a hand-noted deadline bites at.
const frbDueHour = 23, frbDueMinute = 59;

/// Deterministic VEVENT text for the Fristenbuch set (no calendar wrapper,
/// no sentinels — injectFrB wraps). Byte-identical rebuilds are
/// load-bearing: reapplyFrB's merged==cached no-op depends on it, DTSTAMP
/// derives from the deadline itself, never the wall clock (due doctrine).
///
/// DTSTART mirrors the due family exactly: `TZID=Europe/Berlin` + naive
/// local `YYYYMMDDTHHMMSS` — a Berlin deadline must remind at Berlin wall
/// time on a device whose clock sits in another zone. NO DTEND, ever: a
/// deadline is a point in time; without DTEND the parser's +90 display
/// default keeps endGuessed=true and every consumer renders the honest
/// start-only form.
///
/// Every [FristenbuchEntry.label]/[FristenbuchEntry.note] is USER free
/// text pasted from anywhere: it runs through the one sanitizer that owns
/// the sentinel vocabulary (CampusManager.sanitizeSentinels — reused, NOT
/// re-implemented; the Round-10 class: one smuggled BEGIN/END line
/// desyncs every later splice cut) before icsFoldable and the ICS escaping.
String buildFristenbuchBlock(List<FristenbuchEntry> entries) {
  final sorted = [...entries]..sort((a, b) {
    final d = DateTime(a.due.year, a.due.month, a.due.day)
        .compareTo(DateTime(b.due.year, b.due.month, b.due.day));
    return d != 0 ? d : a.id.compareTo(b.id);
  });
  final b = StringBuffer();
  for (final it in sorted) {
    final label = _emitText(it.label);
    final note = it.note == null ? "" : _emitText(it.note!);
    final day = DateTime(it.due.year, it.due.month, it.due.day);
    b.write("BEGIN:VEVENT\r\n"
        "UID:${it.uid}\r\n"
        "DTSTAMP:${_icsStamp(day)}\r\n"
        "DTSTART;TZID=Europe/Berlin:"
        "${_icsLocal(DateTime(day.year, day.month, day.day, frbDueHour, frbDueMinute))}\r\n"
        // "Frist:" is the provenance marker: the digest non-class arm and
        // the agenda point-row arm key on it, so what reads here must be
        // exactly what those arms match. An all-sanitized label still
        // emits ("Frist: " + the date carries the row) — dropping the
        // entry here would silently lose a deadline the student noted.
        "SUMMARY:${_icsEscape("Frist: $label")}\r\n");
    if (note.isNotEmpty) b.write("DESCRIPTION:${_icsEscape(note)}\r\n");
    b.write("END:VEVENT\r\n");
  }
  return b.toString();
}

/// sanitize first (multi-line: drops every sentinel-carrying line), fold
/// second (joins what sanitize's kept-line rejoin left behind and what a
/// pasted CR/LF smuggled), so no label/note can ever start a physical ICS
/// line.
String _emitText(String v) => icsFoldable(CampusManager.sanitizeSentinels(v)).trim();

String _icsEscape(String v) => v
    .replaceAll(r"\", r"\\")
    .replaceAll(";", r"\;")
    .replaceAll(",", r"\,");

String _icsLocal(DateTime d) => "${d.year.toString().padLeft(4, "0")}"
    "${_p2(d.month)}${_p2(d.day)}T${_p2(d.hour)}${_p2(d.minute)}00";

String _icsStamp(DateTime d) => "${_icsLocal(d)}Z";
