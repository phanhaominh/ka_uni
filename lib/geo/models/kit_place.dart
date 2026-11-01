import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:latlong2/latlong.dart';

class KITPlace {
  // MARK: - data provided by KIT in https://www.kit.edu/campusplan/public/scripts/data_de.js
  String id = "";
  String title = "";
  String category = "";
  List<String> aliasList = [];
  List<List<String>> positionList = [];
  String url = ""; // url to the website of the corresponding institution

  // MARK: - Data parsed in some special case
  String dataUrl = "";
  // dataUrl is the url to the page of the KITPlace
  // (if KITPlace was found parsing a module info table)


  LatLng? get latLngFromList {
    if (positionList.isEmpty || positionList[0].length != 2) {
      return null;
    }
    
    try {
      final lat = double.parse(positionList[0][0]);
      final lon = double.parse(positionList[0][1]);
      
      return LatLng(lat, lon);
    } catch (exc) {
      if (kDebugMode) {
        print("Failed to parse positionList: $exc");
      }
      return null;
    }
  }

  KITPlace({
    this.id = "",
    this.title = "",
    this.category = "",
    this.aliasList = const [],
    this.positionList = const [],
    this.url = "",
  });

  static KITPlace get empty => KITPlace();

  factory KITPlace.fromJSON(Map<String, dynamic> json) {
    return KITPlace(
      id: "${json["id"]}",
      title: json["title"] ?? "",
      category: json["category"] ?? "",
      aliasList: (json["aliasList"] as List<dynamic>)
          .map((e) => e.toString())
          .toList(),
      positionList: (json["positionList"] as List<dynamic>)
          .map((e) => (e as List<dynamic>).map((coord) => coord.toString()).toList())
          .toList(),
      url: json["url"]?.toString() ?? "",
    );
  }
}

/// Prefs JSON for the offline place snapshot (GEO_placeSearchSnapshot;
/// GEO_*, not the logout-swept DATA_* - see KITTopographyManager
/// .snapshotKey): the 824 live entries (data_de.js, 2026-11) arrive
/// from a single JS file that rarely changes during the semester, so a
/// cold start can serve stale-OK results while the network fetch is
/// still in flight (or the device is offline altogether). Compact: the
/// fields the search UI reads.
String encodePlacesSnapshot(List<KITPlace> places) => jsonEncode(places
    .map((p) => {
          "id": p.id,
          "title": p.title,
          "category": p.category,
          "aliasList": p.aliasList,
          "positionList": p.positionList,
          "url": p.url,
        })
    .toList());

/// Returns null on any parse failure; a corrupt cache must fall back to
/// an empty search page, never to half-parsed places.
List<KITPlace>? decodePlacesSnapshot(String? raw) {
  if (raw == null || raw.isEmpty) return null;
  try {
    final list = jsonDecode(raw) as List<dynamic>;
    return list
        .map((e) => KITPlace.fromJSON(e as Map<String, dynamic>))
        .toList();
  } on Object catch (_) {
    return null;
  }
}