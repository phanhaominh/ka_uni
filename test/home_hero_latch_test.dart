import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kit_mobile/agenda/logic/next_up.dart';
import 'package:kit_mobile/agenda/views/day_decision_banner.dart';
import 'package:kit_mobile/home/views/home_page.dart';
import 'package:kit_mobile/state_management/kit_provider.dart';
import 'package:kit_mobile/timetable/logic/now_clock.dart';
import 'package:kit_mobile/timetable/models/webcal.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
// The hero card reads the stamp/cache pair via the LIVE async API, so the
// test store must back exactly that platform interface - this is also what
// reproduces F-1: the card is the only async reader while every writer is
// legacy, so a null ghost here is exactly what the card saw on-device.
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

/// R31 F-1 regression: a ghost-null stamp/cache read used to be ADOPTED by
/// the hero (_seenFetchedAt=null, empty feed) => stale banner + no hero +
/// a probe comparing null==null forever. Latch must be impossible: the card
/// keeps its last good feed through the ghost and heals once the pair is
/// visible again - via the async probe (cross-process) or the memory
/// handoff (foreground fetch, the on-device hot path).
void main() {
  const opts = SharedPreferencesOptions();
  final real = DateTime.now();
  final today = DateTime(real.year, real.month, real.day);
  // deterministic hero clock: 08:00 today; a 10:00 lecture is then a
  // lecture-day hero while _feedFresh still reads the real clock against
  // the real-stamped test stamps
  final fakeNow = DateTime(today.year, today.month, today.day, 8);

  late InMemorySharedPreferencesAsync store;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    store = InMemorySharedPreferencesAsync.empty();
    SharedPreferencesAsyncPlatform.instance = store;
    NowClock.timeSource = () => fakeNow;
  });
  tearDown(() => NowClock.timeSource = DateTime.now);

  String fmt(DateTime d) => [
        d.year.toString().padLeft(4, "0"),
        d.month.toString().padLeft(2, "0"),
        d.day.toString().padLeft(2, "0"),
        "T",
        d.hour.toString().padLeft(2, "0"),
        d.minute.toString().padLeft(2, "0"),
        "00",
      ].join();
  String ics(String title, int startHour) => [
        "BEGIN:VCALENDAR",
        "VERSION:2.0",
        "PRODID:-//test//home_hero_latch//EN",
        "BEGIN:VEVENT",
        "UID:$title@latch.test",
        "SUMMARY:$title",
        "DTSTART:${fmt(DateTime(today.year, today.month, today.day, startHour))}",
        "DTEND:${fmt(DateTime(today.year, today.month, today.day, startHour, 90))}",
        "LOCATION:HS 100",
        "END:VEVENT",
        "END:VCALENDAR",
      ].join("\r\n");
  // real-clock stamps: _feedFresh compares against the real DateTime.now()
  String freshStamp() => DateTime.now().toIso8601String();

  Future<KITProvider> mount(WidgetTester tester) async {
    late KITProvider provider;
    await tester.pumpWidget(ChangeNotifierProvider<KITProvider>(
      create: (_) => provider = KITProvider(),
      child: MaterialApp(
        home: Scaffold(body: Center(child: NextUpHomeCard())),
      ),
    ));
    await tester.pumpAndSettle();
    return provider;
  }

  // unmount so the card disarms the NowClock timer chain (a pending Timer
  // past the test body fails the test)
  Future<void> unmount(WidgetTester tester) =>
      tester.pumpWidget(const SizedBox());

  void expectHero(String title) {
    expect(find.byType(NextUpCard), findsOneWidget,
        reason: "hero must show the lecture ($title)");
    expect(find.textContaining(title), findsOneWidget);
    expect(find.byType(DayDecisionBanner), findsNothing,
        reason: "a lecture day never banners (the latch signature was "
            "banner-over-empty-feed)");
  }

  testWidgets("null prefs ghost once: card keeps last good feed, heals",
      (tester) async {
    final t1 = freshStamp();
    await store.setString(WebcalKeys.fetchedAt, t1, opts);
    await store.setString(WebcalKeys.icsCache, ics("Alpha Lecture", 10), opts);
    final provider = await mount(tester);
    expectHero("Alpha Lecture");

    // the ghost: the async view of BOTH keys vanishes under a notify - the
    // exact async/legacy mismatch the card is alone to observe (modelled by
    // a stale-empty platform store; the card builds a fresh
    // SharedPreferencesAsync per read, so it sees the swap)
    final converged = store;
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    provider.notifyListeners();
    await tester.pumpAndSettle();

    expectHero("Alpha Lecture"); // not latched onto the ghost

    // heal: the async view finally converges on the legacy/poll write
    SharedPreferencesAsyncPlatform.instance = converged;
    await converged.setString(WebcalKeys.fetchedAt, freshStamp(), opts);
    await converged.setString(
        WebcalKeys.icsCache, ics("Beta Lecture", 11), opts);
    provider.notifyListeners();
    await tester.pumpAndSettle();

    expectHero("Beta Lecture");
    expect(find.textContaining("Alpha Lecture"), findsNothing);
    await unmount(tester);
  });

  testWidgets("memory handoff adopts while the async store still ghosts",
      (tester) async {
    // cold start with a fully ghosted async view: honest "unavailable",
    // nothing latched (seen-stamp untouched => every later signal re-fires)
    final provider = await mount(tester);
    expect(find.byType(NextUpCard), findsNothing);
    expect(find.byType(DayDecisionBanner), findsOneWidget);

    // foreground fetch success, published exactly as
    // _fetchWebcalTimetableInner does: fields BEFORE the notify
    final cm = provider.campusManager;
    cm.webcalWrittenAt = freshStamp();
    cm.webcalMergedFeed = WebcalFeed.parse(ics("Memory Lecture", 10));
    provider.notifyListeners();
    await tester.pumpAndSettle();

    expectHero("Memory Lecture"); // adopted in-process, prefs never moved

    // a later probe round under the still-ghost store must NOT re-latch
    provider.notifyListeners();
    await tester.pumpAndSettle();
    expectHero("Memory Lecture");

    // heal: prefs catch up to the written stamp -> probe is a no-op and
    // the adopted state persists
    await store.setString(WebcalKeys.fetchedAt, cm.webcalWrittenAt!, opts);
    await store.setString(WebcalKeys.icsCache, ics("Memory Lecture", 10), opts);
    provider.notifyListeners();
    await tester.pumpAndSettle();
    expectHero("Memory Lecture");
    await unmount(tester);
  });
}
