import 'package:flutter/foundation.dart';
import 'package:kit_mobile/local_files_storage/local_file_storage_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../l10n/l10n.dart';
import '../state_management/kit_provider.dart';
import 'models/pinned_file.dart';

const String semestersListKey = "DATA_semestersWithFiles";

class IliasFilesProvider extends ChangeNotifier {
  LocalFileStorageManager localFileStorageManager = LocalFileStorageManager();

  String _filesKeyForSemester(String semesterString) =>
      "DATA_filesFor$semesterString";

  /// Pin identity: two references point at the same pin. When the
  /// reference knows an ILIAS URL the urlString is the key; when it does
  /// not - the cache-page viewer synthesizes `PinnedFile(urlString: "")`
  /// for files opened straight off the disk, so empty URLs are common -
  /// identity falls back to the on-disk path. Matching empty-url pins by
  /// urlString used to treat ALL of them as one file: pinning file B
  /// silently DELETED pin A in addPinnedFile, and rename hit the first
  /// empty-url entry, the wrong file. A reference with neither URL nor
  /// path claims no match at all: two entries whose identity is unknown
  /// stay two entries, unknown must not be resolved into a false claim.
  bool _samePin(PinnedFile reference, PinnedFile stored) =>
      _pinMatches(stored, reference.urlString, reference.fileSystemPath);

  /// The reference side of [_samePin] for callers that carry only the
  /// bare locators - rename and unpin know (semester, urlString[,
  /// fileSystemPath]), not the whole entry.
  bool _pinMatches(
      PinnedFile stored, String urlString, String fileSystemPath) {
    if (urlString.isEmpty) {
      return fileSystemPath.isNotEmpty &&
          stored.fileSystemPath == fileSystemPath;
    }
    return stored.urlString == urlString;
  }

  Future<List<String>> getSemestersList() async {
    final prefs = await SharedPreferences.getInstance();

    var semesters = prefs.getStringList(semestersListKey) ??
        [KITProvider.currentSemesterString];

    if (semesters.isEmpty) {
      semesters = [KITProvider.currentSemesterString];
      await prefs.setStringList(semestersListKey, semesters);
    }

    for (final semester in semesters) {
      await _ensurePinnedFilesListExists(prefs, semester);
    }

    return semesters;
  }

  Future<void> addCurrentSemesterToSemestersList() async {
    final prefs = await SharedPreferences.getInstance();
    await _addSemesterToSemestersList(prefs, KITProvider.currentSemesterString);
  }

  Future<void> addPinnedFile(PinnedFile newFile) async {
    final prefs = await SharedPreferences.getInstance();
    await _addSemesterToSemestersList(prefs, newFile.semesterString);

    final key = _filesKeyForSemester(newFile.semesterString);
    final storedEntries = prefs.getStringList(key) ?? <String>[];
    final updatedEntries = List<String>.from(storedEntries);

    // One entry per file per [_samePin]: with the bare urlString test,
    // the cache-page pins (synthesized urlString == "") all collided, so
    // pinning file B silently DELETED pin A; now URL-less pins dedupe on
    // their path instead.
    updatedEntries.removeWhere((stored) {
      final decoded = PinnedFile.tryDecode(stored);
      return decoded != null && _samePin(newFile, decoded);
    });
    final normalizedFile = newFile.copyWith(
      addedAt: newFile.addedAt.toUtc(),
      customName: _normalizeCustomName(newFile.customName, newFile.moduleTitle),
    );
    updatedEntries.add(normalizedFile.encode());

    await prefs.setStringList(key, updatedEntries);
    notifyListeners();
  }

  Future<void> setPinnedFilesListForSemester(
      String semesterString, List<PinnedFile> files) async {
    final prefs = await SharedPreferences.getInstance();
    await _addSemesterToSemestersList(prefs, semesterString);

    final encodedFiles = files
        .map(
          (file) => file
              .copyWith(
                addedAt: file.addedAt.toUtc(),
                customName:
                    _normalizeCustomName(file.customName, file.moduleTitle),
              )
              .encode(),
        )
        .toList();

    await prefs.setStringList(
        _filesKeyForSemester(semesterString), encodedFiles);
    notifyListeners();
  }

  /// [fileSystemPath] is the fallback locator for pins without an ILIAS
  /// URL (files pinned via the cache-page viewer): with the bare
  /// urlString match, renaming the second empty-url entry hit the FIRST
  /// empty-url entry, the wrong file - callers holding the full PinnedFile
  /// must pass its path along.
  Future<void> updatePinnedFileCustomName({
    required String semesterString,
    required String urlString,
    required String customName,
    String fileSystemPath = "",
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await _ensurePinnedFilesListExists(prefs, semesterString);

    final key = _filesKeyForSemester(semesterString);
    final storedEntries = prefs.getStringList(key) ?? <String>[];

    if (storedEntries.isEmpty) {
      return;
    }

    final List<String> updatedEntries = [];
    var updated = false;

    for (final entry in storedEntries) {
      final decoded = PinnedFile.tryDecode(entry);
      if (decoded == null) {
        updatedEntries.add(entry);
        continue;
      }

      if (!updated && _pinMatches(decoded, urlString, fileSystemPath)) {
        final updatedFile = decoded.copyWith(
          customName: _normalizeCustomName(customName, decoded.moduleTitle),
          addedAt: decoded.addedAt.toUtc(),
        );
        updatedEntries.add(updatedFile.encode());
        updated = true;
      } else {
        updatedEntries.add(decoded
            .copyWith(
              addedAt: decoded.addedAt.toUtc(),
              customName: _normalizeCustomName(
                decoded.customName,
                decoded.moduleTitle,
              ),
            )
            .encode());
      }
    }

    if (!updated) {
      return;
    }

    await prefs.setStringList(key, updatedEntries);
    notifyListeners();
  }

  /// R22: the DISK-side deletes in FilesCachePage removed bytes only -
  /// PinnedFile prefs entries pointing at the deleted path survived and
  /// the pinned list rendered dead tiles whose viewer opened an empty
  /// PDFView (C55's orphan problem mirrored from the other side). Drops
  /// every entry across all semesters whose fileSystemPath was deleted.
  /// This is the path side of the [_samePin] identity taken to its byte
  /// end: bytes gone kills every pin pointing at them, URL-carrying pins
  /// included - a gone file is a gone file whatever locator its pin kept.
  Future<void> unpinFilesByPaths(Set<String> deletedPaths) async {
    if (deletedPaths.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    final semesters =
        prefs.getStringList(semestersListKey) ?? const <String>[];
    var changed = false;
    for (final semester in semesters) {
      final key = _filesKeyForSemester(semester);
      final stored = prefs.getStringList(key) ?? const <String>[];
      if (stored.isEmpty) continue;
      final kept = stored.where((entry) {
        final decoded = PinnedFile.tryDecode(entry);
        if (decoded == null) return true; // never destroy unknown entries
        return !deletedPaths.contains(decoded.fileSystemPath);
      }).toList();
      if (kept.length != stored.length) {
        await prefs.setStringList(key, kept);
        changed = true;
      }
    }
    if (changed) notifyListeners();
  }

  /// [fileSystemPath] is the fallback locator for pins without an ILIAS
  /// URL: with the bare urlString match, unpinning an empty-url pin
  /// dropped EVERY empty-url pin of the semester; a reference with an
  /// empty URL and an empty path now removes nothing rather than guessing
  /// (the viewer's delete went fully path-keyed via [unpinFilesByPaths]).
  Future<void> unpinFile({
    required String semesterString,
    required String urlString,
    String fileSystemPath = "",
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await _ensurePinnedFilesListExists(prefs, semesterString);

    final key = _filesKeyForSemester(semesterString);
    final storedEntries = prefs.getStringList(key) ?? <String>[];

    if (storedEntries.isEmpty) {
      return;
    }

    final updatedEntries = storedEntries.where((entry) {
      final decoded = PinnedFile.tryDecode(entry);
      if (decoded == null) {
        return true;
      }
      return !_pinMatches(decoded, urlString, fileSystemPath);
    }).toList();

    if (updatedEntries.length == storedEntries.length) {
      return;
    }

    await prefs.setStringList(key, updatedEntries);
    notifyListeners();
  }

  Future<List<PinnedFile>> getFilesForSemester(String semesterString) async {
    final prefs = await SharedPreferences.getInstance();
    await _ensurePinnedFilesListExists(prefs, semesterString);

    final entries =
        prefs.getStringList(_filesKeyForSemester(semesterString)) ?? <String>[];
    return entries
        .map(PinnedFile.tryDecode)
        .whereType<PinnedFile>()
        .toList(growable: false);
  }

  Future<List<PinnedFile>> getFilesForCurrentSemester() async {
    return getFilesForSemester(KITProvider.currentSemesterString);
  }

  Future<Map<String, List<PinnedFile>>> getFilesGroupedBySemester() async {
    final semesters = await getSemestersList();
    final Map<String, List<PinnedFile>> grouped = {};

    for (final semester in semesters) {
      grouped[semester] = await getFilesForSemester(semester);
    }

    return grouped;
  }

  String _normalizeCustomName(String customName, String fallbackTitle) {
    final trimmedName = customName.trim();
    if (trimmedName.isNotEmpty) {
      return trimmedName;
    }

    final trimmedFallback = fallbackTitle.trim();
    if (trimmedFallback.isNotEmpty) {
      return trimmedFallback;
    }

    return L10n.t("files.unnamedFile");
  }

  Future<void> _addSemesterToSemestersList(
      SharedPreferences prefs, String semesterString) async {
    final stored = prefs.getStringList(semestersListKey) ?? <String>[];

    if (!stored.contains(semesterString)) {
      final updated = List<String>.from(stored)..add(semesterString);
      await prefs.setStringList(semestersListKey, updated);
    }

    await _ensurePinnedFilesListExists(prefs, semesterString);
  }

  Future<void> _ensurePinnedFilesListExists(
      SharedPreferences prefs, String semesterString) async {
    final key = _filesKeyForSemester(semesterString);
    if (!prefs.containsKey(key)) {
      await prefs.setStringList(key, <String>[]);
    }
  }
}
