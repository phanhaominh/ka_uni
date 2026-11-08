import 'package:flutter/material.dart';

/// Per-Navigator live set of page identity keys. Shared by [pushPageOnce]
/// and the notification deep-link router so BOTH entry paths dedupe against
/// each other: a manually opened AgendaPage and a deep-link tap onto
/// "/agenda" are the same page.
///
/// Keyed by [NavigatorState] instead of one global set: a disposed test
/// Navigator (or a shell torn down by logout) must not leave its keys
/// behind for the NEXT Navigator to dedupe against - Route.dispose never
/// completes [Route.popped], so popped-based cleanup cannot be trusted for
/// teardown, only for pops.
class ActivePages {
  ActivePages._();

  static final Map<NavigatorState, Set<String>> _open = {};

  static bool isOpen(NavigatorState nav, String key) =>
      _open[nav]?.contains(key) ?? false;

  /// Register [key] on [nav] as open and arm removal when [route] finishes
  /// (user pop or deep-link removeRoute both complete [Route.popped]).
  static void track(NavigatorState nav, String key, Route<void> route) {
    _open.putIfAbsent(nav, () => <String>{}).add(key);
    route.popped.whenComplete(() => _open[nav]?.remove(key));
  }

  /// Whole shell destroyed: drop everything registered on it.
  static void clearFor(NavigatorState nav) => _open.remove(nav);

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
