/// R34.4 pins: the OFFICIAL TERM CALENDAR model.
///
/// The fixture is the LIVE capture of `GET https://plus.campus.kit.edu/
/// api/signmeup/meta` taken 2026-11-13 (anonymous 200 — public KIT data,
/// no PII): test/fixtures/smumeta.json. Sample of the wire shape:
///   {"terms":[{"id":"5e19b2de-0bc9-4f32-9034-3c40922b855b",
///     "name":"WS 26/27","fullName":"Wintersemester 2026/27",
///     "isPublished":true,"startDate":"2026-10-01T00:00:00Z",
///     "endDate":"2026-03-31T23:59:59Z", ...}, ...],
///    "headings":[...],"eventTypes":[...]}
/// The WS endDate precedes its own startDate — the broken winter-term
/// year the fetchMine comment already called "unreliable". Pinned below.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kit_mobile/signmeup/signmeup_terms.dart';

void main() {
  Map<String, dynamic> meta(String s) => jsonDecode(s) as Map<String, dynamic>;
  List<SignMeUpTerm> loadFixture() =>
      SignMeUpTerm.listFromJson(
          meta(File('test/fixtures/smumeta.json').readAsStringSync()));

  group('live capture', () {
    test('parses every named term of the real meta body', () {
      final terms = loadFixture();
      expect(terms.length, greaterThanOrEqualTo(10));
      expect(terms.every((t) => t.name.isNotEmpty), isTrue);
      final ws = terms.firstWhere((t) => t.name == "WS 26/27");
      expect(ws.fullName, "Wintersemester 2026/27");
      expect(ws.id.isNotEmpty, isTrue);
    });

    test('term dates are the wire DATE as written, never UTC-shifted', () {
      // "2026-10-01T00:00:00Z" is pseudo-precision: KIT defines terms by
      // date. Reading the shifted instant is the Anny W5 bug class —
      // in Berlin the Z would push SS end 31.03. onto 01.04.
      final terms = loadFixture();
      final ws = terms.firstWhere((t) => t.name == "WS 26/27");
      expect(ws.start, DateTime(2026, 10, 1));
      final ss = terms.firstWhere((t) => t.name == "SS 2026");
      expect(ss.start, DateTime(2026, 4, 1));
      expect(ss.end, DateTime(2026, 9, 30));
      // WS 25/26 prints endDate "2026-03-31T23:59:59Z": the wall date is
      // 31.03. — a UTC->local shift would render it as 01.04.
      final past = terms.firstWhere((t) => t.name == "WS 25/26");
      expect(past.end, DateTime(2026, 3, 31));
    });

    test('broken winter-term year gets exactly one deterministic bump', () {
      // live wire: WS 26/27 endDate 2026-03-31 — FIVE MONTHS before its
      // own startDate 2026-10-01. Month/day are known; only the year is
      // repaired (-> the real KIT semester end 31.03.2027).
      final ws = loadFixture().firstWhere((t) => t.name == "WS 26/27");
      expect(ws.end, DateTime(2027, 3, 31));
      expect(ws.end!.isAfter(ws.start!), isTrue);
    });

    test('the current wire carries NO cancellation bound', () {
      // honesty arm: cancelEnd stays null because the payload has no
      // such field — the model must not conjure one
      for (final t in loadFixture()) {
        expect(t.cancelEnd, isNull, reason: t.name);
      }
    });
  });

  group('defensive parsing', () {
    test('a shipped cancellation key lights up without code changes', () {
      final terms = SignMeUpTerm.listFromJson(meta(jsonEncode({
        "terms": [
          {
            "id": "x1",
            "name": "WS 27/28",
            "startDate": "2027-10-01T00:00:00Z",
            "endDate": "2027-03-31T23:59:59Z",
            "courseCancellationEndDate": "2027-12-15T23:59:59Z",
          }
        ]
      })));
      expect(terms.single.cancelEnd, DateTime(2027, 12, 15));
    });

    test('end still broken after the single bump stays UNKNOWN', () {
      final terms = SignMeUpTerm.listFromJson(meta(jsonEncode({
        "terms": [
          {
            "id": "x2",
            "name": "ZZ 30/31",
            "startDate": "2030-10-01T00:00:00Z",
            "endDate": "2029-03-31T23:59:59Z",
          }
        ]
      })));
      expect(terms.single.end, isNull); // 2030-03-31 < start -> no guess
    });

    test('unnamed or id-less entries are dropped, date-less kept', () {
      final terms = SignMeUpTerm.listFromJson(meta(jsonEncode({
        "terms": [
          {"id": "a", "startDate": "2026-10-01T00:00:00Z"}, // no name
          {"name": "SS 2027", "startDate": "2027-04-01T00:00:00Z"}, // no id
          {"id": "c", "name": "", "fullName": "   "}, // blank names
          {
            "id": "d", // named, unparseable dates: kept, bounds null
            "fullName": "Interim",
            "startDate": "nonsense",
          },
        ]
      })));
      // only "d" survives, titled by its fullName
      expect(terms.map((t) => t.name), ["Interim"]);
      expect(terms.single.start, isNull);
      expect(terms.single.end, isNull);
    });

    test('junk bodies parse to empty, never throw', () {
      expect(SignMeUpTerm.listFromJson(null), isEmpty);
      expect(SignMeUpTerm.listFromJson([]), isEmpty);
      expect(SignMeUpTerm.listFromJson({"headings": []}), isEmpty);
      expect(SignMeUpTerm.listFromJson({"terms": "not a list"}), isEmpty);
    });
  });
}
