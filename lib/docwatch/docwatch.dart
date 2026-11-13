import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// R34.6 — document expiry watch ("Dokumente").
///
/// The user notes documents with a hard expiry (passport, residence permit,
/// insurance certificate). Entries live in the system keychain
/// (FlutterSecureStorage — the app's existing convention from
/// `lib/credentials`), one JSON blob per document under a `DOC_*` key.
///
/// Two rules are load-bearing, both pinned by test/docwatch_test.dart:
///
/// * **Logout dies with the account.** [DocWatchStore.purgeAll] enumerates
///   every `DOC_*` key from the LIVE storage and deletes exactly those —
///   `CredentialsProvider.logout` calls it inside its per-step try/catch,
///   so a keychain hiccup folds into `PartialLogoutException` (reported,
///   never skipped). Never `deleteAll`: the store also holds the KIT
///   credentials and the library keychain copies, and those have their own
///   owners.
/// * **Advisory only — no alarms.** This layer computes tiers, the UI
///   renders them, and NOTHING here ever schedules a notification: a
///   missing document ping when the keychain blips is worse than silence
///   (auto-alarm VETOED).
class DocEntry {
  final String id;
  final String label;

  /// Date-only expiry (time-of-day always 00:00 local).
  final DateTime expiry;

  const DocEntry(
      {required this.id, required this.label, required this.expiry});

  Map<String, dynamic> toJson() => {
        "id": id,
        "label": label,
        "expiry": "${expiry.year.toString().padLeft(4, "0")}-"
            "${expiry.month.toString().padLeft(2, "0")}-"
            "${expiry.day.toString().padLeft(2, "0")}",
      };

  /// Null on ANY malformed or non-map payload — a corrupt entry is dropped,
  /// it never blocks the rest of the list (cache-miss doctrine, R23).
  static DocEntry? decode(String raw) {
    try {
      final j = jsonDecode(raw);
      if (j is! Map) return null;
      final id = j["id"];
      final label = j["label"];
      final expiry = DateTime.parse("${j["expiry"]}");
      if (id is! String || id.isEmpty) return null;
      if (label is! String || label.trim().isEmpty) return null;
      if (expiry.year < 1900) return null;
      return DocEntry(
          id: id,
          label: label.trim(),
          expiry: DateTime(expiry.year, expiry.month, expiry.day));
    } on Object catch (_) {
      return null;
    }
  }
}

/// Warning tier for one document, computed from whole CALENDAR days
/// (same date-difference rule as `L10n.daysFromNow`, never 24-h windows).
enum DocTier { none, ninety, thirty, seven, expired }

/// The 90/30/7 ladder: inside 7 days (incl. today) -> [DocTier.seven],
/// inside 30 -> thirty, inside 90 -> ninety, past -> expired, further out
/// -> none. `now`'s time of day is ignored: a permit expiring at midnight
/// is "today", not "expired at 00:01".
DocTier docTierFor(DateTime expiry, DateTime now) {
  final days = docDaysLeft(expiry, now);
  if (days < 0) return DocTier.expired;
  if (days <= 7) return DocTier.seven;
  if (days <= 30) return DocTier.thirty;
  if (days <= 90) return DocTier.ninety;
  return DocTier.none;
}

/// Whole calendar days until expiry (negative = already expired).
int docDaysLeft(DateTime expiry, DateTime now) {
  final e = DateTime(expiry.year, expiry.month, expiry.day);
  final n = DateTime(now.year, now.month, now.day);
  return e.difference(n).inDays;
}

/// Keychain-backed store of the user's noted documents.
class DocWatchStore {
  /// The ONE prefix logout sweeps out of the keychain (see [purgeAll]).
  static const keyPrefix = "DOC_";

  /// Same iOS keychain group as the KIT credentials — one app, one group.
  static const iOptions = IOSOptions(accountName: "kit-student");
  static const aOptions = AndroidOptions();

  final FlutterSecureStorage _storage;

  DocWatchStore({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  /// All decodable documents, nearest expiry first. Keys that fail to
  /// decode are dropped from storage (self-heal; the corrupt bytes are
  /// useless to render) — a delete throw there never hides the healthy
  /// entries.
  Future<List<DocEntry>> load() async {
    final all = await _storage.readAll(iOptions: iOptions, aOptions: aOptions);
    final entries = <DocEntry>[];
    // materialise first: readAll may hand back the live map itself
    // (the plugin's test platform does), and mutating mid-iteration throws
    for (final key in all.keys.where((k) => k.startsWith(keyPrefix)).toList()) {
      final raw = all[key];
      if (raw == null) continue;
      final e = DocEntry.decode(raw);
      if (e == null) {
        try {
          await _storage
              .delete(key: key, iOptions: iOptions, aOptions: aOptions);
        } on Object catch (_) {
          // undecodable AND undeleteable: still just skip it, the logout
          // purge is the backstop
        }
        continue;
      }
      entries.add(e);
    }
    entries.sort((a, b) => a.expiry.compareTo(b.expiry));
    return entries;
  }

  /// Adds one document; the id is a wall-clock microsecond stamp — entries
  /// are notes, not a concurrency contest, and re-adding the same thing is
  /// the user's call (there is deliberately no edit state, only this and
  /// [remove]).
  Future<void> add(String label, DateTime expiry) async {
    final id = DateTime.now().microsecondsSinceEpoch.toString();
    final e = DocEntry(
        id: id,
        label: label.trim(),
        expiry: DateTime(expiry.year, expiry.month, expiry.day));
    await _storage.write(
        key: "$keyPrefix$id",
        value: jsonEncode(e.toJson()),
        iOptions: iOptions,
        aOptions: aOptions);
  }

  Future<void> remove(String id) =>
      _storage
          .delete(key: "$keyPrefix$id", iOptions: iOptions, aOptions: aOptions);

  /// Logout teardown: enumerate the LIVE storage and delete every `DOC_*`
  /// key. Mirrors the prefs sweep doctrine in `logout()`: read keys through
  /// the live store (never a cached snapshot) and remove exactly the
  /// family's own keys. Errors propagate — the caller owns them
  /// (`failures.add` → `PartialLogoutException`), this layer never swallows
  /// a partial wipe into a lie.
  static Future<void> purgeAll(FlutterSecureStorage storage) async {
    final all = await storage.readAll(iOptions: iOptions, aOptions: aOptions);
    for (final key in all.keys.where((k) => k.startsWith(keyPrefix)).toList()) {
      await storage.delete(key: key, iOptions: iOptions, aOptions: aOptions);
    }
  }
}
