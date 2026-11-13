import 'package:flutter/cupertino.dart';
import 'package:kit_mobile/l10n/l10n.dart';
import 'package:kit_mobile/settings/types/multiple_choice_setting.dart';

import '../types/bool_setting.dart';
import '../types/setting.dart';

// R35.3: PREF_showingProfile and PREF_showingAvgMark were deleted WITH
// their reads and writes (profile block demoted to the grades page).
// The orphan keys in existing prefs are inert residue: like the deleted
// liquidAssEverywhere (R16e) they are never read again - no purge shim.
const showingMensaKey = "PREF_showingMensa";
const showingLibraryKey = "PREF_showingLibrary";

/// R35.3 one-release revert switch (roadmap R35.1 "one-release revert
/// switch", parent integration contract #3): true restores the previous
/// HOME composition (profile block + full module tree). Read in exactly
/// ONE place - `_KITHomePageState.build`. Flip back on, ship the flip
/// for one release, then cut the switch and the legacy branches.
const legacyHomeKey = "PREF_legacyHome";
const defaultIliasPageKey = "PREF_defaultIliasPage";
// the language pref is read by L10n.reload() directly: one constant only,
// a private duplicate could silently drift from the key that has the effect
const languageKey = L10n.languagePrefKey;
const themeModeKey = "PREF_themeMode";

class SettingsProvider extends ChangeNotifier {
  /// Theme mode read synchronously from prefs in main() BEFORE runApp;
  /// seeds the [theme] setting so the first frame is already correct
  /// (restore-after-first-frame used to flash light→dark every launch).
  static String seedThemeMode = "system";
  static SettingsProvider? _instance;

  final BuildContext context;
  SettingsProvider({required this.context}) {
    _instance = this;
    prepare();
  }

  BoolSetting showMensa = BoolSetting(
      valueKey: showingMensaKey,
      defaultValue: true,
      notifyCallback: () => _instance?.notifyListeners());

  BoolSetting showLibrary = BoolSetting(
      valueKey: showingLibraryKey,
      defaultValue: true,
      notifyCallback: () => _instance?.notifyListeners());

  /// R35.3 revert switch; default FALSE = the new HOME=TODAY
  /// composition (no profile block, no module tree) ships.
  BoolSetting legacyHome = BoolSetting(
      valueKey: legacyHomeKey,
      defaultValue: false,
      notifyCallback: () => _instance?.notifyListeners());

  MultipleChoiceSetting<String> defaultIliasPage = MultipleChoiceSetting(
      valueKey: defaultIliasPageKey,
      choices: ["Dashboard", "Meine Kurse & Gruppen"],
      notifyCallback: () => _instance?.notifyListeners());

  /// App language; "system" follows the device locale.
  MultipleChoiceSetting<String> language = MultipleChoiceSetting(
    valueKey: languageKey,
    choices: ["system", "de", "en"],
    notifyCallback: () async {
      await L10n.reload();
      _instance?.notifyListeners();
    },
  );

  /// App theme; "system" follows the device light/dark setting.
  /// Seeded synchronously in main() from prefs (see [seedThemeMode]) so the
  /// FIRST MaterialApp frame already uses the stored mode instead of
  /// flashing the default before the async [prepare] restores it.
  MultipleChoiceSetting<String> theme = MultipleChoiceSetting<String>(
    valueKey: themeModeKey,
    choices: const ["system", "light", "dark"],
    defaultValue: seedThemeMode,
    notifyCallback: () => _instance?.notifyListeners(),
  );

  List<Setting> get settings => [
        legacyHome,
        showMensa,
        showLibrary,
        defaultIliasPage,
        language,
        theme
      ];

  Future<void> prepare() async {
    await Future.wait(settings.map((el) => el.prepare()));
  }
}
