import 'package:flutter/cupertino.dart';
import 'package:kit_mobile/l10n/l10n.dart';
import 'package:kit_mobile/settings/types/multiple_choice_setting.dart';

import '../types/bool_setting.dart';
import '../types/setting.dart';

const showingAvgMarkKey = "PREF_showingAvgMark";
const showingProfileKey = "PREF_showingProfile";
const showingMensaKey = "PREF_showingMensa";
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

  BoolSetting showingAvgMark = BoolSetting(
      valueKey: showingAvgMarkKey,
      defaultValue: true,
      notifyCallback: () => _instance?.notifyListeners());

  BoolSetting showingProfile = BoolSetting(
      valueKey: showingProfileKey,
      defaultValue: true,
      notifyCallback: () => _instance?.notifyListeners());

  BoolSetting showMensa = BoolSetting(
      valueKey: showingMensaKey,
      defaultValue: true,
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
        showingAvgMark,
        showingProfile,
        showMensa,
        defaultIliasPage,
        language,
        theme
      ];

  Future<void> prepare() async {
    await Future.wait(settings.map((el) => el.prepare()));
  }
}
