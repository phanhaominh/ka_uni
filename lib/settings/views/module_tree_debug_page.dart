import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/l10n.dart';
import '../../state_management/campus/campus_manager.dart';

/// Why the "current modules" card does - or does not - show a tree row.
enum ModuleTreeDebugReason {
  /// admitted: the card lists this row
  shown,

  /// the feed rule never recognizes the title, so the feed gate rejects it
  feedMiss,

  /// the feed rule hits, but another admitted row already carries this
  /// module - the admission guard dropped this copy on purpose
  duplicateClash,

  /// an admitted id whose page was never fetched while a fetched card for
  /// the same module exists: [CampusManager.isPlaceholderGhost] hides it
  placeholderGhost,

  /// not admitted although the title is on the feed and no card carries it
  /// (yet) - typically a row whose module page was never fetched
  unexplained,
}

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

  /// The row id sits in `cm.relevantModuleRowIDs`, i.e. the card admits it.
  final bool admitted;

  /// The admission verdict and, where there is no card, the cause.
  final ModuleTreeDebugReason reason;

  const ModuleTreeDebugEntry(
      {required this.title,
      required this.level,
      required this.onFeed,
      required this.pageLoaded,
      required this.admitted,
      required this.reason});
}

/// "Is Advanced Mathematics I actually in the tree, and what does CampusKIT
/// call it?" - answerable on the device instead of by re-running a debug
/// build and reading stdout.
///
/// Plain on purpose: a flat list of every Studienverlauf row, a green check
/// where the card admits it, a tag naming the rejection cause where it does
/// not, and long-press to copy a title so it can be pasted into a bug
/// report. Nothing here changes any state.
class ModuleTreeDebugPage extends StatefulWidget {
  final CampusManager campusManager;

  const ModuleTreeDebugPage({super.key, required this.campusManager});

  /// Level at which CampusKIT starts listing modules (level 1 is the
  /// profile row, level 2 group headings). The card admits rows by their
  /// feed title alone and never filters by level - so neither does the
  /// diagnostic; the view only dims rows below this level.
  static const int moduleLevel = 3;

  /// Diagnostic rows in tree order: every row of the tree, verdict
  /// included. Pure - reads the manager, mutates nothing.
  static List<ModuleTreeDebugEntry> entries(CampusManager cm) {
    final admittedIds = cm.relevantModuleRowIDs.toSet();
    // which modules the card already carries, by title key
    final admittedKeys = <String, String>{};
    for (final id in admittedIds) {
      final key = _knownRowKey(cm, id);
      if (key != null) admittedKeys[id] = key;
    }
    return [
      for (final row in cm.moduleRows)
        () {
          final key = CampusManager.lectureTitleKey(row.title);
          final onFeed = CampusManager.moduleKeyMatchesLectureKey(
              key, cm.enrolledLectureTitles);
          final admitted = admittedIds.contains(row.id);
          ModuleTreeDebugReason reason;
          if (admitted) {
            // the ghost check is the more specific verdict for the same
            // key clash, so it runs before the generic duplicate one
            reason = ModuleTreeDebugReason.shown;
          } else if (!onFeed) {
            reason = ModuleTreeDebugReason.feedMiss;
          } else if (cm.isPlaceholderGhost(row.id)) {
            reason = ModuleTreeDebugReason.placeholderGhost;
          } else if (admittedKeys.entries.any((other) => CampusManager
              .moduleKeysDenoteSameModule(key, other.value))) {
            reason = ModuleTreeDebugReason.duplicateClash;
          } else {
            reason = ModuleTreeDebugReason.unexplained;
          }
          return ModuleTreeDebugEntry(
              title: row.title,
              level: row.level,
              onFeed: onFeed,
              pageLoaded: cm.rowModules.containsKey(row.id),
              admitted: admitted,
              reason: reason);
        }()
    ];
  }

  /// Title key a duplicate check resolves for row id [id]: fetched page
  /// title first, tree title second - the manager's own precedence,
  /// recomputed here because its helpers are private.
  static String? _knownRowKey(CampusManager cm, String id) {
    var title = cm.rowModules[id]?.title.trim() ?? "";
    if (title.isEmpty) {
      for (final row in cm.moduleRows) {
        if (row.id == id) {
          title = row.title.trim();
          break;
        }
      }
    }
    return title.isEmpty ? null : CampusManager.lectureTitleKey(title);
  }

  @override
  State<StatefulWidget> createState() => _ModuleTreeDebugPageState();
}

class _ModuleTreeDebugPageState extends State<ModuleTreeDebugPage> {
  /// One snapshot per page open: building an entry runs the fuzzy feed
  /// rule per row against the whole feed, and a tree easily has thousands
  /// of rows - far too expensive to redo on every interaction. The page
  /// never changes the manager, so it can only ever show the state the
  /// tree had when it was opened; reopening refreshes it.
  late final List<ModuleTreeDebugEntry> _entries;

  /// Copy feedback without setState, so one long-press does not rebuild
  /// thousands of rows; only the hint line listens.
  final ValueNotifier<String> _copiedTitle = ValueNotifier("");

  @override
  void initState() {
    super.initState();
    _entries = ModuleTreeDebugPage.entries(widget.campusManager);
  }

  @override
  void dispose() {
    _copiedTitle.dispose();
    super.dispose();
  }

  void _copyTitle(String title) {
    Clipboard.setData(ClipboardData(text: title));
    HapticFeedback.mediumImpact();
    _copiedTitle.value = title;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(L10n.t("settings.debugFetch")),
      ),
      body: Column(
        children: [
          ValueListenableBuilder<String>(
            valueListenable: _copiedTitle,
            builder: (context, copiedTitle, _) => Padding(
              padding: const EdgeInsets.fromLTRB(15, 10, 15, 10),
              child: Text(
                copiedTitle.isEmpty
                    ? L10n.t("settings.debugTreeCopyHint")
                    : L10n.t("settings.debugTreeCopied", [copiedTitle]),
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.outline),
              ),
            ),
          ),
          if (_entries.isEmpty)
            Padding(
              padding: const EdgeInsets.all(20),
              child: Text(L10n.t("settings.debugTreeEmpty"),
                  style: theme.textTheme.bodyMedium),
            )
          else
            Expanded(
              child: ListView.builder(
                padding: const EdgeInsets.only(bottom: 40),
                itemCount: _entries.length,
                itemBuilder: (context, index) =>
                    _entryRow(context, _entries[index]),
              ),
            ),
        ],
      ),
    );
  }

  Widget _entryRow(BuildContext context, ModuleTreeDebugEntry entry) {
    final theme = Theme.of(context);
    final isModule = entry.level >= ModuleTreeDebugPage.moduleLevel;
    final hintStyle =
        theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline);

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
                      style: isModule ? theme.textTheme.bodyMedium : hintStyle),
                ),
                if (!isModule) ...[
                  const SizedBox(width: 8),
                  Text(L10n.t("settings.debugTreeNoModule"),
                      style: hintStyle),
                ],
                  const SizedBox(width: 8),
                Text("L${entry.level}", style: hintStyle),
                const SizedBox(width: 8),
                if (!entry.pageLoaded)
                  Text(L10n.t("settings.debugTreeNoPage"), style: hintStyle),
                if (entry.admitted)
                  const Padding(
                    padding: EdgeInsets.only(left: 8),
                    child: Icon(CupertinoIcons.check_mark_circled_solid,
                        size: 18, color: Colors.green),
                  )
                else ...[
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(_reasonLabel(entry.reason), style: hintStyle),
                  ),
                ],
              ],
            ),
          ),
          const Divider(height: 1),
        ],
      ),
    );
  }

  static String _reasonLabel(ModuleTreeDebugReason reason) => switch (reason) {
        ModuleTreeDebugReason.shown =>
          L10n.t("settings.debugTreeShown"),
        ModuleTreeDebugReason.feedMiss =>
          L10n.t("settings.debugTreeFeedMiss"),
        ModuleTreeDebugReason.duplicateClash =>
          L10n.t("settings.debugTreeClash"),
        ModuleTreeDebugReason.placeholderGhost =>
          L10n.t("settings.debugTreeGhost"),
        ModuleTreeDebugReason.unexplained =>
          L10n.t("settings.debugTreeUnexplained"),
      };
}
