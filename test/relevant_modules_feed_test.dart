import 'package:flutter_test/flutter_test.dart';
import 'package:kit_mobile/module/models/module.dart';
import 'package:kit_mobile/parsing/models/hierarchic_table_row.dart';
import 'package:kit_mobile/state_management/campus/campus_manager.dart';
import 'package:kit_mobile/state_management/kit_provider.dart';
import 'package:kit_mobile/student/student.dart';
import 'package:kit_mobile/timetable/models/webcal.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The "current modules" card must show THIS semester. The Studienverlauf
/// source tree is CampusKIT's whole-programme list, so the old ILIAS-link
/// rule admitted "Engineering Mechanics III" (planned for a later semester,
/// page already carries an ILIAS course) while hiding "Advanced Mathematics
/// I" (current WS lecture whose CampusKIT page has no ILIAS link at all).
/// The merged timetable feed (webcal + personal + SignMeUp) is the only
/// WS 26/27 ground truth the app has, so feed title membership is the new
/// admission rule; the link rule survives only until the first feed parse.
String _ics(List<String> summaries) {
  final b = StringBuffer("BEGIN:VCALENDAR\r\n");
  var i = 0;
  for (final s in summaries) {
    b.write("BEGIN:VEVENT\r\n"
        "UID:evt${i++}\r\n"
        "SUMMARY:$s\r\n"
        "DTSTART:20261102T080000\r\n"
        "DTEND:20261102T094500\r\n"
        "RRULE:FREQ=WEEKLY;UNTIL=20270201T000000\r\n"
        "LOCATION:10.81 HS93\r\n"
        "END:VEVENT\r\n");
  }
  b.write("END:VCALENDAR\r\n");
  return b.toString();
}

WebcalFeed _feed(List<String> summaries) => WebcalFeed.parse(_ics(summaries))!;

HierarchicTableRow _row(String title) => HierarchicTableRow(
      level: 4,
      title: title,
      href: "https://cascampus.studium.kit.edu/campus/student/module.asp?id=1",
      type: "Modul",
      statusStr: "",
      grade: "",
      pointsAcquired: "",
      pointsMax: "",
    );

KITModule _module(HierarchicTableRow row, String? iliasLink) => KITModule()
  ..id = "csbr-${row.id}"
  ..title = row.title
  ..iliasLink = iliasLink
  ..row = row;

const _em3Link = "https://ilias.studium.kit.edu/goto.php?target=crs_4711";

// Row ids are "<level>_<title>_<year>", so two "Mechanical Design A" rows
// under different section headings (the module-code year comes from the
// technical name) are two rows for one module: the device showed the
// identical card twice.
const _mdaPlain = "4_Mechanical Design A_2024";
const _mdaLinked = "4_Mechanical Design A_2025";

/// Tree carrying "Mechanical Design A" twice, one copy whose page has an
/// ILIAS course; `linkedFirst` decides which copy is admitted first, which
/// on the device is decided by whichever parallel fetch returns first.
Future<CampusManager> _duplicateCardManager({required bool linkedFirst}) async {
  final mgr = CampusManager(Student.empty, () {});
  final plain = _row("Mechanical Design A")..year = 2024;
  final linked = _row("Mechanical Design A")..year = 2025;
  mgr.moduleRows.addAll([plain, linked]);
  mgr.rowModules[plain.id] = _module(plain, null);
  mgr.rowModules[linked.id] = _module(linked, _em3Link);

  await mgr.rememberEnrolledTitles(
      _feed(["Mechanical Design A (Lecture) - 0123456"]));
  await mgr.addRelevantModuleRow(linkedFirst ? linked : plain);
  await mgr.addRelevantModuleRow(linkedFirst ? plain : linked);
  await pumpEventQueue();
  return mgr;
}

/// `fetchAllModules` walks cascampus module pages, which a unit test cannot
/// open; every row instead "arrives" as a module built from the row itself
/// plus the canned ILIAS link for its title.
class _StubTreeManager extends CampusManager {
  final Map<String, String?> linksByTitle;

  _StubTreeManager(this.linksByTitle) : super(Student.empty, () {});

  @override
  Future<KITModule> fetchModule(HierarchicTableRow row,
      {recursiveRetry = true, userInitiated = false}) async {
    final module = KITModule()
      ..id = "csbr-${row.id}"
      ..title = row.title
      ..iliasLink = linksByTitle[row.title]
      ..row = row
      ..hierarchicalTableRowId = row.id;
    rowModules[row.id] = module;
    return module;
  }
}

void main() {
  late CampusManager cm;
  String rmrKey() => "RMR ${KITProvider.currentSemesterString}";

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    cm = CampusManager(Student.empty, () {});
  });

  group("card admission follows the timetable feed", () {
    test("'Advanced Mathematics I' is admitted without an ILIAS link",
        () async {
      // "Advanced Mathematics I" exists on the feed ONLY as the SignMeUp
      // tutorial: accepted tutorial occurrences (non-exam-synth UIDs)
      // must count as the module's lecture being attended this term
      await cm.rememberEnrolledTitles(_feed([
        "3161010 - Engineering Mechanics I (V), Fidlin",
        "Advanced Mathematics I (Tutorial - Group 1)",
      ]));

      final row = _row("Advanced Mathematics I");
      cm.rowModules[row.id] = _module(row, null);
      await cm.addRelevantModuleRow(row);
      await pumpEventQueue();

      expect(cm.relevantModuleRowIDs, [row.id]);
    });

    test("future-semester 'Engineering Mechanics III' loses its ILIAS link",
        () async {
      await cm.rememberEnrolledTitles(_feed([
        "3161010 - Engineering Mechanics I (V), Fidlin",
        "Advanced Mathematics I (Tutorial - Group 1)",
      ]));

      final row = _row("Engineering Mechanics III");
      cm.rowModules[row.id] = _module(row, _em3Link);
      await cm.addRelevantModuleRow(row);
      await pumpEventQueue();

      expect(cm.relevantModuleRowIDs, isEmpty);
    });

    test("roman numerals never match across course numbers", () {
      final keys = {
        CampusManager.lectureTitleKey("3161010 - Engineering Mechanics I (V), Fidlin")
      };
      expect(
          CampusManager.moduleKeyMatchesLectureKey(
              CampusManager.lectureTitleKey("Engineering Mechanics I"), keys),
          isTrue);
      expect(
          CampusManager.moduleKeyMatchesLectureKey(
              CampusManager.lectureTitleKey("Engineering Mechanics III"),
              keys),
          isFalse);
    });

    test("empty lecture-key set keeps the legacy ILIAS-link rule", () async {
      // no feed parsed yet (fresh install / offline first start):
      // with link admits, without link rejects - unchanged behaviour
      final withLink = _row("Engineering Mechanics III");
      cm.rowModules[withLink.id] = _module(withLink, _em3Link);
      await cm.addRelevantModuleRow(withLink);

      final noLink = _row("Advanced Mathematics I");
      cm.rowModules[noLink.id] = _module(noLink, null);
      await cm.addRelevantModuleRow(noLink);
      await pumpEventQueue();

      expect(cm.relevantModuleRowIDs, [withLink.id]);
    });
  });

  group("feed refresh re-evaluates the card", () {
    test("previously admitted future-semester module drops after feed parse",
        () async {
      // admitted under the legacy link rule while no feed existed yet
      final em3 = _row("Engineering Mechanics III");
      cm.rowModules[em3.id] = _module(em3, _em3Link);
      await cm.addRelevantModuleRow(em3);
      await pumpEventQueue();
      expect(cm.relevantModuleRowIDs, [em3.id]);

      await cm.rememberEnrolledTitles(
          _feed(["3161010 - Engineering Mechanics I (V), Fidlin"]));
      await pumpEventQueue();

      expect(cm.relevantModuleRowIDs, isEmpty);
      // the pruned list is written back through the normal storage path
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getStringList(rmrKey()), isEmpty);
    });

    test("feed-gained module is admitted without refetch", () async {
      final am1 = _row("Advanced Mathematics I");
      // fetched earlier and rejected by the legacy rule (no ILIAS link)
      cm.rowModules[am1.id] = _module(am1, null);

      await cm.rememberEnrolledTitles(
          _feed(["Advanced Mathematics I (Tutorial - Group 1)"]));
      await pumpEventQueue();

      expect(cm.relevantModuleRowIDs, [am1.id]);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getStringList(rmrKey()), [am1.id]);
    });

    test("empty or broken feed re-parse keeps the card", () async {
      final am1 = _row("Advanced Mathematics I");
      cm.rowModules[am1.id] = _module(am1, null);
      await cm.rememberEnrolledTitles(
          _feed(["Advanced Mathematics I (Tutorial - Group 1)"]));
      await pumpEventQueue();
      expect(cm.relevantModuleRowIDs, [am1.id]);

      cm.rememberEnrolledTitles(WebcalFeed.parse(_ics([])));
      cm.rememberEnrolledTitles(null);
      await pumpEventQueue();

      expect(cm.relevantModuleRowIDs, [am1.id]);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getStringList(rmrKey()), [am1.id]);
    });

    test("legacy stored ids self-heal on load against the feed keys",
        () async {
      SharedPreferences.setMockInitialValues({
        rmrKey(): [
          "4_Engineering Mechanics III_0",
          "4_Advanced Mathematics I_0",
          "4_Mystery Module_0",
        ],
      });
      cm.moduleRows.addAll([
        _row("Engineering Mechanics III"),
        _row("Advanced Mathematics I"),
      ]);

      await cm.rememberEnrolledTitles(
          _feed(["Advanced Mathematics I (Lecture) - 0140000"]));
      await cm.prepareRelevantModuleRows();
      await pumpEventQueue();

      // EM III's title is known from the Studienverlauf row and not on
      // the feed -> dropped; the unknown id stays: missing information
      // must never empty the card
      expect(cm.relevantModuleRowIDs,
          ["4_Advanced Mathematics I_0", "4_Mystery Module_0"]);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getStringList(rmrKey()),
          ["4_Advanced Mathematics I_0", "4_Mystery Module_0"]);
    });
  });

  group("one card per module", () {
    test("the same module under two tree headings yields one card", () async {
      await cm.rememberEnrolledTitles(
          _feed(["Mechanical Design A (Lecture) - 0123456"]));

      final plain = _row("Mechanical Design A")..year = 2024;
      final copy = _row("Mechanical Design A")..year = 2025;
      cm.moduleRows.addAll([plain, copy]);
      cm.rowModules[plain.id] = _module(plain, null);
      cm.rowModules[copy.id] = _module(copy, null);

      await cm.addRelevantModuleRow(plain);
      await cm.addRelevantModuleRow(copy);
      await pumpEventQueue();

      expect(cm.relevantModuleRowIDs, [_mdaPlain]);
      // the pruned list goes out through the normal storage path
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getStringList(rmrKey()), [_mdaPlain]);
    });

    test("the ILIAS copy of a duplicate wins, whoever arrives first",
        () async {
      for (final linkedFirst in [true, false]) {
        final mgr = await _duplicateCardManager(linkedFirst: linkedFirst);
        expect(mgr.relevantModuleRowIDs, [_mdaLinked],
            reason: "$linkedFirst first: arrival order must not decide");
        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getStringList(rmrKey()), [_mdaLinked]);
      }
    });

    test("modules that only differ in their number stay two cards", () async {
      await cm.rememberEnrolledTitles(_feed([
        "3161010 - Engineering Mechanics I (V), Fidlin",
        "3161010 - Engineering Mechanics III (V), Fidlin",
      ]));

      final em1 = _row("Engineering Mechanics I")..year = 2024;
      final em3 = _row("Engineering Mechanics III")..year = 2025;
      cm.moduleRows.addAll([em1, em3]);
      cm.rowModules[em1.id] = _module(em1, null);
      cm.rowModules[em3.id] = _module(em3, _em3Link);

      await cm.addRelevantModuleRow(em1);
      await cm.addRelevantModuleRow(em3);
      await pumpEventQueue();

      expect(cm.relevantModuleRowIDs.toSet(), {em1.id, em3.id});
    });

    test("the merge rule never folds near-miss titles together", () {
      String k(String raw) => CampusManager.lectureTitleKey(raw);

      // one module, two spellings of it
      expect(
          CampusManager.moduleKeysDenoteSameModule(
              k("Mechanical Design A"),
              k("Mechanical Design  A (Lecture) - 0123456")),
          isTrue);
      // one character apart are two real modules
      expect(
          CampusManager.moduleKeysDenoteSameModule(
              k("Mechanical Design A"), k("Mechanical Design B")),
          isFalse);
      expect(
          CampusManager.moduleKeysDenoteSameModule(
              k("Analysis 1"), k("Analysis 2")),
          isFalse);
      expect(
          CampusManager.moduleKeysDenoteSameModule(
              k("Engineering Mechanics I"), k("Engineering Mechanics III")),
          isFalse);
      // nothing known -> nothing merged
      expect(
          CampusManager.moduleKeysDenoteSameModule("", k("Analysis 1")),
          isFalse);
    });

    test("a stored duplicate pair collapses when the card loads", () async {
      SharedPreferences.setMockInitialValues({
        rmrKey(): [_mdaPlain, _mdaLinked],
      });
      final mgr = CampusManager(Student.empty, () {});
      final plain = _row("Mechanical Design A")..year = 2024;
      final linked = _row("Mechanical Design A")..year = 2025;
      mgr.moduleRows.addAll([plain, linked]);
      mgr.rowModules[plain.id] = _module(plain, null);
      mgr.rowModules[linked.id] = _module(linked, _em3Link);

      await mgr.prepareRelevantModuleRows();
      await pumpEventQueue();

      // position of the first copy, content of the copy carrying ILIAS
      expect(mgr.relevantModuleRowIDs, [_mdaLinked]);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getStringList(rmrKey()), [_mdaLinked]);
    });

    test("fetchAllModules twice keeps the card count", () async {
      final mgr = _StubTreeManager({"Engineering Mechanics III": _em3Link});
      await mgr.rememberEnrolledTitles(_feed([
        "Mechanical Design A (Lecture) - 0123456",
        "Advanced Mathematics I (Tutorial - Group 1)",
      ]));
      mgr.moduleRows.addAll([
        _row("Mechanical Design A")..year = 2024,
        _row("Mechanical Design A")..year = 2025,
        _row("Advanced Mathematics I"),
        _row("Engineering Mechanics III"), // on no timetable
      ]);

      await mgr.fetchAllModules();
      await pumpEventQueue();
      final afterFirst = mgr.relevantModuleRowIDs.toSet();
      expect(afterFirst, {_mdaPlain, "4_Advanced Mathematics I_0"});

      await mgr.fetchAllModules();
      await pumpEventQueue();

      // refetching the whole tree never re-splits the doubled module
      expect(mgr.relevantModuleRowIDs.length, afterFirst.length);
      expect(mgr.relevantModuleRowIDs.toSet(), afterFirst);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getStringList(rmrKey())?.toSet(), afterFirst);
    });
  });
}
