import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:kit_mobile/common_ui/block_container.dart';
import 'package:kit_mobile/common_ui/kit_progress_indicator.dart';
import 'package:kit_mobile/l10n/l10n.dart';
import 'package:kit_mobile/module/models/module.dart';
import 'package:kit_mobile/module_info_table/models/module_info_table_types/module_info_table_sensible.dart';
import 'package:kit_mobile/state_management/kit_provider.dart';
import 'package:kit_mobile/timetable/models/timetable_appointment.dart';
import 'package:kit_mobile/timetable/models/timetable_daily.dart';
import 'package:kit_mobile/timetable/models/timetable_weekly.dart';
import 'package:kit_mobile/timetable/views/timetable_weekly_view.dart';
import 'package:kit_mobile/tutorials/data/tutorial_manager.dart';
import 'package:kit_mobile/tutorials/models/tutorial.dart';
import 'package:kit_mobile/utils/string_prettifiers.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:provider/provider.dart';

class TimetableEditPage extends StatefulWidget {
  const TimetableEditPage({super.key});

  @override
  State<StatefulWidget> createState() {
    return _TimetableEditPageState();
  }
}

class _TimetableEditPageState extends State<TimetableEditPage> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context
          .read<TutorialManager>()
          .ensureSemesterLoaded(KITProvider.currentSemesterString);
    });
  }

  @override
  Widget build(BuildContext context) {
    final vm = context.watch<KITProvider>();
    final tutorialManager = context.watch<TutorialManager>();
    final semester = KITProvider.currentSemesterString;
    final tutorials = tutorialManager
        .tutorialsForSemester(semester)
        .map(
          (tutorial) => _withModuleTitle(
            tutorial,
            vm.campusManager.rowModules.values,
          ),
        )
        .toList(growable: false);

    final modulesById =
        _modulesById(vm.campusManager.rowModules.values);
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(L10n.t("timetable.editTitle")),
      ),
      body: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        L10n.t("timetable.tutorials"),
                        style: theme.textTheme.titleLarge,
                      ),
                    ],
                  ),

                  const SizedBox(height: 8),

                  Text(
                    L10n.t("timetable.tutorialsDescription"),
                    style: theme.textTheme.bodyMedium,
                  ),

                  const SizedBox(height: 16),

                  if (!tutorialManager.isSemesterLoaded(semester))
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 24),
                      child: Center(child: CircularProgressIndicator()),
                    )
                  else if (tutorials.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 24),
                      child: Text(
                        L10n.t("timetable.noTutorials"),
                        style: theme.textTheme.bodyMedium,
                      ),
                    )
                  else
                    ListView.separated(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      itemCount: tutorials.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (context, index) => _TutorialListTile(
                        tutorial: tutorials[index],
                        modulesById: modulesById,
                        onEdit: () => _openTutorialDialog(
                          context,
                          modulesById: modulesById,
                          existing: tutorials[index],
                        ),
                        onDelete: () => _confirmRemoveTutorial(
                          context,
                          tutorial: tutorials[index],
                        ),
                      ),
                    ),

                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      CupertinoButton(
                          padding: EdgeInsets.zero,
                          onPressed: modulesById.isEmpty
                              ? () => _showNoModulesDialog(context)
                              : () => _openTutorialDialog(context,
                                  modulesById: modulesById),
                          child: Icon(CupertinoIcons.add)),
                    ],
                  ),

                  SizedBox(height: 24,),

                  Row(
                    children: [
                      Text(
                        L10n.t("agenda.lecturesExercises"),
                        style: theme.textTheme.titleLarge,
                      ),
                      vm.campusManager.mostImportantModulesFetched ? SizedBox.shrink() : SizedBox(width: 8,),
                      vm.campusManager.mostImportantModulesFetched ? SizedBox.shrink() : KITProgressIndicator()
                    ],
                  ),

                  const SizedBox(height: 8),

                  Text(
                    L10n.t("timetable.addAppointmentsHint"),
                    style: theme.textTheme.bodyMedium,
                  ),

                  Column(
                    children: vm.campusManager.moduleInfoTablesWithAppointments.keys.map((rowId) {
                      final tables = vm.campusManager.moduleInfoTablesWithAppointments[rowId]!;
                      if (tables.isEmpty) {
                        return Row(children: [],);
                      }

                      return Column(
                        children: [
                          SizedBox(height: 32,),

                          Text(sanitizeModuleTitle(tables.first.parentModule.title), style: theme.textTheme.titleLarge, textAlign: TextAlign.center,),

                          SizedBox(height: 8,),

                          BlockContainer(
                            child: Column(
                              children: tables.map((table) {
                                return Padding(
                                  padding: EdgeInsets.only(bottom: 16),
                                  child: ModuleInfoTableSensible(table: table),
                                );
                              }
                              ).toList(),
                            ),
                          )
                        ],
                      );
                    }).toList(),
                  ),

                  // const SizedBox(height: 24),
                  // Text(
                  //   "Aktueller Stundenplan (Vorschau)",
                  //   style: theme.textTheme.titleLarge,
                  // ),
                  // const SizedBox(height: 12),
                ],
              ),
            ),
            TimetableWeeklyView(),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }

  Map<String, KITModule> _modulesById(Iterable<KITModule> modules) {
    final result = <String, KITModule>{};
    for (final module in modules) {
      if (module.id.isEmpty) continue;
      result[module.id] = module;
    }
    return result;
  }

  Tutorial _withModuleTitle(
    Tutorial tutorial,
    Iterable<KITModule> modules,
  ) {
    for (final module in modules) {
      if (module.id == tutorial.moduleId &&
          module.title.trim().isNotEmpty &&
          module.title.trim() != tutorial.moduleTitle) {
        return tutorial.copyWith(moduleTitle: module.title.trim());
      }
    }
    return tutorial;
  }

  Future<void> _openTutorialDialog(
    BuildContext context, {
    required Map<String, KITModule> modulesById,
    Tutorial? existing,
  }) async {
    final theme = Theme.of(context);
    final moduleList = modulesById.values
        .where((module) => module.id.isNotEmpty)
        .toList(growable: false)
      ..sort((a, b) => a.title.compareTo(b.title));

    if (moduleList.isEmpty) {
      await _showNoModulesDialog(context);
      return;
    }

    String selectedModuleId = existing?.moduleId ?? moduleList.first.id;
    Weekday selectedWeekday = existing?.weekday ?? Weekday.monday;
    int selectedBlockIndex = existing?.blockIndex ?? _defaultBlockIndex;
    final TextEditingController notesController = TextEditingController(
      text: existing?.notes ?? "",
    );

    await showDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierColor: theme.scaffoldBackgroundColor.withAlpha(175),
      builder: (dialogContext) {
        return LayoutBuilder(
          builder: (context, constraints) {
            final mediaWidth = MediaQuery.of(dialogContext).size.width;
            final availableWidth = constraints.maxWidth.isFinite
                ? constraints.maxWidth
                : mediaWidth;
            final double dialogWidth =
                availableWidth > 520 ? 520 : availableWidth * 0.92;

            return Stack(
              alignment: Alignment.center,
              children: [
                Center(
                  child: StatefulBuilder(
                    builder: (context, setState) {
                      return BlockContainer(
                        innerPadding: EdgeInsets.all(5),
                        withShadow: true,
                        child: ConstrainedBox(
                          constraints: BoxConstraints(
                            maxWidth: dialogWidth,
                            maxHeight:
                            MediaQuery.of(dialogContext).size.height * 0.85,
                          ),
                          child: Padding(
                            padding: const EdgeInsets.all(20),
                            child: SingleChildScrollView(
                              child: Card(
                                color: Colors.white.withAlpha(0),
                                shadowColor: Colors.grey.withAlpha(0),
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      existing == null
                                          ? L10n.t("timetable.addTutorial")
                                          : L10n.t("timetable.editTutorial"),
                                      style: theme.textTheme.titleLarge,
                                    ),

                                    const SizedBox(height: 16),

                                    DropdownButtonFormField<String>(
                                      initialValue: selectedModuleId,
                                      decoration: InputDecoration(
                                          labelText:
                                              L10n.t("timetable.selectModule"),
                                      ),
                                      items: moduleList
                                          .map(
                                            (module) => DropdownMenuItem(
                                          value: module.id,
                                          child: Text(module.title),
                                        ),
                                      )
                                          .toList(),
                                      onChanged: (value) {
                                        if (value == null) return;
                                        setState(
                                                () => selectedModuleId = value);
                                      },
                                    ),

                                    const SizedBox(height: 12),

                                    DropdownButtonFormField<Weekday>(
                                      initialValue: selectedWeekday,
                                      decoration: InputDecoration(
                                          labelText: L10n.t("timetable.weekdayLabel")),
                                      items: workingWeekdays
                                          .map(
                                            (weekday) => DropdownMenuItem(
                                          value: weekday,
                                          child:
                                          Text(_weekdayLabel(weekday)),
                                        ),
                                      )
                                          .toList(),
                                      onChanged: (value) {
                                        if (value == null) return;
                                        setState(() => selectedWeekday = value);
                                      },
                                    ),

                                    const SizedBox(height: 12),

                                    DropdownButtonFormField<int>(
                                      initialValue: selectedBlockIndex,
                                      decoration: InputDecoration(
                                          labelText: L10n.t("timetable.timeBlock")),
                                      items: _blockOptions
                                          .map(
                                            (option) => DropdownMenuItem(
                                          value: option.index,
                                          child: Text(option.label),
                                        ),
                                      )
                                          .toList(),
                                      onChanged: (value) {
                                        if (value == null) return;
                                        setState(
                                                () => selectedBlockIndex = value);
                                      },
                                    ),

                                    // const SizedBox(height: 12),
                                    //
                                    // TextField(
                                    //   controller: notesController,
                                    //   decoration: const InputDecoration(
                                    //     labelText: "Notizen (optional)",
                                    //     hintText:
                                    //         "z.B. Raum, Ansprechpartner, Hinweise",
                                    //   ),
                                    //   maxLines: 3,
                                    // ),

                                    const SizedBox(height: 24),

                                    Row(
                                      mainAxisAlignment: MainAxisAlignment.end,
                                      children: [
                                        CupertinoButton(
                                          padding: const EdgeInsets.symmetric(
                                              horizontal: 12, vertical: 8),
                                          onPressed: () =>
                                              Navigator.of(dialogContext).pop(),
                                          child: Text(L10n.t("timetable.cancel")),
                                        ),
                                        const SizedBox(width: 12),
                                        CupertinoButton.filled(
                                          padding: const EdgeInsets.symmetric(
                                              horizontal: 14, vertical: 8),
                                          onPressed: () async {
                                            final module =
                                            modulesById[selectedModuleId];
                                            if (module == null) {
                                              return;
                                            }

                                            final tutorial = existing != null
                                                ? existing.copyWith(
                                              moduleId: module.id,
                                              moduleTitle: module.title
                                                  .trim()
                                                  .isEmpty
                                                  ? module.title
                                                  : module.title.trim(),
                                              weekday: selectedWeekday,
                                              blockIndex:
                                              selectedBlockIndex,
                                              notes: notesController.text
                                                  .trim()
                                                  .isEmpty
                                                  ? null
                                                  : notesController.text
                                                  .trim(),
                                            )
                                                : Tutorial.createNew(
                                              moduleId: module.id,
                                              moduleTitle: module.title
                                                  .trim()
                                                  .isEmpty
                                                  ? module.title
                                                  : module.title.trim(),
                                              weekday: selectedWeekday,
                                              blockIndex:
                                              selectedBlockIndex,
                                              semesterString: KITProvider
                                                  .currentSemesterString,
                                              notes: notesController.text
                                                  .trim()
                                                  .isEmpty
                                                  ? null
                                                  : notesController.text
                                                  .trim(),
                                            );

                                            await context
                                                .read<TutorialManager>()
                                                .addOrUpdateTutorial(tutorial);
                                            if (dialogContext
                                                .mounted) {
                                              // the OUTER dialog route pops
                                              // here: guard that context, not
                                              // the page State's
                                              Navigator.of(dialogContext)
                                                  .pop();
                                            }
                                          },
                                          child: Text(L10n.t("timetable.save")),
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Future<void> _confirmRemoveTutorial(
    BuildContext context, {
    required Tutorial tutorial,
  }) async {
    final shouldDelete = await showCupertinoDialog<bool>(
      context: context,
      builder: (dialogContext) => CupertinoAlertDialog(
        title: Text(L10n.t("timetable.deleteTutorial")),
        content: Text(
          L10n.t("timetable.deleteTutorialConfirm", [tutorial.moduleTitle]),
        ),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(L10n.t("timetable.cancel")),
          ),
          CupertinoDialogAction(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            isDestructiveAction: true,
            child: Text(L10n.t("timetable.delete")),
          ),
        ],
      ),
    );

    if (shouldDelete != true || !context.mounted) {
      // dialog dismissal is an async gap: the edit page can already be
      // popped (system back during the dialog animation)
      return;
    }

    await context.read<TutorialManager>().removeTutorial(
          semesterString: tutorial.semesterString,
          tutorialId: tutorial.tutorialId,
        );
  }

  Future<void> _showNoModulesDialog(BuildContext context) {
    return showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (dialogContext) {
        final theme = Theme.of(dialogContext);
        return LayoutBuilder(
          builder: (context, constraints) {
            final mediaWidth = MediaQuery.of(dialogContext).size.width;
            final availableWidth = constraints.maxWidth.isFinite
                ? constraints.maxWidth
                : mediaWidth;
            final double dialogWidth =
                availableWidth > 420 ? 420 : availableWidth * 0.9;

            return Stack(
              alignment: Alignment.center,
              children: [
                Center(
                  child: GlassContainer(
                    // shape: LiquidRoundedSuperellipse(
                    //     borderRadius: appBorderRadiusDouble),
                    // // settings: GlassContainerSettings(
                    // //   glassColor: theme.colorScheme.surface.withOpacity(0.75),
                    // // ),
                    child: ConstrainedBox(
                      constraints: BoxConstraints(maxWidth: dialogWidth),
                      child: Padding(
                        padding: const EdgeInsets.all(20),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              L10n.t("timetable.noModulesTitle"),
                              style: theme.textTheme.titleLarge,
                            ),
                            const SizedBox(height: 12),
                            Text(
                              L10n.t("timetable.noModulesBody"),
                            ),
                            const SizedBox(height: 24),
                            Align(
                              alignment: Alignment.centerRight,
                              child: CupertinoButton(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 12, vertical: 8),
                                onPressed: () =>
                                    Navigator.of(dialogContext).pop(),
                                child: Text(L10n.t("agenda.dismiss")),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  static String _weekdayLabel(Weekday weekday) {
    switch (weekday) {
      case Weekday.monday:
        return L10n.t("timetable.monday");
      case Weekday.tuesday:
        return L10n.t("timetable.tuesday");
      case Weekday.wednesday:
        return L10n.t("timetable.wednesday");
      case Weekday.thursday:
        return L10n.t("timetable.thursday");
      case Weekday.friday:
        return L10n.t("timetable.friday");
      case Weekday.saturday:
        return L10n.t("timetable.saturday");
      case Weekday.sunday:
        return L10n.t("timetable.sunday");
    }
  }

  static final List<_BlockOption> _blockOptions =
      TimetableDaily.genericAppointmentsSchedule
          .asMap()
          .entries
          .where(
            (entry) => entry.value.type != TimetableAppointmentType.lunchBreak,
          )
          .map(
            (entry) => _BlockOption(
              index: entry.key,
              label:
                  "${entry.value.begin.hour.toString().padLeft(2, "0")}:${entry.value.begin.minute.toString().padLeft(2, "0")} - "
                  "${entry.value.end.hour.toString().padLeft(2, "0")}:${entry.value.end.minute.toString().padLeft(2, "0")}",
            ),
          )
          .toList(growable: false);

  static int get _defaultBlockIndex =>
      _blockOptions.isNotEmpty ? _blockOptions.first.index : 0;
}

class _BlockOption {
  final int index;
  final String label;

  const _BlockOption({required this.index, required this.label});
}

class _TutorialListTile extends StatelessWidget {
  final Tutorial tutorial;
  final Map<String, KITModule> modulesById;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  const _TutorialListTile({
    required this.tutorial,
    required this.modulesById,
    required this.onEdit,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final module = modulesById[tutorial.moduleId];
    final title = module?.title ?? tutorial.moduleTitle;
    final blockLabel = _TimetableEditPageState._blockOptions
        .firstWhere(
          (option) => option.index == tutorial.blockIndex,
          orElse: () => _BlockOption(index: tutorial.blockIndex, label: ""),
        )
        .label;

    return ListTile(
      title: Text(
        title,
        style: theme.textTheme.titleMedium,
      ),
      subtitle: Text(
        "${_TimetableEditPageState._weekdayLabel(tutorial.weekday)} · $blockLabel",
      ),
      trailing: Wrap(
        spacing: 8,
        children: [
          CupertinoButton(
            padding: EdgeInsets.zero,
            onPressed: onEdit, minimumSize: Size(32, 32),
            child: const Icon(CupertinoIcons.pencil),
          ),
          CupertinoButton(
            padding: EdgeInsets.zero,
            onPressed: onDelete, minimumSize: Size(32, 32),
            child: Icon(CupertinoIcons.trash, color: theme.colorScheme.error),
          ),
        ],
      ),
    );
  }
}
