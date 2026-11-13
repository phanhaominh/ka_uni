import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:kit_mobile/home/views/campus_now_card.dart';
import 'package:kit_mobile/library/anny_api.dart' show AnnyHttp;
import 'package:kit_mobile/library/library_page.dart';
import 'package:kit_mobile/mensa/models/mensa_models.dart';
import 'package:kit_mobile/state_management/kit_provider.dart';
import 'package:kit_mobile/toasts/models/toasts_provider.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// R36.2 CAMPUS-NOW strip contract: the two old home cards' certified
/// facts survive as two honest glance lines - mensa serving window or
/// the closed/valueNone facts with the source's own DataTrust voice per
/// row, the library seat count (0 IS news) inside its 15-minute
/// present-tense window only, and a chevron+tap ONLY on the row that
/// has a route (library -> LibraryPage, the old card's own pushPageOnce
/// target; the mensa card never had a detail route -> no dead chevron).

/// 503 for everything: the strip's wake-on-enable kicks must stay
/// offline in the harness (mensa_test "card kick must stay offline"
/// discipline, applied to both managers)
class _OfflineClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async =>
      http.StreamedResponse(const Stream.empty(), 503);
}

const _slug = "test-hs-ka-lesesaal";

/// anon-cache snapshot in the restore() shape (anny_manager.boot reads
/// rooms+counts+at from one json under ANN_rooms)
String cachedRooms({required DateTime at, int? free}) => jsonEncode({
      "at": at.toIso8601String(),
      if (free != null) "counts": {_slug: free},
      "rooms": [
        {
          "id": "3404",
          "slug": _slug,
          "name": "Test-Lesesaal",
          "color": "",
          "quantity": 138,
          "serviceId": 452,
          "minDuration": 30,
          "maxDuration": 300,
          "interval": 15,
          "advanceDays": 3,
          "cancelMinutesBefore": 0,
          "openFrom": "",
          "openTo": "",
        }
      ],
    });

void main() {
  /// mount the strip against a hermetic KITProvider: mensa state is set
  /// directly on the manager (mensa_test precedent), anny state arrives
  /// through its own cache restore path; both transports stay offline
  Future<KITProvider> mountStrip(WidgetTester tester,
      {bool mensaData = false,
      Duration mensaAge = const Duration(hours: 1),
      String? mensaSub,
      bool mensaMeals = true,
      String? annyCache}) async {
    SharedPreferences.setMockInitialValues(
        annyCache == null ? {} : {"ANN_rooms": annyCache});
    final vm = KITProvider();
    vm.mensa.transport = (u) async => http.Response("", 403);
    vm.anny.http = AnnyHttp(client: _OfflineClient());
    if (mensaData) {
      final now = DateTime.now();
      vm.mensa.days = [
        MensaDay(
            date: DateTime(now.year, now.month, now.day),
            lines: [
              MensaLine(name: "Linie 1", sub: mensaSub, meals: [
                if (mensaMeals)
                  MensaMeal(
                      name: "Spaghetti Aglio e Olio",
                      priceCents: 385,
                      classifiers: const ["VEG"],
                      additives: const []),
              ]),
            ]),
      ];
      vm.mensa.fetchedAt = now.subtract(mensaAge);
    }
    if (annyCache != null) await vm.anny.boot(); // FLUTTER_TEST gate: cache only
    await tester.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider<KITProvider>.value(value: vm),
        ChangeNotifierProvider(create: (_) => ToastsProvider()),
      ],
      // providers ABOVE MaterialApp (home_r35_split_test idiom): a
      // pushed route mounts above the Navigator, outside `home:` -
      // LibraryPage must inherit them or the tap-through test explodes
      child: MaterialApp(
          home: const Scaffold(
              body: SingleChildScrollView(
                  child: SizedBox(width: 360, child: CampusNowCard())))),
    ));
    await tester.pump();
    return vm;
  }

  testWidgets("fresh state: both lines, no markers, silence is fresh",
      (tester) async {
    await mountStrip(tester,
        mensaData: true,
        mensaSub: "Gut & Günstig 11-14 Uhr",
        annyCache: cachedRooms(at: DateTime.now(), free: 42));

    expect(find.text("Campus jetzt"), findsOneWidget);
    expect(find.textContaining("Mensa"), findsWidgets);
    expect(find.textContaining("geöffnet 11:00–14:00"), findsOneWidget,
        reason: "window comes from the SW's own \"11-14 Uhr\" sub stamp");
    expect(find.textContaining("42 Plätze frei"), findsOneWidget);
    // fresh rows stay silent (and an aging dot never appears)
    expect(find.textContaining("evtl. veraltet"), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets("untrusted mensa cache says so in the footer's own word",
      (tester) async {
    await mountStrip(tester,
        mensaData: true,
        mensaSub: "11-14 Uhr",
        mensaAge: const Duration(hours: 30),
        annyCache: cachedRooms(at: DateTime.now(), free: 42));

    expect(
        find.textContaining("evtl. veraltet"),
        findsOneWidget,
        reason: "past the 24 h horizon the mensa row must name itself "
            "untrusted - the deleted card's footer word, same l10n key");
    // ...while still painting its last-known plan (the old card did)
    expect(find.textContaining("geöffnet 11:00–14:00"), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets("zero seats IS news in the strip", (tester) async {
    await mountStrip(tester,
        annyCache: cachedRooms(at: DateTime.now(), free: 0));

    expect(find.textContaining("0 Plätze frei"), findsOneWidget,
        reason: "the old card printed \"0 Plätze frei\" muted - in a "
            "two-line glance, zero is the news, not filler");
    expect(tester.takeException(), isNull);
  });

  testWidgets("a seat count past 15 min never renders as a number",
      (tester) async {
    await mountStrip(tester,
        mensaData: true,
        mensaSub: "11-14 Uhr",
        annyCache: cachedRooms(
            at: DateTime.now().subtract(const Duration(minutes: 20)),
            free: 42));

    expect(find.textContaining("Plätze frei"), findsNothing,
        reason: "gap planner doctrine: \"free NOW\" on a stale count "
            "is a lie with numbers - the row shows valueNone + the word");
    expect(find.textContaining("—"), findsOneWidget,
        reason: "only the library row falls back - mensa is fresh here");
    expect(find.textContaining("evtl. veraltet"), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets("tap-through: library row opens LibraryPage, mensa row "
      "renders no chevron (it never had a route)", (tester) async {
    await mountStrip(tester,
        mensaData: true,
        mensaSub: "11-14 Uhr",
        annyCache: cachedRooms(at: DateTime.now(), free: 42));

    // F-12: exactly one chevron on the whole strip - the library row
    expect(find.byIcon(Icons.chevron_right), findsOneWidget);

    await tester.tap(find.textContaining("42 Plätze frei"));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.byType(LibraryPage), findsOneWidget,
        reason: "the strip row must land exactly where the deleted "
            "card's own body tap went (LibraryPage.routeName)");
    expect(tester.takeException(), isNull);
  });

  testWidgets("nothing cached: two honest dashes, both rows say why",
      (tester) async {
    await mountStrip(tester);

    expect(find.textContaining("—"), findsNWidgets(2),
        reason: "valueNone for every unknown - never a fabricated zero");
    expect(find.textContaining("evtl. veraltet"), findsNWidgets(2),
        reason: "never-fetched is untrusted (mensa closedCard's "
            "forcedStale precedent): say WHY the row is quiet");
    expect(find.byType(CampusNowCard), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
