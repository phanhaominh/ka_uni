import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../agenda/views/agenda_page.dart';
import '../grades/views/grades_page.dart';
import '../library/library_page.dart';
import '../state_management/kit_provider.dart';
import 'logic/push_page.dart';
import '../exams/views/exams_page.dart';
import '../notifications/notification_payload.dart';

/// Destinations reachable through a notification deep link.
enum NotificationDeepLink {
  agenda,
  agendaToday,
  agendaChanges,
  exams,
  library,
  grades
}

/// Pure payload -> destination mapping. An unknown or absent payload maps
/// to null: the tap stays a silent no-op (OS-restore spew and notifications
/// posted by older builds can carry anything or nothing).
NotificationDeepLink? deepLinkForPayload(String? payload) => switch (payload) {
      NotificationPayload.agenda => NotificationDeepLink.agenda,
      NotificationPayload.agendaToday => NotificationDeepLink.agendaToday,
      NotificationPayload.agendaChanges => NotificationDeepLink.agendaChanges,
      NotificationPayload.exams => NotificationDeepLink.exams,
      // seat check-in safety net: the ping MUST open the library page
      // (audit R21: the payload was emitted but never registered here,
      // so the tap was a silent no-op)
      NotificationPayload.library => NotificationDeepLink.library,
      NotificationPayload.grades => NotificationDeepLink.grades,
      _ => null,
    };

/// Tiny pending queue: set twice -> last wins, consume -> clears.
class NotificationDeepLinkQueue {
  NotificationDeepLink? _pending;

  NotificationDeepLink? get pending => _pending;
  bool get isEmpty => _pending == null;

  void set(NotificationDeepLink link) => _pending = link;

  NotificationDeepLink? take() {
    final link = _pending;
    _pending = null;
    return link;
  }

  void clear() => _pending = null;
}

/// App-level routing of notification taps, identical for every state the
/// tap can arrive in: cold start (launch details), resumed-but-backgrounded
/// (same dispatcher callback as foreground) and foreground.
///
/// Queue path: while the main scaffold does not exist yet (cold start, or
/// the login gate is still closed), [handleTap] only stores the link. The
/// main shell's first frame after login is the lifecycle signal that calls
/// [shellAppeared], which consumes and navigates exactly once. With the
/// shell already on screen, [handleTap] drains immediately. [drain] is also
/// retried on app resume — no polling anywhere.
///
/// One-page rule: at most one deep-link page ever sits on the stack. A tap
/// that arrives while the previous deep-link page is still mounted removes
/// it before pushing, so repeated notification taps can never stack pages
/// that each run their own full refresh (ILIAS SSO chain, up to 45 s
/// SignMeUp wait).
class NotificationDeepLinkRouter {
  NotificationDeepLinkRouter();

  static final NotificationDeepLinkRouter instance =
      NotificationDeepLinkRouter();

  /// Attached to the root MaterialApp by main.dart so taps that arrive
  /// without any UI context can still navigate.
  final GlobalKey<NavigatorState> navigatorKey =
      GlobalKey(debugLabel: "app-root");

  final NotificationDeepLinkQueue queue = NotificationDeepLinkQueue();

  bool _shellReady = false;
  bool get shellReady => _shellReady;
  bool get hasPending => !queue.isEmpty;

  /// The last deep-link page pushed, while it is still on the stack;
  /// see the one-page rule on [drain].
  Route<dynamic>? _pushed;

  void handleTap(String? payload) {
    final link = deepLinkForPayload(payload);
    if (link == null) return;
    queue.set(link);
    drain();
  }

  /// Monotonic shell generation: [shellAppeared] hands out its token and
  /// a [shellGone] carrying an OLDER token no-ops — during a fast
  /// false→true profileReady flap the NEW shell's first frame can run
  /// BEFORE the old shell's AnimatedSwitcher exit disposes, and that late
  /// dispose must not flip the fresh shell back to "not ready" (deep
  /// links would queue forever).
  int _shellGeneration = 0;

  /// The main scaffold is on screen (KITNavContainer's first frame once the
  /// login gate opened). The returned token lets that same shell identify
  /// its own appearance when it later calls [shellGone].
  int shellAppeared() {
    _shellReady = true;
    final token = ++_shellGeneration;
    drain();
    return token;
  }

  /// Logout tears the scaffold down: later taps must queue again, not push
  /// onto a Navigator that is about to drop back to the login form. Fired
  /// by main.dart the moment profileReady flips false (not only from
  /// KITNavContainer.dispose, which lags the AnimatedSwitcher exit and
  /// never runs on an in-place profileReady flap); idempotent. A call
  /// carrying an [appearedToken] older than the newest appearance belongs
  /// to an already-superseded shell and no-ops entirely (see
  /// [_shellGeneration]); token-less calls (main.dart's listener) always
  /// run.
  void shellGone({int? appearedToken}) {
    if (appearedToken != null && appearedToken != _shellGeneration) return;
    _shellReady = false;
    // Session-dead pages must not stay mounted ABOVE the login form: the
    // root AnimatedSwitcher only swaps the ROOT route's content, so every
    // pushed page (exam list, ILIAS webview content, grades) kept showing
    // the dead account's data — and kept its ActivePages key, which made
    // the calendar entry read "already open" (dead icon) until someone
    // popped it. popUntil tears all of them off the app-ROOT Navigator
    // (the only Navigator there is); their armed popped handlers
    // deregister the keys themselves, so the next session's tap pushes
    // fresh instead of deduping against an orphan.
    navigatorKey.currentState?.popUntil((r) => r.isFirst);
    // the popped-slot cleanup runs with the pop ANIMATIONS; clear the
    // reference now so a re-login drain never treats a popped route as
    // the one-page cover to remove (the whenComplete callback re-checks
    // identity and stays silent)
    _pushed = null;
    // A queued link belongs to the dying session: dropping it is the
    // privacy-correct behavior (a post-re-login agenda push the user
    // tapped pre-logout must not fire unbidden for account B).
    queue.clear();
  }

  void drain() {
    if (!_shellReady) return;
    final nav = navigatorKey.currentState;
    if (nav == null) return; // Navigator detached: hold, retry on resume
    final link = queue.take();
    if (link == null) return;
    final routeName = switch (link) {
      NotificationDeepLink.agenda ||
      NotificationDeepLink.agendaToday ||
      NotificationDeepLink.agendaChanges =>
        AgendaPage.routeName,
      NotificationDeepLink.exams => ExamsPage.routeName,
      NotificationDeepLink.library => LibraryPage.routeName,
      NotificationDeepLink.grades => GradesPage.routeName,
    };
    final stale = _pushed;
    final mineStale = stale != null && stale.navigator == nav && stale.isActive;
    // "already open" must mean FOREIGN-open: the router's own live page
    // also owns the key, and deduping against itself would defeat the
    // flag-refresh replace below
    final owner = ActivePages.routeFor(nav, routeName);
    if (owner != null && owner != stale) {
      // a MANUALLY opened page (appbar calendar -> AgendaPage) counts as
      // the target: no clone. If my deep-link page covered it, remove the
      // cover so the tap actually SURFACES the target, and wake the page —
      // a "timetable changed" tap onto an open agenda must reload the
      // announced deltas, the mounted page never re-reads them by itself.
      // The link KIND travels as the resync payload (the suppressed push
      // could not deliver its arrival options as widget params):
      // agenda:today scrolls, agenda:changes pulses. ExamsPage is
      // stateless and rebuild-driven, so the deadline wake is the very
      // fetch its pull-to-refresh runs; the mounted page re-renders from
      // the provider notification.
      if (mineStale) nav.removeRoute(stale);
      switch (link) {
        case NotificationDeepLink.agendaToday:
          unawaited(AgendaResync.request(scrollToToday: true));
        case NotificationDeepLink.agendaChanges:
          unawaited(AgendaResync.request(highlightChanges: true));
        case NotificationDeepLink.agenda:
          unawaited(AgendaResync.request());
        case NotificationDeepLink.exams:
          // the page being foreign-open already proves the provider scope
          // exists (ExamsPage itself resolves KITProvider to render)
          unawaited(Provider.of<KITProvider>(nav.context, listen: false)
              .fetchExams());
        case NotificationDeepLink.library:
          // the booking is already server-side; the page just re-reads
          // the cached manager (its initState kick is cached-first)
          break;
        case NotificationDeepLink.grades:
          // R29 (D2): the ledger renders from already-fetched moduleRows;
          // a re-fetch would be a second full Studienverlauf scrape for a
          // tap whose whole job is "show me what changed"
          break;
      }
      return;
    }
    if (mineStale) {
      // one-page rule: the previous deep-link page is still on the stack
      // (same or different target) — remove it before pushing, so a burst
      // of taps cannot stack pages that each run a full refresh. Safe
      // against the same-name case: popping the stale route fires its
      // armed registry cleanup as a microtask AFTER the fresh route
      // re-registers the key, and the identity check keeps the new owner
      nav.removeRoute(stale);
    }
    final route = MaterialPageRoute(
        // the pages' existing routeName constants as route identity
        settings: RouteSettings(name: routeName),
        builder: (_) => switch (link) {
              NotificationDeepLink.agenda => const AgendaPage(),
              NotificationDeepLink.agendaToday =>
                const AgendaPage(scrollToToday: true),
              NotificationDeepLink.agendaChanges =>
                const AgendaPage(highlightChanges: true),
              NotificationDeepLink.exams => const ExamsPage(),
              NotificationDeepLink.library => const LibraryPage(),
              NotificationDeepLink.grades => const GradesPage(),
            });
    ActivePages.track(nav, routeName, route);
    nav.push(route);
    _pushed = route;
    // the user popping (or a later tap's removal) frees the slot, so the
    // next tap pushes fresh instead of dedupe-removing a dead route
    route.popped.whenComplete(() {
      if (_pushed == route) _pushed = null;
    });
  }

  @visibleForTesting
  void resetForTest() {
    _shellReady = false;
    queue.clear();
    _pushed = null;
    ActivePages.resetForTest();
  }
}
