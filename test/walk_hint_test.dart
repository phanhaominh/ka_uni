import 'package:flutter_test/flutter_test.dart';
import 'package:kit_mobile/agenda/logic/walk_hint.dart';
import 'package:kit_mobile/timetable/models/webcal.dart';
import 'package:kit_mobile/geo/models/kit_place.dart';

// south campus lecture hall cluster vs north campus: ~1 km apart
KITPlace audimax() => KITPlace(
      id: "10.30",
      title: "Audimax (10.30)",
      aliasList: const ["Audimax", "Gebäude 10.30"],
      positionList: const [
        ["49.0930", "8.4241"]
      ],
    );
KITPlace northBuilding() => KITPlace(
      id: "20.10",
      title: "Gebäude 20.10",
      positionList: const [
        ["49.0954", "8.4355"]
      ],
    );
KITPlace nearbyBuilding() => KITPlace(
      id: "10.31",
      title: "Gebäude 10.31",
      positionList: const [
        ["49.0933", "8.4247"]
      ],
    );

void main() {
  test("resolves rooms by building number first, then aliases", () {
    final places = [audimax(), northBuilding()];
    expect(resolveRoomPlace(places, "Geb. 20.10, HS 1")?.id, "20.10");
    expect(resolveRoomPlace(places, "Audimax")?.id, "10.30");
    expect(resolveRoomPlace(places, "Online-Lehrveranstaltung"), isNull);
    expect(resolveRoomPlace(places, "")?.id, isNull);
  });

  test("building numbers match as bounded tokens, not substrings", () {
    // the directory-order trap: an unbounded contains() let "1.2" hit
    // the "21.2" inside "Gebäude 21.2" and certify the WRONG building
    final narrow = KITPlace(id: "1.2", title: "Gebäude 1.2");
    final wide = KITPlace(id: "21.2", title: "Gebäude 21.2");
    expect(resolveRoomPlace([wide, narrow], "1.2, Raum 101")?.id, "1.2");
    expect(resolveRoomPlace([wide, narrow], "Geb. 21.2")?.id, "21.2");
    // no digit-neighbour fallback: unresolvable beats a wrong building
    expect(resolveRoomPlace([wide], "Raum 1.2, 101"), isNull);
  });

  test("fuzzy bind must share real tokens with the winning place", () {
    // differing number-like tokens are never noise: "30.11" may not be
    // certified as its neighbour "30.12", and a mistyped "SR 1001" may
    // not soak into an unrelated seminar room
    final neighbour = KITPlace(id: "30.12", title: "Gebäude 30.12");
    expect(resolveRoomPlace([neighbour], "Gebäude 30.11"), isNull);
    final wrong = KITPlace(id: "sr1011", title: "Seminarraum 1011");
    expect(resolveRoomPlace([wrong], "SR 1001"), isNull);
    // the genuine room still resolves through its shared token
    final right = KITPlace(id: "sr1001", title: "Seminarraum 1001");
    expect(resolveRoomPlace([right], "Seminarraum 1001")?.id, "sr1001");
  });

  test("tight gap across campus warns with walk minutes", () {
    final hint = computeWalkHint(audimax(), northBuilding(), 10);
    expect(hint, isNotNull);
    expect(hint!.tight, isTrue);
    expect(hint.walkMinutes, greaterThan(10));
  });

  test("generous gap across campus is informational only", () {
    final hint = computeWalkHint(audimax(), northBuilding(), 45);
    expect(hint, isNotNull);
    expect(hint!.tight, isFalse);
  });

  test("no hint for same building, near places or silly gaps", () {
    expect(computeWalkHint(audimax(), audimax(), 10), isNull);
    expect(computeWalkHint(audimax(), nearbyBuilding(), 10), isNull);
    expect(computeWalkHint(audimax(), northBuilding(), 2), isNull);
    expect(computeWalkHint(audimax(), northBuilding(), 120), isNull);
    expect(computeWalkHint(null, northBuilding(), 10), isNull);
  });

  IcsOccurrence occ(String uid, int h, int m, {bool guessed = false}) =>
      IcsOccurrence(
          start: DateTime(2026, 11, 2, h, m),
          end: DateTime(2026, 11, 2, h, m).add(const Duration(minutes: 90)),
          title: uid,
          room: "Audimax",
          uid: uid,
          endGuessed: guessed);

  test("a guessed end kills the gap: no certified Fußweg across an "
      "invented interval", () {
    final real1 = occ("a", 8, 0);
    final real2 = occ("b", 10, 0);
    // 09:30 -> 10:00 would be a certifiable gap
    expect(walkHintGap(real1, real2), 30);
    // but not once either side's end is only the parser's +90 default
    expect(walkHintGap(occ("a", 8, 0, guessed: true), real2), isNull);
    expect(walkHintGap(real1, occ("b", 10, 0, guessed: true)), isNull);
    // unchanged silly-gap behaviour
    expect(walkHintGap(real1, occ("c", 9, 20)), isNull); // <= 4 min
    expect(walkHintGap(real1, occ("d", 15, 0)), isNull); // > 90 min
  });
}
