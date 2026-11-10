import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kit_mobile/timetable/models/webcal.dart';

/// The CHANGED band is only correct when both sides of the diff describe
/// the SAME calendar. The foreground fetch and background poll reseed the
/// fingerprint baseline when the feed URL changes (webcal token
/// re-provisioning, E2E test seam) instead of diffing two unrelated
/// calendars - which once produced a phantom 50-delta "all your lectures
/// are cancelled" band.
void main() {
  // fixture clock for the PARSE, not just the fingerprint: parse trims
  // occurrences to [now-1d, now+56d] against the WALL clock, which aged
  // the E2E fixture (1970-DST + Nov-2026 seeds) out of its own window and
  // made parse return null - the trim guard must not expire the fixtures
  // under a growing suite
  final clock = DateTime(2026, 10, 30, 18);
  final real = WebcalFeed.parse(
      File('test/fixtures/wc_now.ics').readAsStringSync(),
      now: clock)!;
  final e2e = WebcalFeed.parse(
      File('test/fixtures/webcal_e2e.ics').readAsStringSync(),
      now: clock)!;

  test("unrelated calendars have different fingerprints", () {
    // both sides of the fingerprint sit in the same fixture-clock window:
    // unrelated calendars must produce different digests, never two empty
    // ones that trivially compare equal
    expect(real.fingerprint(at: clock), isNot(e2e.fingerprint(at: clock)));
  });

  test("cross-calendar diff is the phantom flood the guard prevents", () {
    // quantifies WHY reseeding matters: comparing the E2E feed against the
    // real one reports the whole real timetable as cancelled
    expect(e2e.changesSince(real).length, greaterThan(10));
  });

  test("re-seeded baseline diffs clean against itself", () {
    expect(
        e2e.changesSince(WebcalFeed.parse(
            File('test/fixtures/webcal_e2e.ics').readAsStringSync(),
            now: clock)!),
        isEmpty);
  });
}
