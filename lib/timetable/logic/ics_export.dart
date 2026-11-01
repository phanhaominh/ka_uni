import 'dart:convert';

/// Pure builder that turns the merged timetable cache (CampusKIT webcal +
/// personal ICS block + SignMeUp synthetic block) into a standalone,
/// shareable .ics document. Deliberately free of widgets, plugins and
/// state management so the round-trip with [WebcalFeed] can be unit-tested.
///
/// Security contract: the exported file NEVER carries the subscription URL,
/// its token or any other fetched-from info - only the cache body itself,
/// with every URL line, feed-identifying header property and the internal
/// sentinel markers removed. UIDs are kept verbatim: re-imports must keep
/// updating the same events instead of duplicating them.

/// MIME type the file is shared under.
const icsExportMimeType = "text/calendar";

/// Sentinel lines CampusManager embeds into the cache to make the personal
/// and SignMeUp block injections idempotent. Literals are duplicated here
/// (see campus_manager.dart personalBegin/personalEnd/synthBegin/synthEnd/
/// examSynthBegin/examSynthEnd)
/// to keep this unit independent of the state layer; [buildIcsExport]
/// strips them so the exported document is clean, standard ICS.
const _sentinelMarkers = [
  "X-PERSONAL-ICS-BEGIN",
  "X-PERSONAL-ICS-END",
  "X-SIGNMEUP-SYNTH-BEGIN",
  "X-SIGNMEUP-SYNTH-END",
  "X-EXAM-SYNTH-BEGIN",
  "X-EXAM-SYNTH-END",
];

/// Feed header properties that describe WHO publishes the source calendar;
/// dropped so the export is the student's calendar, not a KIT artifact.
const _sourceProperties = {
  "PRODID",
  "NAME",
  "URL",
  "X-WR-CALNAME",
  "X-WR-CALDESC"
};

/// RFC 5545 line limit; folded continuation lines spend one octet on the
/// leading space, so the first chunk of a logical line may use 74.
const _maxLineOctets = 74;

/// Any-scheme absolute URL marker (matched against lower-cased lines).
final _urlPattern = RegExp(r"[a-z][a-z0-9+.\-]*://");

/// Bytes + event count + filename of one export, or null when there is
/// nothing exportable (no VCALENDAR wrapper or zero VEVENTs).
class IcsExport {
  final List<int> bytes;

  /// Number of VEVENT blocks contained in [bytes].
  final int eventCount;

  /// e.g. "mei-stundenplan-20261031.ics"
  final String fileName;

  const IcsExport(
      {required this.bytes, required this.eventCount, required this.fileName});
}

/// Builds the export document from [mergedIcs] (the raw
/// DATA_webcalIcsCache body). [now] only feeds the filename date and is
/// injectable for deterministic tests; the calendar content itself is
/// untouched.
IcsExport? buildIcsExport(String mergedIcs, {DateTime? now}) {
  if (!mergedIcs.contains("BEGIN:VCALENDAR")) return null;

  final out = <String>[];
  var eventCount = 0;
  for (final line in _unfold(mergedIcs)) {
    if (_isSentinel(line) || _isSourceInfo(line)) continue;
    if (line == "BEGIN:VEVENT") eventCount++;
    out.add(line);
  }
  // empty cache (or one whose only content was stripped): the caller
  // shows its "nothing to export" hint instead of a share sheet
  if (eventCount == 0) return null;
  if (!out.contains("END:VCALENDAR")) out.add("END:VCALENDAR");

  return IcsExport(
    bytes: utf8.encode("${out.map(_foldLine).join("\r\n")}\r\n"),
    eventCount: eventCount,
    fileName: _fileName(now ?? DateTime.now()),
  );
}

/// Line splitting + RFC 5545 unfolding (continuation lines start with a
/// single space/tab); same semantics as the app's WebcalFeed parser.
List<String> _unfold(String raw) {
  final out = <String>[];
  final current = StringBuffer();
  var hasLogical = false;
  for (final line in const LineSplitter().convert(raw)) {
    if ((line.startsWith(" ") || line.startsWith("\t")) && hasLogical) {
      current.write(line.substring(1));
    } else {
      if (hasLogical) out.add(current.toString());
      current.clear();
      current.write(line);
      hasLogical = true;
    }
  }
  if (hasLogical) out.add(current.toString());
  return out;
}

bool _isSentinel(String line) =>
    _sentinelMarkers.any((m) => line == m || line.startsWith("$m:"));

/// Property name of a content line (before the first ';' or ':').
String _propName(String line) {
  final semi = line.indexOf(";");
  final colon = line.indexOf(":");
  final cut = semi < 0
      ? colon
      : (colon < 0 ? semi : (semi < colon ? semi : colon));
  return (cut < 0 ? line : line.substring(0, cut)).toUpperCase();
}

bool _isSourceInfo(String line) {
  final name = _propName(line);
  // X-*-TOKEN / WEBCAL-TOKEN style leftovers, whatever wrote them
  if (name.contains("TOKEN") || _sourceProperties.contains(name)) return true;
  // Lines carrying ANY absolute URL (http, webcal, ...) - unfolded first,
  // so a URL split across fold continuations cannot hide
  return _urlPattern.hasMatch(line.toLowerCase());
}

/// Soft-folds one logical line to <= 75 octets (CRLF + space continuation)
/// without ever cutting a UTF-8 sequence; the exported cache body is
/// already within the limit, this only guards pathological injected lines.
String _foldLine(String line) {
  final bytes = utf8.encode(line);
  if (bytes.length <= _maxLineOctets) return line;
  final parts = <String>[];
  var start = 0;
  var limit = _maxLineOctets;
  while (start < bytes.length) {
    var end =
        start + limit > bytes.length ? bytes.length : start + limit;
    while (end < bytes.length && (bytes[end] & 0xC0) == 0x80) {
      end--; // step back to the start of this codepoint
    }
    parts.add(utf8.decode(bytes.sublist(start, end), allowMalformed: true));
    start = end;
    limit = _maxLineOctets - 1;
  }
  return parts.join("\r\n ");
}

String _fileName(DateTime now) => "mei-stundenplan-"
    "${now.year.toString().padLeft(4, "0")}"
    "${now.month.toString().padLeft(2, "0")}"
    "${now.day.toString().padLeft(2, "0")}.ics";
