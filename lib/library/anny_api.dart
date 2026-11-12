import 'dart:convert';

import 'package:http/http.dart' as http;

/// KIT-Bibliothek seat booking — pure JSON:API client for b.anny.eu (no
/// Flutter imports). Request/response shapes follow the live capture in
/// `audit/anny_api.md` 1:1; where docs.anny.co differs, the capture wins.
/// NEVER log requests or errors: headers carry Bearer JWTs.

const _apiBase = 'https://b.anny.eu/api/v1';
const _community = 'kit-bibliothek-OTNRQaXc';

/// The library's timezone; serialization always carries an explicit offset
/// (`+01:00` / `+02:00`) exactly like the capture.
const annyTimezone = 'Europe/Berlin';

/// Hardcoded public room catalog (approved design): slugs are stable,
/// service ids rot — never hardcode those.
const annyRooms = <({String section, String slug})>[
  (section: 'seats', slug: '1-lehrbuchsammlung-eg-und-1-og'),
  (section: 'seats', slug: '2-lesesaal-naturwissenschaften-2-og-und-empore'),
  (
    section: 'seats',
    slug: '2-lesesaal-naturwissenschaften-2-og-und-empore-kopie-nnlimpvbvg'
  ),
  (section: 'seats', slug: 'lesesaal-medienzentrum-vk0dz5dkh9'),
  (section: 'groups', slug: 'gruppenraume-kit-bibliothek-sud'),
  (section: 'groups', slug: 'gruppenraume-informatikom-ezitnsnlmv'),
  (section: 'groups', slug: 'beratungsbox-bwpevfbngt'),
  (section: 'groups', slug: 'hka'),
];

class AnnyError implements Exception {
  AnnyError(this.status, this.detail);

  /// 0 = client-side problem, no HTTP status involved.
  final int status;

  /// server detail (errors[0]) — never contains credentials or tokens.
  final String detail;

  @override
  String toString() => 'AnnyError($status): $detail';
}

class AnnyUnauthorized extends AnnyError {
  AnnyUnauthorized() : super(401, 'login required');
}

class AnnyRateLimited extends AnnyError {
  AnnyRateLimited(this.retryAfterSec) : super(429, 'rate limited');

  final int retryAfterSec;

  @override
  String toString() => 'AnnyRateLimited: retry in ${retryAfterSec}s';
}

/// JSON:API client: mandatory headers, error dialect, and the client-side
/// guard of the plan (never >4 identical requests per second).
class AnnyHttp {
  AnnyHttp({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  /// ring of recent identical requests: hash → send timestamps (≤4 kept).
  final Map<int, List<DateTime>> _ring = {};
  final Map<String, String> _resourceIds = {};

  static const _ua =
      'Mozilla/5.0 (X11; Linux x86_64; rv:132.0) Gecko/20100101 Firefox/132.0';

  Future<Map<String, dynamic>> get(String path,
          {Map<String, String>? q, String? bearer}) =>
      _send('GET', path, q: q, bearer: bearer);

  Future<Map<String, dynamic>> post(String path, Object? body,
          {Map<String, String>? q, String? bearer}) =>
      _send('POST', path, q: q, bearer: bearer, body: body);

  Uri uri(String path, [Map<String, String>? q]) => Uri.parse(
          '$_apiBase/${path.startsWith("/") ? path.substring(1) : path}')
      .replace(queryParameters: q == null || q.isEmpty ? null : q);

  Map<String, String> headers(String? bearer, {bool withBody = false}) => {
        'accept': 'application/vnd.api+json',
        if (withBody) 'content-type': 'application/vnd.api+json',
        'x-app-key': 'anny_shop',
        'user-agent': _ua,
        if (bearer != null) 'authorization': 'Bearer $bearer',
      };

  Future<Map<String, dynamic>> _send(String method, String path,
      {Map<String, String>? q, String? bearer, Object? body}) async {
    final u = uri(path, q);
    final payload = body == null ? null : jsonEncode(body);
    _guard(method, u, payload);
    final req = http.Request(method, u);
    req.headers.addAll(headers(bearer, withBody: payload != null));
    if (payload != null) req.body = payload;
    final r = await http.Response.fromStream(await _client.send(req));
    Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(r.bodyBytes));
    } on Object catch (_) {}
    final json = decoded is Map<String, dynamic> ? decoded : const <String, dynamic>{};
    if (r.statusCode == 401) throw AnnyUnauthorized();
    if (r.statusCode == 429) throw AnnyRateLimited(_retryAfter(r.headers['retry-after']));
    if (r.statusCode >= 400) throw AnnyError(r.statusCode, _detail(r.body, json));
    return json;
  }

  /// never more than 4 identical requests per second (plan: rate discipline)
  void _guard(String method, Uri u, String? body) {
    final now = DateTime.now();
    final key = Object.hash(method, u.toString(), body ?? '');
    final ring = _ring[key] ??= <DateTime>[];
    ring.removeWhere((DateTime t) => now.difference(t).inMilliseconds >= 1000);
    if (ring.length >= 4) throw AnnyRateLimited(1);
    ring.add(now);
    if (_ring.length > 128) _ring.remove(_ring.keys.first);
  }

  static int _retryAfter(String? h) {
    final secs = int.tryParse(h ?? '');
    if (secs != null) return secs < 0 ? 1 : secs;
    final date = DateTime.tryParse(h ?? ''); // Retry-After may be an HTTP date
    if (date != null) {
      final s = date.difference(DateTime.now()).inSeconds;
      if (s > 0) return s;
    }
    return 5;
  }

  static String _detail(String raw, Map<String, dynamic> json) {
    final errs = json['errors'];
    if (errs is List && errs.isNotEmpty && errs.first is Map) {
      final e = errs.first as Map;
      final d = e['detail'] ?? e['title'] ?? e['code'];
      if (d != null) return '$d';
    }
    return raw.length > 160 ? raw.substring(0, 160) : raw;
  }

  /// numeric resource id for a slug (captured calls key on `resource_id`;
  /// numeric ids pass through, slugs are resolved once and cached).
  Future<String> resourceIdOf(String slugOrId) async {
    if (RegExp(r'^\d+$').hasMatch(slugOrId)) return slugOrId;
    final cached = _resourceIds[slugOrId];
    if (cached != null) return cached;
    final json = await get('resources/$slugOrId', q: const {'include': 'services'});
    final id = _asStr((json['data'] as Map?)?['id']);
    if (id.isEmpty) throw AnnyError(0, 'no resource id for $slugOrId');
    return _resourceIds[slugOrId] = id;
  }

  void dispose() => _client.close();
}

class AnnyRoom {
  const AnnyRoom({
    this.id = '',
    this.slug = '',
    this.name = '',
    this.section = 'seats',
    this.color = '',
    this.quantity = 0,
    this.serviceId = 0,
    this.minDuration = 0,
    this.maxDuration = 0,
    this.interval = 0,
    this.advanceDays = 0,
    this.cancelMinutesBefore = 0,
    this.openFrom = '',
    this.openTo = '',
  });

  final String id, slug, name, section, color;
  final int quantity, serviceId;

  /// durations in minutes; [advanceDays] = booking horizon,
  /// [cancelMinutesBefore] = cancellation deadline before start (cancel meta)
  final int minDuration, maxDuration, interval, advanceDays, cancelMinutesBefore;
  final String openFrom, openTo;
}

class AnnySlot {
  const AnnySlot({required this.start, required this.free, this.unavailability = ''});

  /// Berlin wall time
  final DateTime start;

  /// number_available (fallback: remaining_number_available, quota)
  final int free;

  /// '' when bookable, else the server reason e.g. 'before_lead_time'
  final String unavailability;

  bool get available => unavailability.isEmpty;
}

class AnnyBooking {
  const AnnyBooking({
    required this.id,
    required this.number,
    required this.status,
    required this.start,
    required this.end,
    this.resource = '',
    this.code = '',
    this.cancelUntil,
  });

  final String id, number, status;

  /// Berlin wall times
  final DateTime start, end;

  final String resource;

  /// '!TIX…' = the access_token cancelBooking needs
  final String code;

  final DateTime? cancelUntil;

  bool get isActive =>
      const {'pending', 'reserved', 'accepted', 'confirmed'}.contains(status);
}

/// The KIT-Bibliothek rooms: one anonymous all-resources call; per-slug
/// `resources/{slug}?include=services` fallback (sequential — rate discipline).
Future<List<AnnyRoom>> fetchRooms(AnnyHttp h) async {
  final services = <int, Map<String, Object?>>{};
  final rooms = <String, AnnyRoom>{};
  void absorb(Map<String, dynamic> json) {
    for (final s in ((json['included'] as List?) ?? const []).whereType<Map>()) {
      if (_asStr(s['type']).contains('service')) {
        services[_asInt(s['id'])] = (s['attributes'] as Map?)?.cast<String, Object?>() ?? const {};
      }
    }
    final d = json['data'];
    for (final r in d is List ? d.whereType<Map>() : (d is Map ? [d] : const <Map>[])) {
      final room = _room(r.cast<String, dynamic>(), services);
      if (room.id.isNotEmpty) rooms[room.slug.isEmpty ? room.id : room.slug] = room;
    }
  }

  try {
    absorb(await h.get('communities/$_community/all-resources', q: const {
      'page[number]': '1',
      'page[size]': '14',
      'stateless': '1',
      'include': 'services',
    }));
  } on AnnyError {
    for (final c in annyRooms) {
      absorb(await h.get('resources/${c.slug}', q: const {'include': 'services'}));
    }
  }
  return <AnnyRoom>[
    for (final c in annyRooms)
      if (rooms.remove(c.slug) case final AnnyRoom r) r,
    ...rooms.values,
  ];
}

/// selectable start times for a day (GET intervals/start).
Future<List<AnnySlot>> fetchIntervals(
    AnnyHttp h, String slug, int serviceId, DateTime day) async {
  final json = await h.get('intervals/start', q: {
    'date': _dayStr(day),
    'service_id[$serviceId]': '1',
    'resource_id': await h.resourceIdOf(slug),
    'timezone': annyTimezone,
  });
  return ((json['data'] as List?) ?? const [])
      .whereType<Map>()
      .map((Map<dynamic, dynamic> e) => _slot(e.cast<String, dynamic>(), day))
      .whereType<AnnySlot>()
      .toList();
}

/// bookable dates → quota, for the day strip (GET availability/start-dates).
Future<Map<DateTime, int>> fetchBookableDays(
    AnnyHttp h, String slug, int serviceId) async {
  final now = DateTime.now();
  final from = DateTime(now.year, now.month, now.day);
  final json = await h.get('availability/start-dates', q: {
    'start_date': _dayStr(from),
    'end_date': _dayStr(from.add(const Duration(days: 60))),
    'service_id[$serviceId]': '1',
    'resource_id': await h.resourceIdOf(slug),
    'timezone': annyTimezone,
  });
  final out = <DateTime, int>{};
  for (final item in ((json['data'] as List?) ?? const []).whereType<Map>()) {
    final a = (item['attributes'] as Map?)?.cast<String, Object?>() ?? const <String, Object?>{};
    final d = a['date'] ?? a['start_date'] ?? item['id'];
    if (d == null) continue;
    try {
      final dt = DateTime.parse('$d');
      final q = a['quota'] ?? a['available'];
      out[DateTime(dt.year, dt.month, dt.day)] = q == null ? 1 : _asInt(q);
    } on FormatException catch (_) {}
  }
  return out;
}

/// seats free right now: remaining/quota of the first available interval.
Future<int> freeNow(AnnyHttp h, String slug, int serviceId) async {
  final slots = await fetchIntervals(h, slug, serviceId, DateTime.now());
  return _first(slots.where((AnnySlot s) => s.available))?.free ?? 0;
}

/// cart draft POST order/bookings. The body is byte-identical to the live
/// capture — the server is picky about `add_ons_by_service` & friends.
Future<({String oid, String oat, String bookingId, String number})> cartAdd(
  AnnyHttp h,
  String bearer, {
  required String childResourceId,
  required int serviceId,
  required DateTime start,
  required DateTime end,
}) async {
  final json = await h.post('order/bookings', {
    'resource_id': [childResourceId],
    'service_id': {'$serviceId': 1},
    'timeslot_series_id': null,
    'start_date': _isoBerlin(start),
    'end_date': _isoBerlin(end),
    'description': '',
    'customer_note': '',
    'add_ons_by_service': {'$serviceId': [[]]},
    'sub_bookings_by_service': {},
    'strategy': 'multi-resource',
    'prevent_applying_default_quota': false,
  }, q: const {
    'include': 'bookings,bookings.resource,bookings.service,resource,service,customer-account',
    'stateless': '1',
  }, bearer: bearer);
  final data = json['data'];
  return (
    oid: _asStr(data is Map ? data['id'] : null),
    oat: _asStr(data is Map ? (data['attributes'] as Map?)?['access_token'] : null),
    bookingId: _bookingId(json),
    number: _bookingNumber(json),
  );
}

/// confirm the cart (POST order?oid&oat). Returns the `BB…` booking number.
Future<String> cartCheckout(
  AnnyHttp h,
  String bearer, {
  required String oid,
  required String oat,
  required String givenName,
  required String familyName,
  required String email,
  required String visitToken,
}) async {
  final json = await h.post('order', {
    'customer': {
      'given_name': givenName,
      'family_name': familyName,
      'email': email,
    },
    'accept_terms': true,
    'payment_method': '',
    'success_url': 'https://anny.eu/',
    'cancel_url': 'https://anny.eu/',
    'meta': {'timezone': annyTimezone},
  }, q: {
    'visit_token': visitToken,
    'oid': oid,
    'oat': oat,
    'stateless': '1',
  }, bearer: bearer);
  return _bookingNumber(json);
}

/// drop a failed/expired cart — releases the quota lock (capture lesson).
Future<void> cartDeleteAll(
  AnnyHttp h,
  String bearer, {
  required String oid,
  required String oat,
}) async {
  await h.get('order/bookings/delete-all',
      q: {'stateless': '1', 'oid': oid, 'oat': oat}, bearer: bearer);
}

/// ids of FREE child desks for a window (server already filtered via
/// availability_exact_match); on parse doubt: all ids sorted by name.
Future<List<String>> childSeats(
  AnnyHttp h,
  String slug, {
  required DateTime from,
  required DateTime to,
  required int serviceId,
}) async {
  final json = await h.get('resources/$slug/children', q: {
    'page[size]': '250',
    'filter[available_from]': _isoBerlin(from),
    'filter[available_to]': _isoBerlin(to),
    'filter[availability_exact_match]': '1',
    'filter[availability_service_id]': '$serviceId',
    'filter[exclude_child_resources]': '0',
  });
  final picked = <String>[];
  final all = <({String id, String name})>[];
  var unknown = 0;
  for (final r in ((json['data'] as List?) ?? const []).whereType<Map>()) {
    try {
      final id = _asStr(r['id']);
      if (id.isEmpty) continue;
      final a = (r['attributes'] as Map?) ?? const <dynamic, dynamic>{};
      all.add((id: id, name: _asStr(a['name'])));
      final av = (r['meta'] as Map?)?['resource_availability_result'] ??
          a['resource_availability_result'];
      switch (_freeState(av)) {
        case true:
          picked.add(id);
        case false:
          break;
        default:
          unknown++;
      }
    } on Object catch (_) {
      unknown++;
    }
  }
  if (picked.isEmpty && unknown > 0) {
    // server already filtered availability_exact_match — trust it
    all.sort((({String id, String name}) a, ({String id, String name}) b) => a.name.compareTo(b.name));
    return all.map((({String id, String name}) r) => r.id).toList();
  }
  return picked;
}

/// the captured cancel route: GET with the booking access code
/// (PATCH status → 401, POST → 405; THIS is the way).
Future<void> cancelBooking(
  AnnyHttp h,
  String bearer, {
  required String bookingId,
  required String accessToken,
}) async {
  await h.get('bookings/$bookingId/cancel',
      q: {'access_token': accessToken}, bearer: bearer);
}

/// upcoming bookings: GET bookings?filter[upcoming_only]=1 (capture); if
/// that fails, the authed all-resources variant of the account.
Future<List<AnnyBooking>> myBookings(
    AnnyHttp h, String bearer, String accountUuid) async {
  late Map<String, dynamic> json;
  try {
    json = await h.get('bookings',
        q: const {'filter[upcoming_only]': '1'}, bearer: bearer);
  } on AnnyError {
    json = await h.get('customer-accounts/$accountUuid/all-resources',
        q: const {'page[number]': '1', 'page[size]': '25'}, bearer: bearer);
  }
  final names = <String, String>{};
  for (final i in ((json['included'] as List?) ?? const []).whereType<Map>()) {
    if (_asStr(i['type']) == 'resources') {
      names[_asStr(i['id'])] = _asStr(((i['attributes'] as Map?)?['name']));
    }
  }
  final out = <AnnyBooking>[];
  for (final b in ((json['data'] as List?) ?? const []).whereType<Map>()) {
    final a = (b['attributes'] as Map?)?.cast<String, Object?>() ?? const <String, Object?>{};
    final st = _asStr(a['status']);
    if (st == 'canceled' || st == 'expired') continue;
    try {
      final rid = _asStr(
          (((b['relationships'] as Map?)?['resource'] as Map?)?['data'] as Map?)?['id']);
      out.add(AnnyBooking(
        id: _asStr(b['id']),
        number: _asStr(a['number']),
        status: st,
        start: _wall(DateTime.parse('${a['start_date'] ?? a['start']}')),
        end: _wall(DateTime.parse('${a['end_date'] ?? a['end'] ?? a['start_date']}')),
        resource: names[rid] ?? '',
        code: _asStr(a['code'] ?? a['access_token']),
        cancelUntil: a['cancelable_until'] == null
            ? null
            : _wall(DateTime.parse('${a['cancelable_until']}')),
      ));
    } on FormatException catch (_) {}
  }
  out.sort((AnnyBooking x, AnnyBooking y) => x.start.compareTo(y.start));
  return out;
}

// ---------------------------------------------------------------- parsing --

AnnyRoom _room(Map<String, dynamic> res, Map<int, Map<String, Object?>> services) {
  final a = res['attributes'] as Map? ?? const <dynamic, dynamic>{};
  var sid = 0;
  var sa = const <String, Object?>{};
  final rel = ((res['relationships'] as Map?)?['services'] as Map?)?['data'];
  final ref = rel is List && rel.isNotEmpty ? rel.first : rel;
  if (ref is Map) {
    sid = _asInt(ref['id']);
    sa = services[sid] ?? const {};
  } else {
    final emb = _first((a['services'] as List?)?.whereType<Map>() ?? const []);
    if (emb != null) {
      sid = _asInt(emb['id']);
      sa = (emb['attributes'] as Map?)?.cast<String, Object?>() ?? const {};
    }
  }
  final slug = _asStr(a['slug']);
  final adv = _asInt(sa['advance_booking_period']);
  final advUnit = _asStr(sa['advance_booking_period_type']);
  return AnnyRoom(
    id: _asStr(res['id']),
    slug: slug,
    name: _asStr(a['name']),
    section: _sectionOf(slug),
    color: a['color_map'] is Map
        ? _asStr((a['color_map'] as Map)['color'] ??
            (a['color_map'] as Map)['fill'] ??
            (a['color_map'] as Map)['hex'])
        : _asStr(a['color_map'] ?? a['color']),
    quantity: _asInt(a['quantity']),
    serviceId: sid,
    minDuration: _asInt(sa['min_duration'] ?? sa['minimum_duration']),
    maxDuration: _asInt(sa['max_duration'] ?? sa['maximum_duration']),
    interval: _asInt(sa['booking_interval'] ?? sa['interval']),
    advanceDays: advUnit.startsWith('hour') ? (adv + 23) ~/ 24 : adv,
    cancelMinutesBefore: _toMinutes(
        _asInt(sa['cancellation_period'] ?? a['cancellation_period']),
        _asStr(sa['cancellation_period_type'] ?? a['cancellation_period_type'])),
    openFrom: _asStr(a['open_from']),
    openTo: _asStr(a['open_to']),
  );
}

AnnySlot? _slot(Map<String, dynamic> item, DateTime day) {
  final a = item['attributes'] as Map?;
  if (a == null) return null;
  final t = a['start_time'] ?? a['time'] ?? a['start'] ?? a['start_date'] ?? item['id'];
  if (t == null) return null;
  final s = '$t';
  try {
    final DateTime start;
    if (RegExp(r'^\d{1,2}:\d{2}$').hasMatch(s)) {
      start = DateTime(day.year, day.month, day.day,
          int.parse(s.substring(0, s.length - 3)), int.parse(s.substring(s.length - 2)));
    } else {
      start = _wall(DateTime.parse(s));
    }
    final raw = a['unavailability_type'] ?? a['unavailability'];
    final un = raw is String ? raw : (raw == true ? 'unavailable' : '');
    return AnnySlot(
      start: start,
      free: _asInt(a['number_available'] ?? a['remaining_number_available'] ?? a['quota']),
      unavailability: un == 'available' ? '' : un,
    );
  } on FormatException catch (_) {
    return null;
  }
}

bool? _freeState(Object? av) {
  if (av is! Map) return null;
  final res = av['available'];
  if (res is bool) return res;
  final sar = av['serviceAvailabilityResults'];
  if (sar is List && sar.isNotEmpty) {
    return sar.whereType<Map>().any((Map<dynamic, dynamic> s) {
      final u = s['unavailability_type'];
      return u == null || u == false || u == '' || u == 'available';
    });
  }
  return null;
}

String _bookingId(Map<String, dynamic> json) {
  for (final b in ((json['included'] as List?) ?? const []).whereType<Map>()) {
    if (_asStr(b['type']).contains('booking')) return _asStr(b['id']);
  }
  return '';
}

/// the order draft carries the sub-order number (digits) in data[], the real
/// `BB…` number in the included booking — prefer BB (as the capture shows).
String _bookingNumber(Map<String, dynamic> json) {
  String? any;
  for (final b in ((json['included'] as List?) ?? const []).whereType<Map>()) {
    if (!_asStr(b['type']).contains('booking')) continue;
    final n = _asStr((b['attributes'] as Map?)?['number']);
    if (n.startsWith('BB')) return n;
    if (n.isNotEmpty) any ??= n;
  }
  final d = json['data'];
  final sub = d is List && d.isNotEmpty && d.first is Map
      ? _asStr(((d.first as Map)['attributes'] as Map?)?['number'])
      : (d is Map ? _asStr((d['attributes'] as Map?)?['number']) : '');
  return any ?? sub;
}

// ------------------------------------------------------------------ time --

String _two(int v) => v.toString().padLeft(2, '0');

/// ISO with explicit Berlin offset (EU DST: last Sun Mar→Oct, 01:00Z).
/// Non-UTC DateTimes are treated as Berlin wall time; UTC ones converted.
String _isoBerlin(DateTime d) {
  final utc =
      d.isUtc ? d : DateTime.utc(d.year, d.month, d.day, d.hour, d.minute, d.second);
  int lastSun(int mo) {
    final last = DateTime.utc(utc.year, mo + 1, 0);
    return last.day - (last.weekday % 7);
  }

  final dst = utc.isAfter(DateTime.utc(utc.year, 3, lastSun(3), 1)) &&
      utc.isBefore(DateTime.utc(utc.year, 10, lastSun(10), 1));
  final off = dst ? 2 : 1;
  final loc = utc.add(Duration(hours: off));
  return '${loc.year}-${_two(loc.month)}-${_two(loc.day)}'
      'T${_two(loc.hour)}:${_two(loc.minute)}:${_two(loc.second)}+0$off:00';
}

/// Berlin wall time (plain local DateTime) of any parsed instant.
DateTime _wall(DateTime instant) {
  final s = _isoBerlin(instant.isUtc ? instant : instant.toUtc());
  return DateTime(
      int.parse(s.substring(0, 4)),
      int.parse(s.substring(5, 7)),
      int.parse(s.substring(8, 10)),
      int.parse(s.substring(11, 13)),
      int.parse(s.substring(14, 16)),
      int.parse(s.substring(17, 19)));
}

String _dayStr(DateTime d) => '${d.year}-${_two(d.month)}-${_two(d.day)}';

// ----------------------------------------------------------------- misc --

int _asInt(Object? v) => v is int ? v : int.tryParse(v?.toString() ?? '') ?? 0;

String _asStr(Object? v) => v?.toString() ?? '';

int _toMinutes(int v, String unit) => unit.startsWith('hour')
    ? v * 60
    : (unit.startsWith('day') ? v * 1440 : v);

T? _first<T>(Iterable<T> xs) => xs.isEmpty ? null : xs.first;

String _sectionOf(String slug) {
  for (final c in annyRooms) {
    if (c.slug == slug) return c.section;
  }
  return 'seats';
}
