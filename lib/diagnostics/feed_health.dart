/// R36.1 FEED DOCTOR — per-source health verdicts for the on-device
/// "Feed doctor" settings section.
///
/// ONE-VOICE rule: every rendered doctor row comes from [feedHealth].
/// The UI must never compute a verdict of its own — a row that reads
/// greener on screen than the exported support bundle says is exactly
/// the shared≠rendered divergence this file exists to make impossible.
/// The inputs are the SAME persisted prefs entries [buildSupportBundle]
/// consumes (plus the per-source stamps the bundle cannot show because
/// they live inside JSON blobs): the doctor and the pasteable bundle can
/// therefore never disagree about what the device knows.
///
/// Honesty doctrine, load-bearing here:
///  * a missing key is `unknown`, NEVER `ok` — silence reads as a gap,
///    not as health;
///  * a stamp in the future is a lie (clock skew or forged blob) and is
///    never believed — same rule as DataTrust in R35.2;
///  * every detail string embeds ONLY the scrubbed form of a stored
///    value ([scrubDiag], the same redaction as the exported bundle —
///    DATA_webcalDiag can carry the token URL, it must not re-appear
///    on screen unredacted); [FeedStatus.detailArg] is scrubbed HERE,
///    so "scrub before render" is a property of the pure function, not
///    a hope about the widget tree.
///
/// Pure logic: no context, no l10n, injected `now`, deterministic. The
/// UI formats and localises the returned rows via l10n keys only.
library;

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../timetable/models/webcal.dart';
import 'support_bundle.dart';

/// Health verdict of one data source. Four states, no shading:
/// ok (last fetch inside the source's own TTL), degraded (older than
/// the TTL or a recorded failure — data may still be on screen, but it
/// needs attention), dead (so old nothing on screen should be
/// believed), unknown (nothing persisted says anything — the honest
/// silence).
enum FeedState { ok, degraded, dead, unknown }

/// One doctor row: the row's identity ([source]), its l10n label key,
/// the verdict and the detail wording. [detailKey] may carry one `{0}`
/// placeholder; [detailArg] is the value ALREADY run through
/// [scrubDiag] — the UI must pass it into `L10n.t(detailKey, [arg])`
/// verbatim and must never substitute a raw stored value of its own.
class FeedStatus {
  /// stable machine id ("webcal", "heartbeat", ...) — never shown raw
  final String source;
  final String labelKey;
  final FeedState state;
  final String? detailKey;

  /// scrubbed detail substitution (may be null when [detailKey] has no
  /// placeholder)
  final String? detailArg;

  const FeedStatus(
      {required this.source,
      required this.labelKey,
      required this.state,
      this.detailKey,
      this.detailArg});
}

/// Heartbeat key: epoch MINUTES, plain int, written by the WorkManager
/// poll isolate via [stampLastPollAt] (the write call site lives in
/// meiBackgroundCallback — registration in main.dart is deliberately
/// NOT a write site: registering is not running, and stamping it would
/// fabricate freshness). Absent = the poll has never run.
const lastPollAtKey = "DATA_lastPollAt";

/// Best-effort heartbeat write for the background poll isolate.
/// No BuildContext, no plugin beyond the live platform prefs store (the
/// same store the doctor reads) — a WorkManager isolate has neither an
/// activity nor a main-isolate snapshot. NEVER throws: a heartbeat
/// failure must not sink the poll that is still doing real work.
Future<void> stampLastPollAt() async {
  try {
    await SharedPreferencesAsync()
        .setInt(lastPollAtKey, DateTime.now().millisecondsSinceEpoch ~/ 60000);
  } on Object catch (_) {}
}

// The doctor's keys are the REAL persisted keys (grepped, not guessed).
// Owners import-forbidden (lane rule: read persisted state only), so
// non-Webcal ones are literals with their owner named — same precedent
// as the "MENSA_diag" literal in SupportState.buildBundle.
const _iliasCacheKey = "DATA_iliasCardCache"; // agenda_page card cache
const _mensaFetchedAtKey = "MENSA_fetchedAt";
const _mensaDiagKey = "MENSA_diag";
const _roomsKey = "ANN_rooms"; // anny_manager: {"at": ISO, ...}
const _moduleCachePrefix = "module_cache_";
const _moduleCacheSuffix = "_last_fetch";

// TTL = newest age still read as ok; horizon = past it the row is dead
// (between the two: degraded). Per-source because the pipelines
// legitimately differ: the webcal poll runs every 30 min (a whole
// day of silence is already wrong), a mensa/rooms/ILIAS refetch only
// happens when the app is opened (three days of silence is normal
// life), grades change in human weeks.
const _webcalTtl = Duration(hours: 12);
const _webcalHorizon = Duration(days: 7);
const _openedSourceTtl = Duration(days: 3);
const _openedSourceHorizon = Duration(days: 14);
const _gradesTtl = Duration(days: 7);
const _gradesHorizon = Duration(days: 30);

/// 30-min periodic task with Android batching + Doze grace: a healthy
/// device may legitimately not poll for a few hours, a weekend away
/// from the phone is already the incident the doctor must name.
const _pollTtl = Duration(hours: 24);

/// The verdict list, in render order. Sources with no persisted stamp
/// at all (SignMeUp: the grep proved none exists — DATA_smuOpensFired
/// is a fired-window FSM without a fetch time) report `unknown` with an
/// honest detail, forever, until their owner persists one.
List<FeedStatus> feedHealth(Map<String, String> diag,
    {required bool notificationsPermission,
    required bool credentialsStored,
    DateTime? now}) {
  final moment = now ?? DateTime.now();
  return [
    _heartbeat(diag, moment),
    _webcal(diag, moment),
    _stampRow(
      source: "ilias",
      labelKey: "doctor.ilias",
      at: _iso(_jsonField(diag[_iliasCacheKey], "fetchedAt")),
      diagValue: null,
      ttl: _openedSourceTtl,
      horizon: _openedSourceHorizon,
      now: moment,
    ),
    // no persisted timestamp exists for the SignMeUp mine fetch —
    // "unknown" is the whole truth, and it stays visibly unknown
    const FeedStatus(
        source: "smu",
        labelKey: "doctor.smu",
        state: FeedState.unknown,
        detailKey: "doctor.smuNoStamp"),
    _stampRow(
      source: "rooms",
      labelKey: "doctor.rooms",
      at: _iso(_jsonField(diag[_roomsKey], "at")),
      diagValue: null,
      ttl: _openedSourceTtl,
      horizon: _openedSourceHorizon,
      now: moment,
    ),
    _stampRow(
      source: "mensa",
      labelKey: "doctor.mensa",
      at: _iso(diag[_mensaFetchedAtKey]),
      diagValue: diag[_mensaDiagKey],
      ttl: _openedSourceTtl,
      horizon: _openedSourceHorizon,
      now: moment,
    ),
    _grades(diag, credentialsStored, moment),
    FeedStatus(
        source: "notifications",
        labelKey: "doctor.notifications",
        state:
            notificationsPermission ? FeedState.ok : FeedState.degraded,
        detailKey: notificationsPermission
            ? "doctor.notifGranted"
            : "doctor.notifDenied"),
  ];
}

/// "background refresh: last poll HH:MM / never" — the row that names
/// the R32.4 class failure (scraper went dark) without the owner having
/// to suspect. Old OR absent = degraded with the actionable hint: the
/// usual cause is battery optimization parking the periodic job.
FeedStatus _heartbeat(Map<String, String> diag, DateTime now) {
  final minutes = int.tryParse(diag[lastPollAtKey] ?? "");
  final at = minutes == null
      ? null
      : DateTime.fromMillisecondsSinceEpoch(minutes * 60000);
  if (at == null) {
    return const FeedStatus(
        source: "heartbeat",
        labelKey: "doctor.heartbeat",
        state: FeedState.degraded,
        detailKey: "doctor.heartbeatNever");
  }
  final age = now.difference(at);
  if (age.isNegative) {
    // a poll "from the future" is a corrupt/forged stamp, not freshness
    return const FeedStatus(
        source: "heartbeat",
        labelKey: "doctor.heartbeat",
        state: FeedState.degraded,
        detailKey: "doctor.heartbeatNever");
  }
  if (age <= _pollTtl) {
    return FeedStatus(
        source: "heartbeat",
        labelKey: "doctor.heartbeat",
        state: FeedState.ok,
        detailKey: "doctor.heartbeatAt",
        detailArg: _clock(at, now));
  }
  return FeedStatus(
      source: "heartbeat",
      labelKey: "doctor.heartbeat",
      state: FeedState.degraded,
      detailKey: "doctor.heartbeatStale",
      detailArg: _clock(at, now));
}

/// The agenda's own ICS pipeline: stamp moves only on success, the diag
/// line records the newest failure. A present diag line caps the row at
/// degraded even over a fresh stamp — "it worked this morning and is
/// broken now" IS the actionable truth.
FeedStatus _webcal(Map<String, String> diag, DateTime now) {
  final diagLine = diag[WebcalKeys.diag];
  return _stampRow(
    source: "webcal",
    labelKey: "doctor.webcal",
    at: _iso(diag[WebcalKeys.fetchedAt]),
    diagValue: (diagLine == null || diagLine.isEmpty) ? null : diagLine,
    ttl: _webcalTtl,
    horizon: _webcalHorizon,
    now: now,
  );
}

/// Grades/CampusKIT: session first, then the newest persisted
/// `module_cache_<term>_last_fetch` (the term suffix is dynamic — the
/// map scan takes the family, the newest stamp wins). Without stored
/// credentials nothing here can ever fetch, and the row says so.
FeedStatus _grades(
    Map<String, String> diag, bool credentialsStored, DateTime now) {
  if (!credentialsStored) {
    return const FeedStatus(
        source: "grades",
        labelKey: "doctor.grades",
        state: FeedState.unknown,
        detailKey: "doctor.notLoggedIn");
  }
  DateTime? newest;
  for (final entry in diag.entries) {
    if (!entry.key.startsWith(_moduleCachePrefix) ||
        !entry.key.endsWith(_moduleCacheSuffix)) {
      continue;
    }
    final t = _iso(entry.value);
    if (t != null && (newest == null || newest.isBefore(t))) newest = t;
  }
  return _stampRow(
    source: "grades",
    labelKey: "doctor.grades",
    at: newest,
    diagValue: null,
    ttl: _gradesTtl,
    horizon: _gradesHorizon,
    now: now,
  );
}

/// Shared verdict ladder for every stamp-carrying source.
/// null/absent/unparsable stamp -> unknown ("never loaded", honestly);
/// future stamp -> dead (never believed, same as past the horizon);
/// inside TTL -> ok unless a failure line is standing -> degraded;
/// TTL..horizon -> degraded; past horizon -> dead.
FeedStatus _stampRow(
    {required String source,
    required String labelKey,
    required DateTime? at,
    required String? diagValue,
    required Duration ttl,
    required Duration horizon,
    required DateTime now}) {
  final stamp = at;
  if (stamp == null) {
    return FeedStatus(
        source: source,
        labelKey: labelKey,
        state: FeedState.unknown,
        detailKey: "doctor.neverFetched",
        detailArg: diagValue == null ? null : scrubDiag(diagValue));
  }
  final age = now.difference(stamp);
  if (age.isNegative) {
    // forged/skewed: a future stamp must never read as health
    return FeedStatus(
        source: source,
        labelKey: labelKey,
        state: FeedState.dead,
        detailKey: "doctor.deadSince",
        detailArg: _clock(stamp, now));
  }
  // a recorded failure outranks the age ladder down to degraded:
  // "last success HH:MM" + "failing: <why>" is the pair the user needs
  if (age <= ttl) {
    if (diagValue != null) {
      return FeedStatus(
          source: source,
          labelKey: labelKey,
          state: FeedState.degraded,
          detailKey: "doctor.failing",
          detailArg: scrubDiag(diagValue));
    }
    return FeedStatus(
        source: source,
        labelKey: labelKey,
        state: FeedState.ok,
        detailKey: "doctor.lastFetchAt",
        detailArg: _clock(stamp, now));
  }
  final stale = age <= horizon
      ? FeedState.degraded
      : FeedState.dead;
  return FeedStatus(
      source: source,
      labelKey: labelKey,
      state: stale,
      detailKey: "doctor.lastFetchAt",
      detailArg: _clock(stamp, now));
}

/// "HH:MM" for today, "DD.MM. HH:MM" for anything else — no l10n needed
/// (digits are locale-neutral, the date-first shape matches every stamp
/// in the German-first UI).
String _clock(DateTime at, DateTime now) {
  String two(int v) => v.toString().padLeft(2, "0");
  final sameDay = at.year == now.year &&
      at.month == now.month &&
      at.day == now.day;
  final hm = "${two(at.hour)}:${two(at.minute)}";
  return sameDay ? hm : "${two(at.day)}.${two(at.month)}. $hm";
}

DateTime? _iso(String? raw) {
  if (raw == null || raw.isEmpty) return null;
  return DateTime.tryParse(raw);
}

/// Read one field out of a persisted JSON blob without trusting it:
/// anything malformed (non-JSON, non-map, non-string field) is a
/// missing value, never an exception — the doctor must render on a
/// poisoned store.
String? _jsonField(String? blob, String field) {
  if (blob == null || blob.isEmpty) return null;
  try {
    final decoded = jsonDecode(blob);
    if (decoded is! Map) return null;
    final value = decoded[field];
    return value is String ? value : null;
  } on Object {
    return null;
  }
}
