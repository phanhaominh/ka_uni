import 'package:flutter/material.dart';
import 'package:kit_mobile/common_ui/block_container.dart';
import 'package:kit_mobile/constants/view_constants.dart';
import 'package:kit_mobile/l10n/l10n.dart';
import 'package:kit_mobile/module/models/module.dart';
import 'package:kit_mobile/state_management/kit_provider.dart';
import 'package:kit_mobile/timetable/models/timetable_appointment.dart';
import 'package:kit_mobile/timetable/pages/timetable_appointment_page.dart';
import 'package:kit_mobile/tutorials/data/tutorial_manager.dart';
import 'package:kit_mobile/tutorials/models/tutorial.dart';
import 'package:provider/provider.dart';

import '../models/timetable_daily.dart';

class TimetableDailyView extends StatelessWidget {
  final TimetableDaily tt;

  const TimetableDailyView({super.key, required this.tt});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final deviceWidth = MediaQuery.of(context).size.width;
    final tutorialManager = Provider.of<TutorialManager>(context);
    final kitProvider = Provider.of<KITProvider>(context);

    final modulesById = <String, KITModule>{};
    for (final module in kitProvider.campusManager.rowModules.values) {
      if (module.id.isNotEmpty) {
        modulesById[module.id] = module;
      }
    }

    final semesterString = KITProvider.currentSemesterString;
    final tutorialsList = tutorialManager
        .tutorialsForWeekday(semesterString, tt.weekday)
        .map((tutorial) {
      final module = modulesById[tutorial.moduleId];
      if (module != null && module.title.trim().isNotEmpty) {
        return tutorial.copyWith(moduleTitle: module.title.trim());
      }
      return tutorial;
    }).toList(growable: false);

    final tutorialsByBlock = <int, List<Tutorial>>{};
    for (final tutorial in tutorialsList) {
      tutorialsByBlock.putIfAbsent(tutorial.blockIndex, () => []).add(tutorial);
    }

    final appointmentsByBlock = tt.appointmentsWithTutorials(tutorialsByBlock);

    return Column(
      children: [
        Column(
          children: appointmentsByBlock.map((appointments) {
            final appointment = appointments
                .where((appointment) =>
                    !appointment.isEmpty || appointments.length <= 1)
                .first;
            bool isTut = appointment.type == TimetableAppointmentType.tutorial;

            // try {
            //   appointment as Tutorial;
            //   // isTut = true;
            // } catch (exc) {
            //   isTut = false;
            // }

            final empty = appointment.isEmpty &&
                appointment.type != TimetableAppointmentType.lunchBreak;
            if (empty) {
              // A free block must read as empty: the placeholder dash and
              // its time badge used to render like a lecture called "—".
              return Container(
                decoration: BoxDecoration(
                  border: appointment.begin.hour < 17
                      ? Border(
                          bottom: BorderSide(
                              color: theme.brightness == Brightness.light
                                  ? Colors.black12
                                  : Colors.white.withValues(alpha: 0.15)))
                      : null,
                ),
                child: SizedBox(height: appointment.duration * 0.9),
              );
            }
            return Container(
              decoration: BoxDecoration(
                border: appointment.begin.hour < 17
                    ? Border(
                        bottom: BorderSide(
                            color: theme.brightness == Brightness.light
                                ? Colors.black12
                                : Colors.white.withValues(alpha: 0.15)))
                    : null,
              ),
              child: SizedBox(
                height: appointment.duration * 0.9,
                child: Stack(
                  alignment: Alignment.topLeft,
                  children: [
                    // Padding(
                    //   padding: EdgeInsets.only(left: 15, right: 5, top: 5, bottom: 5),
                    //   child: VerticalDivider(color: theme.colorScheme.primary,),
                    // ),

                    GestureDetector(
                      onTap: () {
                        Navigator.of(context).push(MaterialPageRoute(
                            builder: (context) => TimetableAppointmentPage(
                                appointment: appointment)));
                      },
                      child: SizedBox(
                        width: appointment.type ==
                                TimetableAppointmentType.lunchBreak
                            ? null
                            : deviceWidth * 0.8,
                        child: Container(
                          // asymmetric: the HH:MM badge is Positioned at
                          // the top-right of this Stack, so the text column
                          // reserves the badge's footprint on the right -
                          // long titles used to run under it and cut
                          // mid-word. The badge text grows with the system
                          // font scale, so a const reservation loses that
                          // fight on Large/Largest: scale the text-proportional
                          // part with bodyLarge, keep a constant remainder.
                          padding: EdgeInsets.only(
                              left: 15,
                              right: 10 +
                                  62 *
                                      MediaQuery.textScalerOf(context)
                                          .scale(14) /
                                      14),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              // !isTut ? SizedBox.shrink() : Text("Tutorium:"),

                              appointment.id.isNotEmpty
                                  ? Hero(
                                      tag:
                                          "appointmentTitle_${appointment.title}_${appointment.id}",
                                      child: Text(
                                        isTut
                                            ? L10n.t(
                                                "timetable.tutorialPrefix",
                                                [appointment.displayTitle])
                                            : appointment.displayTitle,
                                        style: theme.textTheme.titleSmall
                                            ?.copyWith(
                                                fontWeight: FontWeight.bold),
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                      ))
                                  : Text(
                                      appointment.displayTitle,
                                      style: theme.textTheme.titleSmall
                                          ?.copyWith(
                                              fontWeight: FontWeight.bold),
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                    ),

                              appointment.place.title.isNotEmpty
                                  ? Hero(
                                      tag:
                                          "appointmentPlace_${appointment.title}_${appointment.id}",
                                      child: Text(
                                        appointment.displayPlace,
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                      ))
                                  : SizedBox(
                                      height: 0,
                                    ),

                              isTut &&
                                      appointment is Tutorial &&
                                      (appointment.notes ?? "").isNotEmpty
                                  ? Text(
                                      appointment.notes!,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                    )
                                  : const SizedBox.shrink(),

                              appointment.type ==
                                      TimetableAppointmentType.lunchBreak
                                  ? Row(
                                      children: [
                                        // CupertinoButton(
                                        //   child: Text("Speiseplan", style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.primary),),
                                        //   onPressed: () {},
                                        //   padding: EdgeInsets.only(left: 0),
                                        // )
                                      ],
                                    )
                                  : const SizedBox(
                                      height: 0,
                                    )
                            ],
                          ),
                        ),
                      ),
                    ),
                    Positioned(
                      top: 0,
                      right: 0,
                      child: ClipRRect(
                        borderRadius:
                            const BorderRadius.only(topRight: appBorderRadius),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.start,
                          children: [
                            BlockContainer(
                                padding:
                                    const EdgeInsets.only(left: 3, bottom: 3),
                                innerPadding: const EdgeInsets.only(
                                    left: 6, bottom: 3, top: 3, right: 6),
                                child: Text(
                                  "${appointment.begin.hour.toString().padLeft(2, "0")}:${appointment.begin.minute.toString().padLeft(2, "0")}",
                                  style: theme.textTheme.bodyLarge?.copyWith(
                                      color: theme.colorScheme.primary),
                                )),
                            // Text("${appointment.end.hour.toString().padLeft(2, "0")}:${appointment.end.minute.toString().padLeft(2, "0")}"),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          }).toList(),
        )
      ],
    );
  }
}
