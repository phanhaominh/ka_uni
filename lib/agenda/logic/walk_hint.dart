import 'package:fuzzywuzzy/fuzzywuzzy.dart';
import 'package:latlong2/latlong.dart';

import '../../geo/models/kit_place.dart';
import '../../timetable/models/webcal.dart';

final RegExp _buildingNumber = RegExp(r"\b\d{1,2}\.\d{1,2}\b");

const double _walkSpeedMs = 1.3; // calm campus walking speed

/// Address tokens for the fuzzy-bind gate: lower-case runs of letters
/// and digits where an inner dot stays part of the token ("30.11"), so
/// "1001" and "1011" are DIFFERENT tokens. Bare short letter runs
/// carry no signal - single digits do: they ARE room numbers ("HS 1").
final RegExp _addressToken = RegExp(r"[a-zäöüß0-9]+(?:\.[a-zäöüß0-9]+)*");
final RegExp _digitToken = RegExp(r"[0-9]");

Set<String> _addressTokens(String s) => _addressToken
    .allMatches(s.toLowerCase())
    .map((m) => m.group(0)!)
    .where((t) => t.length >= 2 || _digitToken.hasMatch(t))
    .toSet();

/// Resolves an ICS room string ("Geb. 30.11, Hörsaal", "Audimax") to a
/// campus place. Building numbers win over fuzzy names: numbers are
/// exact - and matched only as whole tokens. The fuzzy fallback needs a
/// shared address token with its winner before a room is certified.
KITPlace? resolveRoomPlace(List<KITPlace> places, String room) {
  if (room.trim().isEmpty || places.isEmpty) return null;
  final number = _buildingNumber.firstMatch(room)?.group(0);
  if (number != null) {
    // bounded token match: "1.2" must NOT hit the "21.2" inside
    // "Gebäude 21.2" - a digit or dot next to the number makes it a
    // different building. The old unbounded contains() let directory
    // order certify the WRONG building's walk time.
    final bounded =
        RegExp("(?<![.\\d])${number.replaceAll(".", r"\.")}(?![.\\d])");
    final hits = places.where((p) => bounded.hasMatch(p.title)).toList();
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
  if (best == null || bestScore < 75) return null;
  // A lone ratio certifies WRONG rooms: typo'd numbers score high
  // against each other, so "SR 1001" can bind "Seminarraum 1011". The
  // fuzzy bind must also share real address tokens with the winning
  // place - no hint is better than a confidently wrong walk time.
  final roomTokens = _addressTokens(room);
  final bestTokens = {
    for (final c in [best.title, ...best.aliasList]) ..._addressTokens(c)
  };
  final shared = roomTokens.intersection(bestTokens);
  if (shared.isEmpty) return null;
  // with digits in play the shared token has to be one: differing
  // number-like tokens ("30.11" vs "30.12") are never noise - a
  // generic word must not certify the neighbouring building
  if (roomTokens.any(_digitToken.hasMatch)) {
    return shared.any(_digitToken.hasMatch) ? best : null;
  }
  // purely literal binds need a token of substance: three letters
  // ("hs", "geb") are furniture, not identity - unless the room string
  // carries the place's category ("Hörsaal", "Bibliothek", ...)
  if (shared.any((t) => t.length >= 4)) return best;
  final categoryTokens = _addressTokens(best.category);
  return categoryTokens.intersection(roomTokens).isNotEmpty ? best : null;
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

/// Gap in minutes between two adjacent agenda rows, or null when there is
/// nothing to plan: if EITHER side's end was defaulted by the parser
/// (no DTEND - IcsOccurrence.endGuessed, e.g. a Klausur exported without
/// DTEND), the gap is partly invented and no Fußweg may be certified
/// across it.
int? walkHintGap(IcsOccurrence prev, IcsOccurrence next) {
  if (prev.endGuessed || next.endGuessed) return null;
  final gap = next.start.difference(prev.end).inMinutes;
  if (gap <= 4 || gap > 90) return null;
  return gap;
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
