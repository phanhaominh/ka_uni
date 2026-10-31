import 'dart:convert';

import 'package:http/http.dart';
import 'package:kit_mobile/geo/models/kit_place.dart';

class KITTopographyManager {
  static const String dataSrcUrl = "https://www.kit.edu/campusplan/public/scripts/data_de.js";

  List<KITPlace> places = [];

  /// Errors are swallowed by design: the caller fires this during provider
  /// init, a throw there is an unhandled async exception that can kill the
  /// zone; the map simply shows no places until the next launch.
  Future<void> fetchPlaces() async {
    try {
      List<KITPlace> newPlaces = [];

      final response =
          await get(Uri.parse(dataSrcUrl)).timeout(const Duration(seconds: 15));
      String rawResponseBody = response.body;

      // rawResponseBody contains a JS code defining a variable with
      // its value being the array of dictionaries
      // each describing a place. This array is being extracted...
      final startIdx = rawResponseBody.indexOf("[");
      final endIdx = rawResponseBody.lastIndexOf(";");
      if (startIdx < 0 || endIdx <= startIdx) return;
      rawResponseBody = rawResponseBody.substring(startIdx, endIdx);

      //... and parsed...
      List<dynamic> placesData = jsonDecode(rawResponseBody);
      for (final placeData in placesData) {
        Map<String, dynamic> placeDataMap = placeData as Map<String, dynamic>;
        newPlaces.add(KITPlace.fromJSON(placeDataMap));
      }

      places = newPlaces;
    } on Object catch (_) {
      // offline / KIT restructured the JS payload
    }
  }
}