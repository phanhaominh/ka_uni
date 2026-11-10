import 'dart:async';
import 'dart:io' as io;
// ignore: library_prefixes - File needs the unprefixed library too
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:kit_mobile/state_management/campus/campus_manager.dart';
import 'package:kit_mobile/state_management/kit_login_manager.dart';

/// Two live-device classes of failure must never be confused:
///  - a dead SOCKET (offline train, airplane mode) -> "check connection",
///    surface flags keep the last connected verdict
///  - a dead SITE (markup redesign) -> the broken-surface funnel
/// And a dead webcal TOKEN (KIT retires it under a healthy session) must be
/// recognisable as "not a calendar" so the re-provision retry can fire.
void main() {
  group("network-error classification", () {
    test("socket-level failures classify as network", () {
      expect(
          KITLoginManager.isNetworkError(const io.SocketException("no route")),
          isTrue);
      expect(
          KITLoginManager.isNetworkError(
              http.ClientException("connection closed")),
          isTrue);
      expect(KITLoginManager.isNetworkError(TimeoutException("30s")), isTrue);
      expect(
          KITLoginManager.isNetworkError(
              const io.HttpException("bad response")),
          isTrue);
      expect(
          KITLoginManager.isNetworkError(io.HandshakeException("cert pinned")),
          isTrue);
    });

    test("site/logic failures are NOT network errors", () {
      // these must keep walking into the surface-broken funnel
      expect(KITLoginManager.isNetworkError(const FormatException("markup")),
          isFalse);
      expect(KITLoginManager.isNetworkError(StateError("boom")), isFalse);
      expect(KITLoginManager.isNetworkError(Exception("sessionExpired page")),
          isFalse);
    });
  });

  group("feed response gate", () {
    final ics = File("test/fixtures/wc_now.ics").readAsStringSync();

    test("200 + VCALENDAR parses", () {
      final feed = CampusManager.feedFromResponse(
          http.Response(ics, 200, headers: {"content-type": "text/calendar"}));
      expect(feed, isNotNull);
    });

    test("retired token (403/404 page) is not a calendar -> retry fires", () {
      // the Nov-2 device failure: a 200-less error page or a 200 error page
      // without the VCALENDAR marker must read as DEAD, not as "empty week"
      expect(CampusManager.feedFromResponse(http.Response("Forbidden", 403)),
          isNull);
      expect(
          CampusManager.feedFromResponse(
              http.Response("<html>token expired</html>", 200)),
          isNull);
    });

    test("VCALENDAR marker without any event is rejected too", () {
      // parse() returns null for a zero-occurrence body (the old "parse
      // produced no occurrences" funnel) - the gate passes that null
      // through, so a stub feed cannot wipe the cached real calendar
      expect(
          CampusManager.feedFromResponse(
              http.Response("BEGIN:VCALENDAR\r\nEND:VCALENDAR", 200)),
          isNull);
    });
  });
}
