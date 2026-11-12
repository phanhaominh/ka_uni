import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:kit_mobile/l10n/l10n.dart';
import 'package:kit_mobile/mensa/mensa_translate.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// gtx wire shape: [[["en",null,null,10]],null,"de",...]
String gtx(String en) => jsonEncode([
      [
        [en, null, null, 10, 10]
      ],
      null,
      "de"
    ]);

Future<void> settle() =>
    Future<void>.delayed(const Duration(milliseconds: 30));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await L10n.reload(prefOverride: "en");
  });
  tearDown(() async => L10n.reload(prefOverride: "de"));

  group("translator", () {
    test("translates once, caches, notifies", () async {
      var calls = 0;
      final tr = MensaTranslate()
        ..transport = (u) async {
          calls++;
          return http.Response(gtx("Braised beef with dumplings"), 200);
        };
      var notified = 0;
      tr.onChanged = () => notified++;
      tr.request(["Gulasch mit Knödeln"]);
      await tr.idle;
      expect(tr.en("Gulasch mit Knödeln"),
          "Braised beef with dumplings");
      expect(calls, 1);
      expect(notified, 1);
      tr.request(["Gulasch mit Knödeln"]);
      await tr.idle;
      expect(calls, 1, reason: "cache hit must not re-request");
    });

    test("cache survives the install: second instance never goes online",
        () async {
      final first = MensaTranslate()
        ..transport =
            (u) async => http.Response(gtx("Currywurst with potatoes"), 200);
      first.request(["Currywurst mit Kartoffeln"]);
      await settle();
      final p = await SharedPreferences.getInstance();
      expect(p.getString(MensaTranslate.cacheKey), contains("Currywurst"));

      var secondCalls = 0;
      final second = MensaTranslate()
        ..transport = (u) async {
          secondCalls++;
          throw StateError("offline expected");
        };
      second.request(["Currywurst mit Kartoffeln"]);
      await second.idle;
      expect(second.en("Currywurst mit Kartoffeln"),
          "Currywurst with potatoes");
      expect(secondCalls, 0,
          reason: "warm cache = zero network even before restore finishes "
              "(audit: unawaited restore re-queued cached names every boot)");
    });

    test("German UI generates zero third-party traffic", () async {
      await L10n.reload(prefOverride: "de");
      var calls = 0;
      final tr = MensaTranslate()
        ..transport = (u) async {
          calls++;
          return http.Response(gtx("x"), 200);
        };
      tr.request(["Gulasch", "Bratwurst"]);
      await settle();
      expect(calls, 0);
      expect(tr.en("Gulasch"), isNull);
    });

    test("a dead endpoint keeps German and does not retry-storm", () async {
      var calls = 0;
      final tr = MensaTranslate()
        ..transport = (u) async {
          calls++;
          return http.Response("nope", 429);
        };
      tr.request(["Gulasch"]);
      await tr.idle;
      expect(tr.en("Gulasch"), isNull, reason: "failure keeps the German");
      tr.request(["Gulasch"]);
      tr.request(["Gulasch"]);
      await tr.idle;
      expect(calls, 1, reason: "failed this session = not asked again");
    });

    test("malformed endpoint answers are failures, not garbage names",
        () async {
      final tr = MensaTranslate()
        ..transport = (u) async => http.Response("<html>blocked</html>", 200);
      tr.request(["Gulasch"]);
      await tr.idle;
      expect(tr.en("Gulasch"), isNull);
    });

    test("a persistently failing endpoint is given up on", () async {
      // audit 2026-11-12: an EN week of ~40 names against a blocking
      // endpoint used to fire every remaining pair anyway; three straight
      // all-failed batches must silence the session (German stays)
      var calls = 0;
      final tr = MensaTranslate()
        ..transport = (u) async {
          calls++;
          return http.Response("rate limited", 429);
        };
      tr.request([for (int i = 0; i < 12; i++) "Gericht $i"]);
      await tr.idle;
      expect(calls, 6, reason: "3 all-failed batches of 2, then stop");
      expect(tr.en("Gericht 11"), isNull);
    });

    test("requests are queued and drained concurrently-safe", () async {
      var inFlight = 0, peak = 0, done = 0;
      final tr = MensaTranslate()
        ..transport = (u) async {
          inFlight++;
          peak = inFlight > peak ? inFlight : peak;
          await Future<void>.delayed(const Duration(milliseconds: 5));
          inFlight--;
          done++;
          return http.Response(gtx("dish ${u.queryParameters['q']}"), 200);
        };
      tr.request([for (int i = 0; i < 6; i++) "Gericht $i"]);
      await tr.idle;
      expect(done, 6);
      expect(peak, lessThanOrEqualTo(2),
          reason: "must stay a polite two-request burst");
      expect(tr.en("Gericht 3"), "dish Gericht 3");
    });
  });
}
