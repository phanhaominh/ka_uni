/// R32.5: the PREREQ-GATE ALARM. Turns "the Schein-Ampel was recomputed
/// against a freshly persisted ledger" into "which modules became newly
/// blocked since the last diff".
///
/// Pure logic: no prefs, no context, no l10n - exactly like the ledger
/// diff it rides (the snapshot string comes straight from prefs, the
/// caller owns the sentence). The persisted snapshot is the compact
/// `module title -> sorted blocker titles` map and nothing else; the
/// caller rewrites it on EVERY diff so it never rots between pushes.
///
/// Honesty rule inherited from the Ampel itself: a block entry exists
/// only for prerequisite parts the ledger POSITIVELY shows as failed.
/// The app never sees the full admission ruleset, so the event list is a
/// list of KNOWN blocks - the push wording must never imply completeness,
/// and this module never invents a block it cannot point at.
///
/// Seed discipline (same as ledgerDiff): the first-ever snapshot - or a
/// poisoned one - announces NOTHING and only seeds. "The app learned
/// about a block" is not "a block appeared".
library;

import 'dart:convert';

import 'ampel.dart';

/// Snapshot form of the plan's known-block map: display title of every
/// blocked module -> its blocker titles, sorted so the persisted JSON is
/// stable across identical recomputations.
Map<String, List<String>> prereqSnapshot(AmpelPlan plan) => {
      for (final m in plan.all)
        if (m.blockedBy.isNotEmpty) m.module.title: [...m.blockedBy]..sort(),
    };

/// One module that grew a KNOWN block since the snapshot.
class PrereqBlockGrowth {
  /// Display title of the newly blocked module (UI owns the sentence).
  final String module;

  /// Only the BLOCKERS that are new - a module the snapshot already
  /// blocked gains an event solely when its blocker list grew.
  final List<String> newBlockers;

  const PrereqBlockGrowth(this.module, this.newBlockers);
}

/// Growth events between [blockedNow] (this diff, normally
/// [prereqSnapshot] of a fresh [ampelPlan]) and the persisted
/// [snapshotRaw] (JSON of the last diff's map; prefs value verbatim).
///
/// Fires on GROWTH only: a module absent from the snapshot, or a known
/// module that gained at least one blocker. Shrinks (a prerequisite was
/// retaken and passed) and no-change diffs are silent - relief is not
/// news, and a re-announce on every ledger refresh would train the
/// student to ignore the channel. A missing/empty/undecodable
/// [snapshotRaw] is the seed run: silent by contract, the caller's
/// snapshot write teaches the next diff.
List<PrereqBlockGrowth> prereqAlarmDiff({
  required Map<String, List<String>> blockedNow,
  required String? snapshotRaw,
}) {
  if (snapshotRaw == null || snapshotRaw.isEmpty) return const [];
  Map<String, List<String>> previous;
  try {
    previous = {
      for (final e in (jsonDecode(snapshotRaw) as Map).entries)
        if (e.key is String && e.value is List)
          e.key as String: [
            for (final b in e.value as List)
              if (b is String) b
          ],
    };
  } on Object {
    previous = const {}; // undecodable -> seed run, not spam
  }
  // Empty previous is the seed state by contract (first-ever snapshot,
  // or a shape mismatch inside otherwise-valid JSON): announcing every
  // block as "new" would replay the ledgerDiff lesson the wrong way -
  // silence on the seed run, announcements from the NEXT diff on.
  if (previous.isEmpty) return const [];
  return [
    for (final e in blockedNow.entries)
      if (e.value.any((b) => !(previous[e.key] ?? const <String>[]).contains(b)))
        PrereqBlockGrowth(e.key, [
          for (final b in e.value)
            if (!(previous[e.key] ?? const <String>[]).contains(b)) b
        ]),
  ];
}
