import 'dart:async';

import 'package:flutter/material.dart';
import 'package:kit_mobile/state_management/kit_provider.dart';
import 'package:kit_mobile/home/views/relevant_module.dart';
import 'package:kit_mobile/module/models/module.dart';
import 'package:kit_mobile/toasts/models/toasts_provider.dart';
import 'package:kit_mobile/utils/date_time_utils.dart';
import 'package:provider/provider.dart';

import '../../l10n/l10n.dart';
import '../../utils/string_prettifiers.dart';
import '../../common_ui/block_container.dart';

class RelevantModulesView extends StatelessWidget {
  const RelevantModulesView({super.key});

  @override
  Widget build(BuildContext context) {
    final vm = Provider.of<KITProvider>(context);
    final toastsProvider = Provider.of<ToastsProvider>(context, listen: false);
    final theme = Theme.of(context);
    // ghost guard: ids persisted before admission was de-duplicated can
    // name a module whose page never loaded; the placeholder path below
    // would then prettify the row id into a second copy of a fetched
    // card's module - hide it. Genuinely pending modules still render.
    final modules = vm.campusManager.relevantModuleRowIDs
        .where((id) => !vm.campusManager.isPlaceholderGhost(id))
        .toList();
    final lastFetchTime = vm.campusManager.lastModuleFetchTime;
    final lastFetchLabel = lastFetchTime != null
        ? formatHumanReadableTimestamp(lastFetchTime)
        : "-";

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Text(
            L10n.t("home.lastUpdated", [lastFetchLabel]),
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.outline),
          ),
        ),
        const SizedBox(height: 8),
        if (modules.isEmpty)
          // fresh login / first sync: don't show a 300px dead hole
          BlockContainer(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                children: [
                  Icon(Icons.cloud_off,
                      size: 32, color: theme.colorScheme.outline),
                  const SizedBox(height: 8),
                  Text(L10n.t("home.modulesEmpty"),
                      style: theme.textTheme.bodyMedium),
                  const SizedBox(height: 12),
                  FilledButton.tonal(
                    // fire-and-forget without a catch: an empty-state retry
                    // that fails again would fail silently
                    onPressed: () => unawaited(vm
                        .forceRefetchEverything()
                        .catchError((_) => toastsProvider
                            .showTextToast(L10n.t("common.refreshFailed")))),
                    child: Text(L10n.t("home.modulesEmptyBtn")),
                  ),
                ],
              ),
            ),
          )
        else
          SizedBox(
            height: 300,
            child: GridView.count(
              crossAxisCount: 2,
              scrollDirection: Axis.horizontal,
              children: List.generate(modules.length, (idx) {
                final rowID = modules[idx];
                var module = vm.campusManager.rowModules[rowID];

                if (module == null) {
                  module = KITModule();
                  module.title = prettifyTemporaryModuleTitle(rowID);
                }

                return RelevantModuleView(module: module);
              }),
            ),
          ),
      ],
    );
  }
}
