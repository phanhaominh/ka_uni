# FixGrades fix brief
Owned files: lib/grades/, lib/module/, lib/module_info_table/

C34/C35 are the worst in the app (graded modules mis-shown, passed modules vanish from ledger) — read verifier evidence fully before touching; likely in grades ledger build from schedule/module merge. C31b: module_info_table_sensible.dart retry chain — add catchError per verifier.



## Assigned verdicts (FULL verifier detail — authoritative)
- **C31** [REAL/low] campus_manager.dart:1177-1182: `fetchModule(row, userInitiated: true).then((_) => fetchTimetable());` fire-and-forget with no catchError, while guardedCasGet has no try/catch (kit_login_manager.dart:1
  → FIX: Add `.catchError` to the chain at campus_manager.dart:1179 (log + notificationCallback to force a rebuild), and either await or catchError the fetchAllModules() at module_info_table_sensible.dart:139.
- **C33** [REAL/low] module.dart:14 `DateTime examDate = DateTime.now();` is only replaced when the scraped string splits into exactly 3 ints (:89-100); examDateKnown (:134-136) is `examDateStr != "unbekannt"` on the UNTR
  → FIX: Set examDateKnown from the PARSE result at module.dart:98 (e.g. `examDateParsed = dateSplitInt.length == 3`) and base the getter on that flag instead of the literal string comparison at :134-136; trim examDateStr at :54.
- **C34** [REAL/med] hierarchic_table_row.dart:78-81: if the raw grade cell (innerHtml) contains a comma, the grade is cut to the 3 chars around the LAST comma — substring(commaIndex-1, commaIndex+2). A spaced decimal '1 
  → FIX: Replace the fixed-width window at hierarchic_table_row.dart:78-81 with a decimal-probe on the whitespace/entity-stripped text (match `\d{1,3}[,.]\d{1,2}` first, fall back to cleaned full text), so spaced and prose grade cells keep their meaning.
- **C35** [REAL/med] grade_book.dart:48-63 dedups by exact titleKey (seenAt map), titleKey = CampusManager.lectureTitleKey (:159), and lectureTitleKey (campus_manager.dart:1558-1563) truncates at the FIRST ', ' whenever i
  → FIX: At campus_manager.dart:1560-1563 only drop a trailing ', <lecturer>' when the suffix does not look like a module qualifier, or key on titleKey+level+moduleEcts and merge (or refuse to drop) same-key rows whose ECTS differ at grade_book.dart:52-63.
- **C36** [REAL/low] grades_page.dart:20 `static final _sopDeadline = DateTime(2027, 3, 31);` with no settings override; _sopCard (:78-79) turns every not-yet-30-CP student red ('sopOverdue', scheme.error) from 2027-04-01
  → FIX: Derive the deadline from user data (e.g. admission date from the Studienverlauf degree row + 3 semesters) or expose it as a setting; at minimum fall back to hiding the overdue tint when the admission cohort postdates the constant.
- **C43** [REAL/med] module_info_table.dart:100-112: containers are parsed individually and parseFromHtml may return null (:102 skips it), but captions are attached ONLY `if (tables.length == captions.length)` — one skipp
  → FIX: Pair captions to containers structurally at module_info_table.dart:98-112 — iterate .table-container nodes and take each container's own (or immediately preceding) .table-caption element, assigning per-table regardless of how many containers fail to parse.
- **C45** [REAL/med] Confirmed: `grep -rn sqassign lib/` hits NOTHING — the only cascampus exam URL fetched is `view=possibleexams` (campus_manager.dart:2025-2026); 'sqassign' exists only in RUNBOOK.md:19 ('Prüfungsanmeld
  → FIX: Either fetch and parse view=sqassign in _fetchExamsInner (campus_manager.dart:2025) alongside possibleexams and concat the parsed entries, or amend RUNBOOK.md:19 to document possibleexams-only coverage.
- **C46** [REAL/low] campus_manager.dart:2029-2034: success gate `parsed.isNotEmpty || response.body.contains("EXAMLIST")` accepts ANY body containing the id string 'EXAMLIST' — the parser needs ≥7 tds AND examNumber matc
  → FIX: At campus_manager.dart:2031 tighten the gate: treat as broken when the body contains id="EXAMLIST" with <tr> rows but ExamListParser produced zero entries (pass a row-count/shape hint out of parse).
