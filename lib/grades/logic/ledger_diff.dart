/// R29: the LEDGER DIFF. Turns "the Studienverlauf tree was re-fetched"
/// into "which grades were announced since the last fetch".
///
/// Pure logic: no prefs, no context, no l10n - it returns the events and
/// the UI formats the German sentence.
///
/// The snapshot is deliberately tiny - `titleKey -> "state|gradeLabel"` -
/// because the caller persists it between fetches. That is the same reason
/// CampusManager.writeStudentData stores one compact JSON blob: the
/// DEPRECATED per-module cache next to it stored a full page of HTML per
/// row and died of exactly that weight. A snapshot must never carry raw
/// HTML, titles duplicated, or anything the diff does not read.
///
/// Seed discipline (the loud one): with an EMPTY previous snapshot nothing
/// ever fires. A first install has 30+ already-graded modules; announcing
/// each of them as "newly published" on first launch would be a lie (they
/// were not published while the student was away - the app just learned of
/// them) and a notification-storm. First fetch only SEEDS the snapshot;
/// announcements start with the second fetch.
library;

import '../models/grade_book.dart';

/// One grade cell as the ledger remembers it: display state plus the
/// verbatim grade label. No re-normalization on either side - both
/// snapshots are built by GradeBook's classifier, so rewriting e.g. the
/// German comma here could only ever mask a real "5,0 -> 1,3" retake.
String _encode(GradeEntry e) => '${e.state.name}|${e.gradeLabel}';

/// Remember the current tree as a persistable map.
///
/// [entries] should be `GradeBook.modules` (already de-duplicated), but a
/// caller passing raw tree rows stays safe: if one titleKey appears twice,
/// the LAST copy wins. The tree lists retake attempts chronologically, so
/// the last row is the current truth - and because both snapshots are
/// built with the same rule, the double-listed copies of one module can
/// never masquerade as a pending -> graded publication between two fetches
/// (unlike GradeBook._supersedes, which picks the best DISPLAYABLE copy,
/// the diff must pick the SAME copy every time, or it re-announces on
/// every refresh).
///
/// Rows with an empty titleKey (untitled rows) are skipped: they cannot
/// identify anything and must never enter the persisted map.
Map<String, String> ledgerSnapshot(List<GradeEntry> entries) {
  final snapshot = <String, String>{};
  for (final e in entries) {
    if (e.titleKey.isEmpty) continue;
    snapshot[e.titleKey] = _encode(e);
  }
  return snapshot;
}

/// One module whose grade cell changed loudly enough to tell the student.
class PublishedGrade {
  final String titleKey;

  /// Display title of the CURRENT entry; the UI owns the German text.
  final String title;

  /// New grade label, verbatim ("1,3", "bestanden"); empty while pending.
  final String gradeLabel;
  final GradeState state;

  /// False: freshly published (absent before, or was pending - the real
  /// "grade published" signal). True: an ALREADY-GRADED cell changed its
  /// label, i.e. a corrected grade or a retake result landed (5,0 -> 1,3).
  final bool changed;

  PublishedGrade.fromEntry(GradeEntry entry, {required this.changed})
      : titleKey = entry.titleKey,
        title = entry.title,
        gradeLabel = entry.gradeLabel,
        state = entry.state;
}

/// Announcements between [previous] (a snapshot of the last fetch) and
/// [now] (this fetch's entries, normally `GradeBook.modules`).
///
/// Fires exactly two kinds of event:
///  * NEW (changed=false): the titleKey is absent from the snapshot, or
///    was pending and is now graded - the pending -> graded flip is the
///    actual publication a student waits for.
///  * CHANGED (changed=true): snapshot state was already graded and the
///    grade label differs - retake or correction.
///
/// Stays silent on everything else: pending -> pending, rows that VANISHED
/// from this fetch (silence is not an announcement - pushing "your grade
/// disappeared" on a render glitch would train the student to distrust the
/// channel), untitled rows, and - always - an empty [previous] (seed run).
List<PublishedGrade> ledgerDiff({
  required List<GradeEntry> now,
  required Map<String, String> previous,
}) {
  if (previous.isEmpty) return const [];

  // Last copy wins per titleKey, same rule as ledgerSnapshot, so a
  // non-deduplicated caller cannot make prev and now disagree on WHICH
  // copy of a double-listed module they are comparing. Insertion order of
  // first appearance is kept: events arrive in tree order.
  final latest = <String, GradeEntry>{};
  for (final e in now) {
    if (e.titleKey.isEmpty) continue;
    latest[e.titleKey] = e;
  }

  final events = <PublishedGrade>[];
  for (final e in latest.values) {
    final prev = previous[e.titleKey];
    if (prev == null) {
      events.add(PublishedGrade.fromEntry(e, changed: false));
      continue;
    }
    final bar = prev.indexOf('|');
    final prevState = bar < 0 ? prev : prev.substring(0, bar);
    final wasPending = prevState == GradeState.pending.name;
    if (wasPending && e.state != GradeState.pending) {
      // the publication itself - new news, not a "change"
      events.add(PublishedGrade.fromEntry(e, changed: false));
    } else if (!wasPending && _encode(e) != prev) {
      events.add(PublishedGrade.fromEntry(e, changed: true));
    }
    // wasPending && still pending: nothing happened.
  }
  return events;
}
