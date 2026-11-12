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

  // ---- R23: global sweep tests (codify the full-surface audit) ----

  test("GLOBAL de/en key sets are identical (whole table)", () {
    // a key missing in EN silently degrades to German (L10n.t falls back
    // to _de); before this only the module-page and mensa areas were
    // pinned and every other area "rode with its owning slice" - this
    // test makes the whole 400+ key table one guard
    final deKeys = L10n.deTable.keys.toSet();
    final enKeys = L10n.enTable.keys.toSet();
    expect(deKeys.length, greaterThan(300), reason: "table grew? wire it up");
    expect(enKeys.difference(deKeys), isEmpty, reason: "key only in EN");
    expect(deKeys.difference(enKeys), isEmpty,
        reason: "key only in DE -> silent German fallback in EN UI");
  });

  test("GLOBAL placeholder arity matches between de and en", () {
    // differing {0}..{n} counts per key pair guarantee a literal "{1}"
    // on screen or a silently dropped argument in exactly one locale
    int arity(String t) => RegExp(r"\{(\d+)\}")
            .allMatches(t)
            .map((m) => int.parse(m.group(1)!))
            .fold<int>(-1, (a, b) => a > b ? a : b) +
        1;
    for (final k in L10n.deTable.keys) {
      final de = L10n.deTable[k]!;
      final en = L10n.enTable[k]!;
      expect(arity(en), arity(de), reason: "placeholder arity drift: $k");
    }
  });

  test("dynamic month keys exist in both locales", () {
    // timetable_weekly_view builds L10n.t("timetable.month\\$month") -
    // statically invisible; a missing month would print the RAW key
    for (var m = 1; m <= 12; m++) {
      expect(L10n.deTable.containsKey("timetable.month$m"), isTrue,
          reason: "DE month $m");
      expect(L10n.enTable.containsKey("timetable.month$m"), isTrue,
          reason: "EN month $m");
    }
  });
}
