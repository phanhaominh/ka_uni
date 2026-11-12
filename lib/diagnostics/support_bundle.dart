/// R29: SUPPORT BUNDLE - the one text a user can paste to support after a
/// feed goes dark. The live dead-token incident proved a broken feed is
/// undiagnosable from outside; DATA_webcalDiag (see WebcalKeys) helps only
/// while the student still holds the device, and the bundle is what travels.
///
/// Hard rule inherited from the R21 ANN_* scrub in anny_api.dart: scrub
/// BEFORE truncating, so a cut can never leave a raw-secret fragment that
/// merely LOOKS redacted. The prefs families behind these entries (DATA_*,
/// GEO_*, MENSA_*, PREF_* - the logout sweep's roster) hold the live webcal
/// token URL and scraped schedules, so every entry passes [scrubDiag] once
/// more at bundle time: like the two-pass logout sweep, belt and braces -
/// this paste may land in a public issue tracker.
///
/// Pure logic: no context, no prefs, no l10n, injected `now`, deterministic.
/// The UI formats and localises; the bundle is deliberately plain ASCII.
library;

/// URL-shaped payload: the token lives inside it, so there is nothing to
/// salvage - "when did the feed break" is answered by the timestamps anyway.
final _urlShape = RegExp(r"https?://\S+");

/// email shapes - support already knows who wrote in
final _emailShape = RegExp(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+");

/// opaque high-entropy blobs: >=20 chars of base64/alphabet incl. the
/// `+/=-` padding a real key uses; ordinary words stay below the bar
final _tokenShape = RegExp(r"[A-Za-z0-9+/=-]{20,}");

/// fold every run of whitespace (incl. the `\r\n` a wrapped HTTP error body
/// carries) into single spaces - one record, one line, always
String _oneLine(String s) => s.replaceAll(RegExp(r"\s+"), " ").trim();

/// Redact everything from [raw] that must not leave the device.
///
/// Order matters: URLs first (a `?token=` inside one must never face a
/// partial pass), emails BEFORE the token rule (a long local part would
/// otherwise be half-eaten and re-emit at the seam). The placeholders hold
/// no `@` and every run inside them is shorter than the token bar, so no
/// placeholder can re-match a shape: scrubbing is idempotent and callers
/// may scrub their inputs again for free.
///
/// `flutter.`-prefixed prefs keys need no special case - they are noise in
/// the KEY, and only values are ever user-adjacent.
String scrubDiag(String raw) => raw
    .replaceAll(_urlShape, "<url>")
    .replaceAll(_emailShape, "<email>")
    .replaceAll(_tokenShape, "<token>");

/// Ring buffer of the last [max] one-line error records, oldest first.
///
/// No static instance or capture() factory here: main.dart's error hook
/// owns exactly one instance and hands its [lines] to [buildSupportBundle]
/// at export time; wiring it globally from the library would only hide the
/// owner.
class CrashTail {
  CrashTail([this.max = 12]);

  /// default 12: a paste must stay readable, and crash storms arrive in
  /// bursts of <12 distinct failures anyway (one cause, repeated hookups)
  final int max;

  static const _capChars = 160; // same ceiling as the R21 AnnyError scrub

  final _lines = <String>[];

  /// Re-insert an ALREADY-formatted line (a persisted tail re-hydrated at
  /// boot): timestamps survive, the ring cap applies, no re-scrub - the
  /// line passed [record]'s scrubber before it was stored.
  void seed(String line) {
    _lines.add(line);
    while (_lines.length > max) {
      _lines.removeAt(0);
    }
  }

  void record(Object error, [String? route]) {
    final now = DateTime.now();
    final hh = now.hour.toString().padLeft(2, "0");
    final mm = now.minute.toString().padLeft(2, "0");
    var line =
        "$hh:$mm ${error.runtimeType}: ${_oneLine(error.toString())}";
    // scrub before the cut (the R21 rule): everything past the cap is
    // already gone as a secret, not as a visible fragment
    line = scrubDiag(line);
    if (line.length > _capChars) line = line.substring(0, _capChars);
    if (route != null) {
      // the tag rides outside the cap - it is routing metadata the support
      // thread needs, and query strings in route names get scrubbed too
      line = "$line [${scrubDiag(route)}]";
    }
    _lines.add(line);
    while (_lines.length > max) {
      _lines.removeAt(0); // the oldest death is the one support cares least about
    }
  }

  /// oldest-first, so the bundle reads like a timeline
  List<String> get lines => List.unmodifiable(_lines);
}

/// Plain-text report: header, scrubbed feed diagnostics, crash tail, exact
/// alarm permission, honesty footer.
///
/// Feed entries are emitted alphabetically by key (two bundles from the
/// same device state then diff cleanly) and their values are folded to one
/// line - the footer PROMISES "one-line parse status only", so a wrapped
/// HTTP body must not sneak a paragraph in under that promise.
String buildSupportBundle({
  required String appVersion,
  required Map<String, String> diagnostics,
  required List<String> crashTail,
  required bool notificationsPermission,
  DateTime? now,
}) {
  final moment = now ?? DateTime.now();
  final entries = diagnostics.entries.toList()
    ..sort((a, b) => a.key.compareTo(b.key));
  return <String>[
    "KA-UNI support bundle",
    "App version: $appVersion",
    "Generated: ${_stamp(moment.toUtc())} UTC / ${_stamp(moment.toLocal())} local",
    "--- FEEDS ---",
    ...entries.map((e) => "${e.key}: ${scrubDiag(_oneLine(e.value))}"),
    "--- CRASH TAIL (last ${crashTail.length}) ---",
    // re-scrub although CrashTail.record already did: idempotent, cheap,
    // and the bundle is the last fence before a public paste
    ...crashTail.map(scrubDiag),
    "--- NOTIFICATIONS ---",
    "exact-alarms: ${notificationsPermission ? "granted" : "denied"}",
    "contains no personal data - feed diagnostics are one-line parse status only",
  ].join("\n");
}

String _stamp(DateTime t) =>
    "${t.year.toString().padLeft(4, "0")}-${_p(t.month)}-${_p(t.day)} "
    "${_p(t.hour)}:${_p(t.minute)}:${_p(t.second)}";

String _p(int v) => v.toString().padLeft(2, "0");
