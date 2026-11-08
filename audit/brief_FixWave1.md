# Lane BRIEFS — KA.Uni fix wave (repo /home/phan/ka_uni, Flutter)

Shared rules for ALL lanes:
- Flutter SDK: /home/phan/dev/flutter/bin/flutter. FVM not used.
- NEVER run `flutter test` (full suite) — parallel lanes; the parent runs the suite after all lanes land. `flutter analyze --no-pub` is allowed ONLY at the very end of your lane.
- Do NOT run any adb/device commands. Do NOT git commit. Do NOT touch files outside your ownership list.
- German is the default locale; L10n.t(key[,args]) with maps in lib/l10n/strings_*.dart (de) + l10n.dart core (en pairs live beside de in same map files — inspect one to learn the pattern: each string map entry has both languages).
- Match existing code style; keep comments terse, explain WHY not WHAT.
- If a finding is already fixed in current code, skip it and say so in your report.
- Report format: bullet per finding: fixed/skipped(+why), files touched.
