import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:kit_mobile/common_ui/block_container.dart';
import 'package:kit_mobile/common_ui/kit_progress_indicator.dart';
import 'package:kit_mobile/constants/view_constants.dart';
import 'package:kit_mobile/l10n/l10n.dart';
import 'package:kit_mobile/local_files_storage/files_manager.dart';
import 'package:kit_mobile/local_files_storage/models/pinned_file.dart';
import 'package:kit_mobile/local_files_storage/views/file_viewer.dart';
import 'package:provider/provider.dart';

class FilesCachePage extends StatefulWidget {
  const FilesCachePage({super.key});

  @override
  State<StatefulWidget> createState() {
    return _FilesCachePageState();
  }
}

class _FilesCachePageState extends State<FilesCachePage> {
  String expandedSemesterString = "";
  List<String> expandedSemesterStringFiles = [];
  // the sole cached semester auto-expands until the student taps a row
  bool userToggledExpansion = false;
  bool autoExpandScheduled = false;

  /// semester -> cached file paths of the current scan. An inline
  /// FutureBuilder future re-created the recursive directory walk on every
  /// unrelated rebuild (same bug [_CacheSizeText] documents in
  /// settings_page); only pull-to-refresh and the retry button re-run it.
  Future<Map<String, List<String>>>? _cacheFuture;

  /// last completed scan: kept while a refresh future is in flight (the
  /// snapshot is cleared when the future swaps) and patched in place by the
  /// deletion handlers
  Map<String, List<String>>? _lastScan;

  @override
  void initState() {
    super.initState();
    _cacheFuture = _loadCachedFiles(context.read<IliasFilesProvider>());
  }

  /// re-walks the cache directory (pull-to-refresh / retry). Deleting files
  /// patches [_lastScan] instead - that needs no scan to stay truthful.
  Future<void> _rescan() async {
    final future = _loadCachedFiles(context.read<IliasFilesProvider>());
    setState(() => _cacheFuture = future);
    // the FutureBuilder renders the failure; the FutureBuilder-facing and
    // the RefreshIndicator-facing futures must not both reject
    try {
      await future;
    } on Object catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final filesVM = Provider.of<IliasFilesProvider>(context);
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(L10n.t("files.cacheTitle")),
      ),
      body: RefreshIndicator(
          onRefresh: _rescan,
          child: FutureBuilder<Map<String, List<String>>>(
              future: _cacheFuture,
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  // a failed scan used to spin the progress indicator
                  // forever: name the failure and offer the way out
                  return ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    children: [
                      const SizedBox(height: 200),
                      Center(
                        child: Text(
                          L10n.t("common.refreshFailed"),
                          textAlign: TextAlign.center,
                          style: theme.textTheme.bodyMedium?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Center(
                        child: FilledButton(
                          onPressed: _rescan,
                          child: Text(L10n.t("ilias.retry")),
                        ),
                      ),
                    ],
                  );
                }

                // swapping in a refresh future clears the snapshot: keep
                // the previous scan on screen while the new one runs
                final semestersToFiles = snapshot.data ?? _lastScan;
                if (snapshot.data != null) _lastScan = snapshot.data;

                if (semestersToFiles == null) {
                  return ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    children: const [
                      SizedBox(height: 240),
                      Center(child: KITProgressIndicator()),
                    ],
                  );
                }

                final semesters = semestersToFiles.keys.toList();

                if (semesters.isEmpty) {
                  // an empty cache used to render a blank page: say what
                  // the student can do about it - as a scroll view, so the
                  // pull-to-refresh works on a cache smaller than the screen
                  return ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    children: [
                      const SizedBox(height: 200),
                      Center(
                        child: Text(
                          L10n.t("files.cacheEmpty"),
                          textAlign: TextAlign.center,
                          style: theme.textTheme.bodyMedium?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant),
                        ),
                      ),
                    ],
                  );
                }

                // exactly one semester: don't make the student tap to see it
                if (semesters.length == 1 &&
                    !userToggledExpansion &&
                    expandedSemesterString.isEmpty &&
                    !autoExpandScheduled) {
                  autoExpandScheduled = true;
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (mounted && !userToggledExpansion) {
                      _expandSemester(
                          semesters.first, semestersToFiles[semesters.first]!);
                    }
                  });
                }

                return ListView.builder(
                    // pull-to-refresh must work on a one-semester cache too
                    physics: const AlwaysScrollableScrollPhysics(),
                    itemCount: semesters.length,
                    itemBuilder: (context, index) {
                      final currentSemesterString = semesters[index];
                      final iAmSelected = expandedSemesterString
                              .compareTo(currentSemesterString) ==
                          0;
                      // the expanded row tracks live deletions; collapsed rows
                      // read their count straight off the loaded cache map
                      final cachedFiles = iAmSelected
                          ? expandedSemesterStringFiles
                          : semestersToFiles[currentSemesterString]!;

                      return Padding(
                        padding: EdgeInsets.all(defaultPagePadding),
                        child: BlockContainer(
                            child: Column(
                          children: [
                            // the whole header row opens the semester, not
                            // just the small chevron: opaque hit testing so
                            // taps in the gap count too, and one button
                            // node for TalkBack instead of dead text
                            Semantics(
                              button: true,
                              child: GestureDetector(
                                behavior: HitTestBehavior.opaque,
                                onTap: () => _expandSemester(
                                    currentSemesterString,
                                    semestersToFiles[currentSemesterString]!),
                                child: Row(
                                  children: [
                                    Text(
                                      _prettifySemesterString(
                                          currentSemesterString),
                                      style: theme.textTheme.titleMedium,
                                    ),
                                    Text(
                                      L10n.t(
                                          cachedFiles.length == 1
                                              ? "files.cachedFileCountOne"
                                              : "files.cachedFileCountOther",
                                          [cachedFiles.length]),
                                      style: TextStyle(
                                          fontSize: 12,
                                          color: theme
                                              .colorScheme.onSurfaceVariant),
                                    ),
                                    SizedBox(width: 8),
                                    Spacer(),
                                    AnimatedRotation(
                                      curve:
                                          defaultChevronRotationAnimationCurve,
                                      turns: iAmSelected ? 0 : -0.25,
                                      duration:
                                          defaultChevronRotationAnimationDuration,
                                      child: CupertinoButton(
                                        onPressed: () => _expandSemester(
                                            currentSemesterString,
                                            semestersToFiles[
                                                currentSemesterString]!),
                                        padding: EdgeInsets.zero,
                                        child: Semantics(
                                          button: true,
                                          // the chevron reveals the whole
                                          // file list of the semester; no
                                          // dedicated expand string exists
                                          label: L10n.t("settings.viewAll"),
                                          child:
                                              Icon(CupertinoIcons.chevron_down),
                                        ),
                                      ),
                                    )
                                  ],
                                ),
                              ),
                            ),
                            !iAmSelected
                                ? SizedBox.shrink()
                                : Column(
                                    children: <Widget>[
                                          Padding(padding: EdgeInsets.all(5)),
                                          Divider(),
                                        ] +
                                        // the semester index can outlive its
                                        // files (everything deleted): an
                                        // expanded zero-file semester used
                                        // to be blank space
                                        (cachedFiles.isEmpty
                                            ? <Widget>[
                                                Padding(
                                                  padding: EdgeInsets.symmetric(
                                                      vertical: 16,
                                                      horizontal: 8),
                                                  child: Text(
                                                    L10n.t("files.cacheEmpty"),
                                                    textAlign: TextAlign.center,
                                                    style: theme
                                                        .textTheme.bodyMedium
                                                        ?.copyWith(
                                                            color: theme
                                                                .colorScheme
                                                                .onSurfaceVariant),
                                                  ),
                                                ),
                                              ]
                                            : <Widget>[]) +
                                        cachedFiles.map<Widget>((semFile) {
                                          final fileDisplayName =
                                              semFile.substring(semFile.indexOf(
                                                  expandedSemesterString));
                                          return Row(
                                            children: [
                                              Expanded(
                                                child: Text(
                                                  _sanitizeFileDisplayName(
                                                      fileDisplayName),
                                                  softWrap: true,
                                                  maxLines: 3,
                                                  // long ILIAS names used to be
                                                  // cut off mid-glyph
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                ),
                                              ),
                                              Spacer(),
                                              // R23: was an inline
                                              // FutureBuilder(future: File(
                                              // semFile).stat()) - EVERY
                                              // rebuild of this page
                                              // (pin/rename/unpin notify)
                                              // handed every visible row
                                              // a fresh stat() future and
                                              // flashed the spinner again;
                                              // the file's own
                                              // _cacheFuture comment calls
                                              // this out as the known
                                              // anti-pattern. Resolved
                                              // exactly once per row.
                                              _FileSizeText(path: semFile),
                                              // Spacer(),
                                              CupertinoButton(
                                                  child: Semantics(
                                                    button: true,
                                                    label: L10n.t(
                                                        "files.document"),
                                                    child: Icon(CupertinoIcons
                                                        .eye_fill),
                                                  ),
                                                  onPressed: () async {
                                                    await Navigator.of(context)
                                                        .push(MaterialPageRoute(
                                                            builder: (BuildContext
                                                                    context) =>
                                                                PDFScreen(
                                                                    iliasFile: PinnedFile(
                                                                        semesterString:
                                                                            currentSemesterString,
                                                                        urlString:
                                                                            "",
                                                                        moduleTitle:
                                                                            "",
                                                                        addedAt:
                                                                            DateTime
                                                                                .now(),
                                                                        customName:
                                                                            fileDisplayName,
                                                                        fileSystemPath:
                                                                            semFile))));
                                                    // H7: the viewer's own
                                                    // delete button removes
                                                    // bytes and unpins, but
                                                    // this page only re-reads
                                                    // the disk in its OWN
                                                    // delete handlers - coming
                                                    // back used to leave the
                                                    // row listed with a stale
                                                    // size; re-patch the
                                                    // expansion list and the
                                                    // scan exactly the way
                                                    // the delete handler below
                                                    // does
                                                    final newSemFiles = await filesVM
                                                        .localFileStorageManager
                                                        .getFilesForSemesterString(
                                                            currentSemesterString);
                                                    // the viewer can outlive
                                                    // the page: after dispose
                                                    // the state must not be
                                                    // touched (same class of
                                                    // bug as the delete
                                                    // handler)
                                                    if (!mounted) return;
                                                    setState(() {
                                                      if (expandedSemesterString ==
                                                          currentSemesterString) {
                                                        expandedSemesterStringFiles =
                                                            newSemFiles;
                                                      }
                                                      // collapsed rows read
                                                      // their count off the
                                                      // scan: patch it too
                                                      _lastScan?[
                                                              currentSemesterString] =
                                                          newSemFiles;
                                                    });
                                                  }),
                                              CupertinoButton(
                                                onPressed: () async {
                                                  final shouldDelete =
                                                      await _confirmFileDeletion(
                                                          _sanitizeFileDisplayName(
                                                              fileDisplayName));

                                                  if (shouldDelete != true) {
                                                    return;
                                                  }

                                                  await filesVM
                                                      .localFileStorageManager
                                                      .removeFile(semFile);
                                                  // R22: bytes alone are not
                                                  // the deletion - drop any
                                                  // pinned entry pointing at
                                                  // this exact path (dead
                                                  // tiles otherwise)
                                                  await filesVM
                                                      .unpinFilesByPaths({
                                                    semFile
                                                  });
                                                  final newSemFiles = await filesVM
                                                      .localFileStorageManager
                                                      .getFilesForSemesterString(
                                                          currentSemesterString);

                                                  // backing out of the cache
                                                  // page mid-delete used to
                                                  // hit setState-after-dispose
                                                  if (!mounted) return;
                                                  setState(() {
                                                    expandedSemesterStringFiles =
                                                        newSemFiles;
                                                    // collapsed rows read their
                                                    // count off the scan, which
                                                    // rebuilds no longer re-run:
                                                    // patch it
                                                    _lastScan?[
                                                            currentSemesterString] =
                                                        newSemFiles;
                                                  });
                                                },
                                                padding: EdgeInsets.zero,
                                                child: Semantics(
                                                  button: true,
                                                  label: L10n.t("files.delete"),
                                                  child: Icon(
                                                    CupertinoIcons.delete,
                                                    color: Colors.red,
                                                  ),
                                                ),
                                              )
                                            ],
                                          );
                                        }).toList() +
                                        [
                                          CupertinoButton(
                                            onPressed: () async {
                                              final shouldDelete =
                                                  await _confirmFileDeletion(L10n.t(
                                                      "files.allFilesInSemester",
                                                      [
                                                    _prettifySemesterString(
                                                        currentSemesterString)
                                                  ]));
                                              if (shouldDelete != true) {
                                                return;
                                              }

                                              final wiped = <String>{};
                                              for (final file
                                                  in expandedSemesterStringFiles) {
                                                await filesVM
                                                    .localFileStorageManager
                                                    .removeFile(file);
                                                wiped.add(file);
                                              }
                                              // R22: same as the single-file
                                              // delete - the wipe must also
                                              // clear pinned prefs entries
                                              // pointing at wiped bytes
                                              await filesVM
                                                  .unpinFilesByPaths(wiped);
                                              // the wipe outlives the page
                                              // on a slow disk: after
                                              // dispose only the files may
                                              // go, the state must not be
                                              // touched (same class of bug
                                              // as the single-file delete)
                                              if (!mounted) return;
                                              setState(() {
                                                expandedSemesterStringFiles =
                                                    [];
                                                expandedSemesterString = "";
                                                _lastScan?[
                                                        currentSemesterString] =
                                                    const [];
                                              });
                                            },
                                            foregroundColor: Colors.red,
                                            // text-labelled already: VoiceOver
                                            // reads "Alle Löschen, Knopf"
                                            child:
                                                Text(L10n.t("files.deleteAll")),
                                          )
                                        ],
                                  )
                          ],
                        )),
                      );
                    });
              })),
    );
  }

  /// semester string -> the file paths cached for it; a single scan feeds
  /// both the per-row file counts and the expansion list
  Future<Map<String, List<String>>> _loadCachedFiles(
      IliasFilesProvider filesVM) async {
    final semesters =
        await filesVM.localFileStorageManager.getSemestersWithCachedFiles();
    final filesPerSemester = await Future.wait(semesters
        .map(filesVM.localFileStorageManager.getFilesForSemesterString));
    return {
      for (var i = 0; i < semesters.length; i++)
        semesters[i]: filesPerSemester[i],
    };
  }

  Future<bool?> _confirmFileDeletion(String filename) async {
    return await showCupertinoDialog<bool>(
        context: context,
        builder: (dialogContext) => CupertinoAlertDialog(
              title: Text(L10n.t("files.confirmDeletionTitle")),
              content: Text(L10n.t("files.confirmDeletionBody", [filename])),
              actions: [
                CupertinoDialogAction(
                  onPressed: () => Navigator.of(dialogContext).pop(false),
                  child: Text(L10n.t("files.cancel")),
                ),
                CupertinoDialogAction(
                  isDestructiveAction: true,
                  onPressed: () => Navigator.of(dialogContext).pop(true),
                  child: Text(L10n.t("files.delete")),
                ),
              ],
            ));
  }

  String _prettifySemesterString(String semesterString) {
    final underscoreSplit = semesterString.split("_");

    if (underscoreSplit.isEmpty) {
      return "";
    }

    String prettified = underscoreSplit[0];
    if (underscoreSplit.length >= 2) {
      prettified += " ${underscoreSplit[1]}";
    }

    for (int i = 2; i < underscoreSplit.length; i++) {
      prettified += "/${underscoreSplit[i]}";
    }

    return prettified;
    // return semesterString.replaceAll("_", " ").trim();
  }

  String _sanitizeFileDisplayName(String fileDisplayName) {
    fileDisplayName =
        fileDisplayName.substring(fileDisplayName.indexOf("/") + 1);

    return fileDisplayName;
  }

  void _expandSemester(String currentSemesterString, List<String> files) {
    setState(() {
      userToggledExpansion = true;
      if (expandedSemesterString == currentSemesterString) {
        // deselect
        expandedSemesterString = "";
        expandedSemesterStringFiles = [];
        return;
      }
      expandedSemesterString = currentSemesterString;
      expandedSemesterStringFiles = files;
    });
  }
}

/// One file's size label, stat()ed EXACTLY ONCE per mounted row (R23:
/// inline FutureBuilder(future: File(...).stat()) re-ran per rebuild and
/// flashed the spinner on every unrelated provider notification - the
/// memoized `_cacheFuture` in this very file documents that pattern as
/// the bug). Rows in the map carry no keys, so a path change on the same
/// element position re-stats instead of keeping the stale size.
class _FileSizeText extends StatefulWidget {
  const _FileSizeText({required this.path});

  final String path;

  @override
  State<_FileSizeText> createState() => _FileSizeTextState();
}

class _FileSizeTextState extends State<_FileSizeText> {
  late Future<FileStat> _stat = File(widget.path).stat();

  @override
  void didUpdateWidget(_FileSizeText old) {
    super.didUpdateWidget(old);
    if (old.path != widget.path) {
      setState(() => _stat = File(widget.path).stat());
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder(
        future: _stat,
        builder: (context, snapshot) {
          if (snapshot.hasData && snapshot.data != null) {
            return Text(
                "${(snapshot.data!.size / 1024 / 1024).toStringAsFixed(1)} MB");
          }
          if (snapshot.hasError) {
            // a vanished or unreadable file must not spin forever
            return const Text("\u2014");
          }
          return KITProgressIndicator();
        });
  }
}
