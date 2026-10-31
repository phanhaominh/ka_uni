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
  final real = WebcalFeed.parse(
      File('test/fixtures/wc_now.ics').readAsStringSync())!;
  final e2e = WebcalFeed.parse(
      File('test/fixtures/webcal_e2e.ics').readAsStringSync())!;

  test("unrelated calendars have different fingerprints", () {
    expect(real.fingerprint(), isNot(e2e.fingerprint()));
  });

  test("cross-calendar diff is the phantom flood the guard prevents", () {
    // quantifies WHY reseeding matters: comparing the E2E feed against the
    // real one reports the whole real timetable as cancelled
    expect(e2e.changesSince(real).length, greaterThan(10));
  });

  test("re-seeded baseline diffs clean against itself", () {
    expect(e2e.changesSince(WebcalFeed.parse(
        File('test/fixtures/webcal_e2e.ics').readAsStringSync())!), isEmpty);
  });
}
