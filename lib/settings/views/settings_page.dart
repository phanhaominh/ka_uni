import 'dart:async' show unawaited;
import 'dart:convert' show utf8;

import 'package:file_picker/file_picker.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:kit_mobile/bureaucracy/papierkram.dart';
import 'package:kit_mobile/bureaucracy/starter_pack.dart';
import 'package:kit_mobile/docwatch/docwatch.dart';
import 'package:kit_mobile/state_management/campus/campus_manager.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:url_launcher/url_launcher.dart';
import 'package:kit_mobile/common_ui/block_container.dart';
import 'package:kit_mobile/common_ui/max_width_body.dart';
import 'package:kit_mobile/common_ui/kit_progress_indicator.dart';
import 'package:kit_mobile/constants/view_constants.dart';
import 'package:kit_mobile/local_files_storage/files_manager.dart';
import 'package:kit_mobile/settings/providers/settings_provider.dart';
import 'package:kit_mobile/settings/types/multiple_choice_setting.dart';
import 'package:kit_mobile/state_management/kit_provider.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../agenda/views/chronicle_page.dart';
import '../../fristenbuch/fristenbuch_page.dart';
import '../../credentials/data/credentials_provider.dart';
import '../../diagnostics/feed_health.dart';
import '../../diagnostics/support_state.dart';
import '../../notifications/mei_notifications.dart';
import '../../info/views/info_page.dart';
import '../../l10n/l10n.dart';
import '../../local_files_storage/views/pages/files_cache_page.dart';
import 'module_tree_debug_page.dart';
import '../../tutorials/data/tutorial_manager.dart';
import '../../toasts/models/toasts_provider.dart';
import '../../timetable/logic/ics_export_action.dart';
import '../../timetable/models/webcal.dart';

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
    final cm = vm.campusManager;
    final scheme = Theme.of(context).colorScheme;

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
                      // R35.3: the "Show profile" + "Show average grade"
                      // rows died with their PREF_showingProfile /
                      // PREF_showingAvgMark keys (reads AND writes, same
                      // commit). In their seat: the one-release revert
                      // switch for the HOME=TODAY split.
                      SettingRow(
                          title: L10n.t("settings.legacyHome"),
                          // tapping the card toggles the switch, as on the
                          // platform's own settings rows
                          onTap: () => settingsVM.legacyHome
                              .set(!settingsVM.legacyHome.value),
                          trailing: CupertinoSwitch(
                              value: settingsVM.legacyHome.value,
                              onChanged: settingsVM.legacyHome.set)),
                      SettingRow(
                          title: L10n.t("settings.campusNow"),
                          // R36.2: the "Mensa-Bereich" + "Bibliothek-Bereich"
                          // rows collapsed into this one - same seat, one
                          // gate for the merged campus-now strip
                          onTap: () => settingsVM.showCampusNow
                              .set(!settingsVM.showCampusNow.value),
                          trailing: CupertinoSwitch(
                              value: settingsVM.showCampusNow.value,
                              onChanged: settingsVM.showCampusNow.set)),
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

                BlockContainer(
                  // R32 audit: the agenda band (and with it its "older
                  // changes" footer) is invisible on any day the feed saw
                  // no deltas - the stored history needs its own door.
                  child: Semantics(
                    button: true,
                    label: L10n.t("timetable.chronicleTitle"),
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () async {
                        final stored = await SharedPreferencesAsync()
                            .getString(WebcalKeys.changes);
                        if (!context.mounted) return;
                        await Navigator.of(context).push(MaterialPageRoute(
                            builder: (BuildContext context) => ChroniclePage(
                                changes: IcsChange.decode(stored ?? ""))));
                      },
                      child: ConstrainedBox(
                        // >= 48 dp tap target (same card idiom as file cache)
                        constraints: const BoxConstraints(minHeight: 48),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Expanded(
                                child: Text(
                                    L10n.t("timetable.chronicleTitle"))),
                            Icon(CupertinoIcons.chevron_forward,
                                size: 14,
                                color: Theme.of(context).colorScheme.primary),
                          ],
                        ),
                      ),
                    ),
                  ),
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

                // R29 (X1): support bundle - the paste that makes a dead
                // feed debuggable from the outside. In release builds the
                // Debug card above is compiled out, so this is the only
                // diagnostics exit; shares plain text through the OS sheet.
                SettingsSectionTitle(title: L10n.t("settings.sectionSupport")),
                BlockContainer(
                  child: Semantics(
                    button: true,
                    label: L10n.t("settings.shareBundle"),
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () async {
                        final bundle = await SupportState.buildBundle();
                        if (!mounted) return;
                        await SharePlus.instance
                            .share(ShareParams(text: bundle));
                      },
                      child: ConstrainedBox(
                        // >= 48 dp tap target
                        constraints: const BoxConstraints(minHeight: 48),
                        child: SettingRow(
                          title: L10n.t("settings.shareBundle"),
                          trailing: const Icon(CupertinoIcons.share),
                        ),
                      ),
                    ),
                  ),
                ),

                // R36.1: FEED DOCTOR - the on-device view of the same
                // device state the bundle above carries away. When a
                // scraper goes dark (R32.4 class), the owner is TOLD
                // here; every row is a feedHealth verdict, so this
                // table and a pasted bundle can never disagree.
                SettingsSectionTitle(
                    title: L10n.t("settings.doctorSection")),
                const _FeedDoctorSection(),

                // R29 (X4): the two silent opt-ins - personal ICS and Anny
                // sign-in - used to have no visible state anywhere except
                // their own pages; a "why is my own calendar missing from
                // the agenda" now answers itself here. Read-only status:
                // the opt-in UI stays on the owning pages.
                SettingsSectionTitle(title: L10n.t("settings.sectionSetup")),
                BlockContainer(
                  child: Column(
                    children: [
                      SettingRow(
                        title: L10n.t("settings.setupPersonalIcs"),
                        trailing: Text(
                            cm.personalIcs.trim().isNotEmpty
                                ? L10n.t("settings.setupOn")
                                : L10n.t("settings.setupOff"),
                            style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: cm.personalIcs.trim().isNotEmpty
                                    ? scheme.tertiary
                                    : scheme.outline)),
                      ),
                      SettingRow(
                        title: L10n.t("settings.setupAnny"),
                        trailing: Text(
                            vm.anny.signedIn
                                ? L10n.t("settings.setupOn")
                                : L10n.t("settings.setupOff"),
                            style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: vm.anny.signedIn
                                    ? scheme.tertiary
                                    : scheme.outline)),
                      ),
                      SettingRow(
                        // R34.1: deadlines no scraper can know - own
                        // screen, own DATA_* key, honest provenance
                        title: L10n.t("settings.setupFristenbuch"),
                        trailing: Icon(CupertinoIcons.chevron_forward,
                            size: 14, color: scheme.primary),
                        onTap: () => Navigator.of(context).push(
                            MaterialPageRoute(
                                builder: (_) =>
                                    FristenbuchPage(manager: cm))),
                      ),
                    ],
                  ),
                ),

                // R34.6 + R34.2 + R34.3: the paperwork area. Deadlines the
                // app cannot scrape (document expiry), the editorial
                // starter list, and the portal launcher. Advisory through
                // and through: nothing in here arms an alarm, and every
                // card hides itself when its data does not exist.
                SettingsSectionTitle(
                    title: L10n.t("settings.sectionBureaucracy")),

                BlockContainer(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(L10n.t("settings.docsTitle"),
                          style: const TextStyle(
                              fontSize: 15, fontWeight: FontWeight.w600)),
                      const SizedBox(height: 2),
                      Text(L10n.t("settings.docsIntro"),
                          style: TextStyle(
                              fontSize: 12.5,
                              color: scheme.onSurfaceVariant)),
                      const _DocWatchSection(),
                    ],
                  ),
                ),

                // the launcher is only relevant once a profile exists:
                // no login -> no Matrikel to copy -> the whole card is
                // hidden (Student.empty carries the empty string)
                if (vm.student.matriculationNumber.trim().isNotEmpty)
                  BlockContainer(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(L10n.t("settings.papierkramTitle"),
                            style: const TextStyle(
                                fontSize: 15, fontWeight: FontWeight.w600)),
                        const SizedBox(height: 2),
                        Text(L10n.t("settings.papierkramIntro"),
                            style: TextStyle(
                                fontSize: 12.5,
                                color: scheme.onSurfaceVariant)),
                        const SizedBox(height: 4),
                        for (final portal in kPortalRows)
                          _PortalRow(
                              row: portal,
                              matriculation: vm.student.matriculationNumber),
                      ],
                    ),
                  ),

                BlockContainer(
                  child: const _StarterPackSection(),
                ),

                // R29 (X3): the storage story existed only in code
                // comments - here it is the user's. Every claim checked
                // against the manifest (allowBackup=false,
                // dataExtractionRules), the logout sweep (DATA_*) and the
                // secure-storage credentials; the crash tail is the one
                // survivor of logout precisely because it holds no
                // personal data (scrubbed before storage).
                SettingsSectionTitle(
                    title: L10n.t("settings.sectionStorage")),
                BlockContainer(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(L10n.t("settings.storageIntro"),
                          style: TextStyle(
                              fontSize: 12.5,
                              color: scheme.onSurfaceVariant)),
                      const SizedBox(height: 6),
                      for (final item in const [
                        "settings.storageCreds",
                        "settings.storageCache",
                        "settings.storagePrefs",
                        "settings.storageBundle",
                      ])
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 2),
                          child: Text("•  ${L10n.t(item)}",
                              style: TextStyle(
                                  fontSize: 12.5,
                                  color: scheme.onSurfaceVariant)),
                        ),
                      const SizedBox(height: 6),
                      Text(L10n.t("settings.storageOutro"),
                          style: TextStyle(
                              fontSize: 11, color: scheme.outline)),
                    ],
                  ),
                ),

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
    _events =
        RegExp("BEGIN:VEVENT", dotAll: true).allMatches(cm.personalIcs).length;
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

/// R36.1 FEED DOCTOR: renders [feedHealth] verdicts, nothing else.
///
/// Every row on screen is a [FeedStatus] produced by the pure function
/// in lib/diagnostics/feed_health.dart — no verdict, age or color
/// decision lives in this widget beyond mapping [FeedState] to a color.
/// The "check now" action runs the exact refresh the home pull-down
/// uses (no bespoke per-source fetching) and re-reads the device state
/// once it finishes, so the table repaints on the stamps the cascade
/// actually wrote.
class _FeedDoctorSection extends StatefulWidget {
  const _FeedDoctorSection();

  @override
  State<_FeedDoctorSection> createState() => _FeedDoctorSectionState();
}

class _FeedDoctorSectionState extends State<_FeedDoctorSection> {
  List<FeedStatus>? _rows;

  /// covers the first load AND an in-flight "check now" alike
  bool _busy = true;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  /// Live permission probe of the SAME plugin call
  /// MeiNotifications.init() uses for the bundle's notificationsPermission
  /// field: after the user returns from the system page, init() is
  /// already _ready and would never re-probe, so the row would keep
  /// showing the pre-visit verdict for the whole session. A plugin
  /// that cannot answer (iOS, tests) falls back to the bundle source.
  Future<bool> _notificationsPermission() async {
    try {
      final can = await FlutterLocalNotificationsPlugin()
          .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>()
          ?.canScheduleExactNotifications();
      if (can != null) return can;
    } on Object catch (_) {}
    return MeiNotifications.canScheduleExact;
  }

  Future<void> _load() async {
    final credsVM =
        Provider.of<CredentialsProvider>(context, listen: false);
    final rows = await SupportState.feedStatuses(
        credentialsStored: credsVM.credentials.valid,
        notificationsPermission: await _notificationsPermission());
    if (!mounted) return;
    setState(() {
      _rows = rows;
      _busy = false;
    });
  }

  /// The pull-down's own cascade (KITProvider.forceRefetchEverything),
  /// error toast exactly like home's onRefresh idiom; the table reloads
  /// afterwards because the cascade's notifyListeners have moved the
  /// very stamps the rows read.
  void _checkNow() {
    if (_busy) return;
    final vm = Provider.of<KITProvider>(context, listen: false);
    final toastsProvider =
        Provider.of<ToastsProvider>(context, listen: false);
    setState(() => _busy = true);
    unawaited(vm.forceRefetchEverything().catchError((e) {
      if (mounted) {
        toastsProvider.showTextToast(L10n.t("common.refreshFailed"));
      }
    }).whenComplete(() {
      if (!mounted) return;
      unawaited(_load());
    }));
  }

  /// The existing permission channel, reused: the exact-alarm settings
  /// intent behind MeiNotifications' R23 prompt (no new MethodChannel,
  /// no new notification channel).
  Future<void> _openAlarmSettings() async {
    try {
      await FlutterLocalNotificationsPlugin()
          .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>()
          ?.requestExactAlarmsPermission();
    } on Object catch (_) {}
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final rows = _rows;
    return BlockContainer(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SettingRow(
            title: L10n.t(
                _busy ? "settings.doctorChecking" : "settings.doctorCheckNow"),
            onTap: _checkNow,
            trailing: Icon(CupertinoIcons.arrow_clockwise,
                color: scheme.outline, size: 18),
          ),
          Text(
            L10n.t("settings.doctorHint"),
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: scheme.outline),
          ),
          // the rows appear only once the device state has actually
          // been read: a row list that flashes "all unknown" for one
          // frame would be noise, not honesty
          for (final s in rows ?? const <FeedStatus>[])
            _doctorRow(context, s),
        ],
      ),
    );
  }

  Widget _doctorRow(BuildContext context, FeedStatus s) {
    final scheme = Theme.of(context).colorScheme;
    final stateWord = L10n.t(switch (s.state) {
      FeedState.ok => "doctor.stateOk",
      FeedState.degraded => "doctor.stateDegraded",
      FeedState.dead => "doctor.stateDead",
      FeedState.unknown => "doctor.stateUnknown",
    });
    final color = switch (s.state) {
      FeedState.ok => scheme.tertiary,
      FeedState.degraded => Colors.orange.shade700,
      FeedState.dead => scheme.error,
      FeedState.unknown => scheme.outline,
    };
    // detail text = l10n template + the ALREADY-scrubbed argument from
    // feedHealth; a raw stored value must never reach the screen here
    final detail = s.detailKey == null
        ? null
        : (s.detailArg == null
            ? L10n.t(s.detailKey!)
            : L10n.t(s.detailKey!, [s.detailArg!]));
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SettingRow(
            title: L10n.t(s.labelKey),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 10,
                  height: 10,
                  decoration:
                      BoxDecoration(color: color, shape: BoxShape.circle),
                ),
                const SizedBox(width: 8),
                Text(stateWord,
                    style: Theme.of(context)
                        .textTheme
                        .bodySmall
                        ?.copyWith(
                            color: color, fontWeight: FontWeight.w600)),
              ],
            ),
          ),
          if (detail != null)
            Text(
              detail,
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: scheme.outline),
            ),
          // actionable only where action exists: the system page for a
          // denied grant; unknown/never-loaded rows have nothing to
          // open and honestly say nothing
          if (s.source == "notifications" &&
              s.state == FeedState.degraded)
            Align(
              alignment: Alignment.centerLeft,
              child: CupertinoButton(
                padding: const EdgeInsets.symmetric(
                    horizontal: 4, vertical: 14),
                onPressed: _openAlarmSettings,
                child: Text(L10n.t("doctor.openSystemSettings"),
                    style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: scheme.primary)),
              ),
            ),
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

/// R34.6 — "Dokumente" card body: the user's self-noted expiry dates with
/// the 90/30/7 advisory tiers. Add + delete only — editing a note means
/// delete + re-add, which is fewer states to build and to reason about.
/// The whole section NEVER schedules a reminder (auto-alarm VETOED): a
/// card that colours a date is honest, a ping from a keychain read that
/// failed once is not. Entries live in the keychain (DOC_* keys) and die
/// with logout via `DocWatchStore.purgeAll`.
class _DocWatchSection extends StatefulWidget {
  const _DocWatchSection();

  @override
  State<_DocWatchSection> createState() => _DocWatchSectionState();
}

class _DocWatchSectionState extends State<_DocWatchSection> {
  final _store = DocWatchStore();
  List<DocEntry>? _docs; // null while loading
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    try {
      final docs = await _store.load();
      if (!mounted) return;
      setState(() {
        _docs = docs;
        _failed = false;
      });
    } on Object catch (_) {
      // a locked/unreadable keychain must not crash the settings page
      if (!mounted) return;
      setState(() => _failed = true);
    }
  }

  String _date(DateTime d) => "${d.day.toString().padLeft(2, "0")}."
      "${d.month.toString().padLeft(2, "0")}."
      "${d.year}";

  /// Tier line + colour; `null` tier = further out than 90 days = plain
  /// expiry stamp, no warning colour ("ok" never shouts).
  (String, Color)? _tier(DocEntry e, ColorScheme scheme) {
    final now = DateTime.now();
    final days = docDaysLeft(e.expiry, now);
    switch (docTierFor(e.expiry, now)) {
      case DocTier.none:
        return null;
      case DocTier.expired:
        return (L10n.t("settings.docsExpiredFor", [-days]), scheme.error);
      case DocTier.seven:
        if (days == 0) {
          return (L10n.t("settings.docsDueToday"), scheme.error);
        }
        if (days == 1) {
          return (L10n.t("settings.docsDueTomorrow"), scheme.error);
        }
        return (L10n.t("settings.docsExpiresIn", [days]), scheme.error);
      case DocTier.thirty:
      case DocTier.ninety:
        return (L10n.t("settings.docsExpiresIn", [days]), scheme.tertiary);
    }
  }

  Future<void> _addDoc() async {
    final labelCtrl = TextEditingController();
    DateTime? picked;
    final saved = await showDialog<bool>(
        context: context,
        builder: (dialogCtx) => StatefulBuilder(
              builder: (dialogCtx, setDialogState) => AlertDialog(
                title: Text(L10n.t("settings.docsAddTitle")),
                content: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    TextField(
                      controller: labelCtrl,
                      textInputAction: TextInputAction.done,
                      decoration: InputDecoration(
                        isDense: true,
                        hintText: L10n.t("settings.docsLabelHint"),
                        labelText: L10n.t("settings.docsExpiry"),
                        labelStyle: TextStyle(fontSize: 11),
                      ),
                    ),
                    const SizedBox(height: 10),
                    OutlinedButton(
                      onPressed: () async {
                        final now = DateTime.now();
                        final date = await showDatePicker(
                            context: dialogCtx,
                            initialDate:
                                DateTime(now.year, now.month, now.day + 180),
                            firstDate: DateTime(now.year - 1),
                            lastDate: DateTime(now.year + 15));
                        if (date != null) {
                          setDialogState(() => picked = date);
                        }
                      },
                      child: Text(picked == null
                          ? L10n.t("settings.docsPickDate")
                          : _date(picked!)),
                    ),
                  ],
                ),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.of(dialogCtx).pop(false),
                      child: Text(L10n.t("settings.cancel"))),
                  FilledButton(
                      onPressed: () => Navigator.of(dialogCtx).pop(true),
                      child: Text(L10n.t("settings.docsSave"))),
                ],
              ),
            ));
    final label = labelCtrl.text.trim();
    labelCtrl.dispose(); // read before disposing, kept dead on exit
    if (saved != true || !mounted) return;
    final toasts = context.read<ToastsProvider>();
    if (label.isEmpty) {
      toasts.showTextToast(L10n.t("settings.docsNeedLabel"));
      return;
    }
    if (picked == null) {
      toasts.showTextToast(L10n.t("settings.docsNeedDate"));
      return;
    }
    try {
      await _store.add(label, picked!);
      if (!mounted) return;
      toasts.showTextToast(L10n.t("settings.docsSaved"));
    } on Object catch (_) {
      if (!mounted) return;
      toasts.showTextToast(L10n.t("settings.docsLoadFailed"));
    }
    await _reload();
  }

  Future<void> _remove(DocEntry e) async {
    final toasts = context.read<ToastsProvider>();
    try {
      await _store.remove(e.id);
    } on Object catch (_) {
      // the key may already be gone (purged/evicted); the reload below
      // shows the truth either way
    }
    await _reload();
    if (!mounted) return;
    toasts.showTextToast(L10n.t("settings.docsDeleted"));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (_failed) {
      return Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Text(L10n.t("settings.docsLoadFailed"),
            style: TextStyle(fontSize: 12.5, color: scheme.error)),
      );
    }
    final docs = _docs;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (docs == null)
          const Padding(
              padding: EdgeInsets.only(top: 8), child: KITProgressIndicator())
        else if (docs.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(L10n.t("settings.docsEmpty"),
                style: TextStyle(fontSize: 12.5, color: scheme.outline)),
          )
        else
          for (final e in docs)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Flexible + ellipsis: German labels wrap the card
                        // otherwise (R16e row rule)
                        Text(e.label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontSize: 14, fontWeight: FontWeight.w600)),
                        Text(
                          _tier(e, scheme) == null
                              ? L10n.t("settings.docsExpiresOn", [_date(e.expiry)])
                              : "${_date(e.expiry)} · ${_tier(e, scheme)!.$1}",
                          style: TextStyle(
                              fontSize: 12,
                              color: _tier(e, scheme)?.$2 ?? scheme.outline),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: L10n.t("settings.docsDelete"),
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(CupertinoIcons.trash, size: 16),
                    onPressed: () => _remove(e),
                  ),
                ],
              ),
            ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
              onPressed: _addDoc,
              icon: const Icon(CupertinoIcons.plus, size: 16),
              label: Text(L10n.t("settings.docsAdd"))),
        ),
      ],
    );
  }
}

/// R34.3 — one launcher row: EN label + the German official jargon under it
/// (the pairing IS the service — that is what letters and portals call it).
/// Tap launches the official page in the browser; the copy button puts the
/// live profile's Matrikelnummer on the clipboard. The app certifies
/// nothing about the target page and never scrapes it here.
class _PortalRow extends StatelessWidget {
  final PortalRow row;
  final String matriculation;

  const _PortalRow({required this.row, required this.matriculation});

  /// Mirror of agenda_page's private `_launchExternal` (exams_page and the
  /// signmeup card carry the same-named twins): only a well-formed http(s)
  /// URL reaches the launcher, and a missing browser never throws in a tap.
  void _launchExternal(String raw) {
    try {
      final uri = Uri.parse(raw);
      if (uri.host.isEmpty ||
          (uri.scheme != "http" && uri.scheme != "https")) {
        return;
      }
      launchUrl(uri, mode: LaunchMode.externalApplication)
          .catchError((_) => false);
    } on Object catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Semantics(
        button: true,
        label: row.en,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => _launchExternal(row.url),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(row.en,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 14, fontWeight: FontWeight.w600)),
                    Text(row.de,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style:
                            TextStyle(fontSize: 12, color: scheme.outline)),
                  ],
                ),
              ),
              // the copy mini-action lives INSIDE the row; as a real
              // button it wins its own hit-test, the row launch never
              // swallows it (SettingRow's opaque-behind-control rule)
              IconButton(
                tooltip: L10n.t("settings.copyMatr"),
                visualDensity: VisualDensity.compact,
                icon: const Icon(CupertinoIcons.doc_on_doc, size: 16),
                onPressed: () async {
                  await Clipboard.setData(
                      ClipboardData(text: matriculation));
                  if (context.mounted) {
                    context
                        .read<ToastsProvider>()
                        .showTextToast(L10n.t("settings.matrCopied"));
                  }
                },
              ),
              Icon(CupertinoIcons.chevron_forward,
                  size: 14, color: scheme.primary),
            ],
          ),
        ),
      ),
    );
  }
}

/// R34.2 — editorial starter pack: official pages for the first months,
/// every row carrying its `stand:` verification stamp. The future is built
/// once: an inline FutureBuilder re-parsed the asset on every unrelated
/// rebuild (the _CacheSizeText lesson).
class _StarterPackSection extends StatefulWidget {
  const _StarterPackSection();

  @override
  State<_StarterPackSection> createState() => _StarterPackSectionState();
}

class _StarterPackSectionState extends State<_StarterPackSection> {
  late final Future<StarterPack> _future;

  @override
  void initState() {
    super.initState();
    _future = StarterPack.load();
  }

  void _launchExternal(String raw) {
    try {
      final uri = Uri.parse(raw);
      if (uri.host.isEmpty ||
          (uri.scheme != "http" && uri.scheme != "https")) {
        return;
      }
      launchUrl(uri, mode: LaunchMode.externalApplication)
          .catchError((_) => false);
    } on Object catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return FutureBuilder<StarterPack>(
        future: _future,
        builder: (context, snap) {
          if (snap.hasError) {
            // missing asset / bad JSON: say it, never render a half-truth
            return Text(L10n.t("settings.docsLoadFailed"),
                style: TextStyle(fontSize: 12.5, color: scheme.error));
          }
          final pack = snap.data;
          if (pack == null) {
            return const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: KITProgressIndicator());
          }
          final english = L10n.isEnglish;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(L10n.t("settings.starterTitle"),
                  style: const TextStyle(
                      fontSize: 15, fontWeight: FontWeight.w600)),
              const SizedBox(height: 2),
              Text(L10n.t("settings.starterIntro"),
                  style: TextStyle(
                      fontSize: 12.5, color: scheme.onSurfaceVariant)),
              for (final row in pack.rows)
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Semantics(
                    button: true,
                    label: row.title(english: english),
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => _launchExternal(row.url),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(row.title(english: english),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                        fontSize: 14,
                                        fontWeight: FontWeight.w600)),
                              ),
                              Icon(CupertinoIcons.chevron_forward,
                                  size: 14, color: scheme.primary),
                            ],
                          ),
                          Text(row.text(english: english),
                              style: TextStyle(
                                  fontSize: 12.5,
                                  color: scheme.onSurfaceVariant)),
                          Text(
                              L10n.t("settings.starterStand", [row.stand]),
                              style: TextStyle(
                                  fontSize: 11, color: scheme.outline)),
                        ],
                      ),
                    ),
                  ),
                ),
              const SizedBox(height: 6),
            ],
          );
        });
  }
}
