import 'package:fuzzywuzzy/fuzzywuzzy.dart';

import '../../agenda/logic/walk_hint.dart';
import '../../l10n/l10n.dart';
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

/// Folds every remaining accented lowercase letter to its ASCII base
/// (ä/ö/ü/ß are handled BEFORE this, as their German search expansions).
/// Built as an index table because this SDK's dart:core ships no Unicode
/// normalization (String.normalize does not exist) and pub deps are frozen.
const _accentFrom =
    "àáâãåāăąçćĉčďèéêëēėęěğģìíîïīĭįıłñńņòóôõøōőŗśŝšşťùúûūŭůųűýÿźżž";
const _accentTo =
    "aaaaaaaaccccdeeeeeeeeggiiiiiiiilnnnooooooorsssstuuuuuuuuyyzzz";

// Hoisted: normalizePlaceText runs per title + per alias + per alias again
// in the fuzzy tier over ~800 places per search settle, so rebuilding the
// 69-char class and the \s+ program per call was hundreds of identical
// compiles per keystroke behind the 16-22 ms measured rank (F3 note above).
// RegExp matching never mutates the object, so sharing is exact.
final _accentFold = RegExp("[$_accentFrom]", unicode: true);
final _whitespace = RegExp(r"\s+");

/// walk_hint's plain lower-casing plus a German umlaut fold, so a freshman
/// typing "kit-cafe" still finds the "KIT-Café" alias.
String normalizePlaceText(String s) {
  var t = s.toLowerCase().trim();
  t = t.replaceAll("ä", "ae").replaceAll("ö", "oe").replaceAll("ü", "ue");
  t = t.replaceAll("ß", "ss");
  // the umlaut expansions only cover ä/ö/ü/ß: every OTHER accented alias
  // in the directory (é in "KIT-Café", ç/ø/å in institute names) stayed
  // unreachable for the accent-free query that promises to find it — the
  // alias tier scored 0 and only fuzzy luck answered. Fold the rest to
  // their base letters so "cafe" reaches "Café" symmetrically (queries
  // pass through here too).
  t = t.replaceAll("æ", "ae").replaceAll("œ", "oe");
  t = t.replaceAllMapped(
      _accentFold, (m) => _accentTo[_accentFrom.indexOf(m[0]!)]);
  return t.replaceAll(_whitespace, " ");
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
    // Normalize each place's aliases exactly ONCE per settle: the alias
    // tier and the fuzzy tier below both consume this list (indexed in
    // lockstep with p.aliasList); the old code ran normalizePlaceText
    // twice per alias for every non-title hit, on top of the per-call
    // regex compiles - pure double work inside the 16-22 ms rank.
    List<String>? normAliases;
    List<String> normalizedAliases() => normAliases ??=
        [for (final a in p.aliasList) normalizePlaceText(a)];
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
      final aliases = p.aliasList;
      final norm = normalizedAliases();
      for (var i = 0; i < aliases.length; i++) {
        final na = norm[i];
        if (na.isEmpty) continue;
        final s = na == nq
            ? 75
            : na.startsWith(nq)
                ? 70
                : na.contains(nq)
                    ? 65
                    : 0;
        if (s == 0) continue;
        // tie-break: among aliases scoring equally the alphabetically
        // first wins, so the shown "auch:" hint no longer rides on the
        // directory order (which shifts across KIT data refreshes)
        if (tier == null ||
            s > score ||
            (s == score &&
                matchedAlias != null &&
                aliases[i].compareTo(matchedAlias) < 0)) {
          tier = PlaceMatchTier.alias;
          score = s;
          matchedAlias = aliases[i];
        }
      }
    }
    if (tier == null && nq.length >= _fuzzyMinQueryLength) {
      var best = weightedRatio(nq, nt);
      final aliases = p.aliasList;
      // reaching here means the alias tier ran (same tier==null gate),
      // so normalizedAliases() returns its memoized list - never a second
      // normalize pass
      final norm = normalizedAliases();
      for (var i = 0; i < aliases.length; i++) {
        final s = weightedRatio(nq, norm[i]);
        if (s > best) {
          best = s;
          matchedAlias = aliases[i];
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
  final certified = out.takeWhile((m) => m.tier != PlaceMatchTier.fuzzy).length;
  return out.length - certified > _fuzzyRowCap
      ? out.sublist(0, certified + _fuzzyRowCap)
      : out;
}

/// "874 m" / "1,2 km" (de) / "1.2 km" (en): one decimal for km, decimal
/// comma only where German is the active language.
String formatCampusDistance(double meters) {
  if (meters < 1000) return "${meters.round()} m";
  final km = (meters / 1000).toStringAsFixed(1);
  return L10n.isEnglish ? "$km km" : "${km.replaceAll('.', ',')} km";
}
