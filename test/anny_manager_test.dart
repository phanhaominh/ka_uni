// ignore_for_file: library_private_types_in_public_api
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:kit_mobile/library/anny_api.dart';
import 'package:kit_mobile/library/anny_auth.dart';
import 'package:kit_mobile/library/anny_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Hermetic tests for AnnyManager: cache-first paint, the anon/auth split,
/// the cart flow incl. the quota-lock release, and the ONE-silent-re-auth
/// rule — all against the stub transport (pattern from anny_auth_test.dart,
/// plus a Completer gate so no test ever sleeps to prove ordering) and the
/// _FakeAuth seam. Real fixture shapes live in test/anny_api_test.dart;
/// only the bodies this suite parses are repeated here.

const _slug = '2-lesesaal-naturwissenschaften-2-og-und-empore';
const _uuid = "4cfe53f7-83b4-4504-a207-cf551a474361";

// ---- fixtures -------------------------------------------------------------

/// GET resources/{slug}?include=services (live capture, trimmed) — resolves
/// the slug to id 3404 with service 452
const _res3404 = '{"data":{"type":"resources","id":"3404","attributes":{'
    '"slug":"$_slug","name":"2 a. Lesesaal Naturwissenschaften 2. OG",'
    '"quantity":138,"color_map":{"fill_light":{"hex":"#F3F3D3"}}},'
    '"relationships":{"services":{"data":[{"type":"services","id":"452"}]}}},'
    '"included":[{"type":"services","id":"452","attributes":{'
    '"min_duration":30,"max_duration":300,"booking_interval":15,'
    '"advance_booking_period":3}}]}';

/// all-resources: the two catalog rooms (lesesaal first) — anon browse
const _allRooms = '{"data":['
    '{"type":"resources","id":"3404","attributes":{'
    '"slug":"$_slug","name":"2 a. Lesesaal Naturwissenschaften 2. OG",'
    '"quantity":138},"relationships":{"services":{"data":[{"type":"services","id":"452"}]}}},'
    '{"type":"resources","id":"3155","attributes":{'
    '"slug":"gruppenraume-kit-bibliothek-sud","name":"4 a. Gruppenräume Süd",'
    '"quantity":13,"services":[{"id":"450","attributes":{"min_duration":30,'
    '"max_duration":180}}]}}]}';

/// intervals/start (live BARE array, flat items): a tile covering "now"
/// with [free] seats + the next one — freeNow reads the covering tile
String ivNow({int free = 93}) {
  final now = DateTime.now();
  final a = now.subtract(const Duration(minutes: 5));
  final b = now.add(const Duration(minutes: 10));
  return '[{"start_date":"${_iso(a)}","available":true,"number_available":$free,'
      '"quota":138,"unavailability_type":"none"},'
      '{"start_date":"${_iso(b)}","available":true,"number_available":88,'
      '"quota":138,"unavailability_type":"none"}]';
}

String _iso(DateTime wall) {
  int lastSun(int mo) {
    final l = DateTime.utc(wall.year, mo + 1, 0);
    return l.day - (l.weekday % 7);
  }

  final u = DateTime.utc(
      wall.year, wall.month, wall.day, wall.hour, wall.minute, wall.second);
  final off = u.isAfter(DateTime.utc(wall.year, 3, lastSun(3), 1)) &&
          u.isBefore(DateTime.utc(wall.year, 10, lastSun(10), 1))
      ? 2
      : 1;
  String p(int v) => v.toString().padLeft(2, '0');
  return '${wall.year}-${p(wall.month)}-${p(wall.day)}'
      'T${p(wall.hour)}:${p(wall.minute)}:${p(wall.second)}+0$off:00';
}

/// children: A2.005 taken, A2.004 free -> book must pick 3416
const _children = '{"data":['
    '{"id":"3417","attributes":{"name":"A2.005"},'
    '"meta":{"resource_availability_result":{"available":false}}},'
    '{"id":"3416","attributes":{"name":"A2.004"},'
    '"meta":{"resource_availability_result":{"available":true}}}]}';

/// POST order/bookings draft (capture shape): oid/oat/booking + BB number
const _draft = '{"data":{"type":"orders","id":"82176221","attributes":{'
    '"access_token":"oat-7f3a","status":"draft","number":"469411"}},'
    '"included":[{"type":"bookings","id":"8217","attributes":{'
    '"status":"reserved","number":"BB000000000","code":"!TIX5f0a"}}]}';

const _orderDone = '{"data":{"type":"orders","id":"82176221","attributes":{'
    '"status":"completed","number":"469411"}},'
    '"included":[{"type":"bookings","id":"8217","attributes":{'
    '"status":"accepted","number":"BB000000000"}}]}';

/// GET bookings?filter[upcoming_only]=1 — one accepted booking (server truth)
const _bookingsUpcoming =
    '{"data":[{"type":"bookings","id":"8217","attributes":{'
    '"status":"accepted","number":"BB000000000",'
    '"start_date":"2026-11-13T10:00:00+01:00","end_date":"2026-11-13T11:00:00+01:00",'
    '"code":"!TIX5f0a","cancelable_until":"2026-11-13T09:00:00+01:00"},'
    '"relationships":{"resource":{"data":{"type":"resources","id":"3404"}}}}],'
    '"included":[{"type":"resources","id":"3404","attributes":{'
    '"name":"2 a. Lesesaal Naturwissenschaften 2. OG"}}]}';

/// ANN_rooms snapshot in the exact codec AnnyManager writes itself
String cachedRooms({int free = 42}) => jsonEncode({
      "at": DateTime.now().toIso8601String(),
      "counts": {_slug: free},
      "rooms": [
        {
          "id": "3404",
          "slug": _slug,
          "name": "2 a. Lesesaal Naturwissenschaften 2. OG",
          "color": "",
          "quantity": 138,
          "serviceId": 452,
          "minDuration": 30,
          "maxDuration": 300,
          "interval": 15,
          "advanceDays": 3,
          "cancelMinutesBefore": 0,
          "openFrom": "",
          "openTo": "",
        }
      ],
    });

// ---- stub transport (anny_auth_test pattern + hold gate) ------------------

class _Canned {
  const _Canned(this.status, {this.body = ""});
  final int status;
  final String body;
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

  /// gate: while set, sends whose URL contains [holdFor] wait for this
  /// Completer — the deterministic way to assert "paint before the reply"
  Completer<void>? hold;
  String? holdFor;

  http.Request? call(String method, String urlPart) {
    for (final r in requests) {
      if (r.method == method && r.url.toString().contains(urlPart)) return r;
    }
    return null;
  }

  int count(String method, String urlPart) => requests
      .where((r) => r.method == method && r.url.toString().contains(urlPart))
      .length;

  List<String> order() => requests.map((r) => r.url.toString()).toList();

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final req = request as http.Request;
    requests.add(req);
    final h = hold, f = holdFor;
    if (h != null && f != null && req.url.toString().contains(f)) {
      await h.future;
    }
    final t = throwing;
    if (t != null) throw t;
    final url = req.url.toString();
    for (final r in routes) {
      if (r.method == req.method && url.contains(r.urlPart)) {
        final c = r.respond();
        return http.StreamedResponse(
            Stream.value(utf8.encode(c.body)), c.status,
            request: req);
      }
    }
    throw StateError("stub: unexpected ${req.method} $url");
  }
}

// ---- fake auth ------------------------------------------------------------

class _FakeAuth extends AnnyAuth {
  _FakeAuth();

  final calls = <String>[]; // kitUser per attempt
  Object? throwing;
  String nextJwt = "JWT-1";

  @override
  Future<AnnySession> signIn(
      {required String kitUser, required String password}) async {
    calls.add(kitUser);
    final t = throwing;
    if (t != null) throw t;
    nextJwt = "JWT-${calls.length}";
    // fresh (obtainedAt = now) -> isExpired false -> no re-auth needed for
    // ensureFreshSession; only a 401 forces the next one
    return AnnySession(
        jwt: nextJwt, visitToken: "ALVO-${calls.length}", accountUuid: _uuid);
  }
}

// ---- harness --------------------------------------------------------------

class _Fx {
  _Fx(this.m, this.stub, this.auth, this.pwLog);
  final AnnyManager m;
  final _StubClient stub;
  final _FakeAuth auth;
  final List<String> pwLog;
  int notifies = 0;
}

_Fx fx(Map<String, Object> prefs, List<_Route> routes) {
  SharedPreferences.setMockInitialValues(prefs);
  final stub = _StubClient(routes);
  final auth = _FakeAuth();
  final m = AnnyManager()
    ..http = AnnyHttp(client: stub)
    ..auth = auth;
  final pwLog = <String>[];
  String? stored;
  m.passWrite = (pw) async {
    stored = pw;
    pwLog.add(pw);
  };
  m.passRead = () async => stored;
  m.passErase = () async => stored = null;
  final f = _Fx(m, stub, auth, pwLog);
  m.addListener(() => f.notifies++);
  return f;
}

/// the full anon+auth stub surface every post-signIn flow may hit
List<_Route> routes({
  _Canned Function()? bookings,
  _Canned Function()? checkout,
}) =>
    [
      // specific BEFORE generic ("resources/" also matches "/children")
      _Route("GET", "/children", () => const _Canned(200, body: _children)),
      _Route("GET", "delete-all", () => const _Canned(200, body: "{}")),
      _Route("GET", "/cancel", () => const _Canned(200, body: "{}")),
      _Route("GET", "all-resources", () => const _Canned(200, body: _allRooms)),
      _Route("GET", "intervals/start", () => _Canned(200, body: ivNow())),
      _Route("GET", "resources/", () => const _Canned(200, body: _res3404)),
      _Route("GET", "filter%5Bupcoming_only%5D",
          bookings ?? () => const _Canned(200, body: '{"data":[]}')),
      _Route("POST", "order/bookings", () => const _Canned(200, body: _draft)),
      _Route("POST", "/order?",
          checkout ?? () => const _Canned(200, body: _orderDone)),
    ];

/// a plain socket failure for gate-release tests
class socketERR implements Exception { const socketERR(); }

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group("boot (cache-first, mensa discipline)", () {
    test("empty prefs: anon boot = no network, no auth, no password", () async {
      final f = fx({}, routes());
      await f.m.boot();
      expect(f.stub.requests, isEmpty,
          reason: "FLUTTER_TEST gate: boot never kicks the network refresh");
      expect(f.auth.calls, isEmpty, reason: "boot must not sign in");
      expect(f.pwLog, isEmpty);
      expect(f.m.signedIn, isFalse);
      expect(f.m.error, AnnyErrorKind.none);
      expect(f.m.hasData, isFalse);
      expect(f.notifies, greaterThan(0), reason: "boot always notifies");
    });

    test("ANN_rooms cache paints BEFORE any reply, error stays none", () async {
      final f = fx({"ANN_rooms": cachedRooms()}, routes());
      var paintedWithData = false;
      f.m.addListener(() {
        if (f.m.rooms.isNotEmpty) paintedWithData = true;
      });
      await f.m.boot();
      expect(paintedWithData, isTrue,
          reason: "first notify already carries the cached catalog");
      expect(f.m.rooms.single.slug, _slug);
      expect(f.m.freeCounts, {_slug: 42});
      expect(f.m.hasData, isTrue);
      expect(f.stub.requests, isEmpty);
      expect(f.m.error, AnnyErrorKind.none);
    });

    test("refreshAnon notifies while fetching and fills counts + cache",
        () async {
      final f = fx({}, routes());
      f.stub.holdFor = "intervals/start";
      final gate = Completer<void>();
      f.stub.hold = gate;

      final inflight = f.m.refreshAnon();
      await Future<void>(() {});
      await Future<void>(() {});
      expect(f.m.isFetching, isTrue);
      expect(f.notifies, greaterThan(0),
          reason: "loading state paints before the reply arrives");
      expect(f.m.freeCounts, isEmpty);

      gate.complete();
      await inflight;
      expect(f.m.rooms.map((r) => r.slug).toList(),
          [_slug, "gruppenraume-kit-bibliothek-sud"]);
      expect(f.m.freeCounts, {_slug: 93, "gruppenraume-kit-bibliothek-sud": 93},
          reason: "freeNow = tile covering now (relative stub slots)");
      expect(f.m.error, AnnyErrorKind.none);

      final p = await SharedPreferences.getInstance();
      final saved =
          jsonDecode(p.getString("ANN_rooms")!) as Map<String, dynamic>;
      expect(
          saved["counts"], {_slug: 93, "gruppenraume-kit-bibliothek-sud": 93});
      expect((saved["rooms"] as List), hasLength(2));
    });

    test("dead network keeps the stale cache and flips error=offline",
        () async {
      final f = fx({"ANN_rooms": cachedRooms()}, routes());
      await f.m.boot();
      f.stub.throwing = SocketException("dead socket");
      final before = f.notifies;
      await f.m.refreshAnon(force: true);
      expect(f.m.rooms, hasLength(1),
          reason: "stale catalog KEPT, never cleared");
      expect(f.m.freeCounts, {_slug: 42});
      expect(f.m.error, AnnyErrorKind.offline);
      expect(f.notifies, greaterThan(before));
    });
  });

  group("sign-in", () {
    test("success persists the session triple, never the password", () async {
      final f = fx({}, routes());
      final ok = await f.m.signIn("alice", "s3cr3t!");
      expect(ok, isTrue);
      expect(f.m.signedIn, isTrue);
      expect(f.m.error, AnnyErrorKind.none);

      final p = await SharedPreferences.getInstance();
      expect(p.getString("ANN_jwt"), "pending",
          reason: "R21: prefs keep a signed-in MARKER, never the live "
              "token - a stolen prefs file must not carry a usable JWT");
      expect(p.getString("ANN_alvo"), isNull,
          reason: "the alvo token is not persisted at all");
      expect(p.getString("ANN_uuid"), isNull);
      expect(p.getString("ANN_email"), "alice@student.kit.edu");
      expect(p.getString("ANN_first"), isNull,
          reason: "the placeholder prefill was removed (P1: it made the "
              "first booking fail until the user guessed the field)");
      for (final k in p.getKeys()) {
        expect("${p.get(k)}", isNot(contains("s3cr3t!")),
            reason: "the password must never reach prefs (key: $k)");
        expect("${p.get(k)}", isNot(contains("JWT-")),
            reason: "no live token may reach prefs (key: $k)");
      }
      expect(f.pwLog, ["s3cr3t!"], reason: "keychain write happened once");

      expect(f.stub.count("GET", "filter%5Bupcoming_only%5D"), 1,
          reason: "signIn pulls the booking list right after");
    });

    test("401 during refreshBookings: EXACTLY one silent re-auth, then auth",
        () async {
      final f = fx({}, routes(bookings: () => const _Canned(401)));
      final ok = await f.m.signIn("alice", "pw");
      expect(ok, isTrue, reason: "sign-in itself worked; the list failed");
      expect(f.auth.calls.length, 2,
          reason: "1 sign-in + exactly ONE silent re-auth (no loops)");
      expect(f.stub.count("GET", "filter%5Bupcoming_only%5D"), 2,
          reason: "original attempt + retry with the re-minted JWT");
      expect(f.m.error, AnnyErrorKind.auth);
      expect(f.m.bookings, isEmpty);

      final p = await SharedPreferences.getInstance();
      expect(p.getString("ANN_jwt"), "pending",
          reason: "re-mints stay in memory only (R21); the marker stays "
              "the single persisted truth");
    });

    test("bad credentials map AnnyAuthReason -> error=auth, no session",
        () async {
      final f = fx({}, routes());
      f.auth.throwing = const AnnyAuthError(AnnyAuthReason.badCredentials);
      final ok = await f.m.signIn("alice", "wrong");
      expect(ok, isFalse);
      expect(f.m.signedIn, isFalse);
      expect(f.m.error, AnnyErrorKind.auth);
      expect(f.stub.requests, isEmpty,
          reason: "no booking traffic after a rejected sign-in");
    });
  });

  group("R21 lifecycle regressions", () {
    // drain the microtask + event queue so unawaited fetches land
    Future<void> pump() => Future<void>(() {});

    test("sign-out clears identity PII, not just the token triple",
        () async {
      final f = fx({}, routes());
      await f.m.signIn("alice", "pw");
      await f.m.setCheckoutNames("Bob", "Maier");
      final p = await SharedPreferences.getInstance();
      expect(p.getString("ANN_first"), "Bob", reason: "set first");

      await f.m.signOut();

      for (final k in ["ANN_jwt", "ANN_email", "ANN_first", "ANN_last"]) {
        expect(p.getString(k), isNull, reason: "$k must not survive signOut");
      }
      expect(f.m.signedIn, isFalse);
      expect(await f.m.passRead(), isNull,
          reason: "the keychain copy of the KIT password dies with signOut");
      // the NEXT user's confirm sheet reads exactly these keys: it must
      // see an empty form, not Bob's identity
      final id = await f.m.checkoutIdentity();
      expect("${id.first}|${id.last}|${id.email}", "||");
    });

    test("boot scrubs a legacy live JWT from prefs on sight", () async {
      // a pre-fix install persisted the real token; updating the app
      // must not leave it readable until the next sign-out
      final f = fx({"ANN_jwt": "REAL-OLD-TOKEN", "ANN_email": "alice@student.kit.edu"}, routes());
      final p = await SharedPreferences.getInstance();
      await f.m.boot();
      expect(p.getString("ANN_jwt"), isNull,
          reason: "the legacy token is erased on boot");
      expect(f.m.favSlug, isEmpty);
    });

    test("empty catalog is never truth: cache stays, anomaly reported",
        () async {
      // warm the cache first
      final f = fx({}, routes());
      await f.m.refreshAnon();
      expect(f.m.rooms.length, 2);

      f.stub.routes.insert(
          0,
          _Route("GET", "all-resources",
              () => const _Canned(200, body: '{"data":[]}')));
      await f.m.refreshAnon(force: true);
      expect(f.m.rooms.length, 2,
          reason: "a 200-with-empty-array glitch must not blank the card");
      expect(f.m.error, AnnyErrorKind.markup,
          reason: "but it must be reported, not swallowed");
    });

    test("favorite switched mid-fetch: new room's slots still arrive",
        () async {
      final f = fx({}, routes());
      await f.m.refreshAnon();
      final a = f.m.rooms.first, b = f.m.rooms.last;

      f.stub.holdFor = "intervals/start";
      final gate = Completer<void>();
      f.stub.hold = gate;
      f.m.setFav(a.slug);
      final first = f.m.refreshFavSlots();
      await Future<void>(() {});
      await Future<void>(() {});

      f.m.setFav(b.slug); // switch WHILE A's fetch is in flight
      gate.complete();
      f.stub.hold = null;
      f.stub.holdFor = null;
      await first;
      await Future<void>(() {});
      await Future<void>(() {});
      expect(f.stub.count("GET", "intervals/start") >= 3, isTrue,
          reason: "the switch must trigger a SECOND fetch for the new "
              "favorite instead of joining the abandoned one");
    });

    test("the NEWEST favorite's strip survives a late abandoned reply",
        () async {
      final f = fx({}, routes());
      await f.m.refreshAnon();
      final a = f.m.rooms.first, b = f.m.rooms.last;

      f.stub.routes.insert(
          0,
          _Route("GET", "intervals",
              () {
                final t = DateTime.now().add(const Duration(minutes: 30));
                return _Canned(200,
                    body: '[{"start_date":"${_iso(t)}","available":true,'
                        '"number_available":22,"quota":138,'
                        '"unavailability_type":"none"}]');
              })); // B's fresh data
      f.stub.holdFor = "resource=${a.slug}"; // only A's fetch is held
      final gate = Completer<void>();
      f.stub.hold = gate;

      f.m.setFav(a.slug);
      final aFut = f.m.refreshFavSlots(); // A's fetch, held in flight
      await pump();
      await f.m.setFav(b.slug);
      await pump(); // B's strip answers freely, fresh data lands
      expect(f.m.favSlots.every((sl) => sl.free == 22), isTrue,
          reason: "B's fresh data is on screen while A is still in flight");

      gate.complete();
      f.stub.hold = null;
      f.stub.holdFor = null;
      await aFut;
      await pump();
      expect(f.m.favSlots.every((sl) => sl.free == 22), isTrue,
          reason: "A's LATE reply for the abandoned favorite may not "
              "overwrite B's strip (R21 second half of the join bug)");
    });

    test("un-favoriting then re-favoriting still fetches", () async {
      final f = fx({}, routes());
      await f.m.refreshAnon();
      final a = f.m.rooms.first;
      // per-stage counters FIRST (data, then assertion)
      final c0 = f.stub.count("GET", "intervals/start");
      await f.m.setFav(a.slug);
      await pump();
      expect(f.stub.count("GET", "intervals/start") - c0, 1,
          reason: "favorite set -> its strip fetches");
      await f.m.setFav("");
      await pump();
      expect(f.stub.count("GET", "intervals/start") - c0, 1,
          reason: "empty favorite -> no strip fetch");
      await f.m.setFav(a.slug);
      await pump();
      expect(f.stub.count("GET", "intervals/start") - c0, 2,
          reason: "re-favoriting after an empty favorite must fetch again "
              "- the no-fetch fav-'' step may not poison the join check");
    });

    test("a throwing cancel releases the gate (no session-wide lockout)",
        () async {
      final f = fx({}, routes());
      await f.m.signIn("alice", "pw");
      f.stub.throwing = const socketERR();
      final ok = await f.m.cancel(AnnyBooking(
          id: "b1", number: "BB1", status: "accepted",
          start: DateTime.now().add(const Duration(hours: 1)),
          end: DateTime.now().add(const Duration(hours: 2)),
          resource: "x", code: "c1"));
      f.stub.throwing = null;
      expect(ok, isFalse, reason: "a dead socket means NOT cancelled");
      expect(f.m.isBooking, isFalse,
          reason: "the gate must open again after a failed cancel");
      // and the NEXT cancel is really attempted, not gate-rejected:
      f.stub.throwing = null;
      await f.m.cancel(AnnyBooking(
          id: "b1", number: "BB1", status: "accepted",
          start: DateTime.now().add(const Duration(hours: 1)),
          end: DateTime.now().add(const Duration(hours: 2)),
          resource: "x", code: "c1"));
      expect(f.stub.count("GET", "/cancel"), 2,
          reason: "both cancels reached the server - the first was not a "
              "silently-swallowed gate rejection");
    });

    test("book gate is synchronous: second call cannot open a cart",
        () async {
      final f = fx({}, routes());
      await f.m.signIn("alice", "pw");
      await f.m.setCheckoutNames("Eva", "Maier");
      await f.m.refreshAnon(); // rooms feed the gate flow, like signedInFx
      final room = f.m.rooms.first;

      f.stub.holdFor = "order/bookings";
      final gate = Completer<void>();
      f.stub.hold = gate;
      final first = f.m.book(room, DateTime.now(), 60);
      await Future<void>(() {});
      // old code: identity await sat BETWEEN check and set - this second
      // call slipped through and ran a second overlapping cart
      final second = await f.m.book(room, DateTime.now(), 60);
      expect(second, isNull, reason: "gate must reject synchronously");
      gate.complete();
      f.stub.hold = null;
      f.stub.holdFor = null;
      await first;
      expect(f.stub.count("POST", "order/bookings"), 1,
          reason: "exactly one draft cart for two calls");
    });
  });

  group("book (cart flow)", () {
    Future<_Fx> signedInFx({
      _Canned Function()? checkout,
      bool serverTruth = false,
    }) async {
      final f = fx(
          {},
          routes(
              checkout: checkout,
              bookings: serverTruth
                  ? () => const _Canned(200, body: _bookingsUpcoming)
                  : null));
      await f.m.signIn("alice", "pw");
      await f.m.setCheckoutNames("Ada", "Lovelace");
      await f.m.refreshAnon(); // real rooms through the stub
      return f;
    }

    test("happy path: free seat, cart endpoints in order, BB number", () async {
      // server truth includes 8217 -> the unawaited post-book refresh keeps
      // the list stable, so the assertion below cannot race it
      final f = await signedInFx(serverTruth: true);
      final room = f.m.rooms.first;
      expect(room.slug, _slug);
      final before = f.notifies;

      AnnyBooking? booked;
      f.m.onBooked = (b) => booked = b;
      final got = await f.m.book(room, DateTime(2026, 11, 13, 10, 0), 60);

      expect(got, isNotNull);
      expect(got!.number, "BB000000000");
      expect(got.id, "8217");
      expect(got.status, "accepted");
      expect(booked, same(got), reason: "W5 hook fired with the booking");

      final order = f.stub.order();
      final ci = order.indexWhere((u) => u.contains("/children"));
      final ca = order.indexWhere((u) => u.contains("order/bookings"));
      final co = order.indexWhere((u) => u.contains("/api/v1/order?"));
      expect(ci, isNonNegative);
      expect(ci, lessThan(ca), reason: "free seat BEFORE the cart draft");
      expect(ca, lessThan(co), reason: "draft BEFORE checkout");

      final draftReq = f.stub.call("POST", "order/bookings")!;
      expect(jsonDecode(draftReq.body)["resource_id"], ["3416"],
          reason: "the FREE desk (3416), not the taken one (3417)");
      expect(jsonDecode(draftReq.body)["service_id"], {"452": 1});
      expect(draftReq.headers["authorization"], "Bearer JWT-1");

      final checkoutReq = f.stub.call("POST", "/order?")!;
      expect(checkoutReq.url.queryParameters, {
        "visit_token": "ALVO-1",
        "oid": "82176221",
        "oat": "oat-7f3a",
        "stateless": "1",
      });
      expect(jsonDecode(checkoutReq.body)["customer"], {
        "given_name": "Ada",
        "family_name": "Lovelace",
        "email": "alice@student.kit.edu",
      });

      expect(f.stub.count("GET", "delete-all"), 0,
          reason: "success must NOT touch the quota-lock release");
      expect(f.m.bookings.map((b) => b.id), contains("8217"));
      expect(f.m.error, AnnyErrorKind.none);
      expect(f.notifies, greaterThan(before),
          reason: "book() notifies at least once around success");
    });

    test("checkout failure AFTER cartAdd releases the quota lock", () async {
      final f = await signedInFx(
          checkout: () => const _Canned(500,
              body: '{"errors":[{"detail":"cart expired"}]}'));
      final got =
          await f.m.book(f.m.rooms.first, DateTime(2026, 11, 13, 10, 0), 60);
      expect(got, isNull);

      final release = f.stub.call("GET", "delete-all")!;
      expect(f.stub.count("GET", "delete-all"), 1,
          reason: "exactly once — the draft must not linger behind");
      expect(release.url.queryParameters, {
        "stateless": "1",
        "oid": "82176221",
        "oat": "oat-7f3a",
      });
      expect(f.m.error, AnnyErrorKind.markup);
      expect(f.m.bookings, isEmpty);
      expect(f.m.onBooked, isNull);
    });
  });

  group("cancel", () {
    test("token route with the booking code; list updates + onCanceled",
        () async {
      final f = fx({},
          routes(bookings: () => const _Canned(200, body: _bookingsUpcoming)));
      await f.m.signIn("alice", "pw");
      expect(await f.m.refreshBookings(), isTrue);
      final b = f.m.bookings.single;
      expect(b.id, "8217");
      expect(b.code, "!TIX5f0a");
      expect(b.isActive, isTrue);
      expect(f.m.activeBooking?.id, "8217");

      AnnyBooking? canceled;
      f.m.onCanceled = (x) => canceled = x;
      expect(await f.m.cancel(b), isTrue);

      final req = f.stub.call("GET", "/cancel")!;
      expect(req.url.path, "/api/v1/bookings/8217/cancel");
      expect(req.url.queryParameters["access_token"], "!TIX5f0a",
          reason: "the booking code IS the cancel access_token");
      expect(req.headers["authorization"], "Bearer JWT-1");
      expect(canceled?.id, "8217");
      expect(f.m.bookings, isEmpty, reason: "canceled booking leaves the list");
      expect(f.m.activeBooking, isNull);
    });
  });
}
