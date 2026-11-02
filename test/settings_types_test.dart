import 'package:flutter_test/flutter_test.dart';
import 'package:kit_mobile/settings/types/multiple_choice_setting.dart';
import 'package:kit_mobile/settings/types/setting.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Settings store prepare/set semantics: a fresh install must not fire
/// every setting's callback, while a restored non-default value still must
/// (the first frame renders defaults).
void main() {
  test("first run persists the default without notifying", () async {
    SharedPreferences.setMockInitialValues({});
    var notified = 0;
    final setting = Setting<bool>(
        valueKey: "PREF_testBool",
        defaultValue: false,
        notifyCallback: () => notified++);

    await setting.prepare();

    expect(setting.value, false);
    expect(notified, 0); // no spurious rebuild burst on a fresh install
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool("PREF_testBool"), false); // default was persisted
  });

  test("a restored non-default value still notifies", () async {
    SharedPreferences.setMockInitialValues({"PREF_themeMode": "dark"});
    var notified = 0;
    final setting = Setting<String>(
        valueKey: "PREF_themeMode",
        defaultValue: "system",
        notifyCallback: () => notified++);

    await setting.prepare();

    expect(setting.value, "dark");
    expect(notified, 1);
  });

  test("a stored valid choice is kept untouched", () async {
    SharedPreferences.setMockInitialValues(
        {"PREF_defaultIliasPage": "Meine Kurse & Gruppen"});
    var notified = 0;
    final setting = MultipleChoiceSetting<String>(
        valueKey: "PREF_defaultIliasPage",
        choices: ["Dashboard", "Meine Kurse & Gruppen"],
        notifyCallback: () => notified++);

    await setting.prepare();

    expect(setting.value, "Meine Kurse & Gruppen");
    expect(notified, 1); // restored != default: exactly one notify
  });
}
