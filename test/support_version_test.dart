import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kit_mobile/diagnostics/support_state.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// F9: the bundle must print the installed version, not the stale const.
/// Test order is load-bearing: PackageInfo.setMockInitialValues fills a
/// process-static cache, so the no-plugin fallback case must run first,
/// while fromPlatform() still hits an unhandled method channel.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test("kAppVersion equals the pubspec version (bump together)", () {
    // F9's other half: the fallback itself must not go stale. The old test
    // only asserted the bundle CONTAINS the const - true even when the const
    // drifted (0.8.9+65 while pubspec shipped 0.12.0+70).
    final pubspec = File("pubspec.yaml").readAsStringSync();
    final m = RegExp(r"^version:\s*(\S+)\s*$", multiLine: true)
        .firstMatch(pubspec);
    expect(m, isNotNull);
    expect(kAppVersion, m!.group(1));
  });

  test("falls back to kAppVersion when the platform plugin cannot answer",
      () async {
    final bundle = await SupportState.buildBundle();
    expect(bundle, contains(kAppVersion));
  });

  test("bundle carries version+buildNumber from PackageInfo", () async {
    PackageInfo.setMockInitialValues(
      appName: "KIT Campus",
      packageName: "org.example.kit",
      version: "0.9.1",
      buildNumber: "71",
      buildSignature: "",
    );
    final bundle = await SupportState.buildBundle();
    expect(bundle, contains("0.9.1+71"));
    expect(bundle, isNot(contains(kAppVersion)));
  });
}
