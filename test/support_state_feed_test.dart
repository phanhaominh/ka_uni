import 'package:flutter_test/flutter_test.dart';
import 'package:kit_mobile/diagnostics/feed_health.dart';
import 'package:kit_mobile/diagnostics/support_state.dart';
import 'package:kit_mobile/timetable/models/webcal.dart';
import 'package:shared_preferences/shared_preferences.dart';
// The doctor reads BOTH views of the store (legacy snapshot + live async),
// so the harness must back each platform interface independently - the
// InMemorySharedPreferencesAsync setup is the home_hero_latch_test idiom.
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

/// R36.3 PIN: SupportState.feedStatuses' BOTH-STORE merge contract. The
/// pure verdict ladder itself is feed_health_test's job; what lives here is
/// the plumbing that decides WHICH value feedHealth ever sees for a key.
/// The shipped merge is legacy-as-base with the async view overlaying what
/// it can see, because each view ALONE lies:
///  * async-only ghost-nulls (device proof, R31 F-1): a feed loaded hours
///    ago read "never loaded" while the legacy snapshot held its stamp -
///    the async view alone would fabricate that silence here too;
///  * legacy-only can PREdate WorkManager writes (R16f) - so a key the
///    async view holds alone must still be picked up.
/// Honesty stays pinned from below: with both stores empty the row is
/// `unknown`, never a fabricated `ok`.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const opts = SharedPreferencesOptions();

  // injected clock for the whole pin: stamps are built relative to THIS
  // moment, so no test here can ever straddle midnight and decay
  final now = DateTime(2026, 11, 13, 12);
  final freshStamp =
      now.subtract(const Duration(minutes: 5)).toIso8601String();

  late InMemorySharedPreferencesAsync store;

  setUp(() {
    // both views reset per test: an empty view must be provably empty,
    // not merely unpopulated by this test (cross-test ghosts would fake
    // the merge in either direction)
    SharedPreferences.setMockInitialValues({});
    store = InMemorySharedPreferencesAsync.empty();
    SharedPreferencesAsyncPlatform.instance = store;
  });

  Future<FeedStatus> webcalRow() async {
    final statuses = await SupportState.feedStatuses(
        credentialsStored: false,
        // explicit value short-circuits the MeiNotifications probe - this
        // pin is about the prefs plumbing, not the platform channel
        notificationsPermission: true,
        now: now);
    return statuses.firstWhere((s) => s.source == "webcal");
  }

  test("legacy-only stamp still resolves the timetable row to ok "
      "(async-only read would ghost-null it)", () async {
    // the F-1 device scenario: the stamp lives where only the legacy view
    // can see it (the async store is provably empty in setUp) - a doctor
    // reading the async view alone would print "never loaded" over a feed
    // that loaded minutes ago
    SharedPreferences.setMockInitialValues({WebcalKeys.fetchedAt: freshStamp});
    final row = await webcalRow();
    expect(row.state, FeedState.ok,
        reason: "legacy-as-base: a stamp only the snapshot holds is still "
            "the truth for that key - this is the shipped merge fix");
    expect(row.detailKey, "doctor.lastFetchAt");
  });

  test("async-only stamp is picked up too (live WorkManager writes)",
      () async {
    // the other half: the background isolate writes through the LIVE
    // async API; a base-only read would keep showing the older snapshot
    // (or nothing at all, exactly the R16f fabrication class)
    await store.setString(WebcalKeys.fetchedAt, freshStamp, opts);
    final row = await webcalRow();
    expect(row.state, FeedState.ok,
        reason: "the async overlay must reach the verdict for keys only "
            "the live view holds");
  });

  test("empty store: the row says unknown, never a fabricated ok", () async {
    final row = await webcalRow();
    expect(row.state, FeedState.unknown,
        reason: "silence is a gap, not health (feed_health honesty "
            "doctrine, pinned end-to-end through the real store plumbing)");
    expect(row.detailKey, "doctor.neverFetched");
  });
}
