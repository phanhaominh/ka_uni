import 'package:flutter_test/flutter_test.dart';
import 'package:kit_mobile/ilias/ilias_scraper.dart';

// Fixture pins for the pure dashboard parsers: every one of them fails
// SILENTLY when ILIAS reflows its markup, and a parse that yields zeros
// with a 200 OK is indistinguishable from an honest empty page at
// runtime - these shapes are the contract the live pages must keep.
void main() {
  group("unreadFrom", () {
    test("notifications badge comes from the top bar, not an earlier badge",
        () {
      const body = '''
<html><body>
<div id="ilTabs"><span class="badge">9</span>Neue Einträge</div>
<div id="ilTopBar"><span class="badge badge-primary">3</span></div>
<div class="ilDashboard">Willkommen zurück</div>
</body></html>''';
      expect(unreadFrom(body).notifications, 3); // 9 precedes the top bar
    });

    test("badge hunt falls back to the whole page if the marker vanished", () {
      expect(unreadFrom('<html><span class="badge">5</span></html>').notifications,
          5);
    });

    test("mails counts the digit phrase; a bare 'ungelesene Mail' claims one",
        () {
      expect(unreadFrom("<p>4 neue Mails</p>").mails, 4);
      expect(unreadFrom("<p>Sie haben ungelesene Mail</p>").mails, 1);
      expect(unreadFrom("<p>Alles gelesen</p>").mails, 0);
    });
  });

  group("coursesFrom", () {
    test("pins the 'NNNNNNN - Title' enrolment shape (both dash variants)", () {
      const body = '''
<ul>
<li><a href="/goto.php/crs/1234567">1234567 – Analysis I für INIM</a></li>
<li><a href="/goto.php/crs/7654321">7654321 - Basics des Software Engineering</a></li>
<li><a href="/goto.php/crs/1111111">kein Trenner hier</a></li>
</ul>''';
      final courses = coursesFrom(body);
      expect(courses.map((c) => c.number), ["1234567", "7654321"]);
      expect(courses.first.title, "Analysis I für INIM");
      // the separator-drifted enrolment is dropped - exactly why
      // fetchCourses shouts about "anchors present but ZERO parsed"
    });

    test("the same course ref printed twice lands once", () {
      const body = '''
<a href="/goto.php/crs/42">0000042 – Kurs</a>
<a href="/goto.php/crs/42">0000042 – Kurs</a>''';
      expect(coursesFrom(body).length, 1);
    });
  });

  test("newsNodeFrom extracts the PDNews cmdNode", () {
    const body = '<a href="ilias.php?baseClass=ildashboardgui'
        '&cmdNode=a5:42&cmdClass=ilPDNewsGUI&cmd=view">News</a>';
    expect(newsNodeFrom(body), "a5:42");
    expect(newsNodeFrom("<html>no news block</html>"), isNull);
  });
}
