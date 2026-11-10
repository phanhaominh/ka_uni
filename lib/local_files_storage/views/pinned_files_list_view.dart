import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:kit_mobile/l10n/l10n.dart';
import 'package:kit_mobile/local_files_storage/files_manager.dart';
import 'package:kit_mobile/local_files_storage/views/file_viewer.dart';
import 'package:kit_mobile/state_management/kit_provider.dart';
import 'package:provider/provider.dart';

import '../models/pinned_file.dart';

class PinnedFilesListView extends StatefulWidget {
  const PinnedFilesListView({super.key});

  @override
  State<PinnedFilesListView> createState() => _PinnedFilesListViewState();
}

class _PinnedFilesListViewState extends State<PinnedFilesListView> {
  IliasFilesProvider? _manager;

  /// the pinned-file query, memoized for the semester it was loaded for:
  /// inlining it in the FutureBuilder re-ran it on every rebuild, so any
  /// unrelated KITProvider notification flashed the whole list
  Future<List<PinnedFile>>? _files;
  String? _filesSemester;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // the LISTENER is what has to re-query: pins, renames and unpins land in
    // prefs and IliasFilesProvider notifies after every write, while plain
    // rebuilds must not touch the query again
    final manager = context.read<IliasFilesProvider>();
    if (!identical(_manager, manager)) {
      _manager?.removeListener(_onFilesChanged);
      (_manager = manager).addListener(_onFilesChanged);
    }
    _loadFiles();
  }

  @override
  void dispose() {
    _manager?.removeListener(_onFilesChanged);
    super.dispose();
  }

  void _onFilesChanged() {
    if (!mounted) return;
    setState(() => _loadFiles(force: true));
  }

  void _loadFiles({bool force = false}) {
    final semester = KITProvider.currentSemesterString;
    if (!force && _files != null && _filesSemester == semester) return;
    _filesSemester = semester;
    _files = _manager!.getFilesForSemester(semester);
  }

  @override
  Widget build(BuildContext context) {
    final vm = Provider.of<KITProvider>(context);
    final filesManager = Provider.of<IliasFilesProvider>(context);

    return FutureBuilder<List<PinnedFile>>(
      future: _files,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }

        if (snapshot.hasError) {
          // the raw exception belongs in the console: it used to be
          // interpolated straight into the UI ("Fehler: PathNotFound...")
          if (kDebugMode) {
            print("Pinned files query failed: ${snapshot.error}");
          }
          return Center(child: Text(L10n.t('common.refreshFailed')));
        }

        final files = snapshot.data ?? const [];
        if (files.isEmpty) {
          return Center(child: Text(L10n.t('files.noneFound')));
        }

        return ListView.separated(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: files.length,
          separatorBuilder: (_, __) => const Divider(height: 1),
          itemBuilder: (context, index) {
            final file = files[index];
            final addedAt = file.addedAt.toLocal();
            final addedAtLabel =
                '${_twoDigits(addedAt.day)}.${_twoDigits(addedAt.month)}.${addedAt.year} ${_twoDigits(addedAt.hour)}:${_twoDigits(addedAt.minute)}';

            return ListTile(
              // isThreeLine gives exactly 4 text lines of tile height; an
              // unwrapped title that wrapped (files_cache_page documents
              // the same class of bug) made 1+2 = 4 lines of content plus
              // padding clip past the tile bottom. One honest title line:
              title: Text(file.customName,
                  maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text('${file.moduleTitle}\n$addedAtLabel'),
              isThreeLine: true,
              onTap: () => _openFile(context, vm, file),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Tooltip(
                    message: L10n.t('files.renameFile'),
                    child: Semantics(
                      button: true,
                      label: L10n.t('files.renameFile'),
                      child: CupertinoButton(
                        padding: EdgeInsets.zero,
                        child: const Icon(CupertinoIcons.pencil),
                        onPressed: () =>
                            _renameFile(context, filesManager, file),
                      ),
                    ),
                  ),
                  Tooltip(
                    message: L10n.t('files.removeFile'),
                    child: Semantics(
                      button: true,
                      label: L10n.t('files.removeFile'),
                      child: CupertinoButton(
                        padding: EdgeInsets.zero,
                        child: const Icon(
                          CupertinoIcons.pin_slash,
                          color: Colors.red,
                        ),
                        onPressed: () =>
                            _removeFile(context, filesManager, file),
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  void _openFile(BuildContext context, KITProvider vm, PinnedFile file) {
    Navigator.of(context).push(
      MaterialPageRoute(
          // builder: (context) => IliasPageView(
          //   module,
          //   isFileView: true,
          //   PHPSESSID: vm.iliasManager.getPHPSESSID(),
          // ),

          builder: (context) => PDFScreen(iliasFile: file)),
    );
  }

  Future<void> _renameFile(
    BuildContext context,
    IliasFilesProvider manager,
    PinnedFile file,
  ) async {
    final controller = TextEditingController(text: file.customName);
    final String? newName;
    try {
      // module_page._attachIliasLink's standard: the dialog's controller
      // used to leak on every rename — it must die with the dialog
      newName = await showCupertinoDialog<String>(
        context: context,
        builder: (dialogContext) {
          return CupertinoAlertDialog(
            title: Text(L10n.t('files.renameFile')),
            content: SizedBox(
              height: 75, // MediaQuery.of(context).devicePixelRatio,
              child: Padding(
                padding: const EdgeInsets.only(top: 12),
                child: CupertinoTextField(
                  controller: controller,
                  autofocus: true,
                  placeholder: L10n.t('files.newName'),
                ),
              ),
            ),
            actions: [
              CupertinoDialogAction(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: Text(L10n.t('files.cancel')),
              ),
              CupertinoDialogAction(
                isDefaultAction: true,
                onPressed: () =>
                    Navigator.of(dialogContext).pop(controller.text.trim()),
                child: Text(L10n.t('files.save')),
              ),
            ],
          );
        },
      );
    } finally {
      controller.dispose();
    }

    if (newName == null) {
      return;
    }

    await manager.updatePinnedFileCustomName(
      semesterString: file.semesterString,
      urlString: file.urlString,
      customName: newName,
    );
  }

  Future<void> _removeFile(
    BuildContext context,
    IliasFilesProvider manager,
    PinnedFile file,
  ) async {
    final shouldDelete = await showCupertinoDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return CupertinoAlertDialog(
          title: Text(L10n.t('files.removeFile')),
          content: Text(L10n.t('files.removeFileConfirm', [file.customName])),
          actions: [
            CupertinoDialogAction(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: Text(L10n.t('files.cancel')),
            ),
            CupertinoDialogAction(
              isDestructiveAction: true,
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: Text(L10n.t('files.delete')),
            ),
          ],
        );
      },
    );

    if (shouldDelete != true) {
      return;
    }

    await manager.unpinFile(
      semesterString: file.semesterString,
      urlString: file.urlString,
    );
  }

  String _twoDigits(int value) => value.toString().padLeft(2, '0');
}
