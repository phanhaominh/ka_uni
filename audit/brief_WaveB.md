# Wave B — UI polish + cosmetic register
Run AFTER wave A integrated & verified. Sources: GapUxPolish findings (18) + cosmetic verdicts (22).
Assign to owners matching wave-A slices (same files) + one new slice for unowned widgets (profile_view, common_ui).

## GapUxPolish findings
1. [affordance/M] ILIAS glass chips occlude and steal taps from the site itself — where: 30_ilias_dashboard.png / 30_band.png / 08_ilias.png — ilias_page_view.dart:359-407
   problem: Back chip (top:6,left:8) sits on the ILIAS HINWEIS banner text and the KIT logo; refresh chip covers the site's '…' overflow menu; the two bottom-right history chips float over the site's own bottom nav ('Lernerfolge' tab hidden and its taps intercepted — a real dead zone on every ILIAS page).
   fix: Move all four controls into one slim translucent toolbar row above/below the webview (or auto-fade the history chips after 2 s); also bump _glassChip from 40×40 to ≥44 with tooltips.
2. [visual/S] Event-detail map marker is a featureless red blob — where: 09_event_detail.png — timetable_appointment_page.dart:56-84
   problem: The marker is a 25 dp red circle with 7 px blur + 2 px spread shadow, rendered ~3× larger on the dense campus map; it covers the entire building footprint (7) and conveys no room/building label, so the map's only purpose — locating the room — is defeated.
   fix: Replace the circle with a standard map pin icon plus a small room-label chip (e.g. '10.91') anchored above it.
3. [visual/S] Expanded appointment sheet shows nothing but blur — where: 10_event_detail_expanded.png — timetable_appointment_page.dart:100-152
   problem: The sheet's ListView ends with a phantom SizedBox(height: 500) 'drag padding' and the sheet caps at maxChildSize 0.4; when expanded, the title/ID/Ort scroll off the top and the user sees an empty blurred panel with only a drag-handle dot. The title Text also has maxLines: 2 with no overflow: TextOverflow.ellipsis, so it hard-clips mid-word and the hero title ends with a dangling comma ('…Langhoff et al.,').
   fix: Delete the 500 px spacer (minChildSize already guarantees drag room), add overflow: ellipsis to the title, and put real content in the expanded state (address, campus link).
4. [visual/S] Timetable time badge overlaps the lecture title's first line — where: 00_launch.png / 16_carousel_next.png — timetable_daily_view.dart:99-212
   problem: The 'HH:MM' badge is a top-right Positioned in a Stack while the title Column spans the full card width, so long titles run under the badge and are visibly cut mid-word ('Langh' + badge); title Texts use maxLines: 2 with no TextOverflow.ellipsis.
   fix: Reserve the badge width via right padding on the title column (or put title+badge in one Row) and add overflow: TextOverflow.ellipsis.
5. [visual/S] Home carousel header collides with peeking weekday cards — where: 00_launch.png / 16_carousel_next.png — timetable_weekly_view.dart + home header
   problem: 'Today, November 2' / 'Heute' pill float over the adjacent pages' weekday header columns; at the carousel edges you get ghostly half-letters ('Tue' behind 'Tomorrow', orphan '1'), so it reads as a rendering glitch and the 'Heute' pill crowds the peek card.
   fix: Give the date heading its own fixed band above the carousel instead of overlaying it on the card viewport.
6. [info-design/S] Refresh spinner lands on content and is indistinguishable from other spinners — where: 14_profile_collapsed.png, 15_pull_refresh.png, 22_changed_new.png — home_page.dart:65 + RefreshIndicator
   problem: The pull-to-refresh disc settles centered over the profile card name row (14/15) or over the agenda 'Next up' banner (22_changed_new), occluding text; the same bare KITProgressIndicator is also the app-bar profileReady spinner and the modules-section spinner, so nothing tells the user what is loading.
   fix: Set RefreshIndicator displacement so the disc rests in the header gap (or push content down), and give at least the app-bar spinner a Semantics label / distinct inline placement.
7. [visual/S] Student name hard-clips instead of ellipsizing — where: 14_profile_collapsed.png — profile_view.dart:53
   problem: Headline name Text has no overflow policy, so 'HaoMinh Phan…' is sliced mid-glyph next to the spinner — looks broken even though it's just a long name.
   fix: Add overflow: TextOverflow.ellipsis (maxLines: 1) to the name Text.
8. [affordance/S] Settings cards with chevron-only / text-only tap targets — where: 07_settings_scrolled.png — settings_page.dart:154-181 (candidate R103, confirmed)
   problem: The Debug card responds only to the chevron CupertinoButton (padding: EdgeInsets.zero, ~24 dp wide) — the card title and body swallow taps; the cache card likewise only reacts to the small 'Manage' text, while other rows are full-width. Users tap the card body repeatedly with nothing happening.
   fix: Wrap both cards' full body in InkWell/onTap (keep the chevron as decoration) and give the tap target ≥48 dp.
9. [info-design/S] Log out looks like a navigation link, not a destructive wipe — where: 07_settings_scrolled.png — settings_page.dart:193-231
   problem: 'Log out' is plain teal centered text that immediately starts a multi-second full wipe — no destructive (red) styling and no confirm dialog, one mis-tap from a 10 s logout.
   fix: Style it as an outlined red button and add a CupertinoAlertDialog confirmation (pattern already used for file deletion).
10. [consistency/S] Dropdown menus give no selected-state feedback and cover neighbors — where: 19_lang_dialog.png / 20_appearance_dialog.png / 21_ilias_startpage.png — settings_page.dart:486,522
   problem: Language/Theme/ILIAS-start dropdowns open with no checkmark on the active option (only the dimmed row behind shows current value, which the menu then covers), so while open the user must remember which was selected; menus also overlay the adjacent rows making the UI feel broken.
   fix: Add a leading check icon to the selected item (or switch to a SegmentedButton/radio-style menu).
11. [consistency/S] Exam status chips: urgency barely visible, info chip looks actionable — where: 02_exams.png / 27_exams_scrolled.png — exams_page.dart:225 + strings_exams.dart:44-45
   problem: Urgent 'NOT registered' and benign 'not registered' are both thin-outline chips differing only by red-vs-grey tint on a dark card — easy to miss the one that matters; meanwhile the module-number chip '76-T-MACH-113510' renders as an identical outline pill, inviting taps that do nothing.
   fix: Fill the urgent chip (errorContainer background or warning icon) and render the exam-number as plain caption text (or make it copy-to-clipboard on tap).
12. [consistency/S] Three inconsistent date renderings across the exam workflow — where: 28_band.png vs 26_exam_register.png vs 23_agenda_bottom.png — l10n.dart:63-71
   problem: Agenda red card says 'until 7.2.2027' (L10n.until: unpadded), exams page says 'Register by: 07.02.2027 23:59' (padded, with time), ILIAS stamps print 'Sun, 25.10. 00:00' — time-less dates get a noise ' 00:00' tail and the same deadline is written three ways within two taps.
   fix: Centralize one padded date formatter in L10n and have L10n.stamp drop ' HH:mm' when hour/minute are both zero.
13. [consistency/S] Walk-hint row is German-only in the English UI; 'still open' SOP label is mistranslation-flavored — where: 01_agenda.png / 04_grades.png — l10n.dart:188-189, strings_grades.dart:36
   problem: agenda.walkOk/walkTight exist only in the _de map, so English users get 'Fußweg ca. 17 Min' inserted mid-English agenda; the SOP card shows 'still open' (calque of 'noch offen') which reads as 'not closed' rather than 'not yet achieved', next to an untranslated 'Studienorientierungsprüfung' header on an otherwise-English page.
   fix: Add EN strings ('Walk ~17 min', 'Only X min break – ~X min walk', 'not yet met (30 CP by …)') and mirror the official German name in parentheses.
14. [empty-state/S] File-cache page is a black void when empty and silent when collapsed — where: 18_cache_manage.png — files_cache_page.dart:42-58,196-200
   problem: With zero cached files the list renders nothing — a title bar over a black page with no 'no files yet' explanation (the only empty state in the app without one); collapsed semester rows show no file count and a single semester is not auto-expanded, so 'Manage' looks broken after logout/first run.
   fix: Add a 'No cached files — open ILIAS to sync' centered message and a trailing 'N files' count on collapsed rows (auto-expand when exactly one semester).
15. [affordance/M] Card CTAs are bare text links; SignMeUp rows are dead — where: 28_band.png / 26_exam_register.png — agenda_page.dart SignMeUp/red-exam cards, signmeup_mine_card.dart
   problem: 'Register' on the red danger card and the 'SignMeUp registrations' button (which merely repeats the card title) are unstyled text in a corner — weakest possible affordance on the two highest-stakes cards; 'My registrations' rows (with 'pending', 'rank 3') look like list items but have zero tap handlers anywhere, so there is no path from a registration to its detail page.
   fix: Use filled tonal buttons for both CTAs (label: 'Open in SignMeUp'), and make each 'My registrations' row launch the procedure URL.
16. [consistency/S] Zero-count '0 passed' chip glows green like an achievement — where: 04_grades.png — grades_page.dart:144
   problem: failed/pending chips grey out at zero (comment even says 'only real failures may shout red'), but passed is hardcoded green, so a fresh student sees three chips, one confidently green at zero — inconsistent with the app's own zero-grey rule.
   fix: Grey the passed chip when count == 0, same as its siblings.
17. [info-design/M] Feed and own-calendar copies of the same lecture render as unlabeled twins — where: 01_agenda.png / 22_changed_new.png — agenda room-line rows
   problem: A feed lecture and its own-ICS duplicate render as adjacent rows ('Engineering Mechanics I (V), Langhoff…' + 'Engineering Mechanics I (Lecture)' / 'Franz-Grashof-Hörsaal' + 'Franz-Grashof-HS') with no badge saying which one came from the student's personal calendar — the merge result is genuinely confusing even when correct.
   fix: Tag own-calendar events with a small 'own calendar'/'eigener Kalender' chip so the two sources are visually distinguishable (grouping itself is the data pool's call).

## Keep-list (do not regress)
- Agenda room lines are tinted, tappable, and carry the distance anchor into the room finder — the walk-hint row between lectures is a genuinely thoughtful touch (error-tint when the gap is tight).
- 'As of 09:48' freshness footer on the agenda (and red stale variant) — honest, understated data-freshness communication.
- Exams page sectioning (Act now → opens later → other → catalogue) with padded 'Register by: 07.02.2027 23:59' deadlines is scannable and the empty state remains pull-refreshable.
- Long titles in SignMeUp/ILIAS cards ellipsize correctly with '…' — the ellipsis discipline that the home carousel and appointment sheet are missing.
- Language menu uses native language names (System / Deutsch / English) and the whole app re-renders instantly — correct i18n convention, well executed.
- Home's empty-modules card with a tonal retry button is exactly the right pattern for a first-login empty state.
- Export filename 'mei-stundenplan-20261102.ics' is descriptive and dated — better than 90 % of apps.
- Grades SOP card (30-CP progress bar with deadline status) surfaces the Orientierungsprüfung risk where it actually belongs; zero-fail chip correctly stays grey.
- Hero transition from the timetable block title into the detail sheet is present and smooth where it isn't clipped.
- Place-search quick chips (Audimax/Mensa/Bibliothek/Sport) show localized labels while searching the German directory — correct split of UI language vs. data language.
- Red exam-seal badge on the app bar and the orange changes badge give at-a-glance action pressure without notification spam.

## Cosmetic verdict register
- C1 [VerifyShell]: 
- C7 [VerifyShell]: 
- C16 [VerifyAgenda]: Resolve the RefreshIndicator future after the content setState (e.g. run the smu/exams tail unawaited, or return from _refresh once the second setState at :196 lands).
- C21 [VerifyAgenda]: Hoist both to locals once inside build's children construction.
- C22 [VerifyAgenda]: Pause the ticker while the route is not visible (route-focused listener or visibility), and pass the single build-level `now` into _staleFooter.
- C26 [VerifyAgenda]: agenda_page.dart:946 — wrap the GestureDetector's child in `Semantics(button: true, label: shown)`.
- C27 [VerifyAgenda]: Optional: render the tail spinner only while the feed cache has not proven itself (reuse `_feedCached`).
- C38 [VerifyExams]: If touched at all: build a Set<ExamEntry> from catalog once (exams_page.dart:33) and pre-compute the isTakingThisSemester classification into a map before the filters.
- C42 [VerifyExams]: Replace _formatGrade (module_page.dart:242-263) with package:html decoding (`parseFragment(grade).text`) or parse named entities with a regex and pass stray '&' through.
- C44 [VerifyExams]: On home_page, schedule a single one-shot Timer for the nearest future windowStart/windowEnd among unregistered exams and setState on fire (cancel in dispose), instead of adding a p
- C56 [VerifyIlias]: 
- C58 [VerifyIlias]: 
- C59 [VerifyNotifs]: Replace '2 h' with '30-min (best-effort, OS-batched — see R101)' in mei_notifications.dart:31 and :418, and RUNBOOK.md:22/:123.
- C60 [VerifyNotifs]: Add a payload parameter to notifyChange (mei_notifications.dart:99, default agendaChanges) and pass NotificationPayload.agenda from IliasWatcher (ilias_watcher.dart:30-31) so the I
- C83 [VerifyCreds]: Delete the dead notes surface (controller + commented TextField + notes args) or, if the UI is to return, dispose it after `await showDialog` (:465).
- C84 [VerifyCreds]: Optional UX polish: distinguish "credentials rejected" (profileReady false) from network death in main.dart:240-247 and show a dedicated L10n string pointing users to retype their 
- C85 [VerifyCreds]: Define the key once (e.g. l10n.dart) and reference it from settings_provider.dart:13.
- C88 [VerifyCreds]: Delete _loadingSemesters (tutorial_manager.dart:10,:23,:124,:138); anchor the username regex to ^u[a-z]{4}$ and drop the tautological .input check (kit_credentials.dart:18-22); ded
- C91 [VerifyGeo]: Rename to `hasEmptySlot` or delete (timetable_daily.dart:27).
- C92 [VerifyGeo]: Optional polish: clear or dim _results inside _onChanged's setState (place_search_page.dart:107).
- C97 [VerifyGeo]: Optional determinism: on ties keep the shorter alias or lexicographically smallest (place_search.dart:95-101).
- C98 [VerifyGeo]: Optional polish: on the dedupe path, if the call comes from a different route than the in-flight one, show a brief 'already exporting' toast (ics_export_action.dart:26).

## Positives from GapWorkflow (already-agreed product direction, do not re-propose)
assignment tracker, opening-window alarms, SOP projection.
