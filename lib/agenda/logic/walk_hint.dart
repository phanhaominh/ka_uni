import 'package:fuzzywuzzy/fuzzywuzzy.dart';
import 'package:latlong2/latlong.dart';

import '../../geo/models/kit_place.dart';

final RegExp _buildingNumber = RegExp(r"\b\d{1,2}\.\d{1,2}\b");

const double _walkSpeedMs = 1.3; // calm campus walking speed

/// Resolves an ICS room string ("Geb. 30.11, Hörsaal", "Audimax") to a
/// campus place. Building numbers win over fuzzy names: numbers are exact.
KITPlace? resolveRoomPlace(List<KITPlace> places, String room) {
  if (room.trim().isEmpty || places.isEmpty) return null;
  final number = _buildingNumber.firstMatch(room)?.group(0);
  if (number != null) {
    final hits = places.where((p) => p.title.contains(number)).toList();
    if (hits.isNotEmpty) return hits.first;
  }
  KITPlace? best;
  var bestScore = 0;
  for (final p in places) {
    final candidates = [p.title, ...p.aliasList];
    for (final c in candidates) {
      if (c.isEmpty) continue;
      final s = weightedRatio(room.toLowerCase(), c.toLowerCase());
      if (s > bestScore) {
        bestScore = s;
        best = p;
      }
    }
  }
  return bestScore >= 75 ? best : null;
}

class WalkHint {
  final int walkMinutes;
  final bool tight;

  WalkHint(this.walkMinutes, this.tight);
}

/// Walk feasibility for a back-to-back lecture pair. Returns null when a
/// place is unknown, the buildings coincide, or the pair is not interesting
/// (tiny or huge gaps - nobody plans a coffee dash across campus for those).
WalkHint? computeWalkHint(
    KITPlace? from, KITPlace? to, int gapMinutes) {
  final a = from?.latLngFromList, b = to?.latLngFromList;
  if (a == null || b == null) return null;
  if (from!.id == to!.id) return null;
  if (gapMinutes <= 4 || gapMinutes > 90) return null;
  final meters = const Distance().as(LengthUnit.Meter, a, b);
  if (meters < 250) return null; // same building cluster
  final walkMinutes = (meters / _walkSpeedMs / 60).ceil();
  return WalkHint(walkMinutes, walkMinutes > gapMinutes);
}

/// Great-circle metres between two resolved room strings; exposed for the
/// agenda (both hints need the pair distance anyway).
double? roomDistanceMeters(KITPlace? a, KITPlace? b) {
  final la = a?.latLngFromList, lb = b?.latLngFromList;
  if (la == null || lb == null) return null;
  return const Distance().as(LengthUnit.Meter, la, lb);
}

/// Haversine through latlong2 for raw coordinates (kept for tests/debug).
double metersBetween(LatLng a, LatLng b) =>
    const Distance().as(LengthUnit.Meter, a, b);
