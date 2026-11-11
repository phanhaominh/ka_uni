// A key missing from the English map silently degrades to German (L10n.t
// falls back to _de) - the module-detail-page audit hit exactly that leak
// class (German section headers in the English UI). The touched area -
// everything the module page renders - is asserted key-set-equal; the
// remaining areas ride with their owning slices.
import 'package:flutter_test/flutter_test.dart';
import 'package:kit_mobile/l10n/l10n.dart';

/// Every L10n key rendered by lib/module/views/module_page.dart and the
/// module-info table views (headers, appointment rows, ILIAS-attach dialog).
const modulePageKeys = [
  "module.title",
  "module.loadError",
  "module.lastUpdated",
  "module.credits",
  "module.examDateUnknown",
  "module.examInDays",
  "module.examDaysAgo",
  "module.sessionExpired",
  "module.addToTimetableFailed",
  "module.addedToTimetable",
  "module.removedFromTimetable",
  "module.infoButton",
  "module.weekly",
  "module.sectionExams",
  "module.sectionExamsTerm",
  "module.sectionCourses",
  "module.sectionMilestones",
  "module.sectionRequirements",
  "module.sectionModules",
  "settings.moduleAttachIlias",
  "settings.moduleAttachIliasHint",
  "settings.moduleAttachIliasSaved",
  "settings.moduleAttachIliasInvalid",
  "settings.ownIcsSave",
  "files.cancel",
];

void main() {
  test("every key the module page renders is translated in both maps", () {
    for (final key in modulePageKeys) {
      expect(L10n.deTable.containsKey(key), isTrue,
          reason: "$key missing in _de");
      // the silent one: a _de-only key still renders, in German, in EN
      expect(L10n.enTable.containsKey(key), isTrue,
          reason: "$key missing in _en (German leaks into the EN UI)");
    }
  });

  test("module.* key sets are identical between de and en", () {
    final deKeys = {
      for (final k in L10n.deTable.keys)
        if (k.startsWith("module.")) k
    };
    final enKeys = {
      for (final k in L10n.enTable.keys)
        if (k.startsWith("module.")) k
    };
    expect(deKeys, isNotEmpty);
    expect(enKeys.difference(deKeys), isEmpty, reason: "module key only in EN");
    expect(deKeys.difference(enKeys), isEmpty,
        reason: "module key only in DE -> silent German fallback in EN");
  });

  test("mensa.* key sets are identical between de and en", () {
    final deKeys = {
      for (final k in L10n.deTable.keys)
        if (k.startsWith("mensa.")) k
    };
    final enKeys = {
      for (final k in L10n.enTable.keys)
        if (k.startsWith("mensa.")) k
    };
    expect(deKeys, isNotEmpty);
    expect(enKeys.difference(deKeys), isEmpty, reason: "mensa key only in EN");
    expect(deKeys.difference(enKeys), isEmpty,
        reason: "mensa key only in DE -> silent German fallback in EN");
  });
}
