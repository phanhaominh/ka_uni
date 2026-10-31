import 'dart:async';

import 'dart:ui';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:kit_mobile/common_ui/kit_progress_indicator.dart';
import 'package:kit_mobile/constants/view_constants.dart';
import 'package:kit_mobile/l10n/l10n.dart';
import 'package:kit_mobile/home/views/hierarchic_table.dart';
import 'package:kit_mobile/home/views/ka_uni_app_bar_title.dart';
import 'package:kit_mobile/home/views/padded_title.dart';
import 'package:kit_mobile/common_ui/mei_failure_banner.dart';
import 'package:kit_mobile/exams/views/exams_page.dart';
import 'package:kit_mobile/agenda/views/agenda_page.dart';
import 'package:kit_mobile/home/views/relevant_modules.dart';
import 'package:kit_mobile/local_files_storage/views/pinned_files_list_view.dart';
import 'package:kit_mobile/profile/views/profile_view.dart';
import 'package:kit_mobile/settings/providers/settings_provider.dart';
import 'package:kit_mobile/timetable/pages/timetable_edit_page.dart';
import 'package:kit_mobile/timetable/views/timetable_weekly_view.dart';
import 'package:kit_mobile/toasts/models/toasts_provider.dart';
import 'package:provider/provider.dart';

import '../../local_files_storage/views/pages/files_cache_page.dart';
import '../../state_management/kit_provider.dart';

class KITHomePage extends StatefulWidget {
  const KITHomePage({super.key});

  @override
  State<KITHomePage> createState() => _KITHomePageState();
}

class _KITHomePageState extends State<KITHomePage> {
  final _relevantModulesTitleKey = GlobalKey();

  @override
  Widget build(BuildContext context) {
    final vm = Provider.of<KITProvider>(context);
    final toastsProvider = Provider.of<ToastsProvider>(context);
    final settingsVM = Provider.of<SettingsProvider>(context);

    return Scaffold(
        appBar: AppBar(
          flexibleSpace: ClipRect(
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 7, sigmaY: 7),
              child: Container(
                color: Colors.transparent,
              ),
            ),
          ),
          // backgroundColor: Theme.of(context).colorScheme.surface,
          title: KaUniAppBarTitle(),
          centerTitle: true,
          // backgroundColor: Colors.transparent,
          // shadowColor: Colors.transparent,
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.only(
            bottomLeft: Radius.circular(10),
            bottomRight: Radius.circular(10),
          )),
          // surfaceTintColor: Colors.transparent,
          leading: vm.profileReady ? SizedBox.shrink() : KITProgressIndicator(),
          // leading: !kDebugMode
          //     ? null
          //     : CupertinoButton(
          //         child: Icon(
          //           CupertinoIcons.check_mark_circled_solid,
          //           color: Colors.red,
          //         ),
          //         onPressed: () async {
          //           await vm.prepareCachedData();
          //
          //           await credsVM.loadCredentials();
          //           await vm.setCredentials(credsVM.credentials);
          //           print(
          //               "${credsVM.credentials}, ${credsVM.credentials.valid}");
          //           if (credsVM.credentialsLoaded &&
          //               credsVM.credentials.valid) {
          //             await credsVM.login(vm);
          //             await vm.fetchSchedule();
          //             await vm.campusManager.fetchAllModules();
          //           }
          //         }),
          actions: [
            CupertinoButton(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              onPressed: () {
                Navigator.of(context).push(MaterialPageRoute(
                    builder: (context) => const AgendaPage()));
              },
              child: Semantics(
                button: true,
                label: L10n.t("agenda.title"),
                child: Badge(
                  isLabelVisible:
                      vm.campusManager.timetableChanged,
                  backgroundColor: Colors.orange,
                  child: const Icon(CupertinoIcons.calendar, size: 22),
                ),
              ),
            ),
            CupertinoButton(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              onPressed: () {
                Navigator.of(context).push(MaterialPageRoute(
                    builder: (context) =>
                        const ExamsPage()));
              },
              child: Semantics(
                button: true,
                label: L10n.t("exams.title"),
                child: Badge(
                  isLabelVisible: vm.campusManager.exams.any((e) =>
                      e.needsAction(DateTime.now()) &&
                      vm.campusManager.isTakingThisSemester(e) != false),
                  backgroundColor: Colors.red,
                  child: const Icon(
                      CupertinoIcons.checkmark_seal,
                      size: 22),
                ),
              ),
            ),
            CupertinoButton(
              onPressed: () {
                setState(() {
                  settingsVM.showingProfile.toggle();
                });
              },
              child: Semantics(
                button: true,
                label: L10n.t("settings.showProfile"),
                child: AnimatedRotation(
                  curve: defaultChevronRotationAnimationCurve,
                  turns: settingsVM.showingProfile.value ? 0 : -0.25,
                  duration: defaultChevronRotationAnimationDuration,
                  child: Icon(CupertinoIcons.chevron_down),
                ),
              ),
            )
          ],
        ),
        body: Stack(
          children: [
            RefreshIndicator(
              onRefresh: () => vm.forceRefetchEverything(),
              child: SingleChildScrollView(
                // pull-down works even when the page fits the screen
                physics: const AlwaysScrollableScrollPhysics(),
              child: Column(children: [
                Column(
                  mainAxisAlignment: MainAxisAlignment.start,
                  children: <Widget>[
                    MeiFailureBanner(vm: vm),
                    AnimatedSwitcher(
                      duration: Duration(milliseconds: 200),
                      child: settingsVM.showingProfile.value
                          ? ProfileView(
                              relevantModulesTitleKey: _relevantModulesTitleKey,
                            )
                          : SizedBox(),
                    ),
                    TimetableWeeklyView(),
                    CupertinoButton(
                        padding: EdgeInsets.zero,
                        onPressed: () {
                          Navigator.of(context).push(MaterialPageRoute(
                              builder: (BuildContext context) =>
                                  TimetableEditPage()));
                        },
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(CupertinoIcons.pencil_circle),
                            Text(L10n.t("settings.editTimetable")),
                          ],
                        )),
                    const Padding(padding: EdgeInsets.all(10)),
                    Row(
                      children: [
                        PaddedTitle(
                            key: _relevantModulesTitleKey,
                            title: L10n.t("settings.currentModulesIn", [
                              KITProvider.currentSemesterString
                            ])),
                        (vm.campusManager.isFetchingSchedule ||
                                vm.campusManager.isFetchingModules)
                            ? KITProgressIndicator()
                            : SizedBox(
                                width: 0,
                                height: 0,
                              ),
                        Spacer(),
                        CupertinoButton(
                          onPressed: () {
                            toastsProvider
                                .showTextToast(L10n.t("settings.reloadingModules"));
                            // fire-and-forget without a catch would swallow
                            // the failure silently behind the "reloading"
                            // toast that already vanished
                            unawaited(vm.forceRefetchEverything().catchError((e) {
                              toastsProvider
                                  .showTextToast(L10n.t("common.refreshFailed"));
                            }));
                          },
                          padding: EdgeInsets.all(10),
                          child: Icon(CupertinoIcons.refresh),
                        )
                      ],
                    ),
                    Container(
                      padding: EdgeInsets.all(5),
                      child: RelevantModulesView(),
                    ),
                    const Padding(padding: EdgeInsets.all(20)),
                    PaddedTitle(
                      title: L10n.t("settings.pinnedFiles"),
                      trailing: CupertinoButton(
                          child: Text(L10n.t("settings.viewAll")),
                          onPressed: () => Navigator.of(context).push(
                              MaterialPageRoute(
                                  builder: (BuildContext context) =>
                                      FilesCachePage()))),
                    ),
                    PinnedFilesListView(),
                    const Padding(padding: EdgeInsets.all(20)),
                    PaddedTitle(title: L10n.t("settings.myModules")),
                    HierarchicTableView(
                      rows: vm.campusManager.moduleRows,
                    ),
                    // the floating dock overlays the page: without this the
                    // last module rows sit permanently under the pill
                    const SizedBox(height: 140),
                  ],
                )
              ]),
            ),
            ),
          ],
        ));
  }

  // Future<void> _refreshHomeView(KITProvider vm) async {
  //   await vm.forceRefetchEverything();
  // }
}
