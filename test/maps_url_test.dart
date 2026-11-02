// The directions hand-off to Google Maps is a URL contract: get one
// parameter wrong and Maps opens in the wrong place or mode.
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:kit_mobile/geo/logic/maps_url.dart';

void main() {
  group("mapsDirectionsUrl", () {
    test("omits origin so Maps starts from the current location", () {
      final uri = Uri.parse(
          mapsDirectionsUrl(const LatLng(49.0947012, 8.4316034)));
      expect(uri.queryParameters.containsKey("origin"), isFalse);
      expect(uri.queryParameters["destination"], "49.094701,8.431603");
    });

    test("uses the official Maps deep-link shape, walking mode", () {
      final uri = Uri.parse(mapsDirectionsUrl(const LatLng(49.01, 8.41)));
      expect(uri.scheme, "https");
      expect(uri.host, "www.google.com");
      expect(uri.path, "/maps/dir/");
      expect(uri.queryParameters["api"], "1");
      expect(uri.queryParameters["travelmode"], "walking");
    });

    test("negative and zero coordinates keep their sign", () {
      final uri = Uri.parse(mapsDirectionsUrl(const LatLng(0.0, -75.5)));
      expect(uri.queryParameters["destination"], "0.000000,-75.500000");
    });
  });

  group("mapsSearchUrl", () {
    test("room codes and umlauts survive URL encoding", () {
      final uri =
          Uri.parse(mapsSearchUrl("Geb. 30.30 Hörsaal KIT Karlsruhe"));
      expect(uri.path, "/maps/search/");
      expect(uri.queryParameters["query"],
          "Geb. 30.30 Hörsaal KIT Karlsruhe");
      // the wire form must carry percent-encoding, not a bare umlaut
      expect(uri.toString(), contains("H%C3%B6rsaal"));
    });
  });
}
