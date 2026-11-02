# Slice S3 — BSettings
Wave B UI polish. Build 0.7.0+40; wave-A settings fixes (C86/C87/R103/R104, logout teardown) are LIVE — don't undo them.

## OWNED FILES (edit ONLY these)
- lib/settings/views/settings_page.dart
- lib/l10n/strings_settings.dart

Do NOT edit l10n.dart (S1 owns it) — new strings go in strings_settings.dart. Wave-A added `SettingRow.onTap` (whole-row tap) and kDebugMode gating — build on those, don't regress.

## Rules
- VERIFY each claim against current code; wave-A R103 already made trailing-action rows tap-wide — don't redo it, extend only where genuinely still dead.
- Keep-list: Debug section stays gated behind kDebugMode (release hides it — confirmed on device). Language menu uses native names and re-renders instantly (correct — leave it).

## Items
1. **#8 dead tap targets** (settings_page.dart): the Debug card responds ONLY to the trailing chevron; the cache card only to the small "Manage" text. Wrap BOTH full card bodies in an InkWell/onTap launching the same action the small control does (≥48dp target), keep the chevron/"Manage" as visual decoration. Confirm via a quick widget test that a tap at the card's left edge fires. (The Debug card is behind kDebugMode — still fix its hit area for when it shows.)

2. **#9 Log out destructive styling + confirm**: "Log out" is plain teal centered text that instantly starts a ~10s full wipe. Style it as an outlined **red** button (OutlinedButton with error color) and gate the actual `logout()` behind a `CupertinoAlertDialog` confirmation (title + body: says all local data is wiped; Cancel / Log out in red). Reuse the confirm-dialog pattern already used for file deletion (grep for it in local_files_storage). Add de+en keys.

3. **#10 dropdown selected-state**: Language/Theme/ILIAS-start dropdowns open with no check on the active value (the menu covers the row showing it). Add a **leading check icon** (Icons.check) to the currently selected item in the popup menu items. This is in the dropdown builder(s) in settings_page.dart (the MultipleChoice/Language dropdowns ~486/~522).

## Report
Per item VERIFIED-STALE / FIXED(hunk) / SKIPPED. New strings_settings.dart keys (de+en) listed. Do NOT build/test.
