import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/l10n.dart';
import '../../state_management/campus/campus_manager.dart';

/// One Studienverlauf row as the diagnostic shows it.
class ModuleTreeDebugEntry {
  final String title;
  final int level;

  /// The title is recognized on the merged timetable feed - the very rule
  /// that decides whether the "current modules" card admits it.
  final bool onFeed;

  /// The row's CampusKIT module page has been fetched, i.e. `rowModules`
  /// knows it (the card can only ever show such a row).
  final bool pageLoaded;

  const ModuleTreeDebugEntry(
      {required this.title,
      required this.level,
      required this.onFeed,
      required this.pageLoaded});
}

/// "Is Advanced Mathematics I actually in the tree, and what does CampusKIT
/// call it?" - answerable on the device instead of by re-running a debug
/// build and reading stdout.
///
/// Plain on purpose: a flat list of every module-level tree row, a green
/// check where the feed rule matches, a marker where the page was never
/// fetched, and long-press to copy a title so it can be pasted into a bug
/// report. Nothing here changes any state.
class ModuleTreeDebugPage extends StatefulWidget {
  final CampusManager campusManager;

  const ModuleTreeDebugPage({super.key, required this.campusManager});

  /// Diagnostic rows in tree order. Level 3+ is where CampusKIT starts
  /// listing modules (level 1 is the profile/grade row, level 2 the module
  /// groups), so below that nothing can be a module.
  static List<ModuleTreeDebugEntry> entries(CampusManager cm) {
    return [
      for (final row in cm.moduleRows)
        if (row.level >= 3)
          ModuleTreeDebugEntry(
              title: row.title,
              level: row.level,
              onFeed: CampusManager.moduleKeyMatchesLectureKey(
                  CampusManager.lectureTitleKey(row.title),
                  cm.enrolledLectureTitles),
              pageLoaded: cm.rowModules.containsKey(row.id))
    ];
  }

  @override
  State<StatefulWidget> createState() => _ModuleTreeDebugPageState();
}

class _ModuleTreeDebugPageState extends State<ModuleTreeDebugPage> {
  String _copiedTitle = "";

  void _copyTitle(String title) {
    Clipboard.setData(ClipboardData(text: title));
    HapticFeedback.mediumImpact();
    setState(() => _copiedTitle = title);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final entries = ModuleTreeDebugPage.entries(widget.campusManager);

    return Scaffold(
      appBar: AppBar(
        title: Text(L10n.t("settings.debugFetch")),
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 40),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(15, 10, 15, 10),
            child: Text(
              _copiedTitle.isEmpty
                  ? L10n.t("settings.debugTreeCopyHint")
                  : L10n.t("settings.debugTreeCopied", [_copiedTitle]),
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.outline),
            ),
          ),
          if (entries.isEmpty)
            Padding(
              padding: const EdgeInsets.all(20),
              child: Text(L10n.t("settings.debugTreeEmpty"),
                  style: theme.textTheme.bodyMedium),
            )
          else
            for (final entry in entries) _entryRow(context, entry),
        ],
      ),
    );
  }

  Widget _entryRow(BuildContext context, ModuleTreeDebugEntry entry) {
    final theme = Theme.of(context);

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onLongPress: () => _copyTitle(entry.title),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(15, 8, 15, 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(entry.title,
                      style: theme.textTheme.bodyMedium),
                ),
                Text("L${entry.level}",
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.outline)),
                const SizedBox(width: 8),
                if (!entry.pageLoaded)
                  Text(L10n.t("settings.debugTreeNoPage"),
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: theme.colorScheme.outline)),
                if (entry.onFeed)
                  const Padding(
                    padding: EdgeInsets.only(left: 8),
                    child: Icon(CupertinoIcons.check_mark_circled_solid,
                        size: 18, color: Colors.green),
                  ),
              ],
            ),
          ),
          const Divider(height: 1),
        ],
      ),
    );
  }
}
