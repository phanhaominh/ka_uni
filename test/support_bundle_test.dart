import 'package:flutter_test/flutter_test.dart';
import 'package:kit_mobile/diagnostics/support_bundle.dart';

/// R29: the last fence before a paste goes public - ring order, scrub
/// shapes, and the "no raw URL in the bundle" promise.
void main() {
  test("ring keeps the newest max records, oldest first", () {
    final tail = CrashTail(3);
    for (var i = 0; i < 5; i++) {
      tail.record(StateError("boom $i"));
    }
    expect(tail.lines, hasLength(3));
    expect(tail.lines.first, contains("boom 2"));
    expect(tail.lines.last, contains("boom 4"));

    final dflt = CrashTail();
    for (var i = 0; i < 30; i++) {
      dflt.record(StateError("e${i.toString().padLeft(2, "0")}"));
    }
    expect(dflt.lines, hasLength(12));
    expect(dflt.lines.first, contains("e18"));
    expect(dflt.lines.first, isNot(contains("e17")));
    expect(dflt.lines.last, contains("e29"));
  });

  test("URL, token and email shapes are scrubbed", () {
    const raw = "failed https://id.zeit.de/abc/webcal.ics?token=deadbeef "
        "sig=YVd4cFFIaWpKbEswOUQxMkxNWmNkZWYxMjM0NTY3ODk "
        "write max.mustermann@student.kit.edu";
    final clean = scrubDiag(raw);
    expect(clean, contains("<url>"));
    expect(clean, contains("<token>"));
    expect(clean, contains("<email>"));
    expect(clean, isNot(contains("https")));
    expect(clean, isNot(contains("deadbeef")));
    expect(clean, isNot(contains("YVd4cFF")));
    expect(clean, isNot(contains("mustermann")));
  });

  test("long email local part becomes <email>, never a half-eaten <token>",
      () {
    expect(scrubDiag("mail verylonglocalpart1234567@x.org now"),
        "mail <email> now");
  });

  test("scrubbing is idempotent", () {
    const raw = "boom https://a.b/x?k=SECRETtokenishLongerThanTwenty "
        "and user@mail.example.com plus Zm9vYmFyYmF6cXV1eGNvcmdlZDEyMzQ1";
    final once = scrubDiag(raw);
    expect(once, contains("<url>"));
    expect(once, contains("<email>"));
    expect(once, contains("<token>"));
    expect(scrubDiag(once), once);
  });

  test("multi-line error folds into one timestamped line", () {
    final tail = CrashTail();
    tail.record(StateError("bad state\r\nsecond\tline"));
    expect(tail.lines, hasLength(1));
    final line = tail.lines.single;
    expect(line, matches(r"^\d{2}:\d{2} "));
    expect(line, isNot(anyOf(contains("\n"), contains("\r"), contains("\t"))));
    expect(line, contains("StateError: Bad state: bad state second line"));
  });

  test("one-liner capped at 160 chars, route tag rides outside the cap", () {
    // prose-like filler: an opaque x-run would be token-scrubbed away long
    // before the cap mattered - this reaches the cut intact
    final filler = List.filled(40, "detail").join(" ");
    final tail = CrashTail();
    tail.record(StateError(filler));
    expect(tail.lines.single.length, 160);
    tail.record(StateError(filler), "/home");
    expect(tail.lines.last.length, 160 + " [/home]".length);
  });

  test("route query strings are scrubbed too", () {
    final tail = CrashTail();
    tail.record(StateError("m"),
        "https://host/x?t=SECRETtokenishLongerThanTwentyChars");
    expect(tail.lines.single, contains("[<url>]"));
    expect(tail.lines.single, isNot(contains("https")));
    expect(tail.lines.single, isNot(contains("SECRET")));
  });

  test("bundle: header, scrubbed feeds, tail, permission, footer", () {
    final bundle = buildSupportBundle(
      appVersion: "1.4.2+31",
      diagnostics: {
        "GEO_lastStatus": "ok",
        "DATA_webcalDiag":
            "feed failed https://feed.example.org/t/1a2b3c4d5e6f7g8h9i0j/cal.ics 404",
        "MENSA_diag": "parse error\ncache miss",
        "PREF_theme": "dark",
      },
      crashTail: const ["09:14 StateError: boom", "09:16 Exception: feed <url>"],
      notificationsPermission: true,
      now: DateTime.utc(2026, 11, 12, 9, 15),
    );
    expect(bundle, contains("App version: 1.4.2+31"));
    expect(bundle, contains("2026-11-12 09:15:00 UTC"));
    // the whole point: not one raw URL or token path segment survives
    expect(bundle, isNot(contains("http")));
    expect(bundle, isNot(contains("1a2b3c4d5e6f")));
    expect(bundle, contains("DATA_webcalDiag: feed failed <url> 404"));
    // wrapped values are folded - the footer promises one lines only
    expect(bundle, contains("MENSA_diag: parse error cache miss"));
    // alphabetical keys: two bundles from one state diff cleanly
    final feeds =
        bundle.split("--- FEEDS ---\n")[1].split("--- CRASH TAIL")[0];
    expect(feeds.trim().split("\n").first, startsWith("DATA_webcalDiag:"));
    expect(bundle, contains("--- CRASH TAIL (last 2) ---"));
    expect(bundle, contains("09:14 StateError: boom"));
    expect(bundle, contains("exact-alarms: granted"));
    expect(
        bundle,
        endsWith("contains no personal data - feed diagnostics are one-line "
            "parse status only"));
  });

  test("empty crash tail renders the section header only", () {
    final bundle = buildSupportBundle(
      appVersion: "1.0",
      diagnostics: const {},
      crashTail: const [],
      notificationsPermission: false,
      now: DateTime.utc(2026, 11, 12),
    );
    final lines = bundle.split("\n");
    expect(lines, contains("--- FEEDS ---"));
    final i = lines.indexOf("--- CRASH TAIL (last 0) ---");
    expect(i, greaterThanOrEqualTo(0));
    expect(lines[i + 1], "--- NOTIFICATIONS ---");
    expect(lines, contains("exact-alarms: denied"));
  });
}
