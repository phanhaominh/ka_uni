import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../l10n/l10n.dart';
import '../../toasts/models/toasts_provider.dart';
import 'ics_export.dart';

/// Duplicates CampusManager._webcalIcsCacheKey (same as the agenda page
/// does): the export reads the merged feed body straight from storage, so
/// it works without coupling to the state layer.
const _icsCacheKey = "DATA_webcalIcsCache";

/// Single-flight: a double tap must not start two shares that collide on
/// the same date-based temp file - whichever finished first would delete
/// it out from under the other's still-open share sheet.
Future<void>? _inFlight;

Future<void> exportMergedTimetableIcs(BuildContext context) {
  // resolved before the first await; the toast survives widget disposal
  final running = _inFlight;
  if (running != null) return running;
  final toasts = context.read<ToastsProvider>();
  return _inFlight =
      _exportOnce(toasts).whenComplete(() => _inFlight = null);
}

Future<void> _exportOnce(ToastsProvider toasts) async {
  File? shared;
  try {
    final prefs = await SharedPreferences.getInstance();
    final export = buildIcsExport(prefs.getString(_icsCacheKey) ?? "");
    if (export == null) {
      toasts.showTextToast(L10n.t("export.empty"));
      return;
    }
    final dir = await getTemporaryDirectory();
    final file = shared = File("${dir.path}/${export.fileName}");
    await file.writeAsBytes(export.bytes, flush: true);
    final result = await SharePlus.instance.share(ShareParams(files: [
      XFile(file.path, mimeType: icsExportMimeType),
    ]));
    if (result.status == ShareResultStatus.success) {
      toasts.showTextToast(export.eventCount == 1
          ? L10n.t("export.doneOne")
          : L10n.t("export.done", [export.eventCount]));
    }
  } on Object catch (_) {
    // share sheet can throw on headless/emulated targets and temp writes
    // can fail on full storage - surface as the generic failure hint
    toasts.showTextToast(L10n.t("export.failed"));
  } finally {
    // a full merged-timetable copy must not outlive the share: the logout
    // sweep never visits the temp directory, so delete it in all paths
    try {
      await shared?.delete();
    } on Object catch (_) {}
  }
}
