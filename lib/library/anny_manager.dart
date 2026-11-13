import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'anny_api.dart';
import '../notifications/library_notifications.dart';
import '../notifications/mei_notifications.dart';
import '../settings/providers/settings_provider.dart'
    show showingCampusNowKey;
import 'anny_auth.dart';
import '../state_management/kit_login_manager.dart' show KITLoginManager;

/// SharedPreferences keys. ANN_* deliberately, not DATA_*: the room
/// catalog and free counts are PUBLIC Anny data (cache-first across APP
/// RESTARTS — MensaKeys precedent). Logout wipes ALL of ANN_* (the
/// credentials_provider sweep + signOut): nothing library-related may
/// survive on a shared device. Prefs never hold a live token: jwt stores
/// only the "pending" marker; the password lives solely in the keychain
/// ([AnnyKeys.pass]).
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

  bool isFetching = false;

  /// when the anonymous catalog last SUCCEEDED; the home card prints it so
  /// a stale cache is visible instead of silently wrong (R21)
  DateTime? get fetchedAt => _anonFetchedAt; // anonymous half
  bool isSigningIn = false;
  bool isLoadingBookings = false;
  bool isBooking = false; // book + cancel share the exclusive gate

  DateTime? _anonFetchedAt;
  AnnySession? _session;

  /// A session whose silent re-mint FAILED (rotated password, revoked
  /// grant) is dead even though the object is still cached: the UI must
  /// offer sign-in again instead of claiming "Signed in as …" forever
  /// (audit R21). [reauthFailed] resets on the next signIn/_silentReauth.
  bool get signedIn => _session != null && !reauthFailed;
  bool reauthFailed = false;
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
      // older builds persisted the REAL token here; scrub it on sight
      // (R21) — the "pending" marker is all the restore may keep
      if (jwt != null && jwt != "pending") {
        await p.remove(AnnyKeys.jwt);
      }
      // READ the legacy extras BEFORE deleting them (a session restored
      // mid-app-launch used to lose its uuid/alvo to the scrub order)
      final String? legacyAlvo = p.getString(AnnyKeys.alvo);
      final String? legacyUuid = p.getString(AnnyKeys.uuid);
      await p.remove(AnnyKeys.alvo);
      await p.remove(AnnyKeys.uuid);
      if (jwt != null && jwt.isNotEmpty) {
        // obtain a persisted JWT at the epoch: older than its 1 h lifetime
        // with near-certainty, so isExpired is true and the first authed
        // call re-mints it silently via the keychain password
        _session = AnnySession(
            jwt: jwt,
            visitToken: legacyAlvo,
            accountUuid: legacyUuid,
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
    // R22 opt-out honor (mensa precedent, mensa_manager._fetch): hiding
    // the campus-now strip in settings must ALSO stop the third-party
    // traffic, not just unmount the card - boot() and every campus
    // pull-refresh used to contact b.anny.eu regardless of the toggle
    // (R36.2: gate key moved showingLibrary -> showCampusNow)
    try {
      final SharedPreferences prefs0 = await SharedPreferences.getInstance();
      if (prefs0.getBool(showingCampusNowKey) == false) return;
    } catch (_) {}
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
      if (rs.isEmpty) {
        // An empty catalog is NEVER truth: it would blank the card AND
        // overwrite the good ANN_rooms cache, so a transient envelope
        // drift turns into an unrecoverable retry loop. boot() guards the
        // same way (rs.isNotEmpty); keep the cache, report the anomaly.
        throw AnnyError(200, "empty room catalog");
      }
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
  String _favSlotsSlug = "";

  /// Refresh [favSlots] for today (the card's next-free chip).
  /// Single-flight; keeps the previous strip on failure.
  Future<void> refreshFavSlots() {
    // join an in-flight fetch ONLY while it still belongs to the current
    // favorite: fav A -> fav B used to short-circuit into A's fetch and
    // advertise A's times under B until the next network pass (R21)
    final Future<void>? inflight = _favSlotsInFlight;
    if (inflight != null && _favSlotsSlug == favSlug) return inflight;
    late final Future<void> fut;
    final String slug = favSlug;
    _favSlotsSlug = slug;
    fut = () async {
      final AnnyRoom? fav = favRoom;
      if (fav == null || fav.serviceId == 0) return;
      try {
        final slots = await fetchIntervals(
            http, fav.slug, fav.serviceId, DateTime.now());
        // drop a reply for an ABANDONED favorite: A->B mid-fetch used to
        // let A's later answer overwrite B's strip (R21, second half of
        // the join-key bug - keying the join is not enough)
        if (slug != favSlug) return;
        favSlots = slots;
      } catch (e) {
        _diag("fav slots: $e", _kindFromApi(e));
      }
      notifyListeners();
    }();
    _favSlotsInFlight = fut;
    return fut.whenComplete(() {
      if (identical(_favSlotsInFlight, fut)) {
        // the slug KEEPS its value: it describes which fetch the joined
        // future belongs to, and a later switch to the same slug after
        // completion must still re-fetch (fresh data), while an
        // ABANDONED fetch's completion never clears a live fetch's key
        _favSlotsInFlight = null;
      }
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
    // R22: a logout landing inside the multi-hop headless SSO used to be
    // overwritten by this chain's continuation: ANN_* prefs + the KIT
    // email + the keychain password came back AFTER signOut and the
    // ANN_* sweep, so the NEXT user's boot() silently re-minted a live
    // JWT for the dead account (the R21 hazard, racy path left open)
    final int epoch = MeiNotifications.teardownEpoch;
    isSigningIn = true;
    notifyListeners();
    try {
      final AnnySession s =
          await auth.signIn(kitUser: kitUser, password: password);
      if (epoch != MeiNotifications.teardownEpoch) {
        _diag("signed out during sign-in", AnnyErrorKind.none);
        return false;
      }
      _session = s;
      reauthFailed = false;
      final SharedPreferences p = await SharedPreferences.getInstance();
      await _persistSession(p, s); // marker only, never the token
      await p.setString(AnnyKeys.email, "$kitUser@student.kit.edu");
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
    _signOutGen++; // drop any bookings reply still in flight (R22)
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
      // names + KIT email are personal data too: the NEXT user's confirm
      // sheet must never prefill them (audit R21)
      await p.remove(AnnyKeys.email);
      await p.remove(AnnyKeys.first);
      await p.remove(AnnyKeys.last);
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
  /// no loop (plan rule). A FAILED re-mint marks the session dead
  /// ([signedIn] flips) so the UI can offer sign-in again.
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
        final int epoch = MeiNotifications.teardownEpoch;
        final AnnySession s = await auth.signIn(kitUser: kitUser, password: pw);
        if (epoch != MeiNotifications.teardownEpoch) {
          // logged out mid re-mint: _session for the dead account must
          // not come back to life in memory (its prefs are swept)
          return null;
        }
        _session = s;
        reauthFailed = false;
        return s.jwt;
      } on AnnyAuthError catch (e) {
        reauthFailed = true;
        _failAuth(e.reason, "$e");
        return null;
      } catch (e) {
        reauthFailed = true;
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
        // R23: the retry runs INSIDE the `on` handler above — Dart does
        // NOT route a throw from one handler into the sibling `catch (e)`
        // clause, so a non-401 failure during the retry (network death
        // mid-reauth, markup AnnyError) escaped _authed, broke its
        // "never throws" contract, froze isLoadingBookings/_busy in the
        // callers and landed unhandled rejections in the zone. Catch it
        // right here, same containment the first attempt gets.
      } catch (e) {
        _diag("api: $e", _kindFromApi(e));
        return null;
      }
    } catch (e) {
      _diag("api: $e", _kindFromApi(e));
      return null;
    }
  }

  Future<bool>? _bookingsInFlight;

  // R22: bumped by signOut; a bookings reply that started for the OLD
  // session must never re-arm the list after signOut cleared it (the
  // next device user was shown the predecessor's check-in banner)
  int _signOutGen = 0;

  /// Pull the upcoming bookings of the signed-in account. Never throws;
  /// keeps the previous list on failure (mensa discipline).
  Future<bool> refreshBookings() {
    final Future<bool>? inflight = _bookingsInFlight;
    if (inflight != null) return inflight;
    late final Future<bool> fut;
    fut = () async {
      final int gen = _signOutGen;
      if (_session == null) return false;
      isLoadingBookings = true;
      notifyListeners();
      // uuid read INSIDE the call: a silent re-auth may have delivered a
      // fresh one, and myBookings' primary route needs no uuid at all
      final List<AnnyBooking>? list;
      try {
        list = await _authed<List<AnnyBooking>>(
            (String jwt) => myBookings(http, jwt, _session?.accountUuid ?? ""));
      } finally {
        // R23: gate release in finally — same lesson as the isBooking
        // fix: a contract-violating throw used to leave the spinner
        // owner (isLoadingBookings) set for the whole session
        isLoadingBookings = false;
      }
      if (list != null && gen == _signOutGen) {
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
    // synchronous gate (cancel() pattern): the old check->await->set order
    // let a second call slip in during the identity await and ran two
    // overlapping carts (R21). A rejected caller leaves error=none, which
    // the sheet renders as "just taken" - the only state a human can race.
    if (isBooking) return null;
    isBooking = true;
    notifyListeners();
    try {
      return await _bookInner(room, start, minutes);
    } finally {
      isBooking = false;
      notifyListeners();
    }
  }

  Future<AnnyBooking?> _bookInner(
      AnnyRoom room, DateTime start, int minutes) async {
    if (room.serviceId == 0) {
      _diag("book: room ${room.slug} has no service id", AnnyErrorKind.markup);
      return null;
    }
    final id = await checkoutIdentity();
    if (id.first.isEmpty || id.last.isEmpty || id.email.isEmpty) {
      // validation, NOT auth: labeling it auth made the sheet sit on the
      // sign-in path while the real fix was one empty text field
      _diag("book: checkout identity incomplete", AnnyErrorKind.markup);
      return null;
    }
    final Map<String, String> draftCart = {}; // oid/oat while a cart may exist
    {
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
    }
  }

  /// The captured cancel route (GET with the booking access code).
  Future<bool> cancel(AnnyBooking b) async {
    if (isBooking) return false;
    isBooking = true;
    notifyListeners();
    try {
      final bool ok = await _authed<bool>((String jwt) async {
            await cancelBooking(http, jwt,
                bookingId: b.id, accessToken: b.code);
            return true;
          }) ==
          true;
      if (ok) {
        bookings = bookings.where((AnnyBooking x) => x.id != b.id).toList();
        notifyListeners();
        onCanceled?.call(b);
        unawaited(refreshAnon(force: true));
      }
      return ok;
    } finally {
      // an _authed throw used to leave the gate closed until reboot:
      // one stuck flag locked booking AND cancelling for the session
      isBooking = false;
      notifyListeners();
    }
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

  /// Persists only THAT a library session exists - never the token.
  /// The restored session is stamped at the epoch and therefore always
  /// expired, so the first authed call re-mints a fresh JWT from the
  /// keychain password; keeping the real one here would put a live Bearer
  /// in plaintext shared_prefs for its whole hour of validity.
  static Future<void> _persistSession(
      SharedPreferences p, AnnySession s) async {
    await p.setString(AnnyKeys.jwt, "pending");
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
