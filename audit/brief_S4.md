# Slice S4 — BGrades + BFiles + module grade decode
Wave B UI polish. Build 0.7.0+40; wave-A grade ledger (C34/C35/C36) and file-viewer (C55) fixes are LIVE.

## OWNED FILES (edit ONLY these)
- lib/grades/views/grades_page.dart
- lib/l10n/strings_grades.dart
- lib/local_files_storage/views/pages/files_cache_page.dart
- lib/l10n/strings_files.dart
- lib/module/views/module_page.dart

Do NOT edit l10n.dart. All your new strings go in strings_grades.dart / strings_files.dart.

## Rules
- VERIFY each claim against current code first.
- Keep-list: grades SOP card (30-CP progress bar + deadline status) surfaces Orientierungsprüfung risk; zero-fail chip correctly stays grey (wave-A style).

## Items
1. **#13b SOP label** (grades_page.dart + strings_grades.dart): the SOP status shows `sopOpen` = de "noch offen" / en "still open" (calque reads as "not closed"). Change EN to "not yet met" (and consider phrasing that pairs with the CP goal). The SOP header `grades.sopTitle` = "Studienorientierungsprüfung" in BOTH maps — keep the official German name (it's a proper noun) but if the app has a convention, mirror an English gloss in parentheses ONLY on the EN side, e.g. "Studienorientierungsprüfung (orientation exam)". Do NOT change the German map's title.

2. **#16 zero-count green chip** (grades_page.dart ~144): failed/pending grey out at zero, but `passed` is hardcoded green, so a fresh student sees a confident green "0 passed". Grey the passed chip when count == 0, matching its siblings (non-zero passed stays green).

3. **#14 file-cache empty & silent** (files_cache_page.dart): (a) with zero cached files the list is a blank page — add a centered "No cached files — open ILIAS to sync"/DE empty-state message. (b) collapsed semester rows show no file count — add a trailing "{0} files" count. (c) when exactly one semester exists, auto-expand it. Add de+en keys to strings_files.dart.

4. **C42 module grade decode** (module_page.dart ~242-263 `_formatGrade`): it hand-strips a few HTML entities. Replace with package:html decoding (`html_parser.parseFragment(grade).text`) or a named-entity regex that passes a stray '&' through. Check whether package:html is already a dependency (it is — grep imports) and whether a test already pins _formatGrade (update it if so; don't re-pin wrong behavior).

## Report
Per item VERIFIED-STALE / FIXED(hunk) / SKIPPED. New strings keys (de+en) listed. Do NOT build/test.
