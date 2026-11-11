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
  bool _loaded = false;
  bool _running = false;

  static Future<http.Response> _defaultTransport(Uri uri) =>
      http.get(uri, headers: const {"User-Agent": "KA.Uni app"}).timeout(
          const Duration(seconds: 12));

  static String norm(String s) =>
      s.trim().replaceAll(RegExp(r"\s+"), " ");

  /// English form of [de] if known; null while unknown (caller keeps German)
  String? en(String de) => _en[norm(de)];

  /// Queue every not-yet-known name in [names]. Cheap and idempotent: a
  /// name already cached, in flight or failed this session is skipped, so
  /// the card may call this on every build of every menu view.
  void request(Iterable<String> names) {
    if (!L10n.isEnglish) return;
    if (!_loaded) {
      unawaited(_restore());
    }
    var added = false;
    for (final raw in names) {
      final n = norm(raw);
      if (n.isEmpty ||
          _en.containsKey(n) ||
          _queued.contains(n) ||
          _inFlight.contains(n) ||
          _failed.contains(n)) {
        continue;
      }
      _queued.add(n);
      _queue.add(n);
      added = true;
    }
    if (added && !_running) {
      unawaited(_run());
    }
  }

  Future<void> _restore() async {
    _loaded = true;
    try {
      final p = await SharedPreferences.getInstance();
      final raw = p.getString(cacheKey);
      if (raw == null) return;
      final map = jsonDecode(raw) as Map<String, dynamic>;
      map.forEach((k, v) {
        if (v is String && _en.length < _maxCache) _en[k] = v;
      });
      onChanged?.call();
    } catch (_) {
      // a broken cache line is just a cache miss
    }
  }

  Future<void> _run() async {
    _running = true;
    try {
      while (_queue.isNotEmpty) {
        // two in flight, small burst: the endpoint tolerates a casual
        // browsing page constantly; a hammering client gets 429s
        final batch = _queue.take(2).toList();
        for (final n in batch) {
          _queue.remove(n);
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
          await _persist();
          onChanged?.call();
        }
      }
    } finally {
      _running = false;
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
