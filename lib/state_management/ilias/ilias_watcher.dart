import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../ilias/models/ilias_models.dart';
import '../../l10n/l10n.dart';
import '../../notifications/mei_notifications.dart';
import '../../notifications/notification_payload.dart';

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

  /// Injection seam for tests; production deep-links ILIAS pushes to the
  /// PLAIN agenda - never the CHANGED band, whose pulse would highlight a
  /// (possibly empty) timetable-diff section on a pure ILIAS push.
  @visibleForTesting
  static Future<void> Function(String title, String body) notify =
      (title, body) =>
          MeiNotifications.notifyChange(title, body,
              payload: NotificationPayload.agenda);

  /// Guards against two agenda refreshes (init + pull-to-refresh, or a
  /// re-entered route over an orphaned fetch) running the read-modify-write
  /// of the seen list concurrently: both would read the same stale store and
  /// push the SAME announcements twice. Mirrors IliasManager's auth
  /// single-flight; the caller is fire-and-forget so we hand back the shared
  /// in-flight future instead of starting a second pass.
  static Future<void>? _inFlight;

  /// Called after the agenda successfully fetched announcements. Never
  /// throws: a watcher hiccup must not break the agenda refresh.
  /// [stillOurs] re-checks login state before every write/push: the
  /// static teardown epoch is invisible ACROSS isolates, so the poll's
  /// logout fence must come from the platform prefs the main isolate
  /// just swept.
  static Future<void> diffAndNotify(
      List<IliasAnnouncement> fresh,
      {Future<bool> Function()? stillOurs}) {
    final running = _inFlight;
    if (running != null) return running;
    final done = _run(fresh, stillOurs);
    _inFlight = done;
    done.whenComplete(() => _inFlight = null);
    return done;
  }

  static Future<void> _run(
      List<IliasAnnouncement> fresh,
      Future<bool> Function()? stillOurs) async {
    // captured before the first await: a logout mid-fetch bumps the epoch,
    // and every persist/push below must then abort - the sweep has already
    // deleted our key, and re-persisting would resurrect the old student's
    // course titles on a shared device (same fence as every _zoned push)
    final epoch = MeiNotifications.teardownEpoch;
    try {
      final prefs = await SharedPreferences.getInstance();
      final stored = _decode(prefs.getString(seenKey));
      if (stored == null) {
        // seeding the OLD account's board past a logout would resurrect
        // its titles exactly like re-persisting them would
        if (!await _ours(stillOurs, epoch)) return;
        // first run (or unreadable store): seed, notify nothing
        await prefs.setString(seenKey, jsonEncode(_cap([
          for (final a in newOnes(fresh, const {})) idOf(a),
        ], {for (final a in fresh) idOf(a)})));
        return;
      }
      final freshNew = newOnes(fresh, stored.toSet());
      if (freshNew.isEmpty) return;
      if (!await _ours(stillOurs, epoch)) return;
      // persist the seen-marking only AFTER pushing: a silent
      // Android-side drop (plugin returns, nothing throws) used to mark
      // the announcement forever-seen with no notification ever shown -
      // lost, not delayed. A throw leaves the id unmarked too: the next
      // refresh retries it, a late push beats a swallowed one.
      final marked = <String>[];
      // one failing push must not bury its siblings
      for (final a in freshNew.take(_maxNotify)) {
        if (!await _ours(stillOurs, epoch)) return;
        try {
          await notify(
              a.courseTitle.isEmpty
                  ? L10n.t("ilias.notifyFallbackTitle")
                  : a.courseTitle,
              _body(a));
          marked.add(idOf(a));
        } on Object catch (e) {
          if (kDebugMode) print("ilias watcher notify: $e");
        }
      }
      // overflow beyond the per-diff cap was batched, not dropped: mark
      // it anyway, or a whole-board rename would re-notify it every run
      marked.addAll(freshNew.skip(_maxNotify).map(idOf));
      if (marked.isEmpty) return;
      if (!await _ours(stillOurs, epoch)) return;
      final seen = [...stored, ...marked];
      await prefs.setString(
          seenKey, jsonEncode(_cap(seen, {for (final a in fresh) idOf(a)})));
    } on Object catch (e) {
      if (kDebugMode) print("ilias watcher: $e");
    }
  }

  static Future<bool> _ours(
      Future<bool> Function()? stillOurs, int epoch) async {
    if (epoch != MeiNotifications.teardownEpoch) return false;
    return stillOurs == null || await stillOurs();
  }

  /// age-trim to the newest [_maxSeen] (list order = age) - but ids still
  /// on the current board ([onBoard]) are never evicted: trimming a live
  /// announcement out of the seen list makes the next batch that still
  /// carries it look NEW again, resurrecting it as a duplicate push. Only
  /// when the board alone exceeds the cap does the plain age-trim apply.
  static List<String> _cap(List<String> ids, Set<String> onBoard) {
    final excess = ids.length - _maxSeen;
    if (excess <= 0) return ids;
    final dropped = <int>{};
    for (var i = 0; i < ids.length && dropped.length < excess; i++) {
      if (!onBoard.contains(ids[i])) dropped.add(i);
    }
    final kept = [
      for (var i = 0; i < ids.length; i++)
        if (!dropped.contains(i)) ids[i],
    ];
    return kept.length > _maxSeen
        ? kept.sublist(kept.length - _maxSeen)
        : kept;
  }

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
