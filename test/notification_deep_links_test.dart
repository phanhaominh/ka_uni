import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kit_mobile/agenda/views/agenda_page.dart';
import 'package:kit_mobile/exams/views/exams_page.dart';
import 'package:kit_mobile/common_ui/highlight_pulse.dart';
import 'package:kit_mobile/navigation/notification_deep_links.dart';
import 'package:kit_mobile/state_management/kit_provider.dart';
import 'package:kit_mobile/timetable/models/webcal.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Stands in for KITNavContainer: its first frame reports the main shell
/// to the router exactly like the real scaffold does.
class ShellStub extends StatefulWidget {
  const ShellStub({super.key, required this.router});

  final NotificationDeepLinkRouter router;

  @override
  State<ShellStub> createState() => _ShellStubState();
}

class _ShellStubState extends State<ShellStub> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.router.shellAppeared();
    });
  }

  @override
  Widget build(BuildContext context) => const Scaffold(body: Text("shell"));
}

class RecordingObserver extends NavigatorObserver {
  final List<String?> pushed = [];
  final List<String?> removed = [];

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      pushed.add(route.settings.name);

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      removed.add(route.settings.name);
}

Widget harness(NotificationDeepLinkRouter router,
        {required NavigatorObserver observer, Widget? home}) =>
    ChangeNotifierProvider<KITProvider>(
      create: (_) => KITProvider(),
      child: MaterialApp(
        navigatorKey: router.navigatorKey,
        navigatorObservers: [observer],
        home: home ?? ShellStub(router: router),
      ),
    );

void main() {
  group("payload -> destination mapping", () {
    test("morning digest -> agenda (plain)", () {
      expect(deepLinkForPayload('agenda'), NotificationDeepLink.agenda);
    });
    test("lecture reminder -> agenda scrolled to today", () {
      expect(deepLinkForPayload('agenda:today'),
          NotificationDeepLink.agendaToday);
    });
    test("CHANGED delta push -> agenda with band highlight", () {
      expect(deepLinkForPayload('agenda:changes'),
          NotificationDeepLink.agendaChanges);
    });
    test("exam registration deadline -> exams", () {
      expect(deepLinkForPayload('exams'), NotificationDeepLink.exams);
    });
    test("signmeup deadline -> agenda (card only renders there)", () {
      // SignMeUp reminders post the plain agenda payload: /exams shows
      // zero SignMeUp content, the SignMeUpMineCard lives on the agenda
      expect(deepLinkForPayload('agenda'), NotificationDeepLink.agenda);
    });
    test("absent payload -> no destination", () {
      expect(deepLinkForPayload(null), isNull);
    });
    test("foreign or malformed payloads -> no destination", () {
      for (final junk in ["", "agenda:", "agenda;today", "EXAMS", "settings",
        " agenda", "agenda:today ", "agenda:exam"]) {
        expect(deepLinkForPayload(junk), isNull, reason: junk);
      }
    });
  });

  group("pending queue semantics", () {
    test("consume on an empty queue yields null", () {
      final q = NotificationDeepLinkQueue();
      expect(q.take(), isNull);
      expect(q.isEmpty, isTrue);
    });
    test("set then consume returns the link and clears", () {
      final q = NotificationDeepLinkQueue()
        ..set(NotificationDeepLink.agenda);
      expect(q.take(), NotificationDeepLink.agenda);
      expect(q.isEmpty, isTrue);
      expect(q.take(), isNull);
    });
    test("set twice -> last wins", () {
      final q = NotificationDeepLinkQueue()
        ..set(NotificationDeepLink.agenda)
        ..set(NotificationDeepLink.exams);
      expect(q.pending, NotificationDeepLink.exams);
      expect(q.take(), NotificationDeepLink.exams);
      expect(q.take(), isNull); // never the superseded one
    });
    test("set after consume works again", () {
      final q = NotificationDeepLinkQueue()
        ..set(NotificationDeepLink.agendaToday)
        ..take()
        ..set(NotificationDeepLink.agendaChanges);
      expect(q.take(), NotificationDeepLink.agendaChanges);
    });
  });

  group("router queue path (cold start / login gate still closed)", () {
    late NotificationDeepLinkRouter router;
    setUp(() => router = NotificationDeepLinkRouter());

    test("unknown or absent payload queues nothing (no-op)", () {
      router.handleTap(null);
      router.handleTap('');
      router.handleTap('nonsense');
      expect(router.hasPending, isFalse);
    });
    test("tap before the shell exists is queued", () {
      router.handleTap('agenda:today');
      expect(router.queue.pending, NotificationDeepLink.agendaToday);
    });
    test("queued taps collapse: last wins", () {
      router.handleTap('exams');
      router.handleTap('agenda:changes');
      expect(router.queue.pending, NotificationDeepLink.agendaChanges);
    });
    test("drain without a shell is a no-op that KEEPS the link", () {
      router.handleTap('agenda');
      router.drain(); // (shell not ready: handleTap's drain attempt was inert)
      expect(router.hasPending, isTrue);
    });
    test("shell without an attached Navigator keeps the link (never lost)",
        () {
      router.handleTap('exams');
      router.shellAppeared(); // no widget tree -> navigatorKey.currentState null
      expect(router.hasPending, isTrue);
    });
    test("shellGone (logout) blocks draining again", () {
      router.handleTap('exams');
      router.shellAppeared();
      router.shellGone();
      router.drain();
      expect(router.hasPending, isTrue);
      expect(router.shellReady, isFalse);
    });
  });

  testWidgets("queued deep link navigates exactly once when the shell appears",
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final router = NotificationDeepLinkRouter();
    final observer = RecordingObserver();
    router.handleTap('exams'); // tap arrived before any app UI existed

    await tester.pumpWidget(harness(router, observer: observer));
    // the shell's first frame (post-frame, like KITNavContainer) drained;
    // "/" is MaterialApp's own home route push the observer also records
    expect(observer.pushed, ["/", "/exams"]);
    expect(router.hasPending, isFalse);

    // a second drain pass must not double-push
    router.drain();
    expect(observer.pushed, ["/", "/exams"]);
  });

  testWidgets("agenda deep links map to the agenda route", (tester) async {
    SharedPreferences.setMockInitialValues({});
    final router = NotificationDeepLinkRouter();
    final observer = RecordingObserver();
    router.handleTap('agenda:changes');

    await tester.pumpWidget(harness(router, observer: observer));
    expect(observer.pushed, ["/", "/agenda"]);
    expect(router.hasPending, isFalse);
  });

  testWidgets("tap with the shell already up navigates immediately",
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final router = NotificationDeepLinkRouter();
    final observer = RecordingObserver();

    await tester.pumpWidget(harness(router, observer: observer));
    expect(observer.pushed, ["/"]); // only MaterialApp's home push

    router.handleTap('exams'); // foreground / resumed-background tap
    expect(observer.pushed, ["/", "/exams"]); // same frame, no waiting
    expect(router.hasPending, isFalse);
  });

  testWidgets("repeated taps keep exactly one deep-link page on the stack",
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final router = NotificationDeepLinkRouter();
    final observer = RecordingObserver();

    // a freshly pushed route materialises one frame after the push
    Future<void> draw() async {
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400)); // transition
    }

    await tester.pumpWidget(harness(router, observer: observer));
    expect(observer.pushed, ["/"]); // only MaterialApp's home push

    router.handleTap('exams');
    await draw();
    expect(find.byType(ExamsPage), findsOneWidget);
    expect(observer.pushed, ["/", "/exams"]);

    // same target tapped again while the page is still up: replaced,
    // never stacked (a second page would run its own full refresh)
    router.handleTap('exams');
    await draw();
    expect(observer.removed, ["/exams"]);
    expect(observer.pushed, ["/", "/exams", "/exams"]);
    expect(find.byType(ExamsPage), findsOneWidget); // still exactly one

    // different target: still exactly one deep-link page at a time
    router.handleTap('agenda:changes');
    await draw();
    expect(observer.removed, ["/exams", "/exams"]);
    expect(observer.pushed, ["/", "/exams", "/exams", "/agenda"]);
    expect(find.byType(ExamsPage), findsNothing);
    expect(find.byType(AgendaPage), findsOneWidget);

    // the user popping frees the slot: the page is gone, and the next
    // tap pushes fresh without any dedupe removal (popped routes never
    // re-report through didRemove here, so assert the observable state)
    router.navigatorKey.currentState!.pop();
    await tester.pumpAndSettle(); // pop animation + teardown flush
    expect(find.byType(AgendaPage), findsNothing); // page really gone
    router.handleTap('agenda');
    await draw();
    expect(observer.removed, ["/exams", "/exams"]); // no new removal
    expect(observer.pushed.last, "/agenda");
    expect(observer.pushed.length, 5);
    expect(find.byType(AgendaPage), findsOneWidget); // exactly one page
    expect(router.hasPending, isFalse);
  });

  testWidgets("shellGone before a drain keeps the queued link unpushed",
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final router = NotificationDeepLinkRouter();
    final observer = RecordingObserver();

    // shell live with an ATTACHED Navigator: drain could push right now
    await tester.pumpWidget(harness(router, observer: observer));
    expect(observer.pushed, ["/"]);

    // main.dart fires shellGone the instant profileReady flips false,
    // long before KITNavContainer.dispose would
    router.shellGone();
    router.handleTap('agenda:today'); // tap arrives mid-teardown
    await tester.pump();

    expect(observer.pushed, ["/"]); // nothing pushed onto the dying shell
    expect(router.hasPending, isTrue); // link survives for the next shell
    expect(find.text("shell"), findsOneWidget);
  });

  testWidgets("unknown payload with the shell up does nothing",
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final router = NotificationDeepLinkRouter();
    final observer = RecordingObserver();

    await tester.pumpWidget(harness(router, observer: observer));
    router.handleTap('mystery');
    expect(observer.pushed, ["/"]); // still just the home route
    expect(find.text("shell"), findsOneWidget);
  });

  group("agenda arrival options", () {
    // shallow-pumps the real page: seeded changes pref, mocked prefs plugin,
    // and the KITProvider the widget tree reads (offline-safe: the network
    // hops die in the test HttpOverrides before touching timers)
    Future<void> pumpAgenda(WidgetTester tester,
        {required bool highlightChanges}) async {
      SharedPreferences.setMockInitialValues({
        "DATA_webcalChanges": IcsChange.encode([
          IcsChange(
              kind: IcsChangeKind.changed,
              title: "Algorithmen",
              when: DateTime(2026, 11, 2, 10),
              room: "10.30",
              oldRoom: "10.10"),
        ]),
      });
      await tester.pumpWidget(ChangeNotifierProvider<KITProvider>(
        create: (_) => KITProvider(),
        child: MaterialApp(
            home: AgendaPage(highlightChanges: highlightChanges)),
      ));
      // pump until the mocked-prefs _refresh pass has landed (bounded,
      // fake-async advances instantly; avoids microtask-order flakiness)
      for (var i = 0;
          i < 10 && find.textContaining("Algorithmen").evaluate().isEmpty;
          i++) {
        await tester.pump();
      }
    }

    testWidgets("CHANGED band pulses when arrived via deep link",
        (tester) async {
      await pumpAgenda(tester, highlightChanges: true);
      expect(find.textContaining("Algorithmen"), findsWidgets);
      expect(find.byKey(HighlightPulse.pulseKey), findsOneWidget);
    });

    testWidgets("CHANGED band stays quiet on normal arrival", (tester) async {
      await pumpAgenda(tester, highlightChanges: false);
      expect(find.textContaining("Algorithmen"), findsWidgets);
      expect(find.byKey(HighlightPulse.pulseKey), findsNothing);
    });
  });

  group("scrollToToday deep-link arrival", () {
    // the today card is NOT at its final position on the first frame:
    // the CHANGED band and the running-lecture banner appear above it
    // only with the cached/live _refresh rebuild — the old first-frame
    // ensureVisible measured a position the card never keeps
    Future<void> pumpAgendaWithData(WidgetTester tester,
        {required bool scrollToToday}) async {
      // short viewport (standard 800 width, so nothing else rewraps):
      // band + banner push the today card below the 240 px fold
      tester.view.physicalSize = const Size(800, 240);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final now = DateTime.now();
      String two(int n) => n.toString().padLeft(2, "0");
      String stamp(DateTime d) =>
          "${d.year}${two(d.month)}${two(d.day)}"
          "T${two(d.hour)}${two(d.minute)}${two(d.second)}";
      SharedPreferences.setMockInitialValues({
        // one lecture running right now: feeds the today card AND the
        // next-up banner, i.e. the content appearing above it
        "DATA_webcalIcsCache": "BEGIN:VCALENDAR\r\nVERSION:2.0\r\n"
            "BEGIN:VEVENT\r\nUID:today1@kit\r\n"
            "DTSTART:${stamp(now.subtract(const Duration(hours: 1)))}\r\n"
            "DTEND:${stamp(now.add(const Duration(hours: 1)))}\r\n"
            "SUMMARY:Thermodynamics\r\nLOCATION:HS 30\r\nEND:VEVENT\r\n"
            "END:VCALENDAR\r\n",
        "DATA_webcalChanges": IcsChange.encode([
          for (var i = 0; i < 3; i++)
            IcsChange(
                kind: IcsChangeKind.changed,
                title: "Aenderung $i",
                when: DateTime(2026, 11, 2, 10 + i),
                room: "10.3$i",
                oldRoom: "10.1$i"),
        ]),
      });
      await tester.pumpWidget(ChangeNotifierProvider<KITProvider>(
        create: (_) => KITProvider(),
        child: MaterialApp(
            home: AgendaPage(scrollToToday: scrollToToday)),
      ));
      // wait for the cache-load rebuild: the CHANGED band is a built and
      // visible first child, so its text proves the data pass landed
      for (var i = 0;
          i < 10 && find.textContaining("Aenderung 0").evaluate().isEmpty;
          i++) {
        await tester.pump();
      }
      // armed ensureVisible runs from the rebuild's post-frame callback
      // and animates 300 ms; the lazily-built today card materialises as
      // the scroll brings it into range (bounded — a no-op arrival exits
      // once the animation window has passed)
      for (var i = 0;
          i < 6 && find.textContaining("Thermodynamics").evaluate().isEmpty;
          i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    double agendaScroll(WidgetTester tester) => tester
        .state<ScrollableState>(find.byType(Scrollable).first)
        .position
        .pixels;

    testWidgets("re-anchors to the today card after the data rebuild",
        (tester) async {
      await pumpAgendaWithData(tester, scrollToToday: true);
      // the card sits below the 240 px fold once data rendered: only a
      // scroll run AFTER the data rebuild can reach it
      expect(agendaScroll(tester), greaterThan(0));
    });

    testWidgets("stays a hard no-op when scrollToToday is false",
        (tester) async {
      await pumpAgendaWithData(tester, scrollToToday: false);
      // the data rendered (band is a built, visible first child)...
      expect(find.textContaining("Aenderung 0"), findsWidgets);
      // ...and nothing scrolled at all
      expect(agendaScroll(tester), 0);
    });
  });
}
