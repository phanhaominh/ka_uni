import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kit_mobile/credentials/models/kit_credentials.dart';
import 'package:kit_mobile/state_management/kit_login_manager.dart';

// Live credential probe; skipped unless /tmp/.mei_c exists.
// Uses the password verbatim from the file -- the device-side adb input path
// corrupts the '$'/'?' characters in it.
void main() {
  test('Dart stack completes SAML login with real credentials', () async {
    final f = File('/tmp/.mei_c');
    if (!f.existsSync()) {
      markTestSkipped('no credentials file');
      return;
    }
    final parts = f.readAsStringSync().split(RegExp(r"\s+"));
    final mgr = KITLoginManager();
    mgr.credentials =
        KITCredentials(username: parts[0], password: parts[1], valid: true);

    final s0 = await mgr.fetchStage0_Init();
    expect(s0, 0, reason: 'stage0 init failed');

    final s1 = await mgr.fetchStage1_TryToOpenLoginPage(
        "https://campus.studium.kit.edu/Shibboleth.sso/Login?target=https://campus.studium.kit.edu/exams/registration.php?login=1");
    expect(s1.statusCode, 200);

    final s2 = await mgr.fetchStage2_(s1);
    expect(s2, isNotNull, reason: 'stage2 returned null');
    print("STAGE2 -> ${s2!.statusCode} relay=${s2.body
        .toLowerCase()
        .contains("relaystate")} len=${s2.body.length}");

    final boot = await mgr.bootCascampusSession();
    expect(boot, isTrue, reason: 'cascampus boot failed');

    final r = await mgr.guardedCasGet(
        "https://cascampus.studium.kit.edu/campus/student/timetable.asp"
        "?tguid=${mgr.tguid}");
    expect(r.statusCode, 200);
    print("TIMETABLE len=${r.body.length} "
        "plan=${r.body.contains("Studienplan")} "
        "expired=${mgr.sessionExpired(r.body)}");
    expect(
        r.body.contains("Stundenplan") ||
            r.body.contains("Veranstaltung"),
        isTrue,
        reason: 'timetable page not rendered');
  }, timeout: const Timeout(Duration(minutes: 3)));
}
