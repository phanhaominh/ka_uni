import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:kit_mobile/library/anny_api.dart';
import 'package:kit_mobile/notifications/library_notifications.dart';
import 'package:kit_mobile/library/anny_auth.dart';
import 'package:kit_mobile/state_management/kit_login_manager.dart'
    show KITLoginManager;

/// SharedPreferences keys. ANN_* deliberately, not DATA_*: the room catalog
/// and free counts are PUBLIC Anny data (survive logout on a shared device,
/// MensaKeys precedent) — while the session triple (jwt/alvo/uuid) is the
/// only personal data in prefs; the password never lives here at all, only
/// in the keychain ([AnnyKeys.pass]).
class AnnyKeys {
  AnnyKeys._();

  /// favorite room slug (card focus)
  static const fav = "ANN_fav";

  /// checkout identity prefill, editable in the confirm sheet
  static const first = "ANN_first";
  static const last = "ANN_last";

  /// derived as `<kitUser>@student.kit.edu` on sign-in
  static const email = "ANN_email";

  /// session triple — the ONLY personal data in prefs (plan privacy rule)
  static const jwt = "ANN_jwt";
  static const alvo = "ANN_alvo"; // visit token, needed by cart checkout
  static const uuid = "ANN_uuid";

  /// json {at, counts, rooms}: room catalog + free counts together
  static const rooms = "ANN_rooms";

  /// keychain key, same FlutterSecureStorage mechanism as the KIT password
  static const pass = "ANNY_pass";
}

/// How the last Anny operation failed — the card/page dialect translates
/// this into exactly one user-facing hint (mensa failure style: stale data
/// stays visible, the error never replaces it).
enum AnnyErrorKind {
  none,

  /// transport died — not a site incident, back off quietly
  offline,

  /// WAF 403 or 429 rate discipline — wait, do not hammer
  blocked,

  /// credentials/session rejected — sign in again
  auth,

  /// markup/shape change or unexpected API error — fall back to the web
  markup,
}

/// State holder + use-case orchestrator for the KIT-Bibliothek seat card
/// (mirrors MensaManager: cache-first paint, self-contained errors — a
/// throw here would be an unhandled async zone killer — single-flight, and
/// failures NEVER clear good data, only [error] flips).
///
/// The anonymous half (rooms, free counts, day slots) works without any
/// session; the authed half (bookings, book, cancel) rides the headless SSO
/// of [AnnyAuth] and re-mints an expired JWT silently while the KIT
/// password is in the keychain.
class AnnyManager extends ChangeNotifier {
  AnnyManager();

  /// the plan's 5-minute card cadence; refreshAnon inside it is a no-op
  static const anonTtl = Duration(minutes: 5);

  /// test seams (mensa `transport` precedent): stub both for hermetic tests
  @visibleForTesting
  AnnyHttp http = AnnyHttp();
  @visibleForTesting
  AnnyAuth auth = AnnyAuth();

  // keychain seams — flutter_secure_storage has no test implementation,
  // and the password path must stay stubbable without a plugin binding
  @visibleForTesting
  Future<void> Function(String password) passWrite = (String pw) => _secure
      .write(key: AnnyKeys.pass, value: pw, iOptions: _ios, aOptions: _android);
  @visibleForTesting
  Future<String?> Function() passRead = () =>
      _secure.read(key: AnnyKeys.pass, iOptions: _ios, aOptions: _android);
  @visibleForTesting
  Future<void> Function() passErase = () =>
      _secure.delete(key: AnnyKeys.pass, iOptions: _ios, aOptions: _android);

  /// identical mechanism to CredentialsProvider: same plugin, same iOS
  /// accountName — one keychain access group for both KIT passwords
  static const FlutterSecureStorage _secure = FlutterSecureStorage();
  static const IOSOptions _ios = IOSOptions(accountName: "kit-student");
  static const AndroidOptions _android = AndroidOptions();

  /// W5 plugs the check-in local notifications here; the manager itself
  /// stays notification-free (pure logic, no widget/plugin surface beyond
  /// the keychain)
  void Function(AnnyBooking booking)? onBooked;
  void Function(AnnyBooking booking)? onCanceled;

  // ---- state ----

  List<AnnyRoom> rooms = const [];

  /// room slug -> seats free right now; a FAILED freeNow never removes an
  /// entry here — only a successful fetch overwrites (freeNow==0 after a
  /// success honestly means "closed/none free")
  Map<String, int> freeCounts = const {};

  /// today's selectable starts of the favorite room (card next-free chip)
  List<AnnySlot> favSlots = const [];

  List<AnnyBooking> bookings = const [];

  AnnyErrorKind error = AnnyErrorKind.none;

  /// one-line WHY of the last failure (in-memory only: a diag belongs to
  /// the session, and the ANN_* prefs stay minimal per the privacy rule)
  String? diag;

  bool isFetching = false; // anonymous half
  bool isSigningIn = false;
  bool isLoadingBookings = false;
  bool isBooking = false; // book + cancel share the exclusive gate

  DateTime? _anonFetchedAt;
  AnnySession? _session;

  bool get signedIn => _session != null;
  bool get hasData => rooms.isNotEmpty;

  String favSlug = "";
  AnnyRoom? get favRoom => _bySlug(rooms, favSlug);

  AnnyBooking? get activeBooking {
    for (final AnnyBooking b in bookings) {
      if (b.isActive) return b;
    }
    return null;
  }

  @override
  void dispose() {
    onBooked = null;
    onCanceled = null;
    super.dispose();
  }

  // ---- boot / restore ----

  /// Load cache and paint BEFORE the network says anything; then (outside
  /// the test harness, kit_provider mensa-kick precedent) kick the
  /// ANONYMOUS refresh. The authed half never auto-fires at boot: a JWT
  /// persisted across a restart is expectedly dead, and [refreshBookings]
  /// runs on sign-in and when the page opens instead.
  Future<void> boot() async {
    try {
      final SharedPreferences p = await SharedPreferences.getInstance();
      favSlug = p.getString(AnnyKeys.fav) ?? "";
      final String? jwt = p.getString(AnnyKeys.jwt);
      if (jwt != null && jwt.isNotEmpty) {
        // obtain a persisted JWT at the epoch: older than its 1 h lifetime
        // with near-certainty, so isExpired is true and the first authed
        // call re-mints it silently via the keychain password
        _session = AnnySession(
            jwt: jwt,
            visitToken: p.getString(AnnyKeys.alvo),
            accountUuid: p.getString(AnnyKeys.uuid),
            obtainedAt: DateTime.fromMillisecondsSinceEpoch(0));
      }
      final String? raw = p.getString(AnnyKeys.rooms);
      if (raw != null) {
        final Map<String, dynamic> j = jsonDecode(raw) as Map<String, dynamic>;
        final List<AnnyRoom> rs = [
          for (final dynamic r in (j["rooms"] as List? ?? const []))
            _roomFromJson(Map<String, dynamic>.from(r as Map)),
        ];
        if (rs.isNotEmpty) {
          rooms = rs;
          freeCounts = {
            for (final dynamic e in (j["counts"] as Map? ?? const {}).entries)
              '${e.key}': (e.value as num).toInt(),
          };
          final DateTime? at = DateTime.tryParse('${j["at"]}');
          if (at != null) _anonFetchedAt = at;
        }
      }
    } catch (_) {
      // a corrupt snapshot is only a cache miss
    }
    notifyListeners();
    if (!Platform.environment.containsKey("FLUTTER_TEST")) {
      unawaited(refreshAnon());
    }
  }

  // ---- anonymous half ----

  Future<void>? _anonInFlight;

  /// Rooms + free counts (+ the favorite's day slots). Skips inside
  /// [anonTtl] unless [force]; single-flight; never throws.
  Future<void> refreshAnon({bool force = false}) {
    final Future<void>? inflight = _anonInFlight;
    if (inflight != null) return inflight;
    final Future<void> fut = _refreshAnon(force);
    _anonInFlight = fut;
    return fut.whenComplete(() {
      if (identical(_anonInFlight, fut)) _anonInFlight = null;
    });
  }

  Future<void> _refreshAnon(bool force) async {
    final DateTime now = DateTime.now();
    final DateTime? at = _anonFetchedAt;
    if (!force &&
        rooms.isNotEmpty &&
        at != null &&
        now.isAfter(at) &&
        now.difference(at) < anonTtl) {
      return;
    }
    isFetching = true;
    notifyListeners();
    try {
      final List<AnnyRoom> rs = await fetchRooms(http);
      // seed with the PREVIOUS counts of the same rooms: a freeNow that
      // fails must keep the last good number (mensa discipline) — only a
      // SUCCESSFUL fetch overwrites, and its 0 is honest ("closed")
      final Map<String, int> counts = {
        for (final AnnyRoom r in rs)
          if (freeCounts[r.slug] case final int c) r.slug: c,
      };
      for (final AnnyRoom r in rs) {
        try {
          counts[r.slug] = await freeNow(http, r.slug, r.serviceId);
        } catch (e) {
          // one dead room must not sink the card; a dead socket must
          if (KITLoginManager.isNetworkError(e)) rethrow;
          diag = "${DateTime.now().toIso8601String().substring(5, 16)} "
              "freeNow ${r.slug}: $e";
        }
      }
      rooms = rs;
      freeCounts = counts;
      _anonFetchedAt = now;
      error = AnnyErrorKind.none;
      diag = null;
      final SharedPreferences p = await SharedPreferences.getInstance();
      await p.setString(
          AnnyKeys.rooms,
          jsonEncode({
            "at": now.toIso8601String(),
            "counts": freeCounts,
            "rooms": [for (final AnnyRoom r in rs) _roomJson(r)],
          }));
    } catch (e) {
      _diag("anon: $e", _kindFromApi(e));
    }
    isFetching = false;
    // favorite's day slots ride along; their failure keeps the old strip
    final AnnyRoom? fav = favRoom;
    if (fav != null && fav.serviceId != 0) {
      try {
        favSlots =
            await fetchIntervals(http, fav.slug, fav.serviceId, DateTime.now());
      } catch (e) {
        if (KITLoginManager.isNetworkError(e)) {
          _diag("fav slots: offline", AnnyErrorKind.offline);
        }
      }
    }
    notifyListeners();
  }

  Future<void>? _favSlotsInFlight;

  /// Refresh [favSlots] for today (the card's next-free chip).
  /// Single-flight; keeps the previous strip on failure.
  Future<void> refreshFavSlots() {
    final Future<void>? inflight = _favSlotsInFlight;
    if (inflight != null) return inflight;
    late final Future<void> fut;
    fut = () async {
      final AnnyRoom? fav = favRoom;
      if (fav == null || fav.serviceId == 0) return;
      try {
        favSlots =
            await fetchIntervals(http, fav.slug, fav.serviceId, DateTime.now());
      } catch (e) {
        _diag("fav slots: $e", _kindFromApi(e));
      }
      notifyListeners();
    }();
    _favSlotsInFlight = fut;
    return fut.whenComplete(() {
      if (identical(_favSlotsInFlight, fut)) _favSlotsInFlight = null;
    });
  }

  /// Persist the favorite and repaint its strip.
  Future<void> setFav(String slug) async {
    favSlug = slug;
    notifyListeners();
    try {
      final SharedPreferences p = await SharedPreferences.getInstance();
      await p.setString(AnnyKeys.fav, slug);
    } catch (_) {}
    unawaited(refreshFavSlots());
  }

  // ---- auth half ----

  /// Headless SSO sign-in. Persists the session triple + the password to
  /// the keychain (NEVER logged), derives the KIT email, then pulls the
  /// booking list. False = failed; [error] says which flavor.
  Future<bool> signIn(String kitUser, String password) async {
    isSigningIn = true;
    notifyListeners();
    try {
      final AnnySession s =
          await auth.signIn(kitUser: kitUser, password: password);
      _session = s;
      final SharedPreferences p = await SharedPreferences.getInstance();
      await _persistSession(p, s);
      await p.setString(AnnyKeys.email, "$kitUser@student.kit.edu");
      // prefill placeholder until the confirm sheet captures real names
      if ((p.getString(AnnyKeys.first) ?? "").isEmpty) {
        await p.setString(AnnyKeys.first, kitUser);
      }
      try {
        await passWrite(password);
      } catch (_) {
        // no keychain (unit test / locked device): sign-in itself worked,
        // only the silent refresh is unavailable
        _diag("keychain write failed", AnnyErrorKind.none);
      }
      error = AnnyErrorKind.none;
      diag = null;
      notifyListeners();
      await refreshBookings();
      return true;
    } on AnnyAuthError catch (e) {
      _failAuth(e.reason, "$e");
      return false;
    } catch (e) {
      _diag(
          "signIn: $e",
          KITLoginManager.isNetworkError(e)
              ? AnnyErrorKind.offline
              : AnnyErrorKind.markup);
      return false;
    } finally {
      isSigningIn = false;
      notifyListeners();
    }
  }

  /// Forget the session, the password and the booking list (account data
  /// must not survive on a shared device); the anonymous catalog stays.
  Future<void> signOut() async {
    _session = null;
    bookings = const [];
    // rooms/freeCounts/favSlots stay: anonymous data (MensaKeys precedent)
    error = AnnyErrorKind.none;
    diag = null;
    notifyListeners();
    try {
      final SharedPreferences p = await SharedPreferences.getInstance();
      await p.remove(AnnyKeys.jwt);
      await p.remove(AnnyKeys.alvo);
      await p.remove(AnnyKeys.uuid);
    } catch (_) {}
    try {
      await passErase();
    } catch (_) {}
    // no orphan check-in ping may outlive the account that booked
    try {
      await LibraryNotifications.cancelAll();
    } catch (_) {}
  }

  /// Current non-expired JWT, silently re-minted via the keychain password
  /// when older than 50 min. Null = no usable session ([error] explains).
  Future<String?> ensureFreshSession() async {
    final AnnySession? s = _session;
    if (s == null) {
      _diag("no Anny session", AnnyErrorKind.auth);
      return null;
    }
    if (!s.isExpired) return s.jwt;
    return _silentReauth();
  }

  bool _reauthInFlight = false;

  /// ONE silent re-auth at a time, ONE attempt per request: no recursion,
  /// no loop (plan rule).
  Future<String?> _silentReauth() async {
    if (_reauthInFlight) {
      _diag("re-auth already running", AnnyErrorKind.auth);
      return null;
    }
    _reauthInFlight = true;
    try {
      final SharedPreferences p = await SharedPreferences.getInstance();
      final String email = p.getString(AnnyKeys.email) ?? "";
      final String kitUser = email.isEmpty ? "" : email.split("@").first;
      final String? pw = await _safePassRead();
      if (kitUser.isEmpty || pw == null || pw.isEmpty) {
        _diag("silent re-auth: no stored credentials", AnnyErrorKind.auth);
        return null;
      }
      try {
        final AnnySession s = await auth.signIn(kitUser: kitUser, password: pw);
        _session = s;
        await _persistSession(p, s);
        return s.jwt;
      } on AnnyAuthError catch (e) {
        _failAuth(e.reason, "$e");
        return null;
      } catch (e) {
        _diag(
            "re-auth: $e",
            KITLoginManager.isNetworkError(e)
                ? AnnyErrorKind.offline
                : AnnyErrorKind.markup);
        return null;
      }
    } finally {
      _reauthInFlight = false;
    }
  }

  Future<String?> _safePassRead() async {
    try {
      return await passRead();
    } catch (_) {
      return null; // keychain unavailable = password unavailable
    }
  }

  /// Run one Bearer call with the plan's single 401 recovery: expired ->
  /// silent re-mint, dead-anyway -> one re-auth, then surface [error].
  Future<R?> _authed<R>(Future<R> Function(String jwt) call) async {
    String? jwt = await ensureFreshSession();
    if (jwt == null) return null;
    try {
      return await call(jwt);
    } on AnnyUnauthorized {
      jwt = await _silentReauth();
      if (jwt == null) return null;
      try {
        return await call(jwt);
      } on AnnyUnauthorized {
        _diag("re-minted JWT still rejected", AnnyErrorKind.auth);
        return null;
      }
    } catch (e) {
      _diag("api: $e", _kindFromApi(e));
      return null;
    }
  }

  Future<bool>? _bookingsInFlight;

  /// Pull the upcoming bookings of the signed-in account. Never throws;
  /// keeps the previous list on failure (mensa discipline).
  Future<bool> refreshBookings() {
    final Future<bool>? inflight = _bookingsInFlight;
    if (inflight != null) return inflight;
    late final Future<bool> fut;
    fut = () async {
      if (_session == null) return false;
      isLoadingBookings = true;
      notifyListeners();
      // uuid read INSIDE the call: a silent re-auth may have delivered a
      // fresh one, and myBookings' primary route needs no uuid at all
      final List<AnnyBooking>? list = await _authed<List<AnnyBooking>>(
          (String jwt) => myBookings(http, jwt, _session?.accountUuid ?? ""));
      isLoadingBookings = false;
      if (list != null) {
        bookings = list;
        error = AnnyErrorKind.none;
        diag = null;
      }
      notifyListeners();
      return list != null;
    }();
    _bookingsInFlight = fut;
    return fut.whenComplete(() {
      if (identical(_bookingsInFlight, fut)) _bookingsInFlight = null;
    });
  }

  /// The full booking flow of the plan: free seat pick -> cart draft ->
  /// checkout; ANY failure after the draft releases the quota lock again
  /// (delete-all lesson). Returns the booking on success, null on failure
  /// ([error] set, or "just taken" = empty seats).
  Future<AnnyBooking?> book(AnnyRoom room, DateTime start, int minutes) async {
    if (isBooking) return null;
    if (room.serviceId == 0) {
      _diag("book: room ${room.slug} has no service id", AnnyErrorKind.markup);
      return null;
    }
    final id = await checkoutIdentity();
    if (id.first.isEmpty || id.last.isEmpty || id.email.isEmpty) {
      _diag("book: checkout identity incomplete", AnnyErrorKind.auth);
      return null;
    }
    isBooking = true;
    notifyListeners();
    final Map<String, String> draftCart = {}; // oid/oat while a cart may exist
    try {
      final AnnyBooking? b = await _authed<AnnyBooking?>((String jwt) async {
        final DateTime end = start.add(Duration(minutes: minutes));
        final List<String> seats = await childSeats(http, room.slug,
            from: start, to: end, serviceId: room.serviceId);
        if (seats.isEmpty) {
          _diag("book: no free seat left (just taken)", AnnyErrorKind.none);
          return null;
        }
        final draft = await cartAdd(http, jwt,
            childResourceId: seats.first,
            serviceId: room.serviceId,
            start: start,
            end: end);
        draftCart["oid"] = draft.oid;
        draftCart["oat"] = draft.oat;
        final String number;
        try {
          number = await cartCheckout(http, jwt,
              oid: draft.oid,
              oat: draft.oat,
              givenName: id.first,
              familyName: id.last,
              email: id.email,
              visitToken: _session?.visitToken ?? "");
        } catch (_) {
          await _releaseCart(jwt, draftCart); // quota-lock rule
          rethrow;
        }
        return AnnyBooking(
            id: draft.bookingId,
            number: number.isEmpty ? draft.number : number,
            status: "accepted",
            start: start,
            end: end,
            resource: room.name);
      });
      if (b == null) {
        // the 401-retry re-ran the body with a fresh cart; anything still
        // registered here died between draft and checkout
        if (draftCart.isNotEmpty) {
          final String? jwt = await ensureFreshSession();
          if (jwt != null) await _releaseCart(jwt, draftCart);
        }
        return null;
      }
      bookings = [
        ...bookings.where((AnnyBooking x) => x.id != b.id),
        b,
      ]..sort((AnnyBooking x, AnnyBooking y) => x.start.compareTo(y.start));
      error = AnnyErrorKind.none;
      diag = null;
      notifyListeners();
      onBooked?.call(b);
      unawaited(refreshBookings()); // server truth replaces the sketch
      unawaited(refreshAnon(force: true)); // the seat just left the pool
      return b;
    } finally {
      isBooking = false;
      notifyListeners();
    }
  }

  /// The captured cancel route (GET with the booking access code).
  Future<bool> cancel(AnnyBooking b) async {
    if (isBooking) return false;
    isBooking = true;
    notifyListeners();
    final bool ok = await _authed<bool>((String jwt) async {
          await cancelBooking(http, jwt, bookingId: b.id, accessToken: b.code);
          return true;
        }) ==
        true;
    if (ok) {
      bookings = bookings.where((AnnyBooking x) => x.id != b.id).toList();
      notifyListeners();
      onCanceled?.call(b);
      unawaited(refreshAnon(force: true));
    }
    isBooking = false;
    notifyListeners();
    return ok;
  }

  /// The confirm-sheet prefill (W4) / checkout body (book) identity.
  Future<({String first, String last, String email})> checkoutIdentity() async {
    try {
      final SharedPreferences p = await SharedPreferences.getInstance();
      return (
        first: p.getString(AnnyKeys.first) ?? "",
        last: p.getString(AnnyKeys.last) ?? "",
        email: p.getString(AnnyKeys.email) ?? "",
      );
    } catch (_) {
      return (first: "", last: "", email: "");
    }
  }

  /// Let the sheet write edited real names back (email stays derived).
  Future<void> setCheckoutNames(String first, String last) async {
    try {
      final SharedPreferences p = await SharedPreferences.getInstance();
      await p.setString(AnnyKeys.first, first);
      await p.setString(AnnyKeys.last, last);
    } catch (_) {}
  }

  // ---- shared plumbing ----

  static Future<void> _persistSession(
      SharedPreferences p, AnnySession s) async {
    await p.setString(AnnyKeys.jwt, s.jwt);
    final String? alvo = s.visitToken;
    if (alvo != null && alvo.isNotEmpty) {
      await p.setString(AnnyKeys.alvo, alvo);
    }
    final String? uuid = s.accountUuid;
    if (uuid != null && uuid.isNotEmpty) {
      await p.setString(AnnyKeys.uuid, uuid);
    }
  }

  /// Quota-lock release, best effort: on failure the draft entry stays in
  /// [draftCart] so book()'s after-the-fact retry can try once more with a
  /// re-minted JWT; a cart that outlives both dies with its server TTL.
  Future<void> _releaseCart(String jwt, Map<String, String> draftCart) async {
    final String? oid = draftCart.remove("oid");
    final String? oat = draftCart.remove("oat");
    if (oid == null || oat == null) return;
    try {
      await cartDeleteAll(http, jwt, oid: oid, oat: oat);
    } catch (_) {
      draftCart["oid"] = oid;
      draftCart["oat"] = oat;
    }
  }

  static AnnyRoom? _bySlug(List<AnnyRoom> rs, String slug) {
    if (slug.isEmpty) return null;
    for (final AnnyRoom r in rs) {
      if (r.slug == slug) return r;
    }
    return null;
  }

  /// Transport noise is NOT an Anny incident (house rule); WAF 403 and 429
  /// collapse to [AnnyErrorKind.blocked]; the rest of the API noise is
  /// "shape changed" — the card's "try the website" dialect.
  static AnnyErrorKind _kindFromApi(Object e) {
    if (KITLoginManager.isNetworkError(e)) return AnnyErrorKind.offline;
    if (e is AnnyRateLimited) return AnnyErrorKind.blocked;
    if (e is AnnyUnauthorized) return AnnyErrorKind.auth;
    if (e is AnnyError) {
      return e.status == 403 ? AnnyErrorKind.blocked : AnnyErrorKind.markup;
    }
    return AnnyErrorKind.markup;
  }

  void _failAuth(AnnyAuthReason reason, String why) {
    error = switch (reason) {
      AnnyAuthReason.badCredentials => AnnyErrorKind.auth,
      AnnyAuthReason.blocked => AnnyErrorKind.blocked,
      AnnyAuthReason.network => AnnyErrorKind.offline,
      AnnyAuthReason.markupChanged ||
      AnnyAuthReason.ssoUnavailable =>
        AnnyErrorKind.markup,
    };
    diag = "${DateTime.now().toIso8601String().substring(5, 16)} $why";
  }

  /// `kind` [AnnyErrorKind.none] keeps the current [error]: the failure
  /// that gets remembered is the one the user can still act on.
  void _diag(String why, AnnyErrorKind kind) {
    if (kind != AnnyErrorKind.none) error = kind;
    diag = "${DateTime.now().toIso8601String().substring(5, 16)} $why";
  }

  // ---- rooms cache codec (AnnyRoom is a plain value object; the tiny
  // codec lives here so anny_api.dart stays the pure wire layer) ----

  static Map<String, Object?> _roomJson(AnnyRoom r) => {
        "id": r.id,
        "slug": r.slug,
        "name": r.name,
        "color": r.color,
        "quantity": r.quantity,
        "serviceId": r.serviceId,
        "minDuration": r.minDuration,
        "maxDuration": r.maxDuration,
        "interval": r.interval,
        "advanceDays": r.advanceDays,
        "cancelMinutesBefore": r.cancelMinutesBefore,
        "openFrom": r.openFrom,
        "openTo": r.openTo,
      };

  static AnnyRoom _roomFromJson(Map<String, dynamic> j) => AnnyRoom(
        id: "${j["id"] ?? ''}",
        slug: "${j["slug"] ?? ''}",
        name: "${j["name"] ?? ''}",
        color: "${j["color"] ?? ''}",
        quantity: (j["quantity"] as num?)?.toInt() ?? 0,
        serviceId: (j["serviceId"] as num?)?.toInt() ?? 0,
        minDuration: (j["minDuration"] as num?)?.toInt() ?? 0,
        maxDuration: (j["maxDuration"] as num?)?.toInt() ?? 0,
        interval: (j["interval"] as num?)?.toInt() ?? 0,
        advanceDays: (j["advanceDays"] as num?)?.toInt() ?? 0,
        cancelMinutesBefore: (j["cancelMinutesBefore"] as num?)?.toInt() ?? 0,
        openFrom: "${j["openFrom"] ?? ''}",
        openTo: "${j["openTo"] ?? ''}",
      );
}
