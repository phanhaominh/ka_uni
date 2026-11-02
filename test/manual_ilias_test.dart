import 'package:flutter_test/flutter_test.dart';
import 'package:kit_mobile/module/models/module.dart';
import 'package:kit_mobile/parsing/models/hierarchic_table_row.dart';
import 'package:kit_mobile/state_management/campus/campus_manager.dart';
import 'package:kit_mobile/state_management/kit_provider.dart';
import 'package:kit_mobile/student/student.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Some ILIAS courses exist although CampusKIT never links them from the
/// module page (live case: "Advanced Mathematics I", ILIAS course 0140000)
/// - the card and module page stay button-less although the course is
/// joinable. The user can attach such a URL per module title: stored
/// semester-scoped under `MIL <semester>`, matched through
/// lectureTitleKey, and applied ONLY to modules whose CampusKIT link is
/// empty (a printed link always wins).
class _StubFetchManager extends CampusManager {
  final Map<String, String?> linksByTitle;

  _StubFetchManager(this.linksByTitle) : super(Student.empty, () {});

  /// fetchModule without the network; ends with the same production
  /// choke point the real fetchModule runs before returning.
  @override
  Future<KITModule> fetchModule(HierarchicTableRow row,
      {recursiveRetry = true,
      sessionRetried = false,
      userInitiated = false}) async {
    final module = KITModule()
      ..id = "csbr-${row.id}"
      ..title = row.title
      ..iliasLink = linksByTitle[row.title]
      ..row = row
      ..hierarchicalTableRowId = row.id;
    rowModules[row.id] = module;
    await applyManualIliasLink(module);
    return module;
  }
}

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

const _am1Url = "https://ilias.studium.kit.edu/goto.php?target=crs_0140000";
const _em1Native = "https://ilias.studium.kit.edu/goto.php?target=crs_4711";

String milKey() => "MIL ${KITProvider.currentSemesterString}";

void main() {
  late CampusManager cm;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    cm = CampusManager(Student.empty, () {});
  });

  group("manual ILIAS link storage", () {
    test("round-trips and survives a fresh manager instance", () async {
      await cm.setManualIliasUrl("Advanced Mathematics I", _am1Url);
      expect(cm.manualIliasUrlFor("Advanced Mathematics I"), _am1Url);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(milKey()), isNotNull);

      final fresh = CampusManager(Student.empty, () {});
      await fresh.loadManualIliasLinks();
      expect(fresh.manualIliasUrlFor("Advanced Mathematics I"), _am1Url);
    });

    test("title matching is tolerant to case and feed suffixes", () async {
      await cm.setManualIliasUrl("Advanced Mathematics I", _am1Url);

      expect(cm.manualIliasUrlFor("advanced mathematics i (lecture)"), _am1Url);
      expect(cm.manualIliasUrlFor("ADVANCED MATHEMATICS I"), _am1Url);
      expect(cm.manualIliasUrlFor("Advanced Mathematics I (Lecture) - 0140000"),
          _am1Url);
      // a different lecture must not inherit the link
      expect(cm.manualIliasUrlFor("Engineering Mechanics I"), isNull);
    });

    test("removeManualIliasUrl forgets it for good", () async {
      await cm.setManualIliasUrl("Advanced Mathematics I", _am1Url);
      await cm.removeManualIliasUrl("Advanced Mathematics I (Lecture)");

      expect(cm.manualIliasUrlFor("Advanced Mathematics I"), isNull);
      final fresh = CampusManager(Student.empty, () {});
      await fresh.loadManualIliasLinks();
      expect(fresh.manualIliasUrlFor("Advanced Mathematics I"), isNull);
    });

    test("rejects plain http, foreign hosts and look-alike suffixes", () async {
      await expectLater(
          cm.setManualIliasUrl("Advanced Mathematics I",
              "http://ilias.studium.kit.edu/goto.php?target=crs_0140000"),
          throwsArgumentError);
      await expectLater(
          cm.setManualIliasUrl(
              "Advanced Mathematics I", "https://evil.example/crs_0140000"),
          throwsArgumentError);
      // the look-alike only ENDs WITH the host text, not the domain
      await expectLater(
          cm.setManualIliasUrl("Advanced Mathematics I",
              "https://ilias.studium.kit.edu.evil.example/x"),
          throwsArgumentError);

      expect(cm.manualIliasUrlFor("Advanced Mathematics I"), isNull);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(milKey()), isNull);
    });
  });

  group("manual link is a fallback for fetched modules", () {
    test("empty CampusKIT link picks up the manual URL, a real one stays",
        () async {
      // AM-I's page has no link at all; EM-I's page prints one, and even
      // a user-attached wrong URL must never overwrite the real one
      await cm.setManualIliasUrl("Advanced Mathematics I", _am1Url);
      await cm.setManualIliasUrl("Engineering Mechanics I",
          "https://ilias.studium.kit.edu/goto.php?target=crs_wrong");

      final mgr = _StubFetchManager({
        "Advanced Mathematics I": null,
        "Engineering Mechanics I": _em1Native,
      });

      final am1Row = _row("Advanced Mathematics I");
      final em1Row = _row("Engineering Mechanics I");
      final am1 = await mgr.fetchModule(am1Row);
      final em1 = await mgr.fetchModule(em1Row);

      expect(am1.iliasLink, _am1Url);
      expect(mgr.rowModules[am1Row.id]?.iliasLink, _am1Url);
      expect(em1.iliasLink, _em1Native);
    });

    test("an attach while a page is open patches the live module", () async {
      final mgr = _StubFetchManager({"Advanced Mathematics I": ""});
      final row = _row("Advanced Mathematics I");
      final module = await mgr.fetchModule(row);
      expect(module.iliasLink, isEmpty);

      await mgr.setManualIliasUrl("Advanced Mathematics I", _am1Url);
      // the open ModuleView reads the SAME instance; its next rebuild
      // must show the ILIAS button instead of the attach button
      expect(module.iliasLink, _am1Url);
    });
  });
}
