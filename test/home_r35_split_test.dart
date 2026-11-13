import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kit_mobile/grades/views/grades_page.dart';
import 'package:kit_mobile/grades/views/module_tree_view.dart';
import 'package:kit_mobile/home/views/home_page.dart';
import 'package:kit_mobile/l10n/l10n.dart';
import 'package:kit_mobile/local_files_storage/files_manager.dart';
import 'package:kit_mobile/parsing/models/hierarchic_table_row.dart';
import 'package:kit_mobile/profile/views/profile_view.dart';
import 'package:kit_mobile/settings/providers/settings_provider.dart';
import 'package:kit_mobile/state_management/kit_provider.dart';
import 'package:kit_mobile/student/name.dart';
import 'package:kit_mobile/timetable/logic/now_clock.dart';
import 'package:kit_mobile/toasts/models/toasts_provider.dart';
import 'package:kit_mobile/tutorials/data/tutorial_manager.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

/// R35.1 revert switch + R35.3 HOME=TODAY split, pinned as a WIDGET
/// contract: the default home renders neither the profile block nor the
/// module tree, the NAMED door replaces the 16-tap chevron at the old
/// seat, and PREF_legacyHome=true restores the previous composition
/// exactly one release long. The grades page owns what was relocated:
/// the unique degree/semester lines (identity card) and the raw full
/// module tree (footer).
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
  });
  tearDown(() {
    NowClock.timeSource = DateTime.now;
  });

  Future<SettingsProvider> mountHome(WidgetTester tester) async {
    late SettingsProvider settings;
    await tester.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider<KITProvider>(create: (_) => KITProvider()),
        ChangeNotifierProvider<ToastsProvider>(
            create: (_) => ToastsProvider()),
        ChangeNotifierProvider<IliasFilesProvider>(
            create: (_) => IliasFilesProvider()),
        ChangeNotifierProvider<TutorialManager>(
            create: (_) => TutorialManager()),
        ChangeNotifierProvider<SettingsProvider>(
            create: (ctx) => settings = SettingsProvider(context: ctx)),
      ],
      child: MaterialApp(home: const KITHomePage()),
    ));
    // SettingsProvider.prepare() restores PREF_legacyHome asynchronously
    // (legacy prefs) and notifies; give it the frames it needs without
    // pumpAndSettle (the profile-loading spinner never settles)
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    return settings;
  }

  testWidgets("default home is TODAY: no profile block, no module tree",
      (tester) async {
    await mountHome(tester);

    // deleted surfaces
    expect(find.byType(ProfileView), findsNothing);
    expect(find.byType(HierarchicTableView), findsNothing);
    expect(find.text(L10n.t("settings.myModules")), findsNothing);
    // the unlabeled chevron action died with PREF_showingProfile
    expect(find.byIcon(CupertinoIcons.chevron_down), findsNothing);
    // the demotion: one NAMED door at the old block's seat
    expect(find.byType(ProfileDoorCard), findsOneWidget);
    expect(find.text(L10n.t("grades.entry")), findsOneWidget);
  });

  testWidgets("PREF_legacyHome=true restores the old composition "
      "(one-release revert switch, single read site)", (tester) async {
    SharedPreferences.setMockInitialValues({legacyHomeKey: true});
    await mountHome(tester);

    expect(find.text(L10n.t("settings.myModules")), findsOneWidget);
    expect(find.byType(HierarchicTableView), findsOneWidget);
    expect(find.byType(ProfileDoorCard), findsNothing);
    // profile not ready in the harness: the legacy seat shows the
    // fake-zero guard, and only the legacy branch can show it
    expect(find.text(L10n.t("home.profileLoading")), findsWidgets);
  });

  testWidgets("the door opens the grades page", (tester) async {
    await mountHome(tester);
    await tester.tap(find.byType(ProfileDoorCard));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.byType(GradesPage), findsOneWidget);
  });

  testWidgets("grades page carries the relocated identity and the "
      "full-tree footer", (tester) async {
    final vm = KITProvider();
    vm.campusManager.ready = true;
    vm.student.set(
        name: Name(firstName: "Vorname", lastName: "Nachname"),
        matriculationNumber: "12345678",
        degreeProgram: "Mechanical Engineering International (MEI)",
        avgMark: "2,3",
        ectsAcquired: "6,0");
    vm.campusManager.moduleRows = [
      HierarchicTableRow(
          level: 3,
          title: "Module A",
          href: "",
          type: "",
          statusStr: "bestanden",
          grade: "1,3",
          pointsAcquired: "6",
          pointsMax: "6"),
    ];
    await tester.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider<KITProvider>.value(value: vm),
        ChangeNotifierProvider<ToastsProvider>(
            create: (_) => ToastsProvider()),
      ],
      child: MaterialApp(home: const GradesPage()),
    ));
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    // the UNIQUE renderers of R35.3B: degree + semester now live here
    expect(find.text("Mechanical Engineering International (MEI)"),
        findsOneWidget);
    expect(find.text(L10n.t("settings.degreeProgram")), findsOneWidget);
    expect(find.text(L10n.t("settings.semester")), findsOneWidget);
    expect(find.text(KITProvider.currentSemesterString), findsWidgets);
    // the raw full tree (R35.3A relocation) with its section header -
    // the ListView virtualizes, so scroll to the footer first
    await tester.drag(find.byType(ListView), const Offset(0, -2000));
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(find.byType(HierarchicTableView), findsOneWidget);
    expect(find.text(L10n.t("settings.myModules")), findsOneWidget);
    // the tree row itself is reachable under the header
    expect(find.text("Module A"), findsWidgets);
  });
}
