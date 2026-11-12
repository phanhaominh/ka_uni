import 'dart:convert' show utf8;

import 'package:file_picker/file_picker.dart';
import 'package:kit_mobile/state_management/campus/campus_manager.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:kit_mobile/common_ui/block_container.dart';
import 'package:kit_mobile/common_ui/max_width_body.dart';
import 'package:kit_mobile/common_ui/kit_progress_indicator.dart';
import 'package:kit_mobile/constants/view_constants.dart';
import 'package:kit_mobile/local_files_storage/files_manager.dart';
import 'package:kit_mobile/settings/providers/settings_provider.dart';
import 'package:kit_mobile/settings/types/multiple_choice_setting.dart';
import 'package:kit_mobile/state_management/kit_provider.dart';
import 'package:provider/provider.dart';

import '../../credentials/data/credentials_provider.dart';
import '../../info/views/info_page.dart';
import '../../l10n/l10n.dart';
import '../../local_files_storage/views/pages/files_cache_page.dart';
import 'module_tree_debug_page.dart';
import '../../tutorials/data/tutorial_manager.dart';
import '../../toasts/models/toasts_provider.dart';
import '../../timetable/logic/ics_export_action.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<StatefulWidget> createState() {
    return _SettingsPageState();
  }
}

class _SettingsPageState extends State<SettingsPage> {
  bool _loggingOut = false;

  /// lets the cache-size row re-walk after the cache manager pops:
  /// deletions there otherwise left a stale "12.3 MB" on screen
  final GlobalKey<_CacheSizeTextState> _cacheSizeKey =
      GlobalKey<_CacheSizeTextState>();

  @override
  Widget build(BuildContext context) {
    final vm = Provider.of<KITProvider>(context);
    final credsVM = Provider.of<CredentialsProvider>(context);
    final settingsVM = Provider.of<SettingsProvider>(context);

    // final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(L10n.t("settings.title")),
        actions: [
          CupertinoButton(
              child: Icon(CupertinoIcons.info),
              onPressed: () => Navigator.of(context)
                  .push(MaterialPageRoute(builder: (context) => InfoPage())))
        ],
      ),
      body: MaxWidthBody(
        child: SingleChildScrollView(
          child: Container(
            // extra bottom room: the floating dock pill overlays the scroll
            // view, and the last rows (Cache/Log out) must reach above it
            padding: defaultPagePaddingEdgeInsetsAll.copyWith(bottom: 150),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.center,
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                SettingsSectionTitle(title: L10n.t("settings.sectionHomepage")),

                BlockContainer(
                  child: Column(
                    children: [
                      SettingRow(
                          title: L10n.t("settings.showProfile"),
                          // tapping the card toggles the switch, as on the
                          // platform's own settings rows
                          onTap: () => settingsVM.showingProfile
                              .set(!settingsVM.showingProfile.value),
                          trailing: CupertinoSwitch(
                              value: settingsVM.showingProfile.value,
                              onChanged: settingsVM.showingProfile.set)),
                      SettingRow(
                          title: L10n.t("settings.showAvgGrade"),
                          onTap: () => settingsVM.showingAvgMark
                              .set(!settingsVM.showingAvgMark.value),
                          trailing: CupertinoSwitch(
                              value: settingsVM.showingAvgMark.value,
                              onChanged: settingsVM.showingAvgMark.set)),
                      SettingRow(
                          title: L10n.t("mensa.toggle"),
                          onTap: () => settingsVM.showMensa
                              .set(!settingsVM.showMensa.value),
                          trailing: CupertinoSwitch(
                              value: settingsVM.showMensa.value,
                              onChanged: settingsVM.showMensa.set)),
                    ],
                  ),
                ),

                BlockContainer(
                  child: Column(
                    children: [
                      SettingRow(
                          title: L10n.t("settings.language"),
                          trailing: LanguageDropdown(
                              languageSetting: settingsVM.language)),
                      SettingRow(
                          title: L10n.t("settings.appearance"),
                          trailing: MultipleChoiceSettingDropdown(
                              multipleChoiceSetting: settingsVM.theme,
                              labels: {
                                "system": L10n.t("settings.themeSystem"),
                                "light": L10n.t("settings.themeLight"),
                                "dark": L10n.t("settings.themeDark"),
                              })),
                    ],
                  ),
                ),

                SettingsSectionTitle(title: "ILIAS"),

                BlockContainer(
                  child: Column(
                    children: [
                      SettingRow(
                          title: L10n.t("settings.iliasStartPage"),
                          trailing: MultipleChoiceSettingDropdown(
                              multipleChoiceSetting:
                                  settingsVM.defaultIliasPage,
                              labels: {
                                "Dashboard":
                                    L10n.t("settings.iliasPageDashboard"),
                                "Meine Kurse & Gruppen":
                                    L10n.t("settings.iliasPageCourses"),
                              })),
                    ],
                  ),
                ),

                SettingsSectionTitle(
                    title: L10n.t("settings.sectionOwnTimetable")),

                BlockContainer(
                  child: const _OwnIcsSection(),
                ),

                SettingsSectionTitle(
                    title: L10n.t("settings.sectionFileCache")),

                BlockContainer(
                  // the whole card opens the cache manager: before, only the
                  // small "Manage" label responded; it stays as the visual
                  // affordance for the same action
                  child: Semantics(
                    button: true,
                    label: L10n.t("settings.sectionFileCache"),
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () async {
                        await Navigator.of(context).push(MaterialPageRoute(
                            builder: (BuildContext context) =>
                                FilesCachePage()));
                        _cacheSizeKey.currentState?.refresh();
                      },
                      child: ConstrainedBox(
                        // >= 48 dp tap target
                        constraints: const BoxConstraints(minHeight: 48),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            SettingRow(
                              title: L10n.t("settings.cacheSize"),
                              trailing: _CacheSizeText(key: _cacheSizeKey),
                            ),
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  L10n.t("settings.manage"),
                                  style: TextStyle(
                                      color: Theme.of(context)
                                          .colorScheme
                                          .primary),
                                ),
                                Icon(CupertinoIcons.chevron_forward,
                                    size: 14,
                                    color:
                                        Theme.of(context).colorScheme.primary),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),

                // internal fetch telemetry (full Studienverlauf tree with
                // admission verdicts) must not ship in release builds
                if (kDebugMode) ...[
                  SettingsSectionTitle(title: "Debug"),
                  BlockContainer(
                    // whole card (row and hint text) opens the debug page;
                    // the chevron is decoration inheriting this action
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => Navigator.of(context).push(MaterialPageRoute(
                          builder: (BuildContext context) =>
                              ModuleTreeDebugPage(
                                  campusManager: vm.campusManager))),
                      child: ConstrainedBox(
                        // >= 48 dp tap target
                        constraints: const BoxConstraints(minHeight: 48),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            SettingRow(
                              title: L10n.t("settings.debugFetch"),
                              trailing:
                                  const Icon(CupertinoIcons.chevron_forward),
                            ),
                            Text(
                              L10n.t("settings.debugFetchHint"),
                              style: Theme.of(context)
                                  .textTheme
                                  .bodySmall
                                  ?.copyWith(
                                      color: Theme.of(context)
                                          .colorScheme
                                          .outline),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],

                const SizedBox(height: 16),
                OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Theme.of(context).colorScheme.error,
                      side: BorderSide(
                          color: Theme.of(context).colorScheme.error),
                    ),
                    child: Text(L10n.t("settings.logout")),
                    // logout is a 5-10 s multi-vendor wipe; a second tap
                    // mid-flight would re-enter the wipe half-done
                    onPressed: _loggingOut
                        ? null
                        : () async {
                            // destructive action: never start the wipe
                            // without an explicit confirmation (same dialog
                            // pattern as the file deletion confirm)
                            if (!await _confirmLogout(context)) return;
                            // the dialog stays open for user latency; the
                            // page may be gone when it closes
                            if (!mounted) return;
                            final toastsProvider = Provider.of<ToastsProvider>(
                                context,
                                listen: false);
                            setState(() => _loggingOut = true);
                            try {
                              await credsVM.logout(
                                  vm, context.read<TutorialManager>());
                              // logout is a 5-10 s multi-vendor wipe; without a
                              // toast the button looks broken mid-flight
                              if (context.mounted) {
                                toastsProvider.showTextToast(
                                    L10n.t("settings.loggedOut"));
                              }
                            } on PartialLogoutException catch (e) {
                              // the local wipe DID succeed - the user is on
                              // the login form; "logout failed, try again"
                              // would be a lie with no retry path. This is
                              // the residue warning, kept distinct on
                              // purpose (raw step names stay in the console)
                              if (kDebugMode) {
                                print("logout residue: ${e.failures}");
                              }
                              if (context.mounted) {
                                toastsProvider.showTextToast(
                                    L10n.t("settings.loggedOutPartial"));
                              }
                            } on Object catch (e) {
                              // never leak raw exception text into a toast;
                              // it is for the console, not the user
                              if (kDebugMode) {
                                print("Logout failed: $e");
                              }
                              if (context.mounted) {
                                toastsProvider.showTextToast(
                                    L10n.t("settings.logoutFailed"));
                              }
                            } finally {
                              // on success logout navigates away: only touch
                              // the element if this page is still alive
                              if (mounted) {
                                setState(() => _loggingOut = false);
                              }
                            }
                          }),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Confirmation gate for the destructive logout; mirrors the file
  /// deletion confirm in FilesCachePage. Returns false on cancel/dismiss.
  Future<bool> _confirmLogout(BuildContext context) async {
    final confirmed = await showCupertinoDialog<bool>(
        context: context,
        builder: (dialogContext) => CupertinoAlertDialog(
              title: Text(L10n.t("settings.logoutConfirmTitle")),
              content: Text(L10n.t("settings.logoutConfirmBody")),
              actions: [
                CupertinoDialogAction(
                  onPressed: () => Navigator.of(dialogContext).pop(false),
                  child: Text(L10n.t("settings.cancel")),
                ),
                CupertinoDialogAction(
                  isDestructiveAction: true,
                  onPressed: () => Navigator.of(dialogContext).pop(true),
                  child: Text(L10n.t("settings.logout")),
                ),
              ],
            ));
    return confirmed ?? false;
  }

  // Widget _settingRow(String title, Widget trailing) =>
}

/// Import of a faculty/personal timetable ICS (URL or file). Needed
/// because big no-Belegung lectures (AM I etc.) never enter the CampusKIT
/// webcal feed; the faculty distributes them as a separate ICS instead.
class _OwnIcsSection extends StatefulWidget {
  const _OwnIcsSection();

  @override
  State<_OwnIcsSection> createState() => _OwnIcsSectionState();
}

class _OwnIcsSectionState extends State<_OwnIcsSection> {
  final _url = TextEditingController();
  bool _busy = false;
  int _events = -1; // event count, NOT the translated string - a language
  // flip re-builds this page in place and the old string must not survive it

  @override
  void initState() {
    super.initState();
    final cm = context.read<KITProvider>().campusManager;
    cm.ensurePersonalIcsLoaded().then((_) {
      if (mounted) {
        setState(() {
          _url.text = cm.personalIcsUrl;
          _loadStatus(cm);
        });
      }
    });
  }

  @override
  void dispose() {
    _url.dispose();
    super.dispose();
  }

  void _loadStatus(CampusManager cm) {
    _events = RegExp("BEGIN:VEVENT", dotAll: true)
        .allMatches(cm.personalIcs)
        .length;
  }

  String get _statusText => _events == 0
      ? L10n.t("settings.ownIcsNone")
      : L10n.t("settings.ownIcsLoaded", [_events]);

  Future<void> _run(Future<String?> Function() op, {bool clear = false}) async {
    final cm = context.read<KITProvider>().campusManager;
    final toasts = context.read<ToastsProvider>();
    setState(() => _busy = true);
    String? err;
    try {
      if (clear) {
        // the button used to run a no-op closure here: the import lived on
        // in prefs and stayed merged across restarts behind a success toast
        await cm.clearPersonalIcs();
      } else {
        err = await op();
      }
    } catch (_) {
      // A dead link or a pick cancelled mid-flight used to leave _busy
      // true forever, silently disabling all three buttons.
      err = "fetch";
    }
    await cm.ensurePersonalIcsLoaded();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _loadStatus(cm);
      if (clear) _url.text = cm.personalIcsUrl;
    });
    if (clear) {
      // honest branch: a throwing clearPersonalIcs (dead prefs, locked
      // storage) must not hide behind the success toast while the import
      // is still merged into every calendar on the device
      toasts.showTextToast(err == null
          ? L10n.t("settings.ownIcsCleared")
          : L10n.t("settings.ownIcsErrorClear"));
    } else if (err == "bad") {
      toasts.showTextToast(L10n.t("settings.ownIcsErrorBad"));
    } else if (err == "fetch") {
      toasts.showTextToast(L10n.t("settings.ownIcsErrorFetch"));
    } else if (err != "cancelled") {
      toasts.showTextToast(L10n.t("settings.ownIcsSaved"));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(_statusText,
              style: TextStyle(
                  fontSize: 13,
                  color: Theme.of(context).colorScheme.onSurfaceVariant)),
          const SizedBox(height: 8),
          TextField(
            controller: _url,
            enabled: !_busy,
            keyboardType: TextInputType.url,
            decoration: InputDecoration(
              isDense: true,
              hintText: L10n.t("settings.ownIcsUrlHint"),
            ),
          ),
          const SizedBox(height: 8),
          // German intrinsic widths of the three actions (~380-430 dp) blew
          // the ~301 dp card budget at DEFAULT scale: "Entfernen" rendered
          // past the card edge. Save/import share one Wrap (it wraps before
          // anything clips); clear lives on its own right-aligned row, so
          // the destructive action also no longer sits flush against
          // "Datei importieren…". TextButton keeps its >=44 dp tap height.
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton(
                  onPressed: _busy
                      ? null
                      : () => _run(
                          () => cm(context).setPersonalIcsFromUrl(_url.text)),
                  child: Text(L10n.t("settings.ownIcsSave"))),
              OutlinedButton(
                  onPressed: _busy
                      ? null
                      : () => _run(() async {
                            final picked = await FilePicker.pickFiles(
                              type: FileType.custom,
                              allowedExtensions: const ["ics", "txt"],
                              withData: true,
                            );
                            final bytes = picked?.files.single.bytes;
                            if (bytes == null) return "cancelled";
                            return cm(context).setPersonalIcsFromRaw(
                                utf8.decode(bytes, allowMalformed: true));
                          }),
                  child: Text(L10n.t("settings.ownIcsFile"))),
            ],
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                  onPressed:
                      _busy ? null : () => _run(() async => null, clear: true),
                  child: Text(L10n.t("settings.ownIcsClear"))),
            ],
          ),
          const SizedBox(height: 8),
          // one-tap export of the merged cache (webcal + personal ICS +
          // SignMeUp blocks) as a sanitized .ics via the share sheet
          OutlinedButton.icon(
              onPressed: () => exportMergedTimetableIcs(context),
              icon: const Icon(Icons.share, size: 18),
              label: Text(L10n.t("export.timetableFull"))),
        ],
      ),
    );
  }

  static CampusManager cm(BuildContext context) =>
      context.read<KITProvider>().campusManager;
}

/// Cache size is walked once: an inline FutureBuilder re-created the future
/// on every unrelated rebuild (any setting toggle notifying the providers
/// below) and each recreation is a recursive directory walk.
class _CacheSizeText extends StatefulWidget {
  const _CacheSizeText({super.key});

  @override
  State<_CacheSizeText> createState() => _CacheSizeTextState();
}

class _CacheSizeTextState extends State<_CacheSizeText> {
  // not `late final`: refresh() swaps it after the cache page pops
  late Future<int> _sizeFuture;

  @override
  void initState() {
    super.initState();
    _sizeFuture = Provider.of<IliasFilesProvider>(context, listen: false)
        .localFileStorageManager
        .getCacheSize();
  }

  /// re-walks the cache directory; called when FilesCachePage pops since
  /// deletions there change the size this row displays
  void refresh() => setState(() {
        _sizeFuture = Provider.of<IliasFilesProvider>(context, listen: false)
            .localFileStorageManager
            .getCacheSize();
      });

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<int>(
        future: _sizeFuture,
        builder: (context, snapshot) {
          if (snapshot.hasData && snapshot.data != null) {
            return Text(
                "${(snapshot.data! / 1024 / 1024).toStringAsFixed(1)} MB");
          }
          if (snapshot.hasError) {
            // a failed directory walk must not spin forever
            return const Text("—");
          }
          return KITProgressIndicator();
        });
  }
}

class SettingRow extends StatelessWidget {
  final String title;
  final Widget trailing;

  /// Row-wide tap target for rows whose action lives in (or behind) the
  /// trailing widget: the whole card must respond, not just the small
  /// chevron/switch (TalkBack found the title nodes dead before).
  final VoidCallback? onTap;

  const SettingRow(
      {super.key, required this.title, required this.trailing, this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    final row = Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        // the bare title + 20 gap + fixed CupertinoSwitch overflowed at
        // large font scales ("Durchschnittsnote anzeigen"…); Flexible with
        // a one-line ellipsis shrinks the title instead of pushing the
        // switch off the card (same rule profile_view documents)
        Flexible(
          child: Text(
            title,
            style: theme.textTheme.bodyMedium,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        SizedBox(
          width: 20,
        ),
        trailing
      ],
    );
    if (onTap == null) return row;
    // opaque: taps in the space between title and trailing must count too;
    // the trailing control still wins hit-tests inside its own bounds
    return Semantics(
      button: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: row,
      ),
    );
  }
}

class SettingsSectionTitle extends StatelessWidget {
  final String title;

  const SettingsSectionTitle({super.key, required this.title});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      padding: EdgeInsets.only(left: 15, bottom: 2, top: 20),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.start,
        children: [
          Text(
            title,
            // Colors.grey measured 2.7:1 on the light appleGrey scaffold;
            // onSurfaceVariant is the theme's own caption ink (AA in both)
            style: theme.textTheme.bodyMedium?.copyWith(
                fontSize: 15,
                fontWeight: FontWeight.bold,
                color: theme.colorScheme.onSurfaceVariant),
          )
        ],
      ),
    );
  }
}

/// Popup-menu row for dropdowns: a leading check marks the active value,
/// because while the menu is open it covers the row that shows it.
Widget _dropdownItemLabel(BuildContext context,
    {required String label, required bool selected}) {
  return Row(
    children: [
      selected ? const Icon(Icons.check, size: 18) : const SizedBox(width: 18),
      const SizedBox(width: 6),
      Expanded(
        child: Text(
          label,
          textAlign: TextAlign.end,
          style: Theme.of(context).textTheme.bodyMedium,
        ),
      ),
    ],
  );
}

class MultipleChoiceSettingDropdown extends StatelessWidget {
  final MultipleChoiceSetting _multipleChoiceSetting;

  /// Optional display labels decoupled from stored values (e.g. the ILIAS
  /// start page pref must keep the scraped German page title as its value).
  final Map<String, String>? labels;

  const MultipleChoiceSettingDropdown(
      {super.key,
      required MultipleChoiceSetting multipleChoiceSetting,
      this.labels})
      : _multipleChoiceSetting = multipleChoiceSetting;

  @override
  Widget build(BuildContext context) {
    // final settingsVM = Provider.of<SettingsProvider>(context);
    final theme = Theme.of(context);

    return Expanded(
        child: DropdownButton(
            underline: SizedBox.shrink(),
            borderRadius: BorderRadius.all(appBorderRadius),
            dropdownColor: theme.cardColor,
            elevation: 1,
            alignment: Alignment.centerRight,
            items: _multipleChoiceSetting.choices
                .map((el) => DropdownMenuItem(
                      value: el,
                      alignment: Alignment.centerRight,
                      child: _dropdownItemLabel(
                        context,
                        label: labels?["$el"] ?? "$el",
                        selected: el == _multipleChoiceSetting.value,
                      ),
                    ))
                .toList(),
            value: _multipleChoiceSetting.value,
            onChanged: (item) => _multipleChoiceSetting.set(item)));
  }
}

/// Language picker with display names decoupled from stored pref values.
class LanguageDropdown extends StatelessWidget {
  final MultipleChoiceSetting<String> languageSetting;

  const LanguageDropdown({super.key, required this.languageSetting});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final labels = {
      "system": L10n.t("settings.languageSystem"),
      "de": L10n.t("settings.languageDe"),
      "en": L10n.t("settings.languageEn"),
    };
    return Expanded(
        child: DropdownButton<String>(
            underline: const SizedBox.shrink(),
            borderRadius: BorderRadius.all(appBorderRadius),
            dropdownColor: theme.cardColor,
            elevation: 1,
            alignment: Alignment.centerRight,
            items: languageSetting.choices
                .map((el) => DropdownMenuItem(
                      value: el,
                      alignment: Alignment.centerRight,
                      child: _dropdownItemLabel(
                        context,
                        label: labels[el] ?? el,
                        selected: el == languageSetting.value,
                      ),
                    ))
                .toList(),
            value: languageSetting.value,
            onChanged: (item) => languageSetting.set(item!)));
  }
}
