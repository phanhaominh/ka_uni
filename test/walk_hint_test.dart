import 'package:flutter_test/flutter_test.dart';
import 'package:kit_mobile/agenda/logic/walk_hint.dart';
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
}
