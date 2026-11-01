import 'package:flutter/material.dart';
import '../../constants/view_constants.dart';
import '../../grades/views/grades_page.dart';
import 'package:flutter_svg/svg.dart';
import 'package:kit_mobile/settings/providers/settings_provider.dart';
import 'package:provider/provider.dart';

import '../../common_ui/block_container.dart';
import '../../l10n/l10n.dart';
import '../../state_management/kit_provider.dart';
import '../../toasts/models/toasts_provider.dart';

class ProfileView extends StatelessWidget {
  final GlobalKey relevantModulesTitleKey;

  const ProfileView({super.key, required this.relevantModulesTitleKey});

  @override
  Widget build(BuildContext context) {
    final vm = Provider.of<KITProvider>(context);
    final toastsProvider = Provider.of<ToastsProvider>(context);
    final settingsVM = Provider.of<SettingsProvider>(context);

    final theme = Theme.of(context);

    return Padding(
      padding: EdgeInsets.all(15),
      child: Column(
        children: [
          BlockContainer(
            padding: EdgeInsets.zero,
            innerPadding: EdgeInsets.zero,
            child: Container(
              padding: EdgeInsets.zero,
              height: 80,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(20),
                child: Stack(
                  alignment: Alignment.centerLeft,
                  children: [
                    Positioned(
                      left: -30,
                      child: SvgPicture.asset("assets/images/Fan.svg", width: 150, fit: BoxFit.none,),
                    ),

                    GestureDetector(
                      onLongPress: () async => toastsProvider.showTextToast("Hi :)"),
                      child: Container(
                        padding: EdgeInsets.symmetric(horizontal: 15),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Hero(tag: "student_name_repr", child: Text(vm.student.name.repr, style: theme.textTheme.headlineSmall)),
                            Text(vm.student.matriculationNumber),
                          ],
                        ),
                      ),
                    )
                  ],
                ),
              ),
            ),
          ),

          Padding(padding: EdgeInsets.all(5)),

          BlockContainer(
            padding: const EdgeInsets.only(top: 10),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(L10n.t("settings.degreeProgram"), style: theme.textTheme.titleMedium,),
                const Padding(padding: EdgeInsets.all(10)),
                Expanded(
                  child: Text(
                    vm.student.degreeProgram,
                    style: theme.textTheme.titleMedium,
                    maxLines: 2,
                    textAlign: TextAlign.end,
                  ),
                )
              ],
            ),
          ),

          BlockContainer(
            padding: EdgeInsets.only(top: 7),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(L10n.t("settings.semester"), style: theme.textTheme.titleMedium,),
                Text(KITProvider.currentSemesterString, style: theme.textTheme.titleMedium,),
              ],
            ),
          ),

          !settingsVM.showingAvgMark.value ?
          BlockContainer(
              padding: EdgeInsets.only(top: 7),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(L10n.t("settings.creditPoints"), style: theme.textTheme.titleMedium,),

                  Text(vm.student.ectsAcquired, style: theme.textTheme.titleMedium,),
                ],
              )
          )
              : Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              BlockContainer(
                padding: EdgeInsets.only(top: 7),
                child: SizedBox(
                  width: MediaQuery.of(context).size.width * 0.36,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(L10n.t("settings.avgGrade"), style: theme.textTheme.titleMedium,),

                      Text(vm.student.avgMark.toString(), style: theme.textTheme.titleMedium,),
                    ],
                  ),
                ),
              ),

              BlockContainer(
                padding: EdgeInsets.only(top: 7),
                child: SizedBox(
                  width: MediaQuery.of(context).size.width * 0.36,
                  // padding: EdgeInsets.only(top: 10, bottom: 10, left: 15, right: 15),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(L10n.t("settings.creditsShort"), style: theme.textTheme.titleMedium,),

                      Text(vm.student.ectsAcquired, style: theme.textTheme.titleMedium,),
                    ],
                  ),
                )
              ),
            ],
          ),

          // the Studienverlauf tree aggregated into a pass/fail/pending
          // ledger with the 30 CP orientation milestone; the data is already
          // in memory from the login fetch, so this card is pure navigation
          BlockContainer(
            padding: const EdgeInsets.only(top: 7),
            // zero inner padding so the InkWell spans the WHOLE card: with
            // the default padding the ripple/hit area was confined to the
            // bare Row and taps on the visible padding were dead (~24dp
            // target vs Material's 48; place_search_page keeps its padding
            // inside the tappable for exactly this reason)
            innerPadding: EdgeInsets.zero,
            child: InkWell(
              borderRadius: const BorderRadius.all(appBorderRadius),
              onTap: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (context) => const GradesPage())),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 14),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(L10n.t("grades.entry"),
                          style: theme.textTheme.titleMedium),
                    ),
                    Icon(Icons.chevron_right,
                        color: theme.colorScheme.outline),
                  ],
                ),
              ),
            ),
          ),

        ],
      ),
    );
  }
}