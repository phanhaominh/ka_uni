import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:kit_mobile/mensa/mensa_html_parser.dart';
import 'package:kit_mobile/mensa/mensa_translate.dart';
import 'package:kit_mobile/mensa/models/mensa_models.dart';
import 'package:kit_mobile/settings/providers/settings_provider.dart'
    show showingMensaKey;
import 'package:kit_mobile/state_management/kit_login_manager.dart'
    show KITLoginManager;

/// SharedPreferences keys. MENSA_*, deliberately NOT DATA_*: the menu
/// is public Studierendenwerk data with zero account relation - it must
/// survive a logout on a shared device (GEO_placeSearchSnapshot precedent).
class MensaKeys {
  MensaKeys._();

  /// encoded `List<MensaDay>` of the cached week
  static const weekCache = "MENSA_weekCache";

  /// `"<canteen>|<iso-week-of-monday>"` the cached body belongs to - a
  /// different source (new week, other canteen) means the snapshot
  /// describes ANOTHER plan and must reseed, never merge (webcal
  /// feedSource precedent)
  static const feedSource = "MENSA_feedSource";

  static const fetchedAt = "MENSA_fetchedAt";

  /// one-line WHY of the last failure - release builds strip prints;
  /// the card footer appends it, visible to user AND support
  static const diag = "MENSA_diag";
}

/// Fetches + caches the SW Karlsruhe menu for one canteen-week.
///
/// Shape mirrors KITTopographyManager (public feed, self-contained
/// errors - a throw here would be an unhandled async zone killer) with
/// CampusManager mechanics (single-flight, response gate, diag trail).
/// Failures NEVER touch campusManager's surface/offline flags: the
/// Studierendenwerk is not KIT, its outages must not light the
/// "KIT site changed?" banner.
class MensaManager extends ChangeNotifier {
  /// the KIT-north canteen the app defaults to (Adenauerring, the one
  /// steps from the campus gates - the user's link)
  static const defaultCanteen = "adenauerring";

  static const _ttl = Duration(hours: 3);

  final MensaHtmlParser _parser = MensaHtmlParser();

  /// DE→EN dish-name translation (EN UI only; persisted, offline after
  /// first sight). Its cache updates flow through this manager's own
  /// change signal - the card already listens here.
  final MensaTranslate translate = MensaTranslate();

  MensaManager() {
    translate.onChanged = notifyListeners;
  }

  /// test seam - stubbed by unit tests, mirrors the netGet-override
  /// discipline of the campus feed tests
  @visibleForTesting
  Future<http.Response> Function(Uri) transport = _defaultTransport;

  List<MensaDay> days = const [];
  DateTime? fetchedAt;
  String? diag;

  /// cache fence of [days] (`"<canteen>|<week>"`)
  String? _source;

  bool get hasData => days.isNotEmpty;
  Duration? get age =>
      fetchedAt == null ? null : DateTime.now().difference(fetchedAt!);

  /// SW publishes the next week ~18:00-23:00; a 3 h TTL re-pulls
  /// evening updates without hammering the site on every app open.
  /// A FUTURE fetchedAt (clock skew/correction) is never "fresh" -
  /// negative age must not pin the cache until the clock heals
  bool get isFresh {
    final a = age;
    return a != null && a >= Duration.zero && a < _ttl;
  }

  MensaDay? dayFor(DateTime d) {
    for (final MensaDay day in days) {
      if (day.date.year == d.year &&
          day.date.month == d.month &&
          day.date.day == d.day) {
        return day;
      }
    }
    return null;
  }

  static Future<http.Response> _defaultTransport(Uri uri) =>
      http.get(uri, headers: const {"User-Agent": "KA.Uni app"}).timeout(
          // sw-ka answers in <2 s normally; longer than this and the
          // home screen should move on (topography used 15 s too)
          const Duration(seconds: 15));

  /// Plain "popup_plain" a11y render: ~75 KB instead of ~520 KB, one
  /// stable table per day, no JS. The view ignores p= (it always prints
  /// the Studierende price - verified live 11.2026); kw MUST be passed
  /// explicitly or the page only serves the REMAINDER of the week.
  static String urlFor({required String canteen, required int isoWeek}) =>
      "https://www.sw-ka.de/de/hochschulgastronomie/speiseplan/"
      "mensa_$canteen/?view=ok&c=$canteen&STYLE=popup_plain&p=1&kw=$isoWeek";

  /// ISO 8601 week number (Thursday rule) of [d].
  static int isoWeek(DateTime d) {
    // UTC arithmetic: local-tz day differences skew by an hour across
    // DST changes and inDays truncation would drop a week
    final DateTime day = DateTime.utc(d.year, d.month, d.day);
    // the ISO week of d is the calendar week containing d's Thursday
    final DateTime thu = day.add(Duration(days: 4 - day.weekday));
    // week 1 is the week containing January 4 - compare Thursdays
    final DateTime jan4 = DateTime.utc(thu.year, 1, 4);
    final DateTime week1Thu = jan4.add(Duration(days: 4 - jan4.weekday));
    return thu.difference(week1Thu).inDays ~/ 7 + 1;
  }

  /// Restores the cached week (called on boot; the card paints from it
  /// before the network says anything). No-op once anything loaded: a
  /// slow restore settling AFTER a completed fetch must not reseed the
  /// old cache over the fresh days (it reads prefs, the fetch wrote
  /// them - last writer would otherwise win with the STALE value).
  Future<void> restore() async {
    if (days.isNotEmpty || fetchedAt != null) return;
    try {
      final SharedPreferences p = await SharedPreferences.getInstance();
      fetchedAt = DateTime.tryParse(p.getString(MensaKeys.fetchedAt) ?? "");
      diag = p.getString(MensaKeys.diag);
      _source = p.getString(MensaKeys.feedSource);
      final String? raw = p.getString(MensaKeys.weekCache);
      if (raw == null) return;
      final List<MensaDay> parsed = [
        for (final dynamic j in (jsonDecode(raw) as List))
          MensaDay.fromJson(j as List)
      ];
      if (parsed.isEmpty) return; // empty parse = broken payload, not data
      days = parsed;
      notifyListeners();
    } catch (_) {
      // a corrupt snapshot is only a cache miss
    }
  }

  Future<bool>? _inFlight;

  /// a fetch is genuinely in flight RIGHT NOW - the card shows its
  /// spinner on this, never on "fetchedAt happens to be null"
  bool get isFetching => _inFlight != null;

  /// Fetches the week containing [forDate] (default: today) unless the
  /// cache already covers it freshly. Self-contained: never throws;
  /// the bool reports whether the week is now in the state the caller
  /// asked for (fresh TTL skip and the opted-out no-op are successes;
  /// a refused fetch - HTTP error, gate, layout drift, wrong week,
  /// socket death - is the false the card turns into a toast).
  Future<bool> fetchWeek({DateTime? forDate, bool force = false}) {
    final inflight = _inFlight;
    if (inflight != null) return inflight;
    final future = _fetch(forDate ?? DateTime.now(), force);
    _inFlight = future;
    return future.whenComplete(() {
      if (identical(_inFlight, future)) _inFlight = null;
    });
  }

  Future<bool> _fetch(DateTime now, bool force) async {
    // opt-out honor: hiding the section in settings must ALSO stop the
    // third-party traffic, not just the UI (prefs read per fetch: the
    // toggle takes effect on the very next open, no restart needed)
    final SharedPreferences prefs0 =
        await SharedPreferences.getInstance();
    if (prefs0.getBool(showingMensaKey) == false) return true;
    final int kw = isoWeek(now);
    final String source = "$defaultCanteen|$kw";
    if (!force && _source == source && isFresh) return true;
    await _diag("start kw=$kw");
    try {
      final http.Response r =
          await transport(Uri.parse(urlFor(
              canteen: defaultCanteen, isoWeek: kw)));
      // gate first (feedFromResponse precedent): a cookie wall / consent
      // page / error page must not parse "succeed" into an empty week
      if (r.statusCode != 200) {
        await _diag("HTTP ${r.statusCode}");
        return false;
      }
      final String body = KITLoginManager.fixUtf8Body(r).body;
      if (!body.contains("popup") && !body.contains("Speiseplan")) {
        await _diag("gate: not a plan page (${body.length}B)");
        return false;
      }
      final List<MensaDay> parsed = _parser.parseWeek(body, now);
      if (parsed.isEmpty) {
        // empty week during semester break is LEGAL (no day stamps);
        // stamps present but unparsed = layout drift = tell someone
        final int stamps = RegExp(
                r'(?:Mo|Di|Mi|Do|Fr|Sa|So|Mon|Tue|Wed|Thu|Fri|Sat|Sun)\s+\d{1,2}\.\d{1,2}\.')
            .allMatches(body)
            .length;
        final bool layoutDrift = stamps > 0;
        await _diag(layoutDrift
            ? "layout: $stamps day stamps, 0 parsed"
            : "empty week (break?)");
        // keep the previous week cached over a blank one; a break week
        // is the TRUTH, not a failure - no toast for it
        return !layoutDrift;
      }
      // trust but verify: a page that really serves ANOTHER week (the
      // remainder-of-week failure mode kw= is supposed to prevent) must
      // not write a fence claiming THIS week - that would label the
      // wrong plan fresh for the whole TTL and show "closed" on days
      // the real week does serve
      if (parsed.any((MensaDay d) => isoWeek(d.date) != kw)) {
        await _diag("week: kw=$kw served "
            "${parsed.map((MensaDay d) => "${d.date.day}.${d.date.month}")
                .join(",")}");
        return false;
      }
      final SharedPreferences p = await SharedPreferences.getInstance();
      final String encoded =
          jsonEncode([for (final MensaDay d in parsed) d.toJson()]);
      if (p.getString(MensaKeys.weekCache) != encoded) {
        // body before stamp (webcal write-order lesson): a snapshot must
        // never present fresh over stale
        await p.setString(MensaKeys.weekCache, encoded);
      }
      // fence written even when the body is unchanged: in-memory and
      // persisted source must describe the SAME week after every success
      await p.setString(MensaKeys.feedSource, source);
      fetchedAt = DateTime.now();
      await p.setString(
          MensaKeys.fetchedAt, fetchedAt!.toIso8601String());
      await p.remove(MensaKeys.diag);
      diag = null;
      _source = source;
      days = parsed;
      notifyListeners();
      return true;
    } on Object catch (e) {
      // network death is NOT a mensa incident the user can act on -
      // the card just keeps serving its cache; still leave the trail
      await _diag("threw: ${e.runtimeType}");
      return false;
    }
  }

  Future<void> _diag(String why) async {
    diag = "${DateTime.now().toIso8601String().substring(5, 16)} $why";
    try {
      final SharedPreferences p = await SharedPreferences.getInstance();
      await p.setString(MensaKeys.diag, diag!);
    } catch (_) {}
  }
}
