import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kit_mobile/credentials/models/kit_credentials.dart';
import 'package:kit_mobile/ilias/ilias_scraper.dart';
import 'package:kit_mobile/state_management/ilias/ilias_manager.dart';

// Live ILIAS probe; skipped unless /tmp/.mei_c exists. Authenticates through
// ILIAS's own Shibboleth entry (idp-initiated, like the browser flow), then
// exercises the scraper surfaces against the real session.
void main() {
  test('ILIAS SSO + courses + unread + materials parse live', () async {
    final f = File('/tmp/.mei_c');
    if (!f.existsSync()) {
      markTestSkipped('no credentials file');
      return;
    }
    final parts = f.readAsStringSync().split(RegExp(r"\s+"));
    final mgr = IliasManager();
    mgr.credentials =
        KITCredentials(username: parts[0], password: parts[1], valid: true);
    await mgr.authorize();
    final landing = await mgr.session
        .get(Uri.parse("https://ilias.studium.kit.edu/ilias.php"));
    final body = mgr.bodyOf(landing);
    if (!body.contains("goto.php") || body.contains("Lokale ILIAS-Anmeldung")) {
      File('/tmp/p_ilias_sso.html').writeAsStringSync(body);
      fail("ILIAS session missing; body saved (len=${body.length})");
    }

    final courses = await mgr.fetchCourses();
    print("ILIAS courses: $courses");
    expect(courses.length, greaterThanOrEqualTo(4));
    expect(courses.any((c) => c.number == "0140000"), isTrue);

    final unread = await mgr.fetchUnread();
    print("ILIAS unread: $unread");

    final adm = courses.firstWhere((c) => c.number == "0140000");
    final files = await mgr.fetchCourseFiles(adm);
    print("ILIAS files (${files.length}): ${files.take(5).toList()}");
    // AdM ships lecture notes + weekly sheets as of week 7
    expect(files, isNotEmpty);
    expect(files.any((f) => f.url.contains("cmd=sendfile")), isTrue);
    // every course's tree must walk without error; AdM and MSE ship files
    var total = files.length;
    for (final c in courses.where((c) => c.number != "0140000")) {
      final fs = await mgr.fetchCourseFiles(c);
      print("ILIAS ${c.number} files: ${fs.length}");
      total += fs.length;
    }
    expect(total, greaterThanOrEqualTo(8));

    final news = await mgr.fetchAnnouncements();
    print("ILIAS news rows: ${news.length}");
    for (final n in news) {
      print("  [${n.when}] ${n.title} -> ${n.url}");
    }
  }, timeout: const Timeout(Duration(minutes: 4)));
}
