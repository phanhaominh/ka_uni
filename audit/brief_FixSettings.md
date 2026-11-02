# FixSettings fix brief
Owned files: lib/settings/, lib/credentials/, lib/state_management/campus/campus_manager.dart:LOGOUT

C81b (logout side): logout sequence must cancelByUniqueName('mei-webcal-poll') + await in-flight poll before the prefs sweep (verifier prescribes ordering). C87/R104: wrap the Debug section (settings_page.dart ~164-191) in kDebugMode. R103+C88: make SettingRow card-wide tappable when a trailing action exists (InkWell/ GestureDetector wrapping row, preserve chevron). C86: logout chain — make steps individually try/caught so a mid-chain throw still completes the sweep; keep _loggingOut guard.



## Assigned verdicts (FULL verifier detail — authoritative)
- **C81** [REAL/med] mei_notifications.dart meiBackgroundCallback: writes DATA_webcalFeedSource (:377), DATA_webcalChanges (:385-389), DATA_webcalFingerprint (:394/:398) BEFORE the logged-out guard at :400-403, which only
  → FIX: In meiBackgroundCallback, fence ALL writes (feedSource/changes/fingerprint before :377 as well as :415-417) behind a fresh platform-level re-read of DATA_webcalUrl that bypasses the stale per-isolate cache (e.g. SharedPreferencesAsync / direct platform channel), aborting the task if empty; additionally have logout cancel the poll by unique name before the sweep and delay the sweep until the in-flight task returns.
- **C82** [REFUTED/none] Mechanism is described correctly (multiple_choice_setting.dart:17 `assert (choicesSet.contains(newValue));` stripped in release; setting.dart:24-31 prepare() only does `if (stored is T)`), but the tri
  → FIX: (derive from evidence)
- **C83** [COSMETIC/low] Anchors true: notesController allocated per dialog at timetable_edit_page.dart:246-248, `dispose` appears zero times in the file, notes TextField is commented out (:363-367) while notes still round-tr
  → FIX: Delete the dead notes surface (controller + commented TextField + notes args) or, if the UI is to return, dispose it after `await showDialog` (:465).
- **C85** [COSMETIC/low] Duplication confirmed: l10n.dart:24 `static const languagePrefKey = "PREF_language";` vs settings_provider.dart:13 `const languageKey = "PREF_language";`. Both are compile-time identical literals, the
  → FIX: Define the key once (e.g. l10n.dart) and reference it from settings_provider.dart:13.
- **C86** [REAL/low] Confirmed: credentials_provider.dart logout() wraps only the credential wipe in try/catch (:215-219); every later step is unguarded inside one try at the call site (settings_page.dart:204-222 → generi
  → FIX: Wrap each teardown step of logout() (credentials_provider.dart:220-259) in its own try/catch accumulating failures, always run the prefs sweep + cancelAllScheduled + file-cache purge, and rethrow at the end so the toast reflects partial failure.
- **C87** [REAL/low] settings_page.dart:164-191: `SettingsSectionTitle(title: "Debug")` + SettingRow "settings.debugFetch" pushing ModuleTreeDebugPage(:campusManager) with NO kDebugMode guard anywhere in the file's build 
  → FIX: Wrap settings_page.dart:164-191 (title + BlockContainer) in `if (kDebugMode)`, matching login_view.dart:73-75.
- **C88** [COSMETIC/low] Sub-claims judged individually. (1) _loadingSemesters vestigial: CONFIRMED — grep shows only declaration (:10), .clear in clearAll (:23), and .remove in _doLoadSemester (:124,:138); no .add anywhere; 
  → FIX: Delete _loadingSemesters (tutorial_manager.dart:10,:23,:124,:138); anchor the username regex to ^u[a-z]{4}$ and drop the tautological .input check (kit_credentials.dart:18-22); dedupe the language key constant.
- **R103** [REAL/?] Confirmed: SettingRow builds `Row(children: [Text(title), SizedBox(20), trailing])` — the title is inert Text (settings_page.dart:426-437), no InkWell/GestureDetector anywhere; interactivity exists on
  → FIX: Give SettingRow an optional `onTap` and, when set, wrap the whole Row in a CupertinoButton/InkWell (settings_page.dart:416-439 + :170-181), so title+hint+chevron all navigate.
- **R104** [REAL/?] Code mechanism for the device observation confirmed: the entire Debug section — SettingsSectionTitle("Debug") + BlockContainer + SettingRow('settings.debugFetch') pushing ModuleTreeDebugPage — is buil
  → FIX: Wrap settings_page.dart:164-191 in `if (kDebugMode) ...` (spread into the Column's children), matching the existing easter-egg gating pattern.
