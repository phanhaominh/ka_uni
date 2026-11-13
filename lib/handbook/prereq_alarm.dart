/// R32.5: the PREREQ-GATE ALARM. Turns "the Schein-Ampel was recomputed
/// against a freshly persisted ledger" into "which modules became newly
/// blocked since the last diff".
///
/// Pure logic: no prefs, no context, no l10n - exactly like the ledger
/// diff it rides (the snapshot string comes straight from prefs, the
/// caller owns the sentence). The persisted snapshot is the compact
/// `module code -> sorted blocker part codes` map behind a "v2:" format
/// tag, and nothing else; the caller rewrites it on EVERY diff so it
/// never rots between pushes.
///
/// Codes, not titles: the handbook is a bundled asset whose strings may
/// be reworded by a later version bump. A title-keyed snapshot would
/// read every reworded (but identical) module as a NEW block and push
/// growth that never happened - so snapshot keys are module codes and
/// blocker entries are part codes (both stable); titles exist only in
/// the caller's sentence, resolved from the FRESH plan ([prereqTitles]).
/// Anything the resolver cannot match (unexpected shapes) falls back to
/// the title verbatim - never to a guess.
///
/// Honesty rule inherited from the Ampel itself: a block entry exists
/// only for prerequisite parts the ledger POSITIVELY shows as failed.
/// The app never sees the full admission ruleset, so the event list is a
/// list of KNOWN blocks - the push wording must never imply completeness,
/// and this module never invents a block it cannot point at.
///
/// Seed discipline (same as ledgerDiff, but SEEDEDNESS IS EXPLICIT):
/// a snapshot without the v2 tag - first-ever, or written by a pre-keying
/// build - announces NOTHING and only seeds. A v2-tagged EMPTY map is
/// NOT the seed state: it is a live "student currently has zero known
/// blocks", and the first real block IS news (the R32 audit caught the
/// empty-means-seed conflation swallowing exactly that case). A
/// poisoned v2 payload degrades back to seed - silence, then re-teach.
library;

import 'dart:convert';

import 'ampel.dart';

/// Prefix every snapshot write carries; also the seed detector.
const prereqSnapshotTag = "v2:";

/// Snapshot form of the plan's known-block map: code of every blocked
/// module -> its blocker PART codes (title-resolved where the plan
/// carries the part, else the title verbatim), sorted so the persisted
/// JSON is stable across identical recomputations.
Map<String, List<String>> prereqSnapshot(AmpelPlan plan) {
  final partCodes = {
    for (final m in plan.all)
      for (final p in m.module.parts) p.title: p.code,
  };
  return {
    for (final m in plan.all)
      if (m.blockedBy.isNotEmpty)
        m.module.code: [
          for (final b in m.blockedBy) partCodes[b] ?? b,
        ]..sort(),
  };
}

/// code -> display title, modules AND parts, from the fresh plan - the
/// caller's sentence builder (an event's codes must never reach the UI
/// unresolved: codes are stable, but humans read titles).
Map<String, String> prereqTitles(AmpelPlan plan) => {
      for (final m in plan.all)
        m.module.code: m.module.title,
      for (final m in plan.all)
        for (final p in m.module.parts) p.code: p.title,
    };

/// One module that grew a KNOWN block since the snapshot.
class PrereqBlockGrowth {
  /// Code of the newly blocked module (the caller owns the sentence).
  final String moduleCode;

  /// Only the BLOCKERS that are new - a module the snapshot already
  /// blocked gains an event solely when its blocker list grew.
  final List<String> newBlockerCodes;

  const PrereqBlockGrowth(this.moduleCode, this.newBlockerCodes);
}

/// Growth events between [blockedNow] (this diff, normally
/// [prereqSnapshot] of a fresh [ampelPlan]) and the persisted
/// [snapshotRaw] (prefs value verbatim, tag included).
///
/// Fires on GROWTH only: a module absent from the snapshot, or a known
/// module that gained at least one blocker. Shrinks (a prerequisite was
/// retaken and passed) and no-change diffs are silent - relief is not
/// news, and a re-announce on every ledger refresh would train the
/// student to ignore the channel. UNTAGGED input (null/empty/first
/// write of this format) is the seed run: silent by contract. A tagged
/// but undecodable payload is ALSO a seed run - silence, re-teach.
List<PrereqBlockGrowth> prereqAlarmDiff({
  required Map<String, List<String>> blockedNow,
  required String? snapshotRaw,
}) {
  if (snapshotRaw == null || !snapshotRaw.startsWith(prereqSnapshotTag)) {
    return const []; // never seeded (or pre-v2): teach, do not announce
  }
  Map<String, List<String>> previous;
  try {
    previous = {
      for (final e in
          (jsonDecode(snapshotRaw.substring(prereqSnapshotTag.length))
                  as Map)
              .entries)
        if (e.key is String && e.value is List)
          e.key as String: [
            for (final b in e.value as List)
              if (b is String) b
          ],
    };
  } on Object {
    return const []; // poisoned v2 payload -> seed run, not spam
  }
  // NOTE: an EMPTY decoded map is deliberately NOT special here - it is
  // the live "no known blocks" state, so every current block below is
  // genuinely new news. (The R32 audit's MAJOR: the old title-keyed
  // version conflated this with the seed state and swallowed the first
  // real block forever.)
  return [
    for (final e in blockedNow.entries)
      if (e.value
          .any((b) => !(previous[e.key] ?? const <String>[]).contains(b)))
        PrereqBlockGrowth(e.key, [
          for (final b in e.value)
            if (!(previous[e.key] ?? const <String>[]).contains(b)) b
        ]),
  ];
}
