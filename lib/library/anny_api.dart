import 'dart:convert';
import 'package:http/http.dart' as http;

/// KIT-Bibliothek seat booking — pure JSON:API client for b.anny.eu (no Flutter
/// imports). Shapes follow the live capture `audit/anny_api.md` 1:1 (docs.anny.co
/// variants that differ lose); NEVER log requests — headers carry Bearer JWTs.
const _apiBase = 'https://b.anny.eu/api/v1';
const _community = 'kit-bibliothek-OTNRQaXc';
const annyTimezone = 'Europe/Berlin'; // serialization carries explicit offsets

/// hardcoded public room catalog: slugs are stable, service ids rot
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
  final int status; // 0 = client-side problem, no HTTP status involved
  final String detail; // errors[0] detail — never credentials or tokens
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

/// JSON:API client: mandatory headers, error dialect, 4-identical-req/s guard
class AnnyHttp {
  AnnyHttp({http.Client? client}) : _client = client ?? http.Client();
  final http.Client _client;
  final Map<int, List<DateTime>> _ring = {}; // hash → recent send times
  final Map<String, String> _resourceIds = {};
  static const _ua =
      'Mozilla/5.0 (X11; Linux x86_64; rv:132.0) Gecko/20100101 Firefox/132.0';
  Future<Map<String, dynamic>> get(String path,
          {Map<String, String>? q, String? bearer}) =>
      _send('GET', path, q: q, bearer: bearer);
  Future<Map<String, dynamic>> post(String path, Object? body,
          {Map<String, String>? q, String? bearer}) =>
      _send('POST', path, q: q, bearer: bearer, body: body);
  Uri uri(String path, [Map<String, String>? q]) =>
      Uri.parse('$_apiBase/${path.startsWith("/") ? path.substring(1) : path}')
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
    final req = http.Request(method, u)
      ..headers.addAll(headers(bearer, withBody: payload != null));
    if (payload != null) req.body = payload;
    final r = await http.Response.fromStream(await _client.send(req));
    Map<String, dynamic> json = const {};
    Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(r.bodyBytes));
      if (decoded is Map<String, dynamic>) json = decoded;
    } on Object catch (_) {}
    if (r.statusCode == 401) throw AnnyUnauthorized();
    if (r.statusCode == 429)
      throw AnnyRateLimited(_retryAfter(r.headers['retry-after']));
    if (r.statusCode >= 400)
      throw AnnyError(r.statusCode, _detail(r.body, json));
    // live endpoints answering a BARE JSON array instead of a JSON:API
    // document (intervals/start + availability/start-dates, verified
    // against b.anny.eu 2026-11-12) stay reachable via itemsOf
    if (decoded is List) return {'_rawArray': decoded};
    return json;
  }

  /// items of an endpoint that may answer {data:[…]} OR a bare array
  static List itemsOf(Map<String, dynamic> json) =>
      (json['_rawArray'] as List?) ?? (json['data'] as List?) ?? const [];
  void _guard(String method, Uri u, String? body) {
    // rate discipline
    final now = DateTime.now();
    final ring =
        _ring[Object.hash(method, u.toString(), body ?? '')] ??= <DateTime>[];
    ring.removeWhere((t) => now.difference(t).inMilliseconds >= 1000);
    if (ring.length >= 4) throw AnnyRateLimited(1); // ≤4 identical reqs/second
    ring.add(now);
    if (_ring.length > 128) _ring.remove(_ring.keys.first);
  }

  static int _retryAfter(String? h) {
    final secs = int.tryParse(h ?? '');
    if (secs != null) return secs < 0 ? 1 : secs;
    final d = DateTime.tryParse(h ?? ''); // Retry-After may be an HTTP date
    return d != null && d.isAfter(DateTime.now())
        ? d.difference(DateTime.now()).inSeconds
        : 5;
  }

  static String _detail(String raw, Map<String, dynamic> json) {
    final errs = json['errors'];
    if (errs is List && errs.isNotEmpty && errs.first is Map) {
      final e = errs.first as Map;
      if (e['detail'] != null)
        return '${e['detail']}';
      else if (e['title'] != null) return '${e['title']}';
    }
    return raw.length > 160 ? raw.substring(0, 160) : raw;
  }

  /// numeric resource id for a slug (capture keys on resource_id; slugs resolve
  /// once via resources/{slug}?include=services and are cached)
  Future<String> resourceIdOf(String slugOrId) async {
    if (RegExp(r'^\d+$').hasMatch(slugOrId)) return slugOrId;
    final cached = _resourceIds[slugOrId];
    if (cached != null) return cached;
    final json =
        await get('resources/$slugOrId', q: const {'include': 'services'});
    final id = _asStr((json['data'] as Map?)?['id']);
    if (id.isEmpty) throw AnnyError(0, 'no resource id for $slugOrId');
    return _resourceIds[slugOrId] = id;
  }
}

class AnnyRoom {
  const AnnyRoom(
      {this.id = '',
      this.slug = '',
      this.name = '',
      this.color = '',
      this.quantity = 0,
      this.serviceId = 0,
      this.minDuration = 0,
      this.maxDuration = 0,
      this.interval = 0,
      this.advanceDays = 0,
      this.cancelMinutesBefore = 0,
      this.openFrom = '',
      this.openTo = ''});
  final String id, slug, name, color, openFrom, openTo;
  final int quantity, serviceId, minDuration, maxDuration, interval;
  // durations in minutes; advanceDays = booking horizon; cancelMinutesBefore
  // = cancellation deadline before start (cancel meta)
  final int advanceDays, cancelMinutesBefore;
  String get section => _sectionOf(slug);
}

class AnnySlot {
  const AnnySlot(
      {required this.start, required this.free, this.unavailability = ''});
  final DateTime start; // Berlin wall time
  final int free;
  final String unavailability; // fb remaining/quota; '' bookable
  bool get available => unavailability.isEmpty;
}

class AnnyBooking {
  const AnnyBooking(
      {required this.id,
      required this.number,
      required this.status,
      required this.start,
      required this.end,
      this.resource = '',
      this.code = '',
      this.cancelUntil});
  final String id, number, status, resource;
  final DateTime start, end; // Berlin wall times
  final String code;
  final DateTime? cancelUntil; // code = cancel access token
  bool get isActive =>
      const {'pending', 'reserved', 'accepted', 'confirmed'}.contains(status);
}

/// rooms: one anonymous all-resources call, per-slug include=services fallback
Future<List<AnnyRoom>> fetchRooms(AnnyHttp h) async {
  final services = <int, Map<String, Object?>>{}, rooms = <String, AnnyRoom>{};
  void absorb(Map<String, dynamic> json) {
    for (final s
        in ((json['included'] as List?) ?? const []).whereType<Map>()) {
      if (_asStr(s['type']).contains('service')) {
        services[_asInt(s['id'])] =
            (s['attributes'] as Map?)?.cast<String, Object?>() ?? const {};
      }
    }
    final d = json['data'];
    for (final r
        in d is List ? d.whereType<Map>() : (d is Map ? [d] : const <Map>[])) {
      final room = _room(r.cast<String, dynamic>(), services);
      if (room.id.isNotEmpty)
        rooms[room.slug.isEmpty ? room.id : room.slug] = room;
    }
  }

  try {
    absorb(await h.get('communities/$_community/all-resources', q: const {
      'page[number]': '1',
      'page[size]': '14',
      'stateless': '1',
      'include': 'services'
    }));
  } on AnnyError {
    for (final c in annyRooms) {
      absorb(
          await h.get('resources/${c.slug}', q: const {'include': 'services'}));
    }
  }
  return <AnnyRoom>[
    for (final c in annyRooms)
      if (rooms.remove(c.slug) case final AnnyRoom r) r,
    ...rooms.values,
  ];
}

/// selectable start times for a day (GET intervals/start)
Future<List<AnnySlot>> fetchIntervals(
    AnnyHttp h, String slug, int serviceId, DateTime day) async {
  final json = await h.get('intervals/start', q: {
    'date': _dayStr(day),
    'service_id[$serviceId]': '1',
    'resource_id': await h.resourceIdOf(slug),
    'timezone': annyTimezone,
  });
  return itemsOfRaw(json)
      .map((e) => _slot(e.cast<String, dynamic>(), day))
      .whereType<AnnySlot>()
      .toList();
}

/// bookable dates → quota, for the day strip (GET availability/start-dates)
Future<Map<DateTime, int>> fetchBookableDays(
    AnnyHttp h, String slug, int serviceId) async {
  final now = DateTime.now(), from = DateTime(now.year, now.month, now.day);
  final json = await h.get('availability/start-dates', q: {
    'start_date': _dayStr(from),
    'end_date': _dayStr(from.add(const Duration(days: 60))),
    'service_id[$serviceId]': '1',
    'resource_id': await h.resourceIdOf(slug),
    'timezone': annyTimezone,
  });
  final out = <DateTime, int>{};
  // live: bare array of flat {date, available, unavailability_type} -
  // NO quota field (verified 2026-11-12)
  for (final item in itemsOfRaw(json)) {
    final a = (item['attributes'] as Map?)?.cast<String, Object?>() ?? item;
    final dt = _parseT(a['date'] ?? a['start_date'] ?? item['id'], true);
    if (dt == null) continue;
    final un = a['unavailability_type'];
    final av = a['available'];
    final blocked =
        (un is String && un.isNotEmpty && un != 'none' && un != 'available') ||
            av == false;
    final q = a['quota'];
    out[dt] = blocked ? 0 : (q is int ? q : (av == true ? 1 : 0));
  }
  return out;
}

List<Map> itemsOfRaw(Map<String, dynamic> json) =>
    AnnyHttp.itemsOf(json).whereType<Map>().toList();

/// seats free right now: the interval tile covering "now" (contiguous
/// tiles verified live; library-closed windows legitimately mean 0)
Future<int> freeNow(AnnyHttp h, String slug, int serviceId) async {
  final now = DateTime.now();
  final slots = await fetchIntervals(h, slug, serviceId, now);
  for (var i = 0; i < slots.length; i++) {
    if (slots[i].start.isAfter(now)) {
      if (i == 0) return 0; // opens later: nothing running right now
      final covering = slots[i - 1];
      return covering.available && !now.isBefore(covering.start)
          ? covering.free
          : 0;
    }
  }
  return 0; // whole day behind us
}

/// cart draft POST order/bookings — body byte-identical to the live capture
Future<({String oid, String oat, String bookingId, String number})> cartAdd(
    AnnyHttp h, String bearer,
    {required String childResourceId,
    required int serviceId,
    required DateTime start,
    required DateTime end}) async {
  final json = await h.post(
      'order/bookings',
      {
        'resource_id': [childResourceId],
        'service_id': {'$serviceId': 1},
        'timeslot_series_id': null,
        'start_date': _isoBerlin(start),
        'end_date': _isoBerlin(end),
        'description': '',
        'customer_note': '',
        'add_ons_by_service': {
          '$serviceId': [[]]
        },
        'sub_bookings_by_service': {},
        'strategy': 'multi-resource',
        'prevent_applying_default_quota': false,
      },
      q: const {
        'include':
            'bookings,bookings.resource,bookings.service,resource,service,customer-account',
        'stateless': '1',
      },
      bearer: bearer);
  final data = json['data'], attrs = data is Map ? data['attributes'] : null;
  final bk = _first(((json['included'] as List?) ?? const [])
      .whereType<Map>()
      .where((b) => _asStr(b['type']).contains('booking')));
  return (
    oid: _asStr(data is Map ? data['id'] : null),
    oat: _asStr(attrs is Map ? attrs['access_token'] : null),
    bookingId: bk == null ? '' : _asStr(bk['id']),
    number: _bookingNumber(json)
  );
}

/// confirm the cart (POST order?oid&oat). Returns the `BB…` booking number
Future<String> cartCheckout(AnnyHttp h, String bearer,
    {required String oid,
    required String oat,
    required String givenName,
    required String familyName,
    required String email,
    required String visitToken}) async {
  final json = await h.post(
      'order',
      {
        'customer': {
          'given_name': givenName,
          'family_name': familyName,
          'email': email
        },
        'accept_terms': true,
        'payment_method': '',
        'success_url': 'https://anny.eu/',
        'cancel_url': 'https://anny.eu/',
        'meta': {'timezone': annyTimezone},
      },
      q: {'visit_token': visitToken, 'oid': oid, 'oat': oat, 'stateless': '1'},
      bearer: bearer);
  return _bookingNumber(json);
}

/// drop a failed/expired cart — releases the quota lock (capture lesson)
Future<void> cartDeleteAll(AnnyHttp h, String bearer,
    {required String oid, required String oat}) async {
  await h.get('order/bookings/delete-all',
      q: {'stateless': '1', 'oid': oid, 'oat': oat}, bearer: bearer);
}

/// FREE child desks (server filtered exact_match); parse doubt → all ids by name
Future<List<String>> childSeats(AnnyHttp h, String slug,
    {required DateTime from,
    required DateTime to,
    required int serviceId}) async {
  final json = await h.get('resources/$slug/children', q: {
    'page[size]': '250',
    'filter[available_from]': _isoBerlin(from),
    'filter[available_to]': _isoBerlin(to),
    'filter[availability_exact_match]': '1',
    'filter[availability_service_id]': '$serviceId',
    'filter[exclude_child_resources]': '0',
  });
  final picked = <String>[], all = <String, String>{}; // all: id → name
  var unknown = 0;
  for (final r in ((json['data'] as List?) ?? const []).whereType<Map>()) {
    try {
      final id = _asStr(r['id']),
          a = (r['attributes'] as Map?) ?? const <dynamic, dynamic>{};
      if (id.isEmpty) continue;
      all[id] = _asStr(a['name']);
      final fs = _freeState(
          (r['meta'] as Map?)?['resource_availability_result'] ??
              a['resource_availability_result']);
      if (fs == true)
        picked.add(id);
      else if (fs == null) unknown++;
    } on Object catch (_) {
      unknown++;
    }
  }
  // availability info unparsable anywhere → trust the exact_match filter:
  if (picked.isEmpty && unknown > 0) {
    return all.keys.toList()..sort((a, b) => all[a]!.compareTo(all[b]!));
  }
  return picked;
}

/// cancel as captured: GET bookings/{id}/cancel?access_token=CODE (only way)
Future<void> cancelBooking(AnnyHttp h, String bearer,
    {required String bookingId, required String accessToken}) async {
  await h.get('bookings/$bookingId/cancel',
      q: {'access_token': accessToken}, bearer: bearer);
}

/// upcoming: GET bookings?filter[upcoming_only]=1 (capture, Bearer-scoped)
Future<List<AnnyBooking>> myBookings(
    AnnyHttp h, String bearer, String accountUuid) async {
  final json = await h.get('bookings',
      q: const {'filter[upcoming_only]': '1'}, bearer: bearer);
  final names = <String, String>{};
  for (final i in ((json['included'] as List?) ?? const []).whereType<Map>()) {
    if (_asStr(i['type']) == 'resources')
      names[_asStr(i['id'])] = _asStr((i['attributes'] as Map?)?['name']);
  }
  final out = <AnnyBooking>[];
  for (final b in ((json['data'] as List?) ?? const []).whereType<Map>()) {
    final a = (b['attributes'] as Map?)?.cast<String, Object?>() ?? const {};
    final st = _asStr(a['status']);
    if (st == 'canceled' || st == 'expired') continue;
    final start = _parseT(a['start_date'] ?? a['start']);
    if (start == null) continue;
    final rid = _asStr((((b['relationships'] as Map?)?['resource']
        as Map?)?['data'] as Map?)?['id']);
    out.add(AnnyBooking(
      id: _asStr(b['id']),
      number: _asStr(a['number']),
      status: st,
      start: start,
      end: _parseT(a['end_date'] ?? a['end'] ?? a['start_date']) ?? start,
      resource: names[rid] ?? '',
      code: _asStr(a['code'] ?? a['access_token']),
      cancelUntil: _parseT(a['cancelable_until']),
    ));
  }
  out.sort((x, y) => x.start.compareTo(y.start));
  return out;
}

AnnyRoom _room(
    Map<String, dynamic> res, Map<int, Map<String, Object?>> services) {
  final a = res['attributes'] as Map? ?? const <dynamic, dynamic>{};
  var sid = 0;
  var sa = const <String, Object?>{};
  final rel = ((res['relationships'] as Map?)?['services'] as Map?)?['data'];
  final ref = rel is List && rel.isNotEmpty ? rel.first : rel;
  if (ref is Map) {
    sid = _asInt(ref['id']);
    sa = services[sid] ?? const {};
  } else {
    final emb = _first(<Map>[
      ...?((a['services'] as List?)?.whereType<Map>()),
    ]);
    sid = _asInt(emb?['id']);
    sa = (emb?['attributes'] as Map?)?.cast<String, Object?>() ?? const {};
  }
  final adv = _asInt(sa['advance_booking_period']), cm = a['color_map'];
  return AnnyRoom(
    id: _asStr(res['id']),
    slug: _asStr(a['slug']),
    name: _asStr(a['name']),
    color: cm is Map
        ? _asStr(cm['color'] ?? cm['fill'] ?? cm['hex'])
        : _asStr(cm ?? a['color']),
    quantity: _asInt(a['quantity']),
    serviceId: sid,
    minDuration: _asInt(sa['min_duration'] ?? sa['minimum_duration']),
    maxDuration: _asInt(sa['max_duration'] ?? sa['maximum_duration']),
    interval: _asInt(sa['booking_interval'] ?? sa['interval']),
    advanceDays: _asStr(sa['advance_booking_period_type']).startsWith('hour')
        ? (adv + 23) ~/ 24
        : adv,
    cancelMinutesBefore: _toMinutes(
        _asInt(sa['cancellation_period'] ?? a['cancellation_period']),
        _asStr(
            sa['cancellation_period_type'] ?? a['cancellation_period_type'])),
    openFrom: _asStr(a['open_from']),
    openTo: _asStr(a['open_to']),
  );
}

AnnySlot? _slot(Map<String, dynamic> item, DateTime day) {
  // live items are FLAT objects (bare-array answer, verified 2026-11-12);
  // {attributes:{…}} JSON:API shape still accepted
  final a = (item['attributes'] as Map?)?.cast<String, Object?>() ?? item;
  final s =
      '${a['start_time'] ?? a['time'] ?? a['start'] ?? a['start_date'] ?? item['id']}';
  final hhmm = RegExp(r'^(\d{1,2}):(\d{2})$').firstMatch(s);
  final start = hhmm != null
      ? DateTime(day.year, day.month, day.day, int.parse(hhmm.group(1)!),
          int.parse(hhmm.group(2)!))
      : _parseT(s);
  if (start == null) return null;
  final raw = a['unavailability_type'] ?? a['unavailability'];
  final un = raw is String ? raw : (raw == true ? 'unavailable' : '');
  return AnnySlot(
      start: start,
      free: _asInt(a['number_available'] ??
          a['remaining_number_available'] ??
          a['quota']),
      // the live API marks open slots unavailability_type:'none'
      unavailability: (un == 'available' || un == 'none') ? '' : un);
}

bool? _freeState(Object? av) {
  if (av is! Map) return null;
  if (av['available'] is bool) return av['available'] as bool;
  final sar = av['serviceAvailabilityResults'];
  return sar is List && sar.isNotEmpty
      ? sar.whereType<Map>().any((s) => const {null, false, '', 'available'}
          .contains(s['unavailability_type']))
      : null;
}

/// data[] carries the sub-order number (digits), the included booking the
/// real `BB…` number — prefer BB (as the capture shows)
String _bookingNumber(Map<String, dynamic> json) {
  String? any;
  for (final b in ((json['included'] as List?) ?? const []).whereType<Map>()) {
    if (!_asStr(b['type']).contains('booking')) continue;
    final n = _asStr((b['attributes'] as Map?)?['number']);
    if (n.startsWith('BB')) return n;
    if (n.isNotEmpty) any ??= n;
  }
  final d = json['data'], first = d is List && d.isNotEmpty ? d.first : d;
  return any ??
      (first is Map ? _asStr((first['attributes'] as Map?)?['number']) : '');
}

String _two(int v) => v.toString().padLeft(2, '0');

/// EU DST offset in hours: last Sun Mar→Oct, 01:00Z
int _dstOff(DateTime utc) {
  int lastSun(int mo) {
    final l = DateTime.utc(utc.year, mo + 1, 0);
    return l.day - (l.weekday % 7);
  }

  final inDst = utc.isAfter(DateTime.utc(utc.year, 3, lastSun(3), 1)) &&
      utc.isBefore(DateTime.utc(utc.year, 10, lastSun(10), 1));
  return inDst ? 2 : 1;
}

/// ISO with explicit Berlin offset (as captured); non-UTC DateTimes are
/// treated as Berlin wall time, UTC ones converted
String _isoBerlin(DateTime d) {
  final utc = d.isUtc
      ? d
      : DateTime.utc(d.year, d.month, d.day, d.hour, d.minute, d.second);
  final off = _dstOff(utc), loc = utc.add(Duration(hours: off));
  return '${loc.year}-${_two(loc.month)}-${_two(loc.day)}'
      'T${_two(loc.hour)}:${_two(loc.minute)}:${_two(loc.second)}+0$off:00';
}

/// Berlin wall time of any parsed instant; [dayOnly] = calendar day only
DateTime? _parseT(Object? v, [bool dayOnly = false]) {
  if (v == null) return null;
  try {
    final i = DateTime.parse('$v');
    if (dayOnly) return DateTime(i.year, i.month, i.day);
    final u = i.isUtc ? i : i.toUtc(), l = u.add(Duration(hours: _dstOff(u)));
    return DateTime(l.year, l.month, l.day, l.hour, l.minute, l.second);
  } on FormatException {
    return null;
  }
}

String _dayStr(DateTime d) => '${d.year}-${_two(d.month)}-${_two(d.day)}';
int _asInt(Object? v) => v is int ? v : int.tryParse(v?.toString() ?? '') ?? 0;
String _asStr(Object? v) => v?.toString() ?? '';
T? _first<T>(Iterable<T> xs) => xs.isEmpty ? null : xs.first;
int _toMinutes(int v, String unit) =>
    unit.startsWith('hour') ? v * 60 : (unit.startsWith('day') ? v * 1440 : v);
String _sectionOf(String slug) {
  for (final c in annyRooms) {
    if (c.slug == slug) return c.section;
  }
  return 'seats';
}
