import 'package:flutter_test/flutter_test.dart';
import 'package:kit_mobile/common/data_trust.dart';

/// R35.2: the three-state verdict is the ONE voice - thresholds come in
/// per source, the states and their boundaries do not.
void main() {
  final now = DateTime(2026, 11, 13, 12);
  const ttl = Duration(hours: 6);
  const horizon = Duration(hours: 24);

  DataTrust at(Duration age) => dataTrust(
      fetchedAt: now.subtract(age),
      now: now,
      ttl: ttl,
      trustHorizon: horizon);

  test("null stamp is untrusted, never 'fresh by default'", () {
    expect(
        dataTrust(
            fetchedAt: null, now: now, ttl: ttl, trustHorizon: horizon),
        DataTrust.untrusted);
  });

  test("ttl boundary is inclusive-fresh, one second past ages", () {
    expect(at(const Duration(hours: 6)), DataTrust.fresh);
    expect(at(const Duration(hours: 6, seconds: 1)), DataTrust.aging);
  });

  test("horizon boundary: aging until it passes, then untrusted", () {
    expect(at(const Duration(hours: 24)), DataTrust.aging);
    expect(at(const Duration(hours: 24, seconds: 1)), DataTrust.untrusted);
    expect(at(const Duration(days: 9)), DataTrust.untrusted);
  });

  test("a future stamp is untrusted, not flatteringly 'fresh'", () {
    // clock skew or a forged DATA_* blob: an event from the future has
    // not proven anything about the last fetch
    expect(
        dataTrust(
            fetchedAt: now.add(const Duration(minutes: 1)),
            now: now,
            ttl: ttl,
            trustHorizon: horizon),
        DataTrust.untrusted);
  });
}
