import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kit_mobile/agenda/logic/walk_hint.dart';
import 'package:kit_mobile/agenda/views/agenda_page.dart';
import 'package:kit_mobile/exams/models/exam_list.dart';
import 'package:kit_mobile/geo/logic/place_search.dart';
import 'package:kit_mobile/geo/models/kit_place.dart';
import 'package:kit_mobile/geo/network/KITTopographyManager.dart';
import 'package:kit_mobile/geo/views/place_search_page.dart';
import 'package:kit_mobile/state_management/kit_provider.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

// directory fixtures in the shape data_de.js ships
KITPlace audimax() => KITPlace(
      id: "10.30",
      title: "Audimax (10.30)",
      category: "Hörsaal",
      aliasList: const ["Audimax", "Gebäude 10.30"],
      positionList: const [
        ["49.0930", "8.4241"]
      ],
    );
KITPlace mensaNord() => KITPlace(
      id: "10.20",
      title: "Mensa Nord",
      category: "Mensa & Cafeteria",
      aliasList: const ["KIT-Café"],
      url: "https://www.swfa.kit.edu/",
      positionList: const [
        ["49.0947", "8.4317"]
      ],
    );
KITPlace building2010() => KITPlace(
      id: "20.10",
      title: "Gebäude 20.10",
      positionList: const [
        ["49.0954", "8.4355"]
      ],
    );
// a bare-number title: the exact-hit case for the "20.30" query
KITPlace bare2030() => KITPlace(id: "x2030", title: "20.30");
KITPlace building2031() => KITPlace(
      id: "20.31",
      title: "Gebäude 20.31",
      positionList: const [
        ["49.0990", "8.4330"]
      ],
    );
// the F4 regression: at the old fuzzy floor of 40, "KIT-Café" ranked
// this institute as its top hit
KITPlace finanz() => KITPlace(
      id: "40.40",
      title: "Finanzwirtschaft (HFI)",
      category: "institute",
    );
// known-category fixture; "spr" is one of its fuzzy near-misses without
// containing a single certified substring
KITPlace sportInstitut() => KITPlace(
      id: "30.10",
      title: "Institut für Sport- und Sportinformatik",
      category: "institute",
      aliasList: const ["Sport"],
    );

Widget harness(
    {String initialQuery = "",
    String? fromRoom,
    List<KITPlace> places = const []}) {
  final vm = KITProvider();
  vm.topographyManager.places = places;
  return ChangeNotifierProvider<KITProvider>.value(
    value: vm,
    child: MaterialApp(
        home: PlaceSearchPage(initialQuery: initialQuery, fromRoom: fromRoom)),
  );
}

void main() {
  group("ranking", () {
    test("'20.30' exact title beats prefix and fuzzy candidates", () {
      final rank =
          rankPlaces([building2031(), bare2030(), building2010()], "20.30");
      expect(rank.first.place.id, "x2030");
      expect(rank.first.tier, PlaceMatchTier.exact);
      // "Gebäude 20.31" only reaches the fuzzy tier and must trail
      expect(rank.last.place.id, isNot("x2030"));
    });

    test("alias match is reported and ranks ahead of fuzzy noise", () {
      final rank =
          rankPlaces([audimax(), mensaNord(), building2010()], "KIT-Café");
      expect(rank.first.place.id, "10.20");
      expect(rank.first.tier, PlaceMatchTier.alias);
      expect(rank.first.matchedAlias, "KIT-Café");
    });

    test("matching is umlaut-insensitive after normalization", () {
      final rank = rankPlaces([audimax(), mensaNord()], "kit-cafe");
      expect(rank.first.place.id, "10.20");
      expect(rank.first.matchedAlias, "KIT-Café");
    });

    test("empty directory or empty query yields no matches", () {
      expect(rankPlaces([audimax()], "   "), isEmpty);
      expect(rankPlaces([], "audimax"), isEmpty);
    });

    test("reference room decorates rows with distance, never re-sorts", () {
      final rank =
          rankPlaces([building2031(), bare2030()], "20.3", from: audimax());
      // "20.30" starts with the query (85) and leads over "Gebäude 20.31"
      // (contains, 80) even though the latter - not the bare one - has a
      // position: relevance only, distance never re-sorts
      expect(rank.first.place.id, "x2030");
      expect(rank.first.distanceMeters, isNull);
      expect(rank.last.place.id, "20.31");
      expect(rank.last.distanceMeters, isNotNull);
      // the reference place itself never shows a "0 m from itself" line
      final self = rankPlaces([audimax()], "Audimax", from: audimax());
      expect(self.single.distanceMeters, isNull);
    });

    // F4 lens pin: the floor-40 fuzzy tier admitted the finance
    // institute for "KIT-Café" (weightedRatio ~46 < new floor 65)
    test("'KIT-Café' certifies the alias hit and drops the finance junk",
        () {
      final rank = rankPlaces(
          [audimax(), mensaNord(), finanz(), building2010()], "KIT-Café");
      expect(rank.first.place.id, "10.20"); // certified alias, not a guess
      expect(rank.first.tier, PlaceMatchTier.alias);
      expect(rank.any((m) => m.place.id == "40.40"), isFalse);
    });

    // F4 lens pin: below 4 normalized chars only certified tiers run
    test("short queries return certified-tier hits only - never guesses",
        () {
      // "spr" fuzzy-almost-matches the sport institute (partial_ratio
      // clears the old 40 bar) but contains NO certified substring:
      // the honest answer is an empty list, not a guess presented as a hit
      final rank = rankPlaces([audimax(), mensaNord(), sportInstitut()], "spr");
      expect(rank, isEmpty);
      // once long enough (4 chars) the certified tiers answer again -
      // here via the alias "KIT-Café" containing "café"
      final long = rankPlaces([mensaNord()], "café");
      expect(long.single.tier, PlaceMatchTier.alias);
    });

    // F9: the fuzzy wall - generic queries used to end in 200 noise rows
    test("fuzzy tier is capped at 12 rows, certified tiers stay complete",
        () {
      final noise = [
        for (var i = 0; i < 20; i++)
          KITPlace(id: "am$i", title: "Audi Max$i") // fuzzy only: no "audimax" substring
      ];
      final rank = rankPlaces([bareAudimaxSimple(), ...noise], "audimax");
      expect(rank.first.place.id, "am-exact");
      expect(rank.first.tier, PlaceMatchTier.exact);
      expect(rank.where((m) => m.tier == PlaceMatchTier.fuzzy).length, 12);
      expect(rank.length, 13); // 1 certified + 12 fuzzy, never 21
    });
  });

  group("snapshot", () {
    test("round-trips through prefs with every search field intact", () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(KITTopographyManager.snapshotKey,
          encodePlacesSnapshot([audimax(), mensaNord()]));

      final restored =
          decodePlacesSnapshot(prefs.getString(KITTopographyManager.snapshotKey))!;
      expect(restored.length, 2);
      final mensa = restored[1];
      expect(mensa.id, "10.20");
      expect(mensa.title, "Mensa Nord");
      expect(mensa.category, "Mensa & Cafeteria");
      expect(mensa.aliasList, const ["KIT-Café"]);
      expect(mensa.url, "https://www.swfa.kit.edu/");
      expect(mensa.positionList, const [
        ["49.0947", "8.4317"]
      ]);
      expect(mensa.latLngFromList!.latitude, closeTo(49.0947, 1e-9));
      expect(mensa.latLngFromList!.longitude, closeTo(8.4317, 1e-9));
    });

    test("corrupt or missing cache decodes to null, restore reads it back",
        () async {
      SharedPreferences.setMockInitialValues(
          {KITTopographyManager.snapshotKey: "{ not json"});
      expect(decodePlacesSnapshot("{ not json"), isNull);
      expect(decodePlacesSnapshot(null), isNull);
      expect(await KITTopographyManager.loadSnapshot(), isNull);

      SharedPreferences.setMockInitialValues({
        KITTopographyManager.snapshotKey:
            encodePlacesSnapshot([audimax()])
      });
      final restored = await KITTopographyManager.loadSnapshot();
      expect(restored!.single.title, "Audimax (10.30)");
    });

    // F5: a payload parsing to [] used to overwrite the snapshot with
    // "[]" and kill the offline cache for every future cold start
    test("an empty parse result never overwrites the offline cache", () async {
      SharedPreferences.setMockInitialValues({});
      expect(await KITTopographyManager.storeSnapshot([audimax(), mensaNord()]),
          isTrue);
      expect(await KITTopographyManager.storeSnapshot(const []), isFalse);
      final prefs = await SharedPreferences.getInstance();
      final stored = prefs.getString(KITTopographyManager.snapshotKey)!;
      expect(stored, isNotEmpty);
      expect(stored, isNot("[]"));
      expect((await KITTopographyManager.loadSnapshot())!.length, 2);
    });

    // F11: the directory rarely changes - identical refetches must not
    // re-store the whole string on every single launch
    test("identical payload skips the prefs write, changed payload writes",
        () async {
      SharedPreferences.setMockInitialValues({});
      final places = [audimax(), mensaNord()];
      expect(await KITTopographyManager.storeSnapshot(places), isTrue);
      expect(await KITTopographyManager.storeSnapshot(places), isFalse);
      expect(await KITTopographyManager.storeSnapshot([audimax()]), isTrue);
    });

    // F7: DATA_* dies in the logout sweep; the public directory must not
    test("snapshot lives under GEO_ and reads the legacy DATA_ key once",
        () async {
      expect(KITTopographyManager.snapshotKey, "GEO_placeSearchSnapshot");
      // upgrade path: pre-rename cache still restores the directory
      SharedPreferences.setMockInitialValues({
        "DATA_placeSearchSnapshot": encodePlacesSnapshot([audimax()]),
      });
      expect((await KITTopographyManager.loadSnapshot())!.single.title,
          "Audimax (10.30)");
      // new writes land under GEO_ ...
      await KITTopographyManager.storeSnapshot([building2010()]);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString("GEO_placeSearchSnapshot"), isNotNull);
      // ... and shadow the legacy key for good
      expect((await KITTopographyManager.loadSnapshot())!.single.id, "20.10");
    });
  });

  group("distance formatting", () {
    test("haversine metres render German-style km/m", () {
      // ~1.11 km straight north of the Audimax
      final meters =
          metersBetween(LatLng(49.0930, 8.4241), LatLng(49.1030, 8.4241));
      expect(meters, inInclusiveRange(1050, 1180));
      expect(formatCampusDistance(meters), startsWith("1,"));
      expect(formatCampusDistance(meters), endsWith("km"));
      expect(formatCampusDistance(874.6), "875 m");
    });
  });

  group("page", () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    testWidgets("typing filters the result rows live", (tester) async {
      await tester.pumpWidget(
          harness(places: [audimax(), mensaNord(), building2010()]));
      await tester.pump();
      // empty-query state: explainer + quick chips
      expect(find.text("Mensa"), findsOneWidget); // chip label

      await tester.enterText(find.byType(CupertinoTextField), "Audimax");
      await tester.pump(const Duration(milliseconds: 250)); // debounce settles
      expect(find.text("Audimax (10.30)"), findsOneWidget);
      expect(find.text("Mensa Nord"), findsNothing);

      await tester.enterText(find.byType(CupertinoTextField), "quzzzquark");
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.text("Keine Treffer"), findsOneWidget);
      // F8: the dead end must point at the next step
      expect(find.textContaining("Gebäudenummer versuchen"), findsOneWidget);
    });

    // F3: a full rank costs 16-22 ms for multi-token rooms (> one frame)
    // - typing must trigger exactly ONE rank, when the keys settle
    testWidgets("rapid keystrokes rank once, only after the settle",
        (tester) async {
      await tester.pumpWidget(
          harness(places: [audimax(), mensaNord(), building2010()]));
      await tester.pump();
      final field = find.byType(CupertinoTextField);
      // "Aud" already prefix-matches the Audimax: with the old
      // per-keystroke rank, each of these pumps would have rendered it
      for (final typed in ["A", "Au", "Aud"]) {
        await tester.enterText(field, typed);
        await tester.pump(const Duration(milliseconds: 60));
        expect(find.text("Audimax (10.30)"), findsNothing);
      }
      // the timer only completes 200 ms after the LAST keystroke
      await tester.pump(const Duration(milliseconds: 150));
      expect(find.text("Audimax (10.30)"), findsOneWidget);
      expect(find.text("Keine Treffer"), findsNothing);
    });

    testWidgets("clearing the field is instant, not debounce-gated",
        (tester) async {
      await tester.pumpWidget(
          harness(places: [audimax(), mensaNord(), building2010()]));
      await tester.pump();
      final field = find.byType(CupertinoTextField);
      await tester.enterText(field, "Audimax");
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.text("Audimax (10.30)"), findsOneWidget);

      await tester.tap(find.byIcon(CupertinoIcons.clear_thick_circled));
      await tester.pump(); // ONE frame, no 200 ms wait
      expect(find.text("Audimax (10.30)"), findsNothing);
      expect(find.text("Häufig gesucht"), findsOneWidget); // empty view
    });

    testWidgets("quick chip seeds the query", (tester) async {
      await tester.pumpWidget(
          harness(places: [audimax(), mensaNord(), building2010()]));
      await tester.pump();
      await tester.tap(find.text("Mensa"));
      // chips seed through the same debounced path as keystrokes
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.text("Mensa Nord"), findsOneWidget);
      expect(find.text("Audimax (10.30)"), findsNothing);
    });

    testWidgets("tapping a row expands the details in place", (tester) async {
      await tester.pumpWidget(harness(initialQuery: "Mensa", places: [mensaNord()]));
      await tester.pump();
      expect(find.text("KIT-Website öffnen"), findsNothing);

      await tester.tap(find.text("Mensa Nord"));
      await tester.pump();
      expect(find.text("Aliase: KIT-Café"), findsOneWidget);
      expect(find.text("KIT-Website öffnen"), findsOneWidget);
      expect(find.text("www.swfa.kit.edu"), findsOneWidget);

      // tapping again collapses
      await tester.tap(find.text("Mensa Nord"));
      await tester.pump();
      expect(find.text("KIT-Website öffnen"), findsNothing);
    });

    testWidgets("pushed from a room, rows carry its distance", (tester) async {
      await tester.pumpWidget(harness(
          initialQuery: "20.10",
          fromRoom: "Audimax",
          places: [audimax(), building2010()]));
      await tester.pump();
      expect(find.textContaining("≈"), findsOneWidget);
      expect(find.textContaining("von Audimax (10.30)"), findsOneWidget);
    });

    // F6: rows must not print raw English codes for the four real categories
    testWidgets("category codes localize, unknown codes stay raw",
        (tester) async {
      await tester.pumpWidget(harness(initialQuery: "Sport", places: [
        sportInstitut(),
        KITPlace(
            id: "shs",
            title: "Sport-Hochschule",
            category: "Hochschule", // not one of the four live codes
            aliasList: const ["Sport"]),
      ]));
      await tester.pump();
      expect(find.text("Institut"), findsOneWidget); // institute -> de
      expect(find.text("Hochschule"), findsOneWidget); // unknown -> raw
    });

    // F12: only launchable http(s) URLs get the button at all
    testWidgets("unlaunchable urls never render the website button",
        (tester) async {
      await tester.pumpWidget(harness(initialQuery: "Prüfungsamt", places: [
        KITPlace(
            id: "pa1", title: "Prüfungsamt Wirren", url: "mailto:pa@kit.edu"),
        KITPlace(
            id: "pa2",
            title: "Prüfungsamt Kladderadatsch",
            url: "kit.edu/pa"), // no scheme, no host: unparsable as a link
      ]));
      await tester.pump();
      expect(find.text("Prüfungsamt Wirren"), findsOneWidget);
      for (final title in ["Prüfungsamt Wirren", "Prüfungsamt Kladderadatsch"]) {
        await tester.tap(find.text(title)); // expand both in turn
        await tester.pump();
        expect(find.text("KIT-Website öffnen"), findsNothing, reason: title);
      }
    });

    // F10: the prefs read must not surface a premature "Keine Treffer"
    testWidgets("cold start never flashes 'Keine Treffer' mid prefs read",
        (tester) async {
      // empty manager AND empty snapshot cache: load completes async
      await tester.pumpWidget(harness(initialQuery: "audimax"));
      // the frame rendered while loadSnapshot is pending must be the
      // placeholder, not the prematurely empty result list
      expect(find.text("Keine Treffer"), findsNothing);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      // now the cache is genuinely empty: the honest message + hint
      expect(find.text("Keine Treffer"), findsOneWidget);
      expect(find.textContaining("Gebäudenummer versuchen"), findsOneWidget);
    });
  });

  group("agenda entry point", () {
    Widget line(String room) => ChangeNotifierProvider<KITProvider>.value(
          value: KITProvider()..topographyManager.places = [building2010()],
          child: MaterialApp(
              home: Scaffold(body: Center(child: AgendaRoomLine(room: room)))),
        );

    // F1: agenda rows push their room string as query; KIT placeholder
    // rooms ("-"/"--"/"ILIAS") measured 16-89 junk rows and must stay
    // plain Text without a tap target
    testWidgets("placeholder rooms '-' / '--' / 'ILIAS' are not tappable",
        (tester) async {
      for (final junk in ["-", "--", "ILIAS", "ilias"]) {
        await tester.pumpWidget(line(junk));
        expect(
            find.ancestor(
                of: find.text(junk), matching: find.byType(GestureDetector)),
            findsNothing,
            reason: junk);
        await tester.tapAt(tester.getCenter(find.text(junk)));
        await tester.pump();
        expect(find.byType(PlaceSearchPage), findsNothing, reason: junk);
      }
    });

    // F2: the sole entry point must LOOK tappable
    testWidgets("a real room is tinted and opens the Raum-Finder",
        (tester) async {
      await tester.pumpWidget(line("20.30"));
      final textFinder = find.text("20.30");
      expect(
          find.ancestor(
              of: textFinder, matching: find.byType(GestureDetector)),
          findsOneWidget);
      final scheme = Theme.of(tester.element(textFinder)).colorScheme;
      expect(tester.widget<Text>(textFinder).style!.color, scheme.primary);

      await tester.tap(textFinder);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500)); // route push
      expect(find.byType(PlaceSearchPage), findsOneWidget);
    });

    // F1: displayRoom-normalized query, verified choice: cleanRoom only
    // folds duplicated tokens; ICS matching/dedupe keep the raw room
    testWidgets("duplicate room tokens are folded before they become a query",
        (tester) async {
      await tester.pumpWidget(line("Gottlieb-Daimler-HS HS bldg 10.21"));
      expect(find.text("Gottlieb-Daimler-HS bldg 10.21"), findsOneWidget);
    });

    test("roomLabel stays ILIAS-friendly, the tap gate is stricter", () {
      expect(ExamTerm.isPlaceholderRoom("ILIAS"), isTrue);
      expect(ExamTerm.isPlaceholderRoom(" - "), isTrue);
      expect(ExamTerm.isPlaceholderRoom("20.30"), isFalse);
      // exported exam ICS: "ILIAS" as the LOCATION of an online Klausur
      // is information, so roomLabel keeps passing it through (verified:
      // gating the tap on the broader set is the only behavior change)
      expect(ExamTerm("Di, 16.04.2027", "10:00", "ILIAS").roomLabel, "ILIAS");
      expect(ExamTerm("Di, 16.04.2027", "10:00", "--").roomLabel, isEmpty);
    });
  });

  test("alias ties resolve deterministically: alphabetically first wins", () {
    // two aliases scoring identically on "xy": without the tie-break the
    // first in directory order claimed the displayed "auch:" hint, and
    // that order shifts across KIT data refreshes
    final tie = KITPlace(
      id: "tie",
      title: "Testgebäude",
      aliasList: const ["Beta-Xy", "Alpha-Xy"],
    );
    final match = rankPlaces([tie], "xy").single;
    expect(match.tier, PlaceMatchTier.alias);
    expect(match.matchedAlias, "Alpha-Xy");
  });
}

// plain title-only fixture for the fuzzy-cap test
KITPlace bareAudimaxSimple() => KITPlace(id: "am-exact", title: "Audimax");
