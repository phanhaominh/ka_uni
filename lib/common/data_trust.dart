/// R35.2 ONE FRESHNESS VOICE.
///
/// Every scraped surface answers the same question in the same words:
/// "how much do you trust what you see?". Before this, each card picked
/// its own dialect (agenda "As of", mensa "· stale" after a hard 24 h,
/// library "As of HH:MM" with no stale marker at all, home silent) and
/// each threshold was its own magic number. One verdict function, per-
/// source thresholds passed IN (sources legitimately differ: a mensa
/// plan ages over a day, exam windows over a week), per-source wording
/// stays with the source (subline slot).
///
/// The three states are load-bearing, not decoration:
///  * fresh     - within the source's own TTL;
///  * aging     - past TTL but the last-known truth is still on screen
///                WITH its age named; never silently dropped, never
///                presented without the stamp;
///  * untrusted - never fetched, or so old it should not be believed.
///                A card in this state must say WHY it is quiet.
///
/// Weekend-vs-dead-cache lesson (mensa): an EMPTY day is not staleness.
/// Absence of content for a date outside the plan's coverage is an
/// honest "closed/no plan" fact; only the FETCH age decides DataTrust.
/// Do not fold the two.
library;

enum DataTrust { fresh, aging, untrusted }

/// The verdict for one source: [fetchedAt] null => untrusted; age at or
/// below [ttl] => fresh; age within [trustHorizon] of now => aging; past
/// the horizon => untrusted. [now] injected, no clock of its own.
DataTrust dataTrust({
  required DateTime? fetchedAt,
  required DateTime now,
  required Duration ttl,
  required Duration trustHorizon,
}) {
  final at = fetchedAt;
  if (at == null) return DataTrust.untrusted;
  final age = now.difference(at);
  if (age.isNegative) {
    // clock skew or a forged stamp: untrusted, never "fresh" on a lie
    return DataTrust.untrusted;
  }
  if (age <= ttl) return DataTrust.fresh;
  if (age <= trustHorizon) return DataTrust.aging;
  return DataTrust.untrusted;
}
