import 'package:flutter/material.dart';
import '../../constants/view_constants.dart';
import '../../grades/views/grades_page.dart';
import 'package:flutter_svg/svg.dart';
import 'package:provider/provider.dart';

import '../../common_ui/block_container.dart';
import '../../l10n/l10n.dart';
import '../../state_management/kit_provider.dart';
import '../../toasts/models/toasts_provider.dart';

/// R35.3B: REMOVED from the default home composition. This card is now
/// reachable ONLY behind the one-release revert switch (PREF_legacyHome,
/// read once in `_KITHomePageState.build`); its always-visible content
/// (degree, semester, name, matriculation) was relocated to
/// [GradesPage._identityCard], average/CP already live in that page's
/// summary card, and its grades-entry became the home [ProfileDoorCard].
/// The PREF_showingAvgMark toggle is gone (avg+CP pair renders - the
/// old default); F-11's fake "0,0" is fixed here for the revert window:
/// an unavailable average prints "—" exactly like the grades page
/// ("0,0" is never a real German mark: 1,0..5,0 / "nicht bestanden").
/// CUT this file together with the revert switch next wave.
class ProfileView extends StatelessWidget {
  const ProfileView({super.key});

  @override
  Widget build(BuildContext context) {
    final vm = Provider.of<KITProvider>(context);
    final toastsProvider = Provider.of<ToastsProvider>(context);

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
                      child: SvgPicture.asset(
                        "assets/images/Fan.svg",
                        width: 150,
                        fit: BoxFit.none,
                      ),
                    ),
                    GestureDetector(
                      onLongPress: () async =>
                          toastsProvider.showTextToast("Hi :)"),
                      child: Container(
                        padding: EdgeInsets.symmetric(horizontal: 15),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            // the headline name used to slice mid-glyph on
                            // long names; Flexible lets the ellipsis
                            // actually render while the matriculation
                            // number keeps its place
                            Flexible(
                              child: Hero(
                                  tag: "student_name_repr",
                                  child: Text(vm.student.name.repr,
                                      style: theme.textTheme.headlineSmall,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis)),
                            ),
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
                // the German "Studiengang" label at large font scales is
                // wider than the leftover column: as an inflexible Text it
                // overflowed before the Expanded value could shrink
                Flexible(
                  child: Text(L10n.t("settings.degreeProgram"),
                      style: theme.textTheme.titleMedium,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                ),
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
                Flexible(
                  child: Text(L10n.t("settings.semester"),
                      style: theme.textTheme.titleMedium,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                ),
                Flexible(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(KITProvider.currentSemesterString,
                        style: theme.textTheme.titleMedium),
                  ),
                ),
              ],
            ),
          ),

          // R35.3B: the PREF_showingAvgMark toggle is deleted; the
          // avg+CP pair renders the way the pref's default did. F-11:
          // Student.empty prints avgMark "0,0" - never a real German
          // mark - and used to paint that fake zero where the grades
          // page shows "—"; it now prints "—" too. Same for the empty
          // string a parse can leave behind.
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              BlockContainer(
                padding: EdgeInsets.only(top: 7),
                child: SizedBox(
                  width: MediaQuery.of(context).size.width * 0.36,
                  // fixed 0.36*screen budget: the German label overflows it
                  // at large font scales without Flexible + ellipsis
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Flexible(
                        child: Text(L10n.t("settings.avgGrade"),
                            style: theme.textTheme.titleMedium,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis),
                      ),
                      const SizedBox(width: 6),
                      Text(
                          vm.student.avgMark.trim().isEmpty ||
                                  vm.student.avgMark == "0,0"
                              ? L10n.t("grades.valueNone")
                              : vm.student.avgMark,
                          style: theme.textTheme.titleMedium),
                    ],
                  ),
                ),
              ),
                    BlockContainer(
                        padding: EdgeInsets.only(top: 7),
                        child: SizedBox(
                          width: MediaQuery.of(context).size.width * 0.36,
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Flexible(
                                child: Text(L10n.t("settings.creditsShort"),
                                    style: theme.textTheme.titleMedium,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis),
                              ),
                              const SizedBox(width: 6),
                              Text(vm.student.ectsAcquired,
                                  style: theme.textTheme.titleMedium),
                            ],
                          ),
                        )),
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
              onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (context) => const GradesPage())),
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 15, vertical: 14),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(L10n.t("grades.entry"),
                          style: theme.textTheme.titleMedium),
                    ),
                    Icon(Icons.chevron_right, color: theme.colorScheme.outline),
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
