import 'dart:io' show File, HttpOverrides;
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:kit_mobile/credentials/data/credentials_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:kit_mobile/credentials/models/auth_result.dart';
import 'package:kit_mobile/state_management/kit_provider.dart';

// End-to-end over the same wiring the "Log in" button uses, against the live
// KIT SSO. Lives in its OWN suite: TestWidgetsFlutterBinding (pulled in by
// widget tests) fakes every HttpClient response with 400, so this test must
// not share a file with them. Skipped without the local credentials file.
void main() {
  test(
      'real typed-format credentials authenticate via CredentialsProvider.submit',
      () async {
    final f = File('/tmp/.mei_c');
    if (!f.existsSync()) {
      markTestSkipped('no credentials file');
      return;
    }
    // binding for the plugin mock channels, then UNDO the binding's HTTP
    // interception (it answers every request with a fake 400) so KIT stays
    // reachable; student data + keystore both need a storage mock
    TestWidgetsFlutterBinding.ensureInitialized();
    HttpOverrides.global = null;
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    final parts = f.readAsStringSync().split(RegExp(r"\s+"));
    final vm = KITProvider();
    final creds = CredentialsProvider();

    final result = await creds.submit(parts[0], parts[1], vm);
    expect(result, AuthResult.ok);
    expect(vm.profileReady, isTrue);
    expect(creds.displayName, isNotEmpty);
  }, timeout: const Timeout(Duration(minutes: 4)));
}
