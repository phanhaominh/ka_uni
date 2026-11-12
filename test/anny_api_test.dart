// ignore_for_file: library_private_types_in_public_api
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:kit_mobile/library/anny_api.dart';

/// Fixture-driven tests for the Anny JSON:API client — bodies are trimmed
/// copies of the LIVE captures (audit/anny_api.md; /tmp/ka/curl_res.json,
/// curl_iv.json, nr.json). Envelope facts pinned from b.anny.eu 2026-11-12:
/// intervals/start + availability/start-dates answer BARE JSON arrays with
/// FLAT items (reachable via AnnyHttp.itemsOf); open slots carry
/// unavailability_type 'none'; freeNow is the tile covering now.
/// Nothing here touches the network — the transport is the _StubClient
/// below (same pattern as test/anny_auth_test.dart).

const _slug = '2-lesesaal-naturwissenschaften-2-og-und-empore';

// ---- fixtures -------------------------------------------------------------

/// GET resources/{slug}?include=services — live single-resource document
/// (curl_res.json, description/color_map blobs trimmed, every parsed field
/// verbatim).
const _res3404 = '{"data":{"type":"resources","id":"3404","attributes":{'
    '"slug":"$_slug",'
    '"name":"2 a. Lesesaal Naturwissenschaften 2. OG",'
    '"order_index":3000,"quantity":138,"color":"#eded5d",'
    '"color_map":{"fill_light":{"hex":"#F3F3D3"},"accent_light":{"hex":"#EDED5D"}},'
    '"has_children":true,"timezone":"Europe/Berlin","bookings_enabled":true,'
    '"deleted_at":null},'
    '"relationships":{"services":{"data":[{"type":"services","id":"452",'
    '"meta":{"duration_preview":"From 30 minutes to 5 hours",'
    '"supports_instant_booking":true}}]}},"meta":{"display_quota":138}},'
    '"included":[{"type":"services","id":"452","attributes":{'
    '"name":"Lesesaal Naturwissenschaften",'
    '"slug":"gu0tdrhphr4a7adnauorla7ci1wtvt","color":"#F50038",'
    '"has_flexible_duration":true,"booking_interval":15,"min_duration":30,'
    '"max_duration":300,"advance_booking_period":3,"advance_start_time":"20:00:00",'
    '"unit":"minute","auto_accept_bookings":true,"price":0}}]}';

/// the live 404 body for an unknown slug (curl: nr.json, verbatim)
const _notFound = '{"errors":[{"status":"404","title":"Not Found",'
    '"detail":"Resource resources with id does-not-exist-xyz does not exist."}]}';

/// communities/all-resources — two rooms, deliberately in the WRONG catalog
/// order (groups first) to pin that fetchRooms re-orders; 3404 keeps the
/// relationships+included-services route, 3155 the embedded services attr.
const _allRooms = '{"data":['
    '{"type":"resources","id":"3155","attributes":{'
    '"slug":"gruppenraume-kit-bibliothek-sud","name":"4 a. Gruppenräume Süd",'
    '"quantity":13,"services":[{"id":"450","attributes":{'
    '"min_duration":30,"max_duration":180,"booking_interval":30,'
    '"advance_booking_period":3,"cancellation_period":1,'
    '"cancellation_period_type":"hour"}}]}},'
    '{"type":"resources","id":"3404","attributes":{'
    '"slug":"$_slug","name":"2 a. Lesesaal Naturwissenschaften 2. OG",'
    '"quantity":138,"color_map":{"fill_light":{"hex":"#F3F3D3"}}},'
    '"relationships":{"services":{"data":[{"type":"services","id":"452"}]}}}'
    '],"included":[{"type":"services","id":"452","attributes":{'
    '"min_duration":30,"max_duration":300,"booking_interval":15,'
    '"advance_booking_period":3}}]}';

/// intervals/start — BARE array of FLAT items (curl_iv.json shape). The two
/// dated ones are verbatim live items (10:00 free, 23:30 off_schedule); the
/// rest exercise the parse fallbacks of _slot with live field names.
const _ivFlat = '['
    // before_lead_time: grey, not selectable
    '{"start_date":"2026-11-13T09:30:00+01:00","end_date":"2026-11-13T10:00:00+01:00",'
    '"unit":"minute","available":false,"number_available":0,'
    '"remaining_number_available":0,"quota":138,"unavailability_type":"before_lead_time",'
    '"messages":[]},'
    // live item, verbatim (curl_iv.json @10:00): free = number_available (107),
    // NOT remaining_number_available — the chain prefers the first present
    '{"start_date":"2026-11-13T10:00:00+01:00","end_date":"2026-11-13T10:30:00+01:00",'
    '"unit":"minute","available":true,"number_available":107,'
    '"remaining_number_available":1,"quota":138,"unavailability_type":"none",'
    '"resource_ids":["3404"],"messages":[],"series_periods":null,'
    '"timeslot_series_id":null,"title":null,"date_time":"2026-11-13T10:00:00+01:00",'
    '"local_date_time":"2026-11-13T10:00:00+01:00","next_end_date":"2026-11-13T10:30:00+01:00"},'
    // free fallback chain: number_available missing -> remaining (3) ...
    '{"start_date":"2026-11-13T11:00:00+01:00","available":true,'
    '"remaining_number_available":3,"quota":138,"unavailability_type":"none"},'
    // ... -> quota (12)
    '{"start_date":"2026-11-13T12:00:00+01:00","available":true,'
    '"quota":12,"unavailability_type":"none"},'
    // legacy 'available' marker still means bookable
    '{"start_date":"2026-11-13T13:00:00+01:00","available":true,'
    '"number_available":5,"unavailability_type":"available"},'
    // non-string unavailability (bool true) -> 'unavailable'
    '{"start_date":"2026-11-13T14:00:00+01:00","available":false,'
    '"number_available":0,"unavailability":true},'
    // JSON:API-wrapped item still accepted; start_time beats start_date
    '{"type":"intervals","id":"x1","attributes":{"start_time":"15:00",'
    '"start_date":"2026-11-13T20:00:00+01:00","number_available":2,'
    '"unavailability_type":"none"}},'
    // live item, verbatim (curl_iv.json @23:30): off_schedule
    '{"start_date":"2026-11-13T23:30:00+01:00","end_date":"2026-11-14T00:00:00+01:00",'
    '"unit":"minute","available":false,"number_available":0,'
    '"remaining_number_available":0,"quota":138,"unavailability_type":"off_schedule",'
    '"messages":["The booking must start and end in the same schedule. The requested period spans across schedules."]},'
    // unparsable items are dropped, not guessed
    '{"id":"garbage"},'
    '{"type":"intervals","attributes":{}}'
    ']';

/// availability/start-dates — live BARE array shape: {date, available,
/// unavailability_type}, NO quota field (verified 2026-11-12); quota/wrapped
/// variants stay accepted.
const _startDates = '['
    '{"date":"2026-11-12","available":true,"unavailability_type":"none"},'
    '{"date":"2026-11-13","available":true,"quota":42},'
    '{"date":"2026-11-14","available":false,"unavailability_type":"closed"},'
    '{"date":"2026-11-15"},'
    '{"start_date":"2026-11-16","available":true},'
    '{"attributes":{"date":"2026-11-17","quota":7}},'
    '{"id":"junk"}]';

/// order draft from POST order/bookings (capture: order id, oat in
/// attributes.access_token, the real BB number in the included booking)
const _draft = '{"data":{"type":"orders","id":"82176221","attributes":{'
    '"access_token":"oat-7f3a","status":"draft","number":"469411"}},'
    '"included":[{"type":"bookings","id":"8217","attributes":{'
    '"status":"reserved","number":"BB469411363",'
    '"start_date":"2026-11-13T10:00:00+01:00","end_date":"2026-11-13T11:00:00+01:00",'
    '"code":"!TIX5f0a"},"meta":{"cancelable_until":"2026-11-13T09:00:00+01:00"}},'
    '{"type":"resources","id":"3416","attributes":{"name":"A2.004"}}]}';

const _orderDone = '{"data":{"type":"orders","id":"82176221","attributes":{'
    '"status":"completed","number":"469411"}},'
    '"included":[{"type":"bookings","id":"8217","attributes":{'
    '"status":"accepted","number":"BB469411363"}}]}';

// ---- stub client (pattern copied from test/anny_auth_test.dart) ----------

class _Canned {
  const _Canned(this.status, {this.body = "", this.headers = const {}});
  final int status;
  final String body;
  final Map<String, String> headers;
}

class _Route {
  const _Route(this.method, this.urlPart, this.respond);
  final String method;
  final String urlPart;
  final _Canned Function() respond;
}

class _StubClient extends http.BaseClient {
  _StubClient(this.routes);

  final List<_Route> routes;
  final List<http.Request> requests = [];
  Object? throwing;

  http.Request? call(String method, String urlPart) {
    for (final r in requests) {
      if (r.method == method && r.url.toString().contains(urlPart)) return r;
    }
    return null;
  }

  int count(String method, String urlPart) => requests
      .where((r) => r.method == method && r.url.toString().contains(urlPart))
      .length;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final req = request as http.Request;
    requests.add(req);
    final t = throwing;
    if (t != null) throw t;
    final url = req.url.toString();
    for (final r in routes) {
      if (r.method == req.method && url.contains(r.urlPart)) {
        final c = r.respond();
        return http.StreamedResponse(
            Stream.value(utf8.encode(c.body)), c.status,
            headers: c.headers, request: req);
      }
    }
    throw StateError("stub: unexpected ${req.method} $url");
  }
}

/// Berlin wall time -> explicit-offset ISO. Mirrors anny_api's _dstOff rule
/// (last Sun Mar→Oct = +02:00) so _parseT round-trips the wall components
/// back on any test-run date, not only in CET windows.
String isoBerlin(DateTime wall) {
  int lastSun(int mo) {
    final l = DateTime.utc(wall.year, mo + 1, 0);
    return l.day - (l.weekday % 7);
  }

  final asUtc = DateTime.utc(
      wall.year, wall.month, wall.day, wall.hour, wall.minute, wall.second);
  final off = asUtc.isAfter(DateTime.utc(wall.year, 3, lastSun(3), 1)) &&
          asUtc.isBefore(DateTime.utc(wall.year, 10, lastSun(10), 1))
      ? 2
      : 1;
  return '${wall.year}-${_p(wall.month)}-${_p(wall.day)}'
      'T${_p(wall.hour)}:${_p(wall.minute)}:${_p(wall.second)}+0$off:00';
}

String _p(int v) => v.toString().padLeft(2, '0');

/// bare intervals array with two tiles around "now": the one covering now
/// ([nowFree], starts 5 min ago) and the next one — freeNow reads the
/// covering tile, so stub slot times MUST be relative to now
String ivAroundNow({int nowFree = 93, int nextFree = 88}) {
  final now = DateTime.now();
  final a = now.subtract(const Duration(minutes: 5));
  final b = now.add(const Duration(minutes: 10));
  return '[{"start_date":"${isoBerlin(a)}","available":true,'
      '"number_available":$nowFree,"quota":138,"unavailability_type":"none"},'
      '{"start_date":"${isoBerlin(b)}","available":true,'
      '"number_available":$nextFree,"quota":138,"unavailability_type":"none"}]';
}

/// stub that answers the anonymous browse endpoints with the fixtures
_StubClient browseClient({
  _Canned Function()? intervals,
  bool allResourcesFails = false,
}) =>
    _StubClient([
      _Route(
          "GET",
          "all-resources",
          () => allResourcesFails
              ? const _Canned(404, body: _notFound)
              : const _Canned(200, body: _allRooms)),
      // BEFORE the generic resources/ route (children URLs contain it too)
      _Route("GET", "/children", () => const _Canned(200, body: '{"data":[]}')),
      _Route("GET", "intervals/start",
          intervals ?? () => const _Canned(200, body: _ivFlat)),
      _Route("GET", "resources/", () => const _Canned(200, body: _res3404)),
    ]);

// ---- tests ----------------------------------------------------------------

void main() {
  group("rooms", () {
    test("all-resources parses the catalog and re-orders it", () async {
      final stub = browseClient();
      final rooms = await fetchRooms(AnnyHttp(client: stub));

      final all = stub.call("GET", "all-resources")!;
      expect(all.url.queryParameters["page[size]"], "14");
      expect(all.url.queryParameters["include"], "services");
      expect(all.url.queryParameters["stateless"], "1");
      // happy path = ONE call, no per-slug fallback
      expect(stub.count("GET", "resources/"), 0);

      expect(rooms.map((r) => r.slug).toList(),
          [_slug, "gruppenraume-kit-bibliothek-sud"],
          reason: "catalog order wins over the response order");

      final lesesaal = rooms.first;
      expect(lesesaal.id, "3404");
      expect(lesesaal.name, "2 a. Lesesaal Naturwissenschaften 2. OG");
      expect(lesesaal.quantity, 138);
      expect(lesesaal.serviceId, 452, reason: "relationship + included match");
      expect(lesesaal.minDuration, 30);
      expect(lesesaal.maxDuration, 300);
      expect(lesesaal.interval, 15);
      expect(lesesaal.advanceDays, 3);
      expect(lesesaal.cancelMinutesBefore, 0);
      // real behavior pin: color_map is a structured map WITHOUT the
      // top-level color/fill/hex keys the code prefers -> empty, even
      // though attributes.color is '#eded5d'
      expect(lesesaal.color, "");
      expect(lesesaal.openFrom, "");
      expect(lesesaal.openTo, "");
      expect(lesesaal.section, "seats");

      final groups = rooms[1];
      expect(groups.serviceId, 450, reason: "embedded services attribute");
      expect(groups.maxDuration, 180);
      expect(groups.advanceDays, 3);
      expect(groups.cancelMinutesBefore, 60,
          reason: "cancellation_period 1 hour -> minutes");
      expect(groups.section, "groups");
    });

    test("404 on all-resources -> per-slug fallback, single-resource shape",
        () async {
      final stub = browseClient(allResourcesFails: true);
      final rooms = await fetchRooms(AnnyHttp(client: stub));

      // every one of the 8 catalog slugs is resolved (sequentially)
      expect(stub.count("GET", "resources/"), 8);
      expect(stub.requests.first.url.path,
          contains("/communities/kit-bibliothek-OTNRQaXc/all-resources"));

      // the stub answers every slug with the lesesaal -> deduped by slug
      expect(rooms.single.slug, _slug);
      expect(rooms.single.serviceId, 452);
    });
  });

  group("intervals/start (bare flat array)", () {
    test("parses real items + the free fallback chain, drops junk", () async {
      final stub = browseClient();
      final h = AnnyHttp(client: stub);
      final slots = await fetchIntervals(h, _slug, 452, DateTime(2026, 11, 13));

      // slug resolved once, then intervals with the captured q shape
      expect(stub.requests[0].url.path, endsWith("/resources/$_slug"));
      final rq = stub.requests[1].url.queryParameters;
      expect(stub.requests[1].url.path, endsWith("/intervals/start"));
      expect(rq["date"], "2026-11-13");
      expect(rq["service_id[452]"], "1");
      expect(rq["resource_id"], "3404");
      expect(rq["timezone"], "Europe/Berlin");

      expect(
          slots
              .map((s) =>
                  "${s.start.hour}:${_p(s.start.minute)} f=${s.free} '${s.unavailability}'")
              .toList(),
          [
            "9:30 f=0 'before_lead_time'",
            "10:00 f=107 ''", // 'none' = bookable, free=number_available
            "11:00 f=3 ''", // number_available missing -> remaining
            "12:00 f=12 ''", // ... -> quota
            "13:00 f=5 ''", // legacy 'available' marker
            "14:00 f=0 'unavailable'", // bool true -> 'unavailable'
            "15:00 f=2 ''", // wrapped shape, start_time beats start_date
            "23:30 f=0 'off_schedule'",
          ],
          reason: "junk items dropped; 'available'/'none' both -> bookable");
      expect(slots.where((s) => s.available).length, 5);

      // second call on the SAME client reuses the cached resource id
      await fetchIntervals(h, _slug, 452, DateTime(2026, 11, 14));
      expect(stub.count("GET", "resources/"), 1);
    });

    test("fetchBookableDays: live shape has no quota (available:bool wins)",
        () async {
      final stub = _StubClient([
        _Route(
            "GET", "start-dates", () => const _Canned(200, body: _startDates)),
        _Route("GET", "resources/", () => const _Canned(200, body: _res3404)),
      ]);
      final days = await fetchBookableDays(AnnyHttp(client: stub), _slug, 452);

      final rq = stub.requests[1].url.queryParameters;
      final today = DateTime.now();
      expect(stub.requests[1].url.path, endsWith("/availability/start-dates"));
      expect(rq["start_date"],
          "${today.year}-${_p(today.month)}-${_p(today.day)}");
      final to = today.add(const Duration(days: 60));
      expect(rq["end_date"], "${to.year}-${_p(to.month)}-${_p(to.day)}");
      expect(rq["service_id[452]"], "1");
      expect(rq["resource_id"], "3404");

      expect(days, {
        DateTime(2026, 11, 12): 1, // available:true, quota absent -> 1
        // live shape sends dated entries as offset instants
        // ("2026-11-13T00:00:00+01:00"); the day is the DATE PREFIX as
        // written — DateTime.parse's UTC fields keyed it a day early
        DateTime(2026, 11, 13): 42, // explicit quota wins
        DateTime(2026, 11, 14): 0, // closed -> 0 even if quota absent
        DateTime(2026, 11, 15): 0, // neither available nor quota -> 0
        DateTime(2026, 11, 16): 1, // start_date fallback
        DateTime(2026, 11, 17): 7, // JSON:API-wrapped variant accepted
      });
    });

    test("live +01:00-midnight instants key their DATE PREFIX, not UTC day",
        () async {
      // LIVE shape (2026-11-12 capture): start-dates entries are offset
      // instants ("2026-11-13T00:00:00+01:00"); DateTime.parse's UTC
      // field getters key them 2026-11-12 and the day strip shows every
      // date one day early. The day is the prefix exactly as written.
      final stub = _StubClient([
        _Route("GET", "start-dates", () => const _Canned(200, body:
            '[{"date":"2026-11-13T00:00:00+01:00","available":true},'
            '{"date":"2026-12-24T00:00:00+01:00","quota":5}]')),
        _Route("GET", "resources/", () => const _Canned(200, body: _res3404)),
      ]);
      final days = await fetchBookableDays(AnnyHttp(client: stub), _slug, 452);
      expect(days[DateTime(2026, 11, 13)], 1);
      expect(days[DateTime(2026, 12, 24)], 5);
      expect(days.keys.any((d) => d.day == 12 || d.day == 23), false,
          reason: "no UTC-shifted keys");
    });

    test("freeNow reads the tile COVERING now (relative slots)", () async {
      final h = AnnyHttp(
          client:
              browseClient(intervals: () => _Canned(200, body: ivAroundNow())));
      expect(await freeNow(h, _slug, 452), 93,
          reason: "covering tile (now-5min), not the next one");

      final closed = AnnyHttp(client: browseClient(intervals: () {
        final later = DateTime.now().add(const Duration(hours: 2));
        return _Canned(200,
            body: '[{"start_date":"${isoBerlin(later)}",'
                '"available":true,"number_available":10,"unavailability_type":"none"}]');
      }));
      expect(await freeNow(closed, _slug, 452), 0,
          reason: "first tile starts after now -> opens later, nothing free");

      final blockedTile = AnnyHttp(client: browseClient(intervals: () {
        final now = DateTime.now();
        return _Canned(200,
            body:
                '[{"start_date":"${isoBerlin(now.subtract(const Duration(minutes: 5)))}",'
                '"available":false,"number_available":0,"unavailability_type":"before_lead_time"},'
                '{"start_date":"${isoBerlin(now.add(const Duration(minutes: 10)))}",'
                '"available":true,"number_available":10,"unavailability_type":"none"}]');
      }));
      expect(await freeNow(blockedTile, _slug, 452), 0,
          reason: "covering tile not bookable -> 0, next tile ignored");
    });

    test("itemsOf bridges bare-array and {data:[…]} answers", () {
      expect(
          AnnyHttp.itemsOf({
            "_rawArray": [1, 2]
          }),
          [1, 2]);
      expect(
          AnnyHttp.itemsOf({
            "data": [3]
          }),
          [3]);
      expect(AnnyHttp.itemsOf({}), isEmpty);
    });
  });

  group("error dialect", () {
    test("429 carries Retry-After seconds; absent header -> 5", () async {
      final withHdr = AnnyHttp(
          client: _StubClient([
        _Route("GET", "flaky",
            () => const _Canned(429, headers: {"retry-after": "42"})),
      ]));
      final e = await withHdr.get("flaky").then<AnnyRateLimited>(
          (_) => throw StateError("must throw"),
          onError: (Object e) => e as AnnyRateLimited);
      expect(e.retryAfterSec, 42);
      expect(e.status, 429);

      final bare = AnnyHttp(
          client:
              _StubClient([_Route("GET", "flaky", () => const _Canned(429))]));
      await expectLater(
          bare.get("flaky"),
          throwsA(isA<AnnyRateLimited>()
              .having((e) => e.retryAfterSec, "retryAfterSec", 5)));

      final negative = AnnyHttp(
          client: _StubClient([
        _Route("GET", "flaky",
            () => const _Canned(429, headers: {"retry-after": "-2"})),
      ]));
      await expectLater(
          negative.get("flaky"),
          throwsA(isA<AnnyRateLimited>()
              .having((e) => e.retryAfterSec, "retryAfterSec", 1)));
    });

    test("401 -> AnnyUnauthorized (also on 401 with a body)", () async {
      final h = AnnyHttp(
          client: _StubClient([
        _Route("GET", "bookings",
            () => const _Canned(401, body: '{"errors":[{"detail":"nope"}]}')),
      ]));
      await expectLater(
          h.get("bookings", bearer: "JWT"),
          throwsA(isA<AnnyUnauthorized>()
              .having((e) => e.status, "status", 401)
              .having((e) => e.detail, "detail", "login required")));
    });

    test("non-JSON error body -> truncated raw detail", () async {
      final raw = "<html><body>Bad Gateway</body></html>" * 30;
      final h = AnnyHttp(
          client: _StubClient(
              [_Route("GET", "gate", () => _Canned(503, body: raw))]));
      final e = await h.get("gate").then<Object>(
          (_) => throw StateError("must throw"),
          onError: (Object e) => e);
      final err = e as AnnyError;
      expect(err.status, 503);
      expect(err.detail, raw.substring(0, 160),
          reason: "detail truncated to 160 chars, not the whole page");
      expect(err.detail.length, 160);
    });

    test("JSON:API errors[] detail wins, title as fallback", () async {
      final h = AnnyHttp(
          client: _StubClient([
        _Route(
            "GET",
            "detail",
            () => const _Canned(500,
                body: '{"errors":[{"detail":"slot just taken"}]}')),
        _Route(
            "GET",
            "title",
            () => const _Canned(422,
                body: '{"errors":[{"title":"Unprocessable"}]}')),
      ]));
      await expectLater(
          h.get("detail"),
          throwsA(isA<AnnyError>()
              .having((e) => e.detail, "detail", "slot just taken")));
      await expectLater(
          h.get("title"),
          throwsA(isA<AnnyError>()
              .having((e) => e.detail, "detail", "Unprocessable")));
    });
  });

  group("rate guard (≤4 identical reqs/second)", () {
    test("5th identical request never leaves the client", () async {
      final stub = _StubClient(
          [_Route("GET", "times", () => const _Canned(200, body: "{}"))]);
      final h = AnnyHttp(client: stub);
      for (var i = 0; i < 4; i++) {
        await h.get("times"); // identical URL, within one second
      }
      await expectLater(
          h.get("times"),
          throwsA(isA<AnnyRateLimited>()
              .having((e) => e.retryAfterSec, "retryAfterSec", 1)));
      // the 5th was refused client-side: transport saw exactly 4
      expect(stub.count("GET", "times"), 4);

      // different URL = different hash bucket, not throttled
      final other = _StubClient([
        _Route("GET", "times", () => const _Canned(200, body: "{}")),
        _Route("GET", "other", () => const _Canned(200, body: "{}")),
      ]);
      final h2 = AnnyHttp(client: other);
      for (var i = 0; i < 5; i++) {
        await h2.get(i.isEven ? "times" : "other");
      }
      expect(other.count("GET", "times"), 3);
      expect(other.count("GET", "other"), 2);
    });
  });

  group("resourceIdOf", () {
    test("numeric ids pass through, slugs resolve once + cache", () async {
      final stub = browseClient();
      stub.routes.insert(
          0,
          _Route("GET", "does-not-exist",
              () => const _Canned(404, body: _notFound)));
      final h = AnnyHttp(client: stub);
      expect(await h.resourceIdOf("3191"), "3191");
      expect(stub.requests, isEmpty, reason: "no lookup for numeric ids");

      expect(await h.resourceIdOf(_slug), "3404");
      expect(await h.resourceIdOf(_slug), "3404");
      expect(stub.count("GET", "resources/"), 1,
          reason: "slug resolved once, then cached");

      await expectLater(
          h.resourceIdOf("does-not-exist-xyz"),
          throwsA(isA<AnnyError>().having((e) => e.status, "status", 404).having(
              (e) => e.detail,
              "detail",
              "Resource resources with id does-not-exist-xyz does not exist.")));

      final empty = AnnyHttp(
          client: _StubClient([
        _Route("GET", "ghost", () => const _Canned(200, body: '{"data":{}}'))
      ]));
      await expectLater(
          empty.resourceIdOf("ghost"),
          throwsA(isA<AnnyError>()
              .having((e) => e.detail, "detail", "no resource id for ghost")));
    });
  });

  group("cart flow (capture shapes)", () {
    _StubClient cartStub({_Canned? checkout}) => _StubClient([
          _Route(
              "POST", "order/bookings", () => const _Canned(200, body: _draft)),
          _Route("POST", "/order?",
              () => checkout ?? const _Canned(200, body: _orderDone)),
          _Route("GET", "delete-all", () => const _Canned(200, body: "{}")),
        ]);

    test("cartAdd sends the captured body byte-shape, parses oid/oat/BB",
        () async {
      final stub = cartStub();
      // UTC inputs -> the exact strings of the live capture (10:00 Berlin)
      final got = await cartAdd(AnnyHttp(client: stub), "JWT-1",
          childResourceId: "3416",
          serviceId: 452,
          start: DateTime.utc(2026, 11, 13, 9, 0),
          end: DateTime.utc(2026, 11, 13, 10, 0));

      expect((got.oid, got.oat, got.bookingId, got.number),
          ("82176221", "oat-7f3a", "8217", "BB469411363"),
          reason: "oid from data.id, oat from attributes.access_token, "
              "bookingId+BB number from the included booking");

      final req = stub.call("POST", "order/bookings")!;
      expect(req.url.queryParameters["stateless"], "1");
      expect(req.url.queryParameters["include"],
          "bookings,bookings.resource,bookings.service,resource,service,customer-account");
      expect(req.headers["authorization"], "Bearer JWT-1");
      expect(req.headers["content-type"], "application/vnd.api+json");
      expect(req.headers["accept"], "application/vnd.api+json");
      expect(req.headers["x-app-key"], "anny_shop");
      expect(req.headers["user-agent"], startsWith("Mozilla/5.0"));
      expect(jsonDecode(req.body), {
        "resource_id": ["3416"],
        "service_id": {"452": 1},
        "timeslot_series_id": null,
        "start_date": "2026-11-13T10:00:00+01:00",
        "end_date": "2026-11-13T11:00:00+01:00",
        "description": "",
        "customer_note": "",
        "add_ons_by_service": {
          "452": [[]]
        },
        "sub_bookings_by_service": {},
        "strategy": "multi-resource",
        "prevent_applying_default_quota": false,
      });
    });

    test("serialization: Berlin +01:00 winter, +02:00 summer (UTC inputs)",
        () async {
      final stub = cartStub();
      await cartAdd(AnnyHttp(client: stub), "J",
          childResourceId: "1",
          serviceId: 1,
          start: DateTime.utc(2026, 7, 15, 8, 0),
          end: DateTime.utc(2026, 7, 15, 9, 0));
      final body = jsonDecode(stub.call("POST", "order/bookings")!.body);
      expect(body["start_date"], "2026-07-15T10:00:00+02:00");
      expect(body["end_date"], "2026-07-15T11:00:00+02:00");
    });

    test("WALL inputs (the manager path) serialize as-is, never shifted",
        () async {
      // _parseT/AnnySlot contract: Berlin WALL times. The book() flow
      // feeds them straight into cartAdd — a shifted serialization
      // books the wrong hour (old bug: +1h winter / +2h summer).
      final stub = cartStub();
      await cartAdd(AnnyHttp(client: stub), "J",
          childResourceId: "1",
          serviceId: 1,
          start: DateTime(2026, 11, 13, 10, 0),
          end: DateTime(2026, 11, 13, 11, 0));
      var body = jsonDecode(stub.call("POST", "order/bookings")!.body);
      expect(body["start_date"], "2026-11-13T10:00:00+01:00",
          reason: "the exact value the captured request sent");
      expect(body["end_date"], "2026-11-13T11:00:00+01:00");

      final summer = cartStub();
      await cartAdd(AnnyHttp(client: summer), "J",
          childResourceId: "1",
          serviceId: 1,
          start: DateTime(2026, 7, 15, 10, 0),
          end: DateTime(2026, 7, 15, 11, 0));
      body = jsonDecode(summer.call("POST", "order/bookings")!.body);
      expect(body["start_date"], "2026-07-15T10:00:00+02:00",
          reason: "wall fields untouched, offset matches the season");
    });

    test("cartCheckout posts the captured order body + oid/oat query",
        () async {
      final stub = cartStub();
      final number = await cartCheckout(AnnyHttp(client: stub), "JWT-2",
          oid: "82176221",
          oat: "oat-7f3a",
          givenName: "Ada",
          familyName: "Lovelace",
          email: "ujpuu@student.kit.edu",
          visitToken: "alvo-9");
      expect(number, "BB469411363",
          reason: "BB from included beats digit sub-order");

      final req = stub.call("POST", "/order?")!;
      expect(req.url.path, "/api/v1/order");
      expect(req.url.queryParameters, {
        "visit_token": "alvo-9",
        "oid": "82176221",
        "oat": "oat-7f3a",
        "stateless": "1",
      });
      expect(jsonDecode(req.body), {
        "customer": {
          "given_name": "Ada",
          "family_name": "Lovelace",
          "email": "ujpuu@student.kit.edu",
        },
        "accept_terms": true,
        "payment_method": "",
        "success_url": "https://anny.eu/",
        "cancel_url": "https://anny.eu/",
        "meta": {"timezone": "Europe/Berlin"},
      });
    });

    test("booking number: included non-BB still beats the sub-order digit",
        () async {
      final stub = cartStub(
          checkout: const _Canned(200,
              body:
                  '{"data":{"id":"82176221","attributes":{"number":"469411"}},'
                  '"included":[{"type":"bookings","id":"8217",'
                  '"attributes":{"number":"777"}}]}'));
      final number = await cartCheckout(AnnyHttp(client: stub), "J",
          oid: "1",
          oat: "2",
          givenName: "A",
          familyName: "B",
          email: "c@d",
          visitToken: "v");
      expect(number, "777");

      // no included at all -> the data[] digit remains
      final noIncl = cartStub(
          checkout: const _Canned(200,
              body: '{"data":{"id":"9","attributes":{"number":"469411"}}}'));
      expect(
          await cartCheckout(AnnyHttp(client: noIncl), "J",
              oid: "1",
              oat: "2",
              givenName: "A",
              familyName: "B",
              email: "c@d",
              visitToken: "v"),
          "469411");
    });

    test("cartDeleteAll: GET with stateless+oid+oat (quota-lock release)",
        () async {
      final stub = cartStub();
      await cartDeleteAll(AnnyHttp(client: stub), "JWT-3",
          oid: "82176221", oat: "oat-7f3a");
      final req = stub.call("GET", "delete-all")!;
      expect(req.url.path, "/api/v1/order/bookings/delete-all");
      expect(req.url.queryParameters,
          {"stateless": "1", "oid": "82176221", "oat": "oat-7f3a"});
      expect(req.headers["authorization"], "Bearer JWT-3");
    });

    test("cancelBooking: GET /bookings/{id}/cancel?access_token=CODE",
        () async {
      final stub = _StubClient(
          [_Route("GET", "/cancel", () => const _Canned(200, body: "{}"))]);
      await cancelBooking(AnnyHttp(client: stub), "JWT-4",
          bookingId: "8217", accessToken: "!TIX5f0a");
      final req = stub.call("GET", "/cancel")!;
      expect(req.url.path, "/api/v1/bookings/8217/cancel");
      expect(req.url.queryParameters["access_token"], "!TIX5f0a");
      expect(req.method, "GET");
      expect(req.body, isEmpty);
      expect(req.headers["authorization"], "Bearer JWT-4");
    });
  });

  group("childSeats", () {
    test("explicit resource_availability_result decides; q shape captured",
        () async {
      const body = '{"data":['
          '{"id":"3417","attributes":{"name":"A2.005"},'
          '"meta":{"resource_availability_result":{"available":false}}},'
          '{"id":"3416","attributes":{"name":"A2.004"},'
          '"meta":{"resource_availability_result":{"available":true}}},'
          // serviceAvailabilityResults: every entry blocked -> hard no
          '{"id":"3418","attributes":{"name":"A2.006"},'
          '"meta":{"resource_availability_result":{"serviceAvailabilityResults":'
          '[{"unavailability_type":"before_lead_time"}]}}},'
          // live meta shape (is_available) is NOT the parsed key -> unknown;
          // picked non-empty already -> this desk stays out (real behavior)
          '{"id":"3419","attributes":{"name":"A2.007"},'
          '"meta":{"is_available":true}}]}';
      final stub = _StubClient([
        _Route("GET", "/children", () => const _Canned(200, body: body)),
      ]);
      final seats = await childSeats(AnnyHttp(client: stub), _slug,
          from: DateTime.utc(2026, 11, 13, 9, 0),
          to: DateTime.utc(2026, 11, 13, 10, 0),
          serviceId: 452);
      expect(seats, ["3416"]);

      final rq = stub.requests.single.url.queryParameters;
      expect(stub.requests.single.url.path,
          endsWith("/resources/$_slug/children"));
      expect(rq["page[size]"], "250");
      expect(rq["filter[available_from]"], "2026-11-13T10:00:00+01:00");
      expect(rq["filter[available_to]"], "2026-11-13T11:00:00+01:00");
      expect(rq["filter[availability_exact_match]"], "1");
      expect(rq["filter[availability_service_id]"], "452");
      expect(rq["filter[exclude_child_resources]"], "0");
    });

    test("no parseable availability anywhere -> trust exact_match filter",
        () async {
      // all ids, sorted by NAME (ids deliberately in reverse order)
      const body = '{"data":['
          '{"id":"9002","attributes":{"name":"A2.001"},"meta":{"is_available":true}},'
          '{"id":"9001","attributes":{"name":"A2.002"},"meta":{"is_available":false}}]}';
      final stub = _StubClient([
        _Route("GET", "/children", () => const _Canned(200, body: body)),
      ]);
      final seats = await childSeats(AnnyHttp(client: stub), _slug,
          from: DateTime.utc(2026, 11, 13, 9, 0),
          to: DateTime.utc(2026, 11, 13, 10, 0),
          serviceId: 452);
      expect(seats, ["9002", "9001"],
          reason: "server already filtered exact_match; order is by name");
    });
  });

  group("anonymous browse headers", () {
    test("GET sends accept/x-app-key/UA but NO authorization", () async {
      final stub = _StubClient([
        _Route("GET", "ping", () => const _Canned(200, body: "{}")),
      ]);
      await AnnyHttp(client: stub).get("ping");
      final h = stub.requests.single.headers;
      expect(h["accept"], "application/vnd.api+json");
      expect(h["x-app-key"], "anny_shop");
      expect(h["user-agent"], startsWith("Mozilla/5.0"));
      expect(h["authorization"], isNull,
          reason: "browsing stays anonymous — no personal data on browse");
    });
  });

  group("myBookings", () {
    test("upcoming_only query + BB fields + room name, canceled skipped",
        () async {
      const body = '{"data":['
          '{"type":"bookings","id":"8217","attributes":{'
          '"number":"BB469411363","status":"accepted",'
          '"start_date":"2026-11-13T10:00:00+01:00",'
          '"end_date":"2026-11-13T11:00:00+01:00",'
          '"code":"!TIX5f0a","cancelable_until":"2026-11-13T09:00:00+01:00"},'
          '"relationships":{"resource":{"data":{"type":"resources","id":"3404"}}}},'
          '{"type":"bookings","id":"8218","attributes":{'
          '"number":"BB469411364","status":"canceled",'
          '"start_date":"2026-11-14T10:00:00+01:00"}},'
          // no parsable start -> dropped, never guessed
          '{"type":"bookings","id":"8219","attributes":{"status":"reserved"}}],'
          '"included":[{"type":"resources","id":"3404","attributes":'
          '{"name":"2 a. Lesesaal Naturwissenschaften 2. OG"}}]}';
      final stub = _StubClient([
        _Route("GET", "/bookings", () => const _Canned(200, body: body)),
      ]);
      final list =
          await myBookings(AnnyHttp(client: stub), "JWT-9", "4cfe53f7-uuid");

      final req = stub.call("GET", "/bookings")!;
      expect(req.url.path, "/api/v1/bookings");
      expect(req.url.queryParameters["filter[upcoming_only]"], "1");
      expect(req.headers["authorization"], "Bearer JWT-9");

      expect(list.length, 1, reason: "canceled + start-less rows never show");
      final b = list.single;
      expect((b.id, b.number, b.status), ("8217", "BB469411363", "accepted"));
      expect(b.isActive, isTrue);
      expect(b.start, DateTime(2026, 11, 13, 10),
          reason: "+01:00 instants surface as Berlin wall times");
      expect(b.end, DateTime(2026, 11, 13, 11));
      expect(b.resource, "2 a. Lesesaal Naturwissenschaften 2. OG");
      expect(b.code, "!TIX5f0a", reason: "cancelBooking needs this as token");
      expect(b.cancelUntil, DateTime(2026, 11, 13, 9));
    });
  });
}
