import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kit_mobile/fristenbuch/fristenbuch.dart';
import 'package:kit_mobile/fristenbuch/fristenbuch_page.dart';
import 'package:kit_mobile/state_management/campus/campus_manager.dart';
import 'package:kit_mobile/student/student.dart';
import 'package:shared_preferences/shared_preferences.dart';
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

/// R34.1: the Fristenbuch editor page, driven like a user. The page owns
/// the commit path (store write + owner re-apply into the merged cache),
/// so every mutation test reads BOTH back: the store AND the cache the
/// agenda/digest/reminders actually parse.

final _today = DateTime.now();

String _lectureDoc() => "BEGIN:VCALENDAR\r\n"
    "BEGIN:VEVENT\r\n"
    "UID:evt-page@kit\r\n"
    "SUMMARY:Thermo I (V), Mueller\r\n"
    "DTSTART:${_fmt(DateTime(_today.year, _today.month, _today.day + 2, 8))}\r\n"
    "DTEND:${_fmt(DateTime(_today.year, _today.month, _today.day + 2, 10))}\r\n"
    "END:VEVENT\r\n"
    "END:VCALENDAR\r\n";

String _fmt(DateTime d) {
  String p(int v) => v.toString().padLeft(2, "0");
  return "${d.year}${p(d.month)}${p(d.day)}T${p(d.hour)}${p(d.minute)}00";
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late InMemorySharedPreferencesAsync asyncStore;
  late CampusManager cm;

  setUp(() async {
    // the legacy store carries the two keys reapplyFrB fences on (an
    // unprovisioned account would be a silent no-op and the assertions
    // would all "pass" on an empty cache)
    SharedPreferences.setMockInitialValues({
      "DATA_webcalUrl": "https://webcal.test/wc.ics",
      "DATA_webcalIcsCache": _lectureDoc(),
    });
    asyncStore = InMemorySharedPreferencesAsync.empty();
    SharedPreferencesAsyncPlatform.instance = asyncStore;
    cm = CampusManager(Student.empty, () {});
  });

  Future<String> legacyCache() async =>
      (await SharedPreferences.getInstance()).getString("DATA_webcalIcsCache") ??
      "";

  Future<void> pumpPage(WidgetTester tester) async {
    await tester.pumpWidget(
        MaterialApp(home: FristenbuchPage(manager: cm)));
    await tester.pumpAndSettle();
  }

  Future<void> addEntry(WidgetTester tester, String label) async {
    await tester.tap(find.byKey(const ValueKey("frbAdd")));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const ValueKey("frbLabel")), label);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey("frbDate")));
    await tester.pumpAndSettle();
    await tester.tap(find.text("OK")); // picker keeps its preselected day
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey("frbSave")));
    await tester.pumpAndSettle();
  }

  testWidgets("empty state names itself honestly (no scraped-truth look)",
      (tester) async {
    await pumpPage(tester);
    expect(find.text("Fristenbuch"), findsOneWidget); // app bar
    expect(
        find.textContaining("die du selbst notierst"),
        findsOneWidget, // coverage header: own notes, never verified
        reason: "the honesty header is the page's reason to exist");
    expect(find.text("Noch keine Fristen notiert."), findsOneWidget);
  });

  testWidgets("add: dialog -> entry on the page, in the store AND in the "
      "merged cache (pipeline arm)", (tester) async {
    await pumpPage(tester);
    await addEntry(tester, "Wohnung kündigen");

    expect(find.text("Wohnung kündigen"), findsOneWidget);
    // provenance chip on the row: self-noted, never scraped
    expect(find.text("selbst notiert"), findsOneWidget);

    final raw = await asyncStore.getString(
        fristenbuchStoreKey, const SharedPreferencesOptions());
    expect(raw, contains("Wohnung kündigen"));

    // the cache the agenda/digest/reminders parse gained the synth event
    final cache = await legacyCache();
    expect(cache, contains("UID:kauni-frb-1"));
    expect(cache, contains("SUMMARY:Frist: Wohnung kündigen"));
    expect(CampusManager.extractFrB(cache), isNotEmpty);
    // cm memory mirrors it (the next fetch's projection carries it)
    expect(cm.frbSynth, contains("kauni-frb-1"));
  });

  testWidgets("the add dialog refuses a label-less or date-less draft "
              "and offers no edit affordance (delete + re-add by contract)",
      (tester) async {
    await pumpPage(tester);
    await tester.tap(find.byKey(const ValueKey("frbAdd")));
    await tester.pumpAndSettle();
    final save = tester.widget<TextButton>(
        find.byKey(const ValueKey("frbSave")));
    expect(save.onPressed, isNull); // no label, no date: not saveable
    await tester.enterText(
        find.byKey(const ValueKey("frbLabel")), "Nur Text");
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<TextButton>(find.byKey(const ValueKey("frbSave")))
            .onPressed,
        isNull, // a date is REQUIRED (records consumers never see null)
        reason: "dateless entries must not exist");

    await tester.tap(find.text("Abbrechen")); // close the draft dialog
    await tester.pumpAndSettle();

    // seeded entry: row exists with a delete control and NO edit control
    await asyncStore.setString(
        fristenbuchStoreKey,
        fristenbuchEntriesToJson([
          FristenbuchEntry(
              id: 5, label: "BAföG Amt", due: DateTime(_today.year,
                  _today.month, _today.day + 4))
        ]),
        const SharedPreferencesOptions());
    await tester.pumpWidget(const SizedBox()); // unmount: a real re-entry
    // rebuilds the page and re-reads the store (initState), like a fresh
    // push from settings
    await pumpPage(tester);
    expect(find.text("BAföG Amt"), findsOneWidget);
    expect(find.byKey(ValueKey("frbDelete-5")), findsOneWidget);
    expect(find.byIcon(Icons.edit), findsNothing);
    expect(find.byIcon(Icons.edit_outlined), findsNothing);
  });

  testWidgets("delete: entry leaves page, store and cache (owner may "
      "shrink the layer)", (tester) async {
    await asyncStore.setString(
        fristenbuchStoreKey,
        fristenbuchEntriesToJson([
          FristenbuchEntry(
              id: 1,
              label: "Immatrikationsamt Formular",
              due: DateTime(
                  _today.year, _today.month, _today.day + 3))
        ]),
        const SharedPreferencesOptions());
    await pumpPage(tester);
    expect(
        CampusManager.extractFrB(await legacyCache()), isEmpty); // pre-seed
    // first commit puts it in the cache through the page path once (the
    // widget starts from the STORE; the cache only gains the block on an
    // owner write — add/delete both run it, delete alone on an
    // un-injected cache must still leave the store clean):
    await tester.tap(find.byKey(ValueKey("frbDelete-1")));
    await tester.pumpAndSettle();

    expect(find.text("Immatrikationsamt Formular"), findsNothing);
    final raw = await asyncStore.getString(
        fristenbuchStoreKey, const SharedPreferencesOptions());
    expect(raw, isNot(contains("Immatrikationsamt")));
    expect(CampusManager.extractFrB(await legacyCache()), isEmpty);
    expect(cm.frbSynth, isEmpty);
  });
}
