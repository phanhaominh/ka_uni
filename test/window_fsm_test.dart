import 'package:flutter_test/flutter_test.dart';
import 'package:kit_mobile/agenda/logic/window_fsm.dart';

/// R34.7: registration windows have a STATE the app may assert about -
/// and every rule about a MISSING bound must keep the app from inventing
/// one. The ping the state machine drives (R33.1 "opens now") fires on
/// the CLOSED->OPEN transition, once.
void main() {
  final now = DateTime(2026, 11, 13, 12);

  test("both bounds: half-open [start, end)", () {
    expect(
        windowState(
            start: now.subtract(const Duration(hours: 1)),
            end: now.add(const Duration(hours: 1)),
            now: now),
        ExamWindowState.open);
    expect(
        windowState(
            start: now.add(const Duration(hours: 1)),
            end: now.add(const Duration(hours: 5)),
            now: now),
        ExamWindowState.closed);
    expect(
        windowState(
            start: now.subtract(const Duration(days: 5)),
            end: now.subtract(const Duration(hours: 1)),
            now: now),
        ExamWindowState.closed);
    // exactly at end: closed; exactly at start: open
    expect(
        windowState(start: now.subtract(const Duration(hours: 1)), end: now, now: now),
        ExamWindowState.closed);
    expect(
        windowState(start: now, end: now.add(const Duration(hours: 1)), now: now),
        ExamWindowState.open);
  });

  test("start only: unknown end never fabricates a close", () {
    expect(
        windowState(
            start: now.subtract(const Duration(days: 3)), now: now),
        ExamWindowState.open);
    expect(
        windowState(start: now.add(const Duration(days: 3)), now: now),
        ExamWindowState.closed);
  });

  test("end only: unknown start never certifies an open", () {
    // end in the future COULD mean "open" or "not yet started" - with no
    // start the app cannot tell: unbekannt (the cockpit's needsAction
    // gate refuses exactly this guess); a PASSED end does certify closed
    expect(
        windowState(end: now.add(const Duration(days: 3)), now: now),
        ExamWindowState.unbekannt);
    expect(
        windowState(end: now.subtract(const Duration(days: 1)), now: now),
        ExamWindowState.closed);
  });

  test("no bounds or inverted bounds: unbekannt, never guessed", () {
    expect(windowState(now: now), ExamWindowState.unbekannt);
    expect(
        windowState(
            start: now.add(const Duration(days: 1)),
            end: now.subtract(const Duration(days: 1)),
            now: now),
        ExamWindowState.unbekannt);
    expect(
        windowState(start: now, end: now, now: now),
        ExamWindowState.unbekannt);
  });

  test("transitions: CLOSED->OPEN pings, unseen-open is a separate group",
      () {
    final t = windowTransitions(previous: {
      "a": ExamWindowState.closed,
      "b": ExamWindowState.open,
      "c": ExamWindowState.unbekannt,
    }, current: {
      "a": ExamWindowState.open, // opened since last poll -> one ping
      "b": ExamWindowState.open, // stayed open -> silent
      "c": ExamWindowState.open, // unknown became known-open -> silent
      "d": ExamWindowState.open, // first sight of an open window
      "e": ExamWindowState.closed,
    });
    expect(t.newlyOpened, ["a"]);
    expect(t.firstSightOpen, ["d"]);
  });

  test("re-closed windows do not re-ping without an open sighting", () {
    final t = windowTransitions(
        previous: {"a": ExamWindowState.closed},
        current: {"a": ExamWindowState.closed});
    expect(t.newlyOpened, isEmpty);
    expect(t.firstSightOpen, isEmpty);
  });
}
