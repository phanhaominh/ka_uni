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

  @override
  Widget build(BuildContext context) {
    final filesVM = Provider.of<IliasFilesProvider>(context);
    final theme = Theme.of(context);

    // semester -> its cached files: one scan feeds the per-row file
    // counts and the expansion list
    final cacheFuture = _loadCachedFiles(filesVM);

    return Scaffold(
      appBar: AppBar(
        title: Text(L10n.t("files.cacheTitle")),
      ),
      body: FutureBuilder(
          future: cacheFuture,
          builder: (context, snapshot) {
            if (snapshot.hasData && snapshot.data != null) {
              final semestersToFiles = snapshot.data!;
              final semesters = semestersToFiles.keys.toList();

              if (semesters.isEmpty) {
                // an empty cache used to render a blank page: say what
                // the student can do about it
                return Center(
                  child: Padding(
                    padding: EdgeInsets.all(defaultPagePadding * 2),
                    child: Text(
                      L10n.t("files.cacheEmpty"),
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant),
                    ),
                  ),
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
                          GestureDetector(
                            child: Row(
                              children: [
                                Text(
                                  _prettifySemesterString(currentSemesterString),
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
                                      color: theme.colorScheme
                                          .onSurfaceVariant),
                                ),
                                SizedBox(width: 8),
                                Spacer(),
                                AnimatedRotation(
                                  curve: defaultChevronRotationAnimationCurve,
                                  turns: iAmSelected ? 0 : -0.25,
                                  duration: defaultChevronRotationAnimationDuration,
                                  child: CupertinoButton(
                                    onPressed: () => _expandSemester(
                                        currentSemesterString,
                                        semestersToFiles[
                                            currentSemesterString]!),
                                    padding: EdgeInsets.zero,
                                    child: Icon(CupertinoIcons.chevron_down),
                                  ),
                                )
                              ],
                            ),
                            onTap: () => _expandSemester(
                                currentSemesterString,
                                semestersToFiles[currentSemesterString]!),
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
                                                  padding: EdgeInsets
                                                      .symmetric(
                                                          vertical: 16,
                                                          horizontal: 8),
                                                  child: Text(
                                                    L10n.t("files.cacheEmpty"),
                                                    textAlign: TextAlign.center,
                                                    style: theme.textTheme
                                                        .bodyMedium
                                                        ?.copyWith(
                                                            color: theme
                                                                .colorScheme
                                                                .onSurfaceVariant),
                                                  ),
                                                ),
                                              ]
                                            : <Widget>[]) +
                                      cachedFiles
                                          .map<Widget>((semFile) {
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
                                              ),
                                            ),
                                            Spacer(),
                                            FutureBuilder(
                                                future: File(semFile).stat(),
                                                builder: (context, snapshot) {
                                                  if (snapshot.hasData &&
                                                      snapshot.data != null) {
                                                    return Text(
                                                        "${(snapshot.data!.size / 1024 / 1024).toStringAsFixed(1)} MB");
                                                  }

                                                  return KITProgressIndicator();
                                                }),
                                            // Spacer(),
                                            CupertinoButton(
                                                child: Icon(
                                                    CupertinoIcons.eye_fill),
                                                onPressed: () {
                                                  Navigator.of(context).push(MaterialPageRoute(
                                                      builder: (BuildContext
                                                              context) =>
                                                          PDFScreen(
                                                              iliasFile: PinnedFile(
                                                                  semesterString:
                                                                      currentSemesterString,
                                                                  urlString: "",
                                                                  moduleTitle:
                                                                      "",
                                                                  addedAt:
                                                                      DateTime
                                                                          .now(),
                                                                  customName:
                                                                      fileDisplayName,
                                                                  fileSystemPath:
                                                                      semFile))));
                                                }),
                                            CupertinoButton(
                                              onPressed: () async {
                                                final shouldDelete = await _confirmFileDeletion(_sanitizeFileDisplayName(
                                                    fileDisplayName));

                                                if (shouldDelete != true) {
                                                  return;
                                                }
                                                
                                                await filesVM
                                                    .localFileStorageManager
                                                    .removeFile(semFile);
                                                final newSemFiles = await filesVM
                                                    .localFileStorageManager
                                                    .getFilesForSemesterString(
                                                        currentSemesterString);

                                                setState(() {
                                                  expandedSemesterStringFiles =
                                                      newSemFiles;
                                                });
                                              },
                                              padding: EdgeInsets.zero,
                                              child: Icon(
                                                CupertinoIcons.delete,
                                                color: Colors.red,
                                              ),
                                            )
                                          ],
                                        );
                                      }).toList() +
                                      [
                                        CupertinoButton(
                                          onPressed: () async {
                                            final shouldDelete = await _confirmFileDeletion(L10n.t("files.allFilesInSemester", [_prettifySemesterString(currentSemesterString)]));
                                            if (shouldDelete != true) {
                                              return;
                                            }

                                            for (final file
                                                in expandedSemesterStringFiles) {
                                              await filesVM
                                                  .localFileStorageManager
                                                  .removeFile(file);
                                            }
                                            setState(() {
                                              expandedSemesterStringFiles = [];
                                              expandedSemesterString = "";
                                            });
                                          },
                                          foregroundColor: Colors.red,
                                          child: Text(L10n.t("files.deleteAll")),
                                        )
                                      ],
                                )
                        ],
                      )),
                    );
                  });
            }

            return Center(
              child: KITProgressIndicator(),
            );
          }),
    );
  }

  /// semester string -> the file paths cached for it; a single scan feeds
  /// both the per-row file counts and the expansion list
  Future<Map<String, List<String>>> _loadCachedFiles(
      IliasFilesProvider filesVM) async {
    final semesters = await filesVM.localFileStorageManager
        .getSemestersWithCachedFiles();
    final filesPerSemester = await Future.wait(semesters
        .map(filesVM.localFileStorageManager.getFilesForSemesterString));
    return {
      for (var i = 0; i < semesters.length; i++)
        semesters[i]: filesPerSemester[i],
    };
  }

  Future<bool?> _confirmFileDeletion(String filename) async {
    return await showCupertinoDialog<bool>(context: context, builder: (dialogContext) => CupertinoAlertDialog(
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
