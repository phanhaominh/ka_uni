import 'package:flutter/material.dart';

/// Per-Navigator live map of page identity key -> the Route that owns it.
/// Shared by [pushPageOnce] and the notification deep-link router so BOTH
/// entry paths dedupe against each other: a manually opened AgendaPage and
/// a deep-link tap onto "/agenda" are the same page.
///
/// Keyed by [NavigatorState]: the deep-link harness (tests) and any future
/// scoped Navigator must not dedupe against another Navigator's pages. The
/// app itself has exactly ONE Navigator for its whole lifetime (root
/// MaterialApp navigator; no nested `Navigator(` exists), so entries are
/// naturally bounded and the shell/logout flap never clears live pages.
///
/// Values (not just membership) matter twice:
///  * removal fires on [Route.popped] but only deletes the entry if it
///    STILL belongs to that route - the deep-link "remove stale, push
///    fresh" path completes the old route's popped AFTER the new route
///    registered the same key (microtask ordering), and a blind remove
///    would silently deregister the live page;
///  * the router must distinguish "this page is open" from "THIS page is
///    open": its own stale route is registered too, and dedupe against
///    itself would defeat the flag-refresh replace.
class ActivePages {
  ActivePages._();

  static final Map<NavigatorState, Map<String, Route<dynamic>>> _open = {};

  static bool isOpen(NavigatorState nav, String key) =>
      _open[nav]?.containsKey(key) ?? false;

  /// The route currently holding [key] on [nav], if any.
  static Route<dynamic>? routeFor(NavigatorState nav, String key) =>
      _open[nav]?[key];

  /// Register [key] on [nav] as owned by [route]; removal is armed on
  /// [Route.popped] (user pop or removeRoute both complete it) but only
  /// fires for the route that still owns the key (see class doc).
  static void track(NavigatorState nav, String key, Route<void> route) {
    _open.putIfAbsent(nav, () => <String, Route<dynamic>>{})[key] = route;
    route.popped.whenComplete(() {
      if (_open[nav]?[key] == route) _open[nav]!.remove(key);
    });
  }

  @visibleForTesting
  static void resetForTest() => _open.clear();
}

/// Pushes [page] under identity [routeName] at most once at a time: an
/// impatient double-tap used to stack N identical pages (each running its own
/// full refresh) behind N back-presses. If the page is already open the tap
/// is a no-op - matching the dock's ILIAS dedupe the app converges on.
Future<T?> pushPageOnce<T>(
  NavigatorState nav, {
  required String routeName,
  required Widget Function(BuildContext) page,
}) {
  if (ActivePages.isOpen(nav, routeName)) return Future<T?>.value();
  final route = MaterialPageRoute<T>(
      settings: RouteSettings(name: routeName), builder: page);
  ActivePages.track(nav, routeName, route);
  nav.push<T>(route);
  return route.popped.then((_) => null);
}
