import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:kit_mobile/l10n/l10n.dart';

/// On-demand German→English translation of canteen dish and line names.
///
/// The menu content is German at the source; an English UI with German dish
/// names is readable but useless for choosing ("Koeri? Bratwurst?"). There
/// is no offline dictionary that covers the Studierendenwerk's vocabulary,
/// so this uses Google's keyless web endpoint (the same one the translate
/// website's UI calls) and PERSISTS every result in prefs: a dish name is
/// paid for at most once per install, after which the card works fully
/// offline and the German original stays one long-press away (Tooltip).
///
/// Deliberate limits:
/// - only runs while [L10n.isEnglish] - German users never generate traffic;
/// - only public menu text leaves the device (no personal data);
/// - failures are remembered per name for the session (no retry storm on a
///   blocked endpoint) and simply leave the German name on screen;
/// - cache is capped FIFO, keys are `MENSA_trx_*` - translations are public
///   text derivatives, safe to survive logout like the menu cache itself.
class MensaTranslate {
  MensaTranslate();

  static const cacheKey = "MENSA_trx_en";
  static const _maxCache = 900;

  /// pluggable for tests; release build never sees a non-default transport
  @visibleForTesting
  Future<http.Response> Function(Uri) transport = _defaultTransport;

  /// fired after any cache mutation the UI should reflect (the manager
  /// wires this to its own notifyListeners - the card already listens)
  VoidCallback? onChanged;

  final Map<String, String> _en = {};
  final Set<String> _queued = {};
  final Set<String> _inFlight = {};
  final Set<String> _failed = {};
  final List<String> _queue = [];
  final List<String> _pending = [];
  Future<void>? _restoreF;
  bool _running = false;
  bool _gaveUp = false; // endpoint is blocking us; stay quiet this session
  int _failedBatches = 0;

  static Future<http.Response> _defaultTransport(Uri uri) =>
      http.get(uri, headers: const {"User-Agent": "KA.Uni app"}).timeout(
          const Duration(seconds: 12));

  static final RegExp _ws = RegExp(r"\s+");

  static String norm(String s) => s.trim().replaceAll(_ws, " ");

  /// English form of [de] if known; null while unknown (caller keeps German)
  String? en(String de) => _en[norm(de)];

  /// Queue every not-yet-known name in [names]. Cheap and idempotent: a
  /// name already cached, in flight or failed this session is skipped, so
  /// the card may call this on every build of every menu view. Nothing
  /// goes online before the persisted cache has been READ - a warm cache
  /// means zero requests on every later launch (audit 2026-11-12: an
  /// unawaited restore let each cold start re-queue ~40 cached names).
  void request(Iterable<String> names) {
    if (!L10n.isEnglish || _gaveUp) return;
    final restore = _restoreF ??= _restore();
    for (final raw in names) {
      final n = norm(raw);
      if (n.isNotEmpty) _pending.add(n);
    }
    // microtask hop also covers the "restore already done" case
    unawaited(restore.whenComplete(_flush));
  }

  void _flush() {
    if (_pending.isEmpty) return;
    final flush = _pending.toSet();
    _pending.clear();
    var added = false;
    for (final n in flush) {
      if (_en.containsKey(n) ||
          _queued.contains(n) ||
          _inFlight.contains(n) ||
          _failed.contains(n)) {
        continue;
      }
      _queued.add(n);
      _queue.add(n);
      added = true;
    }
    // queue-non-empty restart also recovers if a throwing listener ever
    // unwound a previous drain with items left over
    if (!_running && (added || _queue.isNotEmpty)) {
      unawaited(_run());
    }
  }

  /// test hook: resolves once nothing is pending, queued or in flight
  @visibleForTesting
  Future<void> get idle async {
    while (_pending.isNotEmpty || _running || _queue.isNotEmpty || _inFlight.isNotEmpty) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  Future<void> _restore() async {
    try {
      final p = await SharedPreferences.getInstance();
      final raw = p.getString(cacheKey);
      if (raw == null) return;
      final map = jsonDecode(raw) as Map<String, dynamic>;
      map.forEach((k, v) {
        // never let the (possibly stale) disk copy override a fresher
        // value that arrived while restore was in flight
        if (v is String && !_en.containsKey(k) && _en.length < _maxCache) _en[k] = v;
      });
      onChanged?.call();
    } catch (_) {
      // a broken cache line is just a cache miss
    }
  }

  Future<void> _run() async {
    if (_running) return;
    _running = true;
    // R23: a cold English cache drains ~20-40 sequential 2-name batches;
    // per-batch onChanged -> mensa.notifyListeners -> KITProvider ->
    // WHOLE home tree rebuild (weekly grid, cards, modules table) per
    // round-trip = 20-40 dashboard rebuilds across the drain. Throttle
    // progress repaints to one per 2 s and guarantee a final flush so the
    // last batch still lands.
    var lastNotify = DateTime.fromMillisecondsSinceEpoch(0);
    var changedSinceNotify = false;
    try {
      while (_queue.isNotEmpty) {
        // two in flight, small burst: the endpoint tolerates a casual
        // browsing page constantly; a hammering client gets 429s
        final batch = <String>[];
        for (final n in _queue.toList()) {
          _queue.remove(n);
          if (_en.containsKey(n)) {
            _queued.remove(n); // cached meanwhile (restore flush race) - drop
            continue;
          }
          batch.add(n);
          if (batch.length == 2) break;
        }
        if (batch.isEmpty) continue;
        for (final n in batch) {
          _inFlight.add(n);
        }
        final results = await Future.wait(batch.map(_translateOne));
        var changed = false;
        for (var i = 0; i < batch.length; i++) {
          _inFlight.remove(batch[i]);
          _queued.remove(batch[i]);
          final r = results[i];
          if (r == null || r.isEmpty) {
            _failed.add(batch[i]);
          } else {
            _put(batch[i], r);
            changed = true;
          }
        }
        if (changed) {
          _failedBatches = 0;
          await _persist();
          final now = DateTime.now();
          if (now.difference(lastNotify).inMilliseconds >= 2000) {
            lastNotify = now;
            changedSinceNotify = false;
            onChanged?.call();
          } else {
            changedSinceNotify = true;
          }
        } else if (++_failedBatches >= 3) {
          // three straight all-failed batches = blocked or rate-limited
          // endpoint; stop hammering it with the rest of the week (the
          // German names stay on screen, next launch may fare better)
          _gaveUp = true;
          _queue.forEach((n) {
            _failed.add(n);
            _queued.remove(n);
          });
          _queue.clear();
          break;
        }
      }
    } finally {
      _running = false;
      if (changedSinceNotify) onChanged?.call();
    }
  }

  void _put(String de, String en) {
    _en[de] = en;
    while (_en.length > _maxCache) {
      _en.remove(_en.keys.first); // FIFO, insertion-ordered map
    }
  }

  Future<void> _persist() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(cacheKey, jsonEncode(_en));
    } catch (_) {}
  }

  /// gtx dialect: `[[["en part",["de part",null,null,10],...],...], ...]`
  Future<String?> _translateOne(String de) async {
    try {
      final uri = Uri.https("translate.googleapis.com",
          "/translate_a/single", {"client": "gtx", "sl": "de", "tl": "en", "dt": "t", "q": de});
      final r = await transport(uri);
      if (r.statusCode != 200) return null;
      final root = jsonDecode(utf8.decode(r.bodyBytes)) as List;
      final segs = root[0] as List;
      final out = segs
          .map((s) => (s as List).isEmpty ? "" : (s[0] as String? ?? ""))
          .join();
      return out.trim().isEmpty ? null : out.trim();
    } on Object {
      return null;
    }
  }
}
