// One place to build "navigate there" URLs for the external Maps app.
// Origin is DELIBERATELY never set: the Google Maps directions URL without
// an origin starts from the user's current location, which is exactly the
// question a student asks at 09:40 ("how do I get to 10.91 RIGHT NOW").
import 'package:latlong2/latlong.dart';

/// Walking-biased directions URL to exact coordinates. 6 decimal places
/// keep the string short while staying far below one-meter error.
String mapsDirectionsUrl(LatLng destination) => Uri(
      scheme: "https",
      host: "www.google.com",
      path: "/maps/dir/",
      queryParameters: {
        "api": "1",
        "destination":
            "${destination.latitude.toStringAsFixed(6)},${destination.longitude.toStringAsFixed(6)}",
        "travelmode": "walking",
      },
    ).toString();

/// Fallback when no coordinates are known: search the place text near KIT
/// so Maps geocodes it and offers the same directions UI.
String mapsSearchUrl(String query) => Uri(
      scheme: "https",
      host: "www.google.com",
      path: "/maps/search/",
      queryParameters: {"api": "1", "query": query},
    ).toString();
