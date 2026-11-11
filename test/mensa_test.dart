import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:kit_mobile/common_ui/kit_progress_indicator.dart';
import 'package:kit_mobile/l10n/l10n.dart';
import 'package:kit_mobile/mensa/mensa_html_parser.dart';
import 'package:kit_mobile/mensa/mensa_manager.dart';
import 'package:kit_mobile/mensa/mensa_translate.dart';
import 'package:kit_mobile/mensa/models/mensa_models.dart';
import 'package:kit_mobile/mensa/views/mensa_today_card.dart';
import 'package:kit_mobile/settings/providers/settings_provider.dart'
    show showingMensaKey;
import 'package:kit_mobile/state_management/kit_provider.dart';
import 'package:kit_mobile/toasts/models/toasts_provider.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Fixture: live capture of the popup_plain week view,
/// Mensa am Adenauerring, ISO week 46 of 2026 (11.-15.11.) -
/// real feed of 11.2026, parser invariants pinned from it.
String fixture() =>
    File('test/fixtures/mensa_adenauerring_kw46.html').readAsStringSync();

MensaMeal findMeal(MensaDay day, String needle) => day.lines
    .expand((l) => l.meals)
    .firstWhere((m) => m.name.contains(needle));

void main() {
  final ref = DateTime(2026, 11, 11, 12);

  group("parser on the live fixture", () {
    final days = MensaHtmlParser().parseWeek(fixture(), ref);

    test("pins exact day count and dates (no slack)", () {
      expect(days.map((d) => d.date).toList(),
          [DateTime(2026, 11, 11), DateTime(2026, 11, 12), DateTime(2026, 11, 13)]);
    });

    test("exact meal counts per day", () {
      expect(days[0].mealCount, 40);
      expect(days[1].mealCount, 39);
      expect(days[2].mealCount, 38);
    });

    test("line names keep their cell structure (runs not glued)", () {
      final names = days[0].lines.map((l) => l.name).toList();
      expect(names.first, "Linie 1");
      expect(names, contains("Schnitzelbar"));
      expect(names, contains("[kœri]werk"));
      // "Linie 1Gut & Günstig" was the <br>-gluing regression:
      for (final n in names) {
        expect(RegExp(r"[a-z][A-Z]").hasMatch(n), isFalse,
            reason: "glued runs in line name: $n");
      }
      final korri = days[0].lines.firstWhere((l) => l.name == "[kœri]werk");
      expect(korri.sub, contains("11-14 Uhr"));
    });

    test("VEG means vegetarian, VG means vegan (SW KA legend)", () {
      final gnocchi = findMeal(days[0], "Gnocchi in Käsesauce");
      expect(gnocchi.classifiers, contains("VEG"));
      expect(gnocchi.isVegetarian, isTrue);
      expect(gnocchi.isVegan, isFalse,
          reason: "cheese sauce is NOT vegan - VEG/VG swapped again?");
      final krautsalat = findMeal(days[0], "Krautsalat");
      expect(krautsalat.classifiers, contains("VG"));
      expect(krautsalat.isVegan, isTrue);
    });

    test("prices parse to cents (German comma)", () {
      expect(findMeal(days[0], "Jambalaya").priceCents, 405);
      expect(findMeal(days[0], "Jambalaya").priceText, "4,05 €");
    });

    test("additives split out of the name and leave it clean", () {
      final jambalaya = findMeal(days[0], "Jambalaya");
      expect(jambalaya.additives, ["Se"]);
      expect(jambalaya.name, isNot(contains("(Se)")));
      expect(jambalaya.name,
          "Jambalaya Kreolisches Reisgericht mit Hühnchen");
    });

    test("a rebuilt parser sees the same week after a snapshot round-trip",
        () {
      final encoded = [for (final d in days) d.toJson()];
      final back =
          [for (final j in encoded) MensaDay.fromJson(j)];
      expect(back.length, days.length);
      final b0 = back[0];
      expect(b0.mealCount, days[0].mealCount);
      expect(b0.date, days[0].date);
      final src = findMeal(days[0], "Jambalaya");
      final dst = findMeal(b0, "Jambalaya");
      expect(dst.priceCents, src.priceCents);
      expect(dst.classifiers, src.classifiers);
      expect(dst.additives, src.additives);
    });
  });

  test("year edges: a Dec stamp fetched on Jan 1 is LAST year", () {
    // ISO weeks 1-3 straddle the new year; the old forward-only bump
    // filed such stamps a full year into the future
    const h = "<html><body><h1>Mensa</h1><h1>Mo 28.12.</h1>"
        "<table><tr><td>Linie 1</td><td><table><tr><td>[VG]</td>"
        "<td><span>Testgericht</span></td><td><span>1,00 €</span></td>"
        "</tr></table></td></tr></table></body></html>";
    final days = MensaHtmlParser().parseWeek(h, DateTime(2027, 1, 1, 12));
    expect(days.single.date, DateTime(2026, 12, 28));
  });

  test("a stamp without a table must not steal the next day's table", () {
    // measured live in the midnight window: stamps roll off the served
    // page, and a stamp whose own table is gone must pair with NOTHING -
    // pairing it forward filed Thursday's dishes under Wednesday
    const h = "<html><body><h1>Mensa</h1><h1>Mi 11.11.</h1>"
        "<h1>Do 12.11.</h1>"
        "<table><tr><td>Linie 1</td><td><table><tr><td>[VG]</td>"
        "<td><span>Testgericht</span></td><td><span>1,00 €</span></td>"
        "</tr></table></td></tr></table></body></html>";
    final days = MensaHtmlParser().parseWeek(h, DateTime(2026, 11, 12, 12));
    expect(days.length, 1,
        reason: "Mi has no table of its own; it must not claim Do's");
    expect(days.single.date, DateTime(2026, 11, 12));
    expect(days.single.mealCount, 1);
  });

  test("two tables under the same stamp merge into one day entry", () {
    // lunch and dinner headers can repeat the date stamp; dayFor and the
    // week fence must never face two entries for one calendar day
    const h = "<html><body><h1>Mensa</h1><h1>Mi 11.11.</h1>"
        "<table><tr><td>Linie 1</td><td><table><tr><td></td>"
        "<td><span>Mittag</span></td><td><span>1,00 €</span></td>"
        "</tr></table></td></tr></table>"
        "<h1>Mi 11.11.</h1>"
        "<table><tr><td>Abendessen</td><td><table><tr><td></td>"
        "<td><span>Abendbrot</span></td><td><span>2,00 €</span></td>"
        "</tr></table></td></tr></table></body></html>";
    final days = MensaHtmlParser().parseWeek(h, DateTime(2026, 11, 12, 12));
    expect(days.length, 1);
    expect(days.single.lines.length, 2);
    expect(days.single.mealCount, 2);
  });

  group("manager", () {
    late _Stub stub;
    MensaManager build() {
      final m = MensaManager();
      m.transport = (u) async => stub.respond(u);
      return m;
    }

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      stub = _Stub()..body = fixture();
    });

    test("isoWeek: fixed anchors incl. both ISO year edges", () {
      expect(MensaManager.isoWeek(DateTime(2026, 11, 11)), 46);
      expect(MensaManager.isoWeek(DateTime(2026, 1, 1)), 1); // Thu
      expect(MensaManager.isoWeek(DateTime(2027, 1, 1)), 53,
          reason: "Fri 01.01.2027 belongs to 2026-W53");
      expect(MensaManager.isoWeek(DateTime(2026, 12, 31)), 53);
      expect(MensaManager.isoWeek(DateTime(2024, 1, 1)), 1); // Mon
    });

    test("url carries kw explicitly (remainder-of-week default is a trap)",
        () {
      final u = MensaManager.urlFor(canteen: "adenauerring", isoWeek: 46);
      expect(u, contains("kw=46"));
      expect(u, contains("STYLE=popup_plain"));
    });

    test("fetch stores the snapshot and answers dayFor", () async {
      final m = build();
      expect(
          await m.fetchWeek(
              forDate: DateTime(2026, 11, 11)), isTrue);
      expect(m.days.length, 3);
      expect(m.dayFor(DateTime(2026, 11, 12))!.mealCount, 39);
      final p = await SharedPreferences.getInstance();
      expect(p.getString(MensaKeys.weekCache), isNotNull);
      expect(p.getString(MensaKeys.feedSource), "adenauerring|46");
      expect(p.getString(MensaKeys.diag), isNull);
      // the requested week came from the date, not from any server default
      expect(stub.lastUri!.toString(), contains("kw=46"));
    });

    test("restore() serves a fresh manager offline", () async {
      final m = build();
      await m.fetchWeek(forDate: DateTime(2026, 11, 11));
      final m2 = MensaManager(); // no transport stubbed - offline
      await m2.restore();
      expect(m2.hasData, isTrue);
      expect(m2.dayFor(DateTime(2026, 11, 11))!.mealCount, 40);
    });

    test("TTL: second fetch within window does not hit the network",
        () async {
      final m = build();
      await m.fetchWeek(forDate: DateTime(2026, 11, 11));
      final calls = stub.calls;
      await m.fetchWeek(forDate: DateTime(2026, 11, 11));
      expect(stub.calls, calls, reason: "fresh cache must serve");
      await m.fetchWeek(forDate: DateTime(2026, 11, 11), force: true);
      expect(stub.calls, calls + 1);
    });

    test("HTTP 403 keeps the cache, reports failure, leaves a diag",
        () async {
      final m = build();
      await m.fetchWeek(forDate: DateTime(2026, 11, 11));
      stub.status = 403;
      expect(await m.fetchWeek(force: true), isFalse,
          reason: "the card must be able to toast a real failure");
      expect(m.days.length, 3, reason: "cache survives a failed pull");
      expect(m.diag, contains("403"));
    });

    test("consent/error page never masquerades as an empty week",
        () async {
      final m = build();
      stub.body = "<html><body>Bitte Cookies akzeptieren</body></html>";
      expect(await m.fetchWeek(), isFalse);
      expect(m.days, isEmpty);
      expect(m.diag, contains("gate"));
    });

    test("an empty break week is the TRUTH, not a failure", () async {
      final m = build();
      // real page, no day stamps anywhere = canteen not serving
      stub.body = "<html><h1>Speiseplan</h1>"
          "<p>In dieser Woche keine Ausgabe.</p></html>";
      expect(await m.fetchWeek(), isTrue,
          reason: "no toast for a semester break");
      expect(m.diag, contains("empty week"));
    });

    test("layout drift (stamps present, nothing parseable) says LAYOUT",
        () async {
      final m = build();
      stub.body = "<html><h1>Speiseplan</h1><h1>Fr 13.11.</h1>"
          "<div>restructured</div></html>";
      await m.fetchWeek();
      expect(m.diag, contains("layout"));
    });

    test("a page serving ANOTHER week never writes this week's fence",
        () async {
      final m = build();
      // cached week 46 first
      await m.fetchWeek(forDate: DateTime(2026, 11, 11));
      final before = m.fetchedAt;
      // now request week 47 but the stub keeps serving the week-46
      // fixture (the remainder-of-week trap) -> must refuse to accept
      await m.fetchWeek(forDate: DateTime(2026, 11, 16), force: true);
      expect(m.diag, contains("week: kw=47"));
      expect(m.days[0].date, DateTime(2026, 11, 11),
          reason: "old good cache stays, wrong week not stored");
      expect(m.fetchedAt, before,
          reason: "rejected fetch must not restamp freshness");
      final p = await SharedPreferences.getInstance();
      expect(p.getString(MensaKeys.feedSource), "adenauerring|46",
          reason: "fence must not lie about holding week 47");
    });

    test("hidden-section opt-out also stops the traffic", () async {
      SharedPreferences.setMockInitialValues({showingMensaKey: false});
      final m = build();
      await m.fetchWeek();
      expect(stub.calls, 0,
          reason: "section hidden in settings = zero third-party GETs");
      expect(m.days, isEmpty);
    });

    test("restore after a completed fetch does not clobber with old cache",
        () async {
      final m = build();
      await m.fetchWeek(forDate: DateTime(2026, 11, 11));
      final daysBefore = m.days;
      // poison the persisted cache behind the manager's back, then
      // let a late restore settle: it must no-op, not reseed
      final p = await SharedPreferences.getInstance();
      await p.setString(MensaKeys.weekCache, "[]");
      await m.restore();
      expect(m.days, same(daysBefore));
    });

    test("socket death is a diag line, not a crash and not a wipe",
        () async {
      final m = build();
      await m.fetchWeek(forDate: DateTime(2026, 11, 11));
      stub.throwing = const _FakeSocket();
      await m.fetchWeek(forDate: DateTime(2026, 11, 11), force: true);
      expect(m.days.length, 3);
      expect(m.diag, contains("threw"));
    });
  });

  group("home card", () {
    // pumps the REAL card against a provider whose manager holds a
    // restored week - the same state an offline boot paints
    Future<void> pumpCard(WidgetTester tester,
        {Duration? age,
        withData = true,
        Map<String, Object> extraPrefs = const {}}) async {
      SharedPreferences.setMockInitialValues(extraPrefs);
      final now = DateTime.now();
      final vm = KITProvider();
      vm.mensa.transport =
          (u) async => http.Response("", 403); // card kick must stay offline
      vm.mensa.translate.transport =
          (u) async => http.Response("[]", 503); // no translate traffic either
      if (withData) {
        vm.mensa.days = [
          MensaDay(date: DateTime(now.year, now.month, now.day), lines: [
            MensaLine(name: "Linie 1", meals: [
              MensaMeal(
                  name: "Spaghetti Aglio e Olio",
                  priceCents: 385,
                  classifiers: const ["VEG"],
                  additives: const []),
              MensaMeal(
                  name: "Seelachsfilet",
                  priceCents: 390,
                  classifiers: const ["MSC"],
                  additives: const []),
            ]),
          ]),
        ];
        vm.mensa.fetchedAt =
            now.subtract(age ?? const Duration(hours: 1));
      }
      await tester.pumpWidget(MaterialApp(
        home: MultiProvider(
          providers: [
            ChangeNotifierProvider<KITProvider>.value(value: vm),
            ChangeNotifierProvider(create: (_) => ToastsProvider()),
          ],
          child: Scaffold(
            body: SingleChildScrollView(
              child: SizedBox(width: 360, child: const MensaTodayCard()),
            ),
          ),
        ),
      ));
      await tester.pump();
    }

    testWidgets("renders the cached day with prices and veg badges",
        (tester) async {
      await pumpCard(tester);
      expect(find.text("Spaghetti Aglio e Olio"), findsOneWidget);
      expect(find.text("3,85 €"), findsOneWidget);
      expect(find.text("vegetarisch"), findsOneWidget);
      expect(find.text("vegan"), findsNothing);
      expect(find.textContaining("Stand:"), findsOneWidget);
      // a fresh snapshot must NOT shout staleness
      expect(find.textContaining("evtl. veraltet"), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets("EN UI shows translated names with the German a tap away",
        (tester) async {
      await L10n.reload(prefOverride: "en");
      try {
        await pumpCard(tester, extraPrefs: {
          MensaTranslate.cacheKey: jsonEncode({
            "Spaghetti Aglio e Olio": "Spaghetti with garlic and oil",
            "Seelachsfilet": "Haddock fillet",
            "Linie 1": "Line 1",
          }),
        });
        await tester.pump(); // translation cache restore (async prefs)
        expect(find.text("Spaghetti with garlic and oil"), findsOneWidget);
        expect(find.text("Haddock fillet"), findsOneWidget);
        expect(find.textContaining("Line 1"), findsOneWidget);
        final tips = tester.widgetList<Tooltip>(find.byType(Tooltip));
        expect(tips.map((t) => t.message),
            containsAll(["Spaghetti Aglio e Olio", "Seelachsfilet"]),
            reason: "long-press must still reveal the German original");
      } finally {
        await L10n.reload(prefOverride: "de");
      }
    });

    testWidgets("a >6 h old cache says so in the footer", (tester) async {
      await pumpCard(tester, age: const Duration(hours: 7));
      expect(find.textContaining("evtl. veraltet"), findsOneWidget);
    });

    testWidgets("fresh install with a dead feed offers RETRY, not an "
        "eternal spinner (D1: fetchedAt==null used to spin forever)",
        (tester) async {
      await pumpCard(tester, withData: false);
      expect(find.text("Noch kein Speiseplan geladen."), findsOneWidget);
      expect(find.text("Jetzt laden"), findsOneWidget);
      expect(find.byType(KITProgressIndicator), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets("a day outside a STALE cache admits the cache is old",
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      final vm = KITProvider();
      vm.mensa.transport = (u) async => http.Response("", 403);
      vm.mensa.days = [MensaDay(date: DateTime(2020, 1, 2), lines: const [])];
      vm.mensa.fetchedAt =
          DateTime.now().subtract(const Duration(hours: 30));
      await tester.pumpWidget(MaterialApp(
        home: MultiProvider(
          providers: [
            ChangeNotifierProvider<KITProvider>.value(value: vm),
            ChangeNotifierProvider(create: (_) => ToastsProvider()),
          ],
          child: Scaffold(
            body: SingleChildScrollView(
              child: SizedBox(width: 360, child: const MensaTodayCard()),
            ),
          ),
        ),
      ));
      await tester.pump();
      expect(find.text("Heute keine Ausgabe."), findsOneWidget);
      expect(find.textContaining("evtl. veraltet"), findsOneWidget,
          reason: "a Friday cache claiming 'closed' on a Monday must "
              "admit it is stale, not pose as today's truth");
      expect(tester.takeException(), isNull);
    });

    testWidgets("weekend without plan data shows the closed line",
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      final vm = KITProvider();
      vm.mensa.days = [
        // cached, but NOT today: e.g. a Friday snapshot seen on Sunday
        MensaDay(date: DateTime(2020, 1, 2), lines: const []),
      ];
      vm.mensa.fetchedAt = DateTime.now();
      await tester.pumpWidget(MaterialApp(
        home: MultiProvider(
          providers: [
            ChangeNotifierProvider<KITProvider>.value(value: vm),
            ChangeNotifierProvider(create: (_) => ToastsProvider()),
          ],
          child: Scaffold(
            body: SingleChildScrollView(
              child: SizedBox(width: 360, child: const MensaTodayCard()),
            ),
          ),
        ),
      ));
      await tester.pump();
      expect(find.text("Heute keine Ausgabe."), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}

class _FakeSocket implements Exception {
  const _FakeSocket();
}

class _Stub {
  String body = "";
  int status = 200;
  int calls = 0;
  Uri? lastUri;
  Object? throwing;

  Future<http.Response> respond(Uri u) async {
    calls++;
    lastUri = u;
    final t = throwing;
    if (t != null) throw t;
    return http.Response(body, status,
        headers: {"content-type": "text/html; charset=utf-8"});
  }
}
