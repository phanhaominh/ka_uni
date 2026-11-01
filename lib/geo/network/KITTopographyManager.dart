import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';

import 'package:http/http.dart';
import 'package:kit_mobile/geo/models/kit_place.dart';

class KITTopographyManager {
  static const String dataSrcUrl = "https://www.kit.edu/campusplan/public/scripts/data_de.js";

  /// Prefs key of the offline place snapshot (see encodePlacesSnapshot);
  /// the Raum-Finder restores it when the live list is still empty.
  /// Deliberately GEO_*, NOT DATA_*: the logout sweep (see the "Full
  /// data sweep" comment in credentials_provider.logout) deletes every
  /// DATA_* key because it holds PERSONAL data (webcal token, scraped
  /// schedule, ILIAS pins). The campus directory is public KIT data
  /// with zero account relation - it must SURVIVE a logout on a shared
  /// device so the next session cold-starts with a working Raum-Finder.
  static const String snapshotKey = "GEO_placeSearchSnapshot";

  /// The pre-Round-5 key, from when the snapshot still lived under the
  /// swept DATA_* prefix: loadSnapshot reads it once as a fallback so
  /// installs upgrading across this boundary keep their offline
  /// directory (the old key then dies in the next logout sweep like
  /// any other DATA_* entry).
  static const String legacySnapshotKey = "DATA_placeSearchSnapshot";

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

      // An EMPTY parse result is a restructured/emptied payload, not a
      // genuinely empty directory: committing it would blank the map
      // AND overwrite the snapshot with "[]", killing the offline cache
      // for every future cold start. Keep yesterday's directory.
      if (newPlaces.isEmpty) return;

      places = newPlaces;
      // Persist the offline snapshot: a prefs hiccup must never sink
      // the in-memory places
      try {
        await storeSnapshot(newPlaces);
      } on Object catch (_) {}
    } on Object catch (_) {
      // offline / KIT restructured the JS payload
    }
  }

  /// Writes the snapshot under [snapshotKey], returning whether bytes
  /// actually moved. Two guards:
  /// * an empty list never overwrites a good cache (see fetchPlaces);
  /// * an identical payload skips the prefs write - the directory
  ///   changes rarely, and re-storing the whole ~500 KB string on
  ///   every launch (the old behavior) was pure flash churn. Reading
  ///   the stored string first makes the comparison free.
  static Future<bool> storeSnapshot(List<KITPlace> places) async {
    if (places.isEmpty) return false;
    final prefs = await SharedPreferences.getInstance();
    final encoded = encodePlacesSnapshot(places);
    if (prefs.getString(snapshotKey) == encoded) return false;
    await prefs.setString(snapshotKey, encoded);
    return true;
  }

  /// Snapshot restore for cold starts: KIT's data_de.js changes rarely,
  /// so yesterday's directory is good-enough search material while the
  /// live fetch is in flight or the device is offline. Null when nothing
  /// has ever been cached; falls back once to the pre-rename DATA_ key.
  static Future<List<KITPlace>?> loadSnapshot() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return decodePlacesSnapshot(
          prefs.getString(snapshotKey) ?? prefs.getString(legacySnapshotKey));
    } on Object catch (_) {
      return null;
    }
  }
}