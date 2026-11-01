import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../ilias/models/ilias_models.dart';
import '../../l10n/l10n.dart';
import '../../notifications/mei_notifications.dart';

/// Watches the agenda's ILIAS announcements and pushes new ones as heads-up
/// notifications. The personal-news feed the agenda already fetches is the
/// only material source: no extra scraping, no extra session hits.
///
/// State is a JSON list of seen announcement ids in prefs, insertion order =
/// age. A key that is ABSENT means "never ran": the first run seeds silently,
/// otherwise a fresh install would fire every old announcement at once.
class IliasWatcher {
  IliasWatcher._();

  static const seenKey = "DATA_iliasWatchSeen";

  /// Bound on the seen list (age-trimmed) and on pushes per diff: a course
  /// renaming its whole news board must not bury the notification shade.
  static const _maxSeen = 300;
  static const _maxNotify = 3;

  /// Injection seam for tests; production uses the shared "changes" channel
  /// and its agenda deep link, same as the timetable-diff pushes.
  @visibleForTesting
  static Future<void> Function(String title, String body) notify =
      MeiNotifications.notifyChange;

  /// Guards against two agenda refreshes (init + pull-to-refresh, or a
  /// re-entered route over an orphaned fetch) running the read-modify-write
  /// of the seen list concurrently: both would read the same stale store and
  /// push the SAME announcements twice. Mirrors IliasManager's auth
  /// single-flight; the caller is fire-and-forget so we hand back the shared
  /// in-flight future instead of starting a second pass.
  static Future<void>? _inFlight;

  /// Called after the agenda successfully fetched announcements. Never
  /// throws: a watcher hiccup must not break the agenda refresh.
  static Future<void> diffAndNotify(List<IliasAnnouncement> fresh) {
    final running = _inFlight;
    if (running != null) return running;
    final done = _run(fresh);
    _inFlight = done;
    done.whenComplete(() => _inFlight = null);
    return done;
  }

  static Future<void> _run(List<IliasAnnouncement> fresh) async {
    // captured before the first await: a logout mid-fetch bumps the epoch,
    // and every persist/push below must then abort - the sweep has already
    // deleted our key, and re-persisting would resurrect the old student's
    // course titles on a shared device (same fence as every _zoned push)
    final epoch = MeiNotifications.teardownEpoch;
    try {
      final prefs = await SharedPreferences.getInstance();
      final stored = _decode(prefs.getString(seenKey));
      if (stored == null) {
        // first run (or unreadable store): seed, notify nothing
        await prefs.setString(seenKey, jsonEncode(_cap([
          for (final a in newOnes(fresh, const {})) idOf(a),
        ])));
        return;
      }
      final freshNew = newOnes(fresh, stored.toSet());
      if (freshNew.isEmpty) return;
      // persist the seen-marking BEFORE notifying so a redelivered board
      // never re-notifies; overflow-beyond-cap and the pushed prefix are
      // all marked (they were not silently dropped, just batched)
      if (epoch != MeiNotifications.teardownEpoch) return;
      final seen = [...stored, for (final a in freshNew) idOf(a)];
      await prefs.setString(seenKey, jsonEncode(_cap(seen)));
      // one failing push must not bury its siblings (their ids are already
      // persisted, so skipping a throw is the only safe fallback)
      for (final a in freshNew.take(_maxNotify)) {
        if (epoch != MeiNotifications.teardownEpoch) return;
        try {
          await notify(
              a.courseTitle.isEmpty
                  ? L10n.t("ilias.notifyFallbackTitle")
                  : a.courseTitle,
              _body(a));
        } on Object catch (e) {
          if (kDebugMode) print("ilias watcher notify: $e");
        }
      }
    } on Object catch (e) {
      if (kDebugMode) print("ilias watcher: $e");
    }
  }

  /// age-trim to the newest [_maxSeen] (list order = age).
  static List<String> _cap(List<String> ids) => ids.length > _maxSeen
      ? ids.sublist(ids.length - _maxSeen)
      : ids;

  /// Stable identity: the news feed has no ids, so the ref id plus a
  /// normalized title stands in. Normalization is deliberately minimal -
  /// case and whitespace only, never punctuation: trimming trailing
  /// punctuation collapsed "Übungsblatt 7", "7." and "7!!!" (and every
  /// "Vorlesung (28.10.)" vs "(28.10") into ONE id, permanently swallowing
  /// the distinct second post. Losing a real announcement is far worse than
  /// an occasional duplicate push, so an over-eager dedupe is the failure we
  /// refuse to accept.
  @visibleForTesting
  static String idOf(IliasAnnouncement a) =>
      "${a.courseRefId}|${_normalizeTitle(a.title)}";

  /// fresh minus seen, preserving dashboard order, deduped WITHIN fresh;
  /// entries whose title carries no letter or digit are skipped entirely.
  @visibleForTesting
  static List<IliasAnnouncement> newOnes(
      List<IliasAnnouncement> fresh, Set<String> seen) {
    final out = <IliasAnnouncement>[];
    final mine = <String>{};
    for (final a in fresh) {
      // a title without ONE letter or digit is scraping residue, not an
      // announcement - the guard may only REJECT punctuation-only titles,
      // never strip punctuation from real ones (see idOf)
      if (!_hasContent.hasMatch(_normalizeTitle(a.title))) continue;
      final id = idOf(a);
      if (seen.contains(id) || !mine.add(id)) continue;
      out.add(a);
    }
    return out;
  }

  static final _hasContent = RegExp(r"[\p{L}\p{N}]", unicode: true);

  static String _normalizeTitle(String title) =>
      title.toLowerCase().replaceAll(RegExp(r"\s+"), " ").trim();

  static String _body(IliasAnnouncement a) {
    final when = a.when;
    if (when == null) return a.title;
    final d = when.day.toString().padLeft(2, "0");
    final m = when.month.toString().padLeft(2, "0");
    return "${a.title} – $d.$m.";
  }

  /// null => first run / corrupt: callers must seed, never diff against
  /// nothing (that would re-notify the whole board). A wrong-typed element
  /// is corruption TOO: "[1,2]" coerced via "$e" to ids would diff against
  /// never-matching junk and re-notify the entire board through the back
  /// door - exactly what the seed-on-null path exists to prevent.
  static List<String>? _decode(String? raw) {
    if (raw == null) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List || !decoded.every((e) => e is String)) return null;
      return decoded.cast<String>();
    } on Object {
      return null;
    }
  }
}
