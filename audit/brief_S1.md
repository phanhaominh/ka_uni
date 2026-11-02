# Slice S1 — BAgenda (schedule & exam domain)
Wave B UI polish. Build 0.7.0+40 is on the device; suite green; wave-A fixes are LIVE.

## OWNED FILES (edit ONLY these; touch nothing else)
- lib/agenda/views/agenda_page.dart
- lib/exams/views/exams_page.dart
- lib/signmeup/signmeup_mine_card.dart
- lib/timetable/models/webcal.dart
- lib/l10n/l10n.dart   (YOU are the sole l10n.dart owner this wave — de AND en maps + formatter helpers)
- lib/l10n/strings_exams.dart

If a fix genuinely needs a file outside this set, STOP and message `Main` with the exact hunk; do NOT edit it.

## Rules (wave-A lessons)
- VERIFY every claim against CURRENT code before editing — several audit claims are stale; if already satisfied, do nothing and say so. Never re-pin behavior that is already correct.
- webcal.dart DEDUP KEY IS FROZEN: series key stays `title|series-DTSTART` + longest-seriesEnd-wins. Do NOT add room/UID to any series key (wave-A C74 revert; fixture test/webcal_test.dart 'clone series' will fail if you break it). Occurrence-level dedupeKey (uid|start|seriesEnd) also stays.
- Keep-list (do not regress): agenda room lines tinted+tappable+carry distance anchor; "As of HH:MM" freshness footer (and red stale variant); exams sectioning (Act now → opens later → other → catalogue) with padded "Register by: 07.02.2027 23:59"; SignMeUp/ILIAS cards already ellipsize with "…".

## Items
1. **#15 Card CTAs (agenda side)** — the red danger exam card "Register" and the "SignMeUp registrations" button are bare unstyled text. Make both **FilledButton.tonal** (or FilledButton for the danger card) with a clear label. The redundant "SignMeUp registrations" button that just repeats the card title → relabel to an action ("Open in SignMeUp" — add agenda key). In signmeup_mine_card.dart, each "My registrations" row (shows pending/rank N) has no tap handler: give it an onTap that launches that procedure's SignMeUp URL via the existing url_launcher error-handled helper used in agenda_page (_launchExternal). If a row has no launchable URL, make it non-interactive (no dead affordance).

2. **#17 own-calendar source chip** — a feed lecture and its duplicate from the student's OWN imported ICS render as unlabeled adjacent rows. Add a small chip "eigener Kalender"/"own calendar" on occurrences originating from the personal ICS. Implementation: IcsOccurrence needs a source flag. In webcal.dart, set it when parsing VEVENT blocks that carry the personal-ICS sentinel (find how personal ICS is marked — `X-` property or the UID range that stripPersonalIcs keys on; reuse that discriminator, do NOT invent a second one). Wire flag: parse → occurrence → agenda room-line renders the chip. Add de+en agenda string.

3. **#12 date rendering** — three inconsistent renderings of the same deadline. Centralize: (a) `L10n.stamp(d)` must DROP the " HH:mm" tail when hour==0 && minute==0 (so a date-only event shows "Sun, 25.10." not "Sun, 25.10. 00:00"). (b) Keep `until()`/`stamp()` as the ONLY date formatters; do not introduce a parallel one. Confirm the exams-page "Register by:" path and the agenda red card both route through these (they live in your files). Grep for any local date re-implementation in your owned files and funnel it into L10n.

4. **#13 walk EN (VERIFY)** — agenda.walkOk/walkTight: check they exist in BOTH _de and _en (I believe they already do — lines ~190/~292). If both present, NO change; report "already satisfied". (The SOP-label half of #13 is a different slice — ignore it.)

5. **Cosmetic (only if the site is trivially in your way; else skip and say so):**
   - C21: agenda_page build children — hoist repeated expressions to locals once.
   - C22: pause the agenda ticker while the route isn't visible; pass the single build-level `now` into _staleFooter.
   - C26: agenda_page.dart:~946 — wrap the GestureDetector child in `Semantics(button: true, label: shown)`.
   - C27: render the feed tail spinner only while the cache hasn't proven itself (reuse `_feedCached`).
   - C38: exams_page.dart:~33 — build a Set<ExamEntry> from the catalogue once and precompute isTakingThisSemester into a map before the filters (only if it's a clean win).

## Report
Return per item: VERIFIED-STALE / FIXED(hunk) / SKIPPED(reason). New l10n keys you added (de+en) listed at the end. Do NOT run build/test (Main does integrated verify). Message `Main` with anything needing an out-of-slice file.
