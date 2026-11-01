import 'package:flutter/material.dart';

import '../agenda/views/agenda_page.dart';
import '../exams/views/exams_page.dart';
import '../notifications/notification_payload.dart';

/// Destinations reachable through a notification deep link.
enum NotificationDeepLink { agenda, agendaToday, agendaChanges, exams }

/// Pure payload -> destination mapping. An unknown or absent payload maps
/// to null: the tap stays a silent no-op (OS-restore spew and notifications
/// posted by older builds can carry anything or nothing).
NotificationDeepLink? deepLinkForPayload(String? payload) => switch (payload) {
      NotificationPayload.agenda => NotificationDeepLink.agenda,
      NotificationPayload.agendaToday => NotificationDeepLink.agendaToday,
      NotificationPayload.agendaChanges => NotificationDeepLink.agendaChanges,
      NotificationPayload.exams => NotificationDeepLink.exams,
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

  /// The main scaffold is on screen (KITNavContainer's first frame once the
  /// login gate opened).
  void shellAppeared() {
    _shellReady = true;
    drain();
  }

  /// Logout tears the scaffold down: later taps must queue again, not push
  /// onto a Navigator that is about to drop back to the login form. Fired
  /// by main.dart the moment profileReady flips false (not only from
  /// KITNavContainer.dispose, which lags the AnimatedSwitcher exit and
  /// never runs on an in-place profileReady flap); idempotent.
  void shellGone() => _shellReady = false;

  void drain() {
    if (!_shellReady) return;
    final nav = navigatorKey.currentState;
    if (nav == null) return; // Navigator detached: hold, retry on resume
    final link = queue.take();
    if (link == null) return;
    final stale = _pushed;
    if (stale != null && stale.navigator == nav) {
      // one-page rule: the previous deep-link page is still on the stack
      // (same or different target) — remove it before pushing, so a burst
      // of taps cannot stack pages that each run a full refresh
      nav.removeRoute(stale);
    }
    final route = MaterialPageRoute(
        // the pages' existing routeName constants as route identity
        settings: RouteSettings(
            name: switch (link) {
              NotificationDeepLink.agenda ||
              NotificationDeepLink.agendaToday ||
              NotificationDeepLink.agendaChanges =>
                AgendaPage.routeName,
              NotificationDeepLink.exams => ExamsPage.routeName,
            }),
        builder: (_) => switch (link) {
              NotificationDeepLink.agenda => const AgendaPage(),
              NotificationDeepLink.agendaToday =>
                const AgendaPage(scrollToToday: true),
              NotificationDeepLink.agendaChanges =>
                const AgendaPage(highlightChanges: true),
              NotificationDeepLink.exams => const ExamsPage(),
            });
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
  }
}
