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
