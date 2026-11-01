import 'package:fuzzywuzzy/fuzzywuzzy.dart';

import '../../agenda/logic/walk_hint.dart';
import '../models/kit_place.dart';

/// Ranking logic for the Raum-Finder ([PlaceSearchPage]): a pure function
/// over the already-downloaded campus directory (824 live places in
/// data_de.js, 2026-11), no I/O, no context. Cost note: one full rank
/// measures 16-22 ms for multi-token agenda rooms (over the 16.7 ms
/// frame budget), 6.8-14.2 ms for plain names - so the PAGE debounces
/// keystrokes; this file stays timer-free.

/// Relevance tiers, best first: an exact title hit beats a prefix hit,
/// which beats an alias hit, which beats a weightedRatio fuzzy hit.
enum PlaceMatchTier { exact, prefix, alias, fuzzy }

class PlaceMatch {
  final KITPlace place;
  final PlaceMatchTier tier;
  final int score;

  /// The alias that produced the match (row shows the "auch: …" hint),
  /// null when the title itself matched.
  final String? matchedAlias;

  /// Great-circle metres from the reference room, only set when the page
  /// was pushed with one and both sides carry a position.
  final double? distanceMeters;

  const PlaceMatch(
      {required this.place,
      required this.tier,
      required this.score,
      this.matchedAlias,
      this.distanceMeters});
}

/// walk_hint's plain lower-casing plus a German umlaut fold, so a freshman
/// typing "kit-cafe" still finds the "KIT-Café" alias.
String normalizePlaceText(String s) {
  var t = s.toLowerCase().trim();
  t = t.replaceAll("ä", "ae").replaceAll("ö", "oe").replaceAll("ü", "ue");
  t = t.replaceAll("ß", "ss");
  return t.replaceAll(RegExp(r"\s+"), " ");
}

/// Below this weightedRatio a fuzzy hit is noise, not a candidate. The
/// old 40 bar let "KIT-Café" surface the Finanzwirtschaft institute on
/// top - junk dressed as a result. Walk hints resolve with a 75 bar
/// (they must CERTIFY a room); interactive search keeps a lower bar
/// here, backed by _fuzzyMinQueryLength and _fuzzyRowCap.
const int _fuzzyMinScore = 65;

/// 1-3 characters carry no real signal: the directory's edit distances
/// all cluster near the floor, so short queries would spray guesswork.
/// Below this normalized length only the CERTIFIED tiers (exact/prefix/
/// alias - substring truth) are consulted; "20.30" style numbers never
/// needed fuzzy anyway.
const int _fuzzyMinQueryLength = 4;

/// After the sort, the fuzzy tier is capped at this many rows so a
/// generic query cannot end in a 200-row wall of near-noise. The
/// certified tiers stay complete (they sort ahead of the fuzzy block).
const int _fuzzyRowCap = 12;

/// Ranks [places] for [query]: exact title > prefix/contains on title
/// (building numbers live inside titles like "Gebäude 20.30") > alias match
/// > weightedRatio fuzzy over title+aliases. Inside a tier: score,
/// descending. Never sorts by [from] distance - that is a decoration.
List<PlaceMatch> rankPlaces(List<KITPlace> places, String query,
    {KITPlace? from}) {
  final nq = normalizePlaceText(query);
  if (nq.isEmpty || places.isEmpty) return const [];
  final fromPos = from?.latLngFromList;
  final out = <PlaceMatch>[];
  for (final p in places) {
    final nt = normalizePlaceText(p.title);
    PlaceMatchTier? tier;
    var score = 0;
    String? matchedAlias;
    if (nt == nq) {
      tier = PlaceMatchTier.exact;
      score = 100;
    } else if (nt.startsWith(nq)) {
      tier = PlaceMatchTier.prefix;
      score = 85;
    } else if (nt.contains(nq)) {
      tier = PlaceMatchTier.prefix;
      score = 80;
    }
    if (tier == null) {
      for (final a in p.aliasList) {
        final na = normalizePlaceText(a);
        if (na.isEmpty) continue;
        final s = na == nq ? 75 : na.startsWith(nq) ? 70 : na.contains(nq) ? 65 : 0;
        if (s == 0) continue;
        if (tier == null || s > score) {
          tier = PlaceMatchTier.alias;
          score = s;
          matchedAlias = a;
        }
      }
    }
    if (tier == null && nq.length >= _fuzzyMinQueryLength) {
      var best = weightedRatio(nq, nt);
      for (final a in p.aliasList) {
        final s = weightedRatio(nq, normalizePlaceText(a));
        if (s > best) {
          best = s;
          matchedAlias = a;
        }
      }
      if (best >= _fuzzyMinScore) {
        tier = PlaceMatchTier.fuzzy;
        score = best;
      }
    }
    if (tier == null) continue;
    double? distanceMeters;
    final pos = p.latLngFromList;
    if (fromPos != null && pos != null && p.id != from!.id) {
      // reuse the walk-hint haversine; the reference room itself needs no
      // "0 m from itself" line
      distanceMeters = metersBetween(fromPos, pos);
    }
    out.add(PlaceMatch(
        place: p,
        tier: tier,
        score: score,
        matchedAlias: matchedAlias,
        distanceMeters: distanceMeters));
  }
  out.sort((a, b) {
    final byTier = a.tier.index.compareTo(b.tier.index);
    return byTier != 0 ? byTier : b.score.compareTo(a.score);
  });
  // certified tiers sort first, so the trailing block is exactly fuzzy
  final certified =
      out.takeWhile((m) => m.tier != PlaceMatchTier.fuzzy).length;
  return out.length - certified > _fuzzyRowCap
      ? out.sublist(0, certified + _fuzzyRowCap)
      : out;
}

/// "874 m" / "1,2 km" - German decimal comma, one decimal for km.
String formatCampusDistance(double meters) {
  if (meters < 1000) return "${meters.round()} m";
  return "${(meters / 1000).toStringAsFixed(1).replaceAll('.', ',')} km";
}
