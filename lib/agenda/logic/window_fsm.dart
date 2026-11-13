/// R34.7: exam/SignMeUp registration WINDOW STATE MACHINE.
///
/// A window is open, closed, or UNBEKANNT (unknown). Unknown bounds stay
/// unknown - KIT omits window ends on some lists, and guessing "still
/// open" from a missing end is exactly the fabrication class this fork
/// bans. The machine exists because the app needs a STATE, not just a
/// timestamp: R33.1's "opens now" ping fires on the CLOSED->OPEN
/// TRANSITION (at most once per window even across app restarts), and the
/// cockpit's "+N mehr" flap dies by counting only windows this snapshot
/// can name.
///
/// Pure: no prefs, no clock of its own - the caller supplies `now`.
library;

enum ExamWindowState { open, closed, unbekannt }

/// Derive the state of one window from its (nullable) bounds.
/// Rules, in order, each pinned in test/window_fsm_test.dart:
///  * both bounds known: [start, end) - open iff start <= now < end;
///  * only a start: open iff start <= now (an unknown end does not make a
///    past start closed); a future start is "closed-not-yet" -> reported
///    as closed with a future start the caller can still arm rows from;
///  * only an end: open iff now < end (a known end alone certifies the
///    window has not passed);
///  * neither, or a start not before an end: unbekannt.
ExamWindowState windowState(
    {DateTime? start, DateTime? end, required DateTime now}) {
  if (start != null && end != null) {
    if (!end.isAfter(start)) return ExamWindowState.unbekannt;
    return !start.isAfter(now) && now.isBefore(end)
        ? ExamWindowState.open
        : ExamWindowState.closed;
  }
  if (start != null) {
    // start known, end unknown: never invent the end
    return start.isAfter(now) ? ExamWindowState.closed : ExamWindowState.open;
  }
  if (end != null) {
    // end known, start unknown: a future end CANNOT certify "open" (the
    // window may not have started yet - the cockpit's needsAction gate
    // refuses exactly this guess), a passed end certifies closed
    return now.isBefore(end) ? ExamWindowState.unbekannt : ExamWindowState.closed;
  }
  return ExamWindowState.unbekannt;
}

/// Diff two persisted snapshots: every window that was CLOSED (or unseen)
/// and is OPEN now is a transition worth one ping. Windows absent from
/// [previous] but OPEN now count as transitions only if the caller says
/// they are new (first sight of an open window is exactly the R33.1
/// backfill case) - this function keeps that choice with the caller by
/// returning both groups separately.
({List<String> newlyOpened, List<String> firstSightOpen}) windowTransitions({
  required Map<String, ExamWindowState> previous,
  required Map<String, ExamWindowState> current,
}) {
  final newly = <String>[];
  final fresh = <String>[];
  for (final e in current.entries) {
    if (e.value != ExamWindowState.open) continue;
    final before = previous[e.key];
    if (before == null) {
      fresh.add(e.key);
    } else if (before == ExamWindowState.closed) {
      newly.add(e.key);
    }
  }
  return (newlyOpened: newly, firstSightOpen: fresh);
}
