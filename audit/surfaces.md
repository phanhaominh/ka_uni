# KA.Uni — UI Exercise Checklist (all user-reachable surfaces)

Generated 2026-11-02 from the 8 scout subsystem maps (pool `map2`); every cited handler re-read against the current tree at `/home/phan/ka_uni` on that date. Line numbers as-verified (drift from the scouts' maps corrected where re-read). Package `kit_mobile`; all paths relative to `lib/` unless noted.

## 1. Boot / Login gate (LoginPage)

- [ ] Cold start / auto-login — open app with stored creds — binding init → L10n bootstrap → notifications bootstrap (never blanks app on failure) → preload cache → SSO re-login; lands on Home shell, or Login with "invalidCredentials" toast if session dead — `main.dart:28-58` (bootstrap), `main.dart:225-247` (login chain), `main.dart:295` (AnimatedSwitcher gate `profileReady ? KITNavContainer() : LoginPage()`)
- [ ] Credential-load spinner — first frame before credentials load — centered KITProgressIndicator — `main.dart:~285-292`
- [ ] Username field — Login screen — prefilled with STORED USERNAME ONLY (password never prefilled); disabled until credentialsLoaded / while loggingIn — `credentials/views/login_view.dart:58-63` (prefill), `:96-105` (field)
- [ ] Password field — Login screen — obscured, visiblePassword keyboard, never auto-filled — `login_view.dart:107-118`
- [ ] "Einloggen" button — type uxxxx + password, tap — SSO submit; success → shell + background `loginPostSteps`; failure → form re-enabled; throw → `auth.fail` toast — `login_view.dart:~129-131` → `_submitLogin` `login_view.dart:247-292`
- [ ] Double-tap submit guard — mash Einloggen — second tap ignored while `_awaitingAuthentication` — `login_view.dart:250-252`
- [ ] Info icon (login) — tap "i" next to Einloggen — pushes InfoPage — `login_view.dart:~120-124`
- [ ] Debug-only "Hallo" title tap — tap greeting (debug builds) — silently reloads stored credentials; NO-OP in release (`kDebugMode` gate) — `login_view.dart:75-81`
- [ ] Maintenance overlay — KIT serves maintenance HTML — blurred full-screen overlay with "Dismiss" button; dismiss removes overlay — `login_view.dart:~211-226` (`vm.dismissOverlayHtml`)
- [ ] Login-failure toast — wrong creds — `auth.invalidCredentials` toast, form stays — `main.dart:246-247`

## 2. App shell / bottom dock (KITNavContainer)

- [ ] Settings glyph — tap dock gear — body swaps to SettingsPage (`_selectedPage=0`) — `navigation/views/kit_nav_container.dart:~91-92`
- [ ] Home glyph — tap dock house — body swaps to KITHomePage (default index 1) — `kit_nav_container.dart:~93-94`
- [ ] ILIAS paperclip glyph — tap dock clip — PUSHES `IliasPageView(KITModule())` (dashboard fallback honoring PREF_defaultIliasPage); tab index never becomes 2 — `kit_nav_container.dart:~95-104`
- [ ] Tab switch state loss — Home→Settings→Home — scroll positions/state of unmounted pages NOT preserved (known design) — `kit_nav_container.dart:105-111` (body list literal, index-2 entry dead)
- [ ] Deep-link shell gate — tap notification while logged out — queue holds; drains when shell appears / on resume — `kit_nav_container.dart:28-34` (shellAppeared), `:37-42` (shellGone), `main.dart:264-270`, `main.dart:275-280`

## 3. Home tab (KITHomePage)

- [ ] Profile-ready spinner (AppBar leading) — open app during login — spinner replaces title until profileReady — `home/views/home_page.dart:~85`
- [ ] Calendar icon (AppBar) — tap — pushes AgendaPage; ORANGE badge when `campusManager.timetableChanged` (CHANGED band pending); Semantics label agenda.title — `home_page.dart:87-106` (push `:90-93`, badge `:100-104`)
- [ ] Exam-seal icon (AppBar) — tap — pushes ExamsPage; RED badge when any exam `needsAction(now) && isTakingThisSemester(e) != false` — `home_page.dart:107-127` (push `:109-112`, badge `:117-122`)
- [ ] Chevron profile toggle (AppBar) — tap chevron — AnimatedSwitcher shows/hides profile card; app-bar title swaps logo↔"Hi, <firstName>"; PERSISTS (PREF_showingProfile), shared with Settings switch — `home_page.dart:128-144` (toggle `:129-131`), `home/views/ka_uni_app_bar_title.dart:22-37`
- [ ] Pull-to-refresh (whole page) — drag down — forceRefetchEverything; on error `common.refreshFailed` toast; works even when page fits screen — `home_page.dart:148-157`
- [ ] Failure banner — parse/bot failure states — non-dismissible strip; ladder: botChallenge (red700) > both broken (red600) > exams (orange800) > timetable (orange800); session death NOT surfaced — `home_page.dart:~162`, `common_ui/mei_failure_banner.dart:17-31`
- [ ] Profile card visibility — Settings "Show profile" or chevron — card appears/disappears under app bar — `home_page.dart:163-169`
- [ ] Timetable carousel — swipe left/right on weekday cards — infinite carousel; weekend renders zzz placeholder — `home_page.dart:170`, `timetable/views/timetable_weekly_view.dart:39-48` (carousel), `:117-140` (weekend)
- [ ] "Heute/today" button in carousel — swipe ≥2 pages away, tap "today" — animates back to today page (see candidate C5 for stale-anchor glitch); button hidden when |offset|≤1 — `timetable/views/ui_elements/show_today_button.dart:31-33`, `_showToday` `timetable_weekly_view.dart:157-162`
- [ ] Timetable block row tap — tap a lecture block in a day card — pushes TimetableAppointmentPage (map + sheet); time badge top-right; empty blocks render blank — `timetable/views/timetable_daily_view.dart:~109-116` (tap), `:185` (badge), `:74-86` (empty)
- [ ] Appointment page map — open appointment — flutter_map OSM tiles + marker, FutureBuilder on placeData (scrapes KIT campus page; campus-centre fallback); draggable sheet with Hero title — `timetable/pages/timetable_appointment_page.dart:~35` (FutureBuilder), `:111-158` (sheet/Hero)
- [ ] "Stundenplan bearbeiten" pencil row — tap below carousel — pushes TimetableEditPage — `home_page.dart:171-186` (push `:174-177`)
- [ ] "Current modules in <semester>" section row — scroll to module grid — title with semester; spinner while fetching schedule/modules — `home_page.dart:188-200`
- [ ] Refresh-modules icon — tap circular-arrows beside section title — `settings.reloadingModules` toast immediately; on failure `common.refreshFailed` toast — `home_page.dart:202-215`
- [ ] Relevant-modules grid — module cards (2-col, height 300) — placeholder cards get prettified row-id titles while pending; ghost-placeholder ids hidden; "last updated" stamp above grid — `home/views/relevant_modules.dart:~78-92` (grid), `:38-45` (stamp), ghost filter `:29-32`
- [ ] Module card info icon — tap ⓘ on a module card — pushes ModuleView (FutureBuilder; network fetch may run before push) — `home/views/relevant_module.dart:47-53`
- [ ] Module card "ILIAS" text button — tap when module has iliasLink (button HIDDEN when null/empty) — awaits module lookup + mounted guard, then pushes IliasPageView with real SSO session — `relevant_module.dart:59-72`
- [ ] Module card star badge — module with favorited child — small gold star, no tap action — `relevant_module.dart:~86-97`
- [ ] Empty-modules state card — fresh login/first sync — cloud_off icon + text + FilledButton.tonal retry → forceRefetch + failure toast — `relevant_modules.dart:~50-73` (button `:63-69`)
- [ ] "Pinned files" title + "View all" — tap — pushes FilesCachePage — `home_page.dart:225-231` (push `:227-230`)
- [ ] Pinned files list — below Pinned files title — tap a file → PDFScreen — `home_page.dart:232`, `local_files_storage/views/pinned_files_list_view.dart:96-110`
- [ ] "My modules" tree — scroll to bottom — rows level<3 hidden; row tap → ModuleView (fetch may run first, NO loading UI); grade text shown only if <6 chars — `home/views/hierarchic_table.dart:22-24` (level gate), `:30-35` (tap), `:47` (grade), `home_page.dart:234-238`

## 4. Profile card (on Home)

- [ ] Name-card LONG-PRESS (easter egg) — press-hold the name row — toast "Hi :)" — `profile/views/profile_view.dart:~58-60`
- [ ] Degree / semester cards — visible with showingProfile — degree program + current semester (WS/SS heuristic) — `profile_view.dart:~80-98`
- [ ] ECTS / avg-grade cards — toggle "Show avg grade" in Settings — ON: avg + ECTS side-by-side; OFF: single ECTS row — `profile_view.dart:~100-140`
- [ ] Grades ledger entry card — tap "Studienverlauf" card (whole card tappable incl. padding) — pushes GradesPage — `profile_view.dart:~152-160`

## 5. AgendaPage (calendar icon / deep links)

- [ ] Open from Home calendar icon — see §3 — plain AgendaPage — `home_page.dart:90-93`
- [ ] Share/export ICS icon (AppBar) — tap share — single-flight export of merged cache via share sheet; success toast with event count / empty / failed toasts; temp file deleted on all paths — `agenda/views/agenda_page.dart:~332-336` → `timetable/logic/ics_export_action.dart:23-30`
- [ ] Pull-to-refresh — drag anywhere in list — full 6-phase `_refresh` (prefs-first render, ILIAS, SignMeUp/exam bounded waits) — `agenda_page.dart:339-340` (RefreshIndicator) → `:130-235`; see candidate C16 (spinner can outlive visible content)
- [ ] CHANGED band — appears when DATA_webcalChanges non-empty — tertiary card "Stundenplan geändert (n)", first 6 change rows, "+N more" line — `agenda_page.dart:~343-347` (render), `:402-447` (`_changedBand`)
- [ ] CHANGED band dismiss — tap "Verwerfen" (Semantics hint `agenda-dismiss-changes`) — removes changes pref, clears home orange badge immediately, band disappears — `agenda_page.dart:~438-444` → `_dismissChanges` `:296-312`
- [ ] CHANGED band pulse (deep link only) — tap a timetable-change notification — ~2 s HighlightPulse glow around band — `agenda_page.dart:343-347` + `common_ui/highlight_pulse.dart:13`
- [ ] "Next up" banner — with a lecture within 12 h — now-running / next lecture countdown, refreshed by 30 s ticker — `agenda_page.dart:~566-635`
- [ ] Today / Tomorrow day sections — always rendered — lecture rows "HH:MM–HH:MM title" + room line; past rows faded; running row bold; lectures running past midnight stay on their day — `agenda_page.dart:~349-352`, rows `:485-500`
- [ ] Room line (AgendaRoomLine) — tap tinted (scheme.primary) room text — pushes PlaceSearchPage with room as query AND distance anchor; placeholder rooms ("-", "--", "ILIAS") stay plain untappable Text — `agenda_page.dart:918-952` (tap `:944-950`, gate `:940-942`)
- [ ] Walk hint row — two adjacent lectures with 5–90 min gap — walking-person row "Fußweg X min" (error-colored when tight); suppressed when either side's end is guessed — `agenda_page.dart:532-563`, math `agenda/logic/walk_hint.dart:47-71`
- [ ] Next-exam countdown card — registered exam ≤45 days out — "Nächste Klausur" card with title/date — `agenda_page.dart:~640-690`
- [ ] ILIAS card header + unread badge — "{N} neu" shown when notifications>0 (mails parsed but never displayed) — `agenda_page.dart:~722-775` (badge `:734-736`)
- [ ] ILIAS card states — spinner only while loading AND nothing cached; error line ONLY when nothing cached; "none" line when empty — `agenda_page.dart:~737-752`
- [ ] ILIAS announcement rows (≤5) — tap an announcement — opens URL in EXTERNAL browser (raw launchUrl, no scheme gate — see C19); chevron affordance — `agenda_page.dart:~754-773` (onTap `:770-772`)
- [ ] Red exams card — while any registration window open & unregistered (relevance-gated) — danger card + "Zur Anmeldung" button → pushes ExamsPage — `agenda_page.dart:~776-822` (button `:815-823`)
- [ ] "Prüfungsanmeldungen werden geprüft…" pending card — exams not yet loaded and not broken — `agenda_page.dart:355-361`
- [ ] SignMeUp procedures card — open SignMeUp procedures exist — ≤3 rows + button opening https://plus.campus.kit.edu/ externally — `agenda_page.dart:~895-912` (launchUrl `:904-908`)
- [ ] SignMeUp "my registrations" card — own registrations exist — display-only rows + state chips, NO tap handlers anywhere (grep-verified) — `agenda_page.dart:366-367`, `signmeup/signmeup_mine_card.dart:56-131`
- [ ] Stale-data footer — feed older than 6 h (or unstampable) — red "as of … ago" line; fresh shows neutral "as of HH:MM" — `agenda_page.dart:~695-719`
- [ ] Bottom loading spinner — while `_loading` — small spinner at LIST TAIL below content (not a replacing state) — `agenda_page.dart:369-373`
- [ ] Long-press — nowhere on agenda (verified: zero onLongPress) — no hidden surface — n/a

## 6. PlaceSearchPage (Raum-Finder; agenda room lines are the ONLY entry)

- [ ] Autofilled search field — arrives with room as query — text prefilled; clear (×) button while editing, clears instantly — `geo/views/place_search_page.dart:137-146` (field + clearButtonMode)
- [ ] Quick chips Audimax / Mensa / Bibliothek / Sport — empty-query view, tap a chip — seeds query and re-ranks — `place_search_page.dart:51-56` (defs), `:~206-222` (`_chip` InkWell → `_useChipQuery` `:122-125`)
- [ ] Result rows expand-in-place — tap a result row — row expands in place (no second page); tap again collapses — `place_search_page.dart:~255-262` (`_expandedKey`)
- [ ] Website button (expanded row) — expand a result with URL — http(s)-validated link renders "Website" button → external browser; unparsable/non-http renders NOTHING — `place_search_page.dart:~307-322` (`_launchableUrl`), `:332-352` (`_websiteRow`)
- [ ] Distance anchor — entered from a room line — results show "≈ x km/m von <room>" (German-comma format) — `place_search_page.dart:75-90` (resolve), `geo/logic/place_search.dart:144+` (formatter)
- [ ] Cold-start no-flash gate — open during prefs read — never flashes "Keine Treffer" while snapshot loads — `place_search_page.dart:39` (`_loaded`), gate `:~155-160`
- [ ] Debounced ranking — type fast — results update ~200 ms after last keystroke (old rows may momentarily lag the field — C92) — `place_search_page.dart:113-119`
- [ ] Offline snapshot fallback — airplane mode, open room line — results from GEO_placeSearchSnapshot (survives logout) — `geo/network/KITTopographyManager.dart:92-101`, consumed `place_search_page.dart:79-84`

## 7. ExamsPage (seal icon / red agenda card / exam notifications)

- [ ] Open via seal icon / agenda red card / exam notification — any — self-heal auto-fetch when never fetched (post-frame) — `exams/views/exams_page.dart:20-26`
- [ ] Pull-to-refresh — drag — refetch; false → `exams.loadError` toast — `exams_page.dart:62-68`
- [ ] Broken-state branch — examsSurfaceBroken — error text + "Erneut versuchen" FilledButton → retry — `exams_page.dart:69-84`
- [ ] Endless-spinner branch — never-loaded and not broken — spinner list — `exams_page.dart:85-93`
- [ ] Empty state — zero exams — centered "exams.empty" text (still pull-refreshable) — `exams_page.dart:~96-101`
- [ ] Sections — Act-now (danger-bordered, red "Nicht angemeldet" chip), registered, upcoming (opens later), rest, quiet catalogue — sorted deadline→title→exam-number — `exams_page.dart:30-58` (buckets), `:125-140` (comparators), card/chips `:160-175`
- [ ] No in-app registration — cards offer NO register button — registration happens at KIT in browser; app only flags + notifies (by design) — `_card` region `exams_page.dart`
- [ ] Red seal badge lag — let a window close while Home stays open — badge only re-evaluates on rebuild (no timer — C44) — `home_page.dart:117`

## 8. GradesPage (profile card entry)

- [ ] Entry — tap "Studienverlauf" card — pushes GradesPage (pure data, no scrape) — `profile_view.dart:~155-159` → `grades/views/grades_page.dart:13-16`
- [ ] Pull-to-refresh — drag — `fetchSchedule(refreshSession:false)`; !ready → `grades.loadError` toast — `grades_page.dart:33-42`
- [ ] SOP 30-CP card — always — LinearProgressIndicator (green when reached) + progress line; overdue after 2027-03-31 → error tint (hardcoded — C36) — `grades_page.dart:20` (deadline), `:~90-105` (bar)
- [ ] Summary card — always — total CP, average (or "valueNone"), chips passed/failed/pending (zero-fail chip stays grey) — `grades_page.dart:~117-150`
- [ ] Sections failed → passed → pending — scroll — failed rows error-tinted; flexible grade chip; "N CP" only when >0 — `grades_page.dart:~60-70`, rows `:~195-215`

## 9. ModuleView (module page)

- [ ] Open — tree row tap OR module-card ⓘ — FutureBuilder: header, exam date row (clock/check/question icon + "Prüfung in N Tagen"), grade row, credits row, info tables — `module/views/module_page.dart:~57-100`
- [ ] "ILIAS" app-bar button — when module has a link — pushes IliasPageView for THAT course — `module_page.dart:62-66`
- [ ] "Modul an ILIAS anhängen" button — when NO link — URL dialog; save → validated (https + ilias.studium.kit.edu[/sub] only) → toast saved; invalid → toast invalid; persisted "MIL <semester>" — `module_page.dart:67-70` → `_attachIliasLink` `:~190-240`
- [ ] Favorite star (Sensible table rows) — tap star on a lecture/exercise row — server toggle; on failure: session toast + force-refetch + fuzzy re-find + SECOND toggle retry + haptics — `module_info_table/models/module_info_table_types/module_info_table_sensible.dart:~95-152`
- [ ] Appointment rows (date/time cells) — arrow + date + time rows — `module_info_table/views/appointment_cell.dart`
- [ ] Generic table fallback — no "Titel" column — plain Table render — `module_info_table/models/module_info_table_types/module_info_table_generic.dart`

## 10. ILIAS WebView (IliasPageView)

- [ ] Landings (4) — module-card ILIAS button / module-page ILIAS button / module attach dialog / dock paperclip — WebView of course or dashboard; JS unrestricted; spinner until PHPSESSID non-empty — entries §3/§9; gate `ilias/views/ilias_page_view.dart:314-322`
- [ ] Back chip (top-left glass) — appears when poppable — pops the page — `ilias_page_view.dart:~397-404`
- [ ] Refresh chip (top-right glass) — tap — re-authorizes with `refreshSession:true` (cookie wipe + full SSO); empty result → `ilias.refreshError` toast — `ilias_page_view.dart:~405-410` → closure `:325-340`
- [ ] Forward/back history chips (bottom-right glass) — tap — webview goBack/goForward — `ilias_page_view.dart:~411-423` (`_FloatingNavChips`)
- [ ] PDF (sendfile) download — tap a file link inside ILIAS — navigation intercepted → "wird geladen" toast → PDFScreen; failures toast `ilias.downloadFailed`; %PDF magic-byte gate on cache reuse — `ilias_page_view.dart:128-135` (intercept), `:172-186` (`_saveAsFile`), `:193-263` (`_doSaveAsFile`)

## 11. File surfaces

- [ ] PDFScreen pin/save button — tap pin — dialog (module title + name) → addPinnedFile → `files.fileSaved` toast (or saveFailed) — `local_files_storage/views/file_viewer.dart:46-51`, `_handlePinPressed` `:~190-220`
- [ ] PDFScreen share button — tap share — system share sheet with the file — `file_viewer.dart:52-69`
- [ ] PDFScreen delete button — tap trash — unpin + delete file + pop (unawaited unpin — C55) — `file_viewer.dart:70-80`
- [ ] Pinned list tile tap — Home pinned files — opens PDFScreen — `pinned_files_list_view.dart:96-110`
- [ ] Pinned tile rename — trailing rename — CupertinoAlertDialog with text field → updatePinnedFileCustomName — `pinned_files_list_view.dart:112-152`
- [ ] Pinned tile delete — trailing delete — confirm dialog → remove — `pinned_files_list_view.dart:154-180`
- [ ] FilesCachePage semester expand — open via "View all" or Settings→Manage — tap semester header — expands to file list (second tap collapses) — `local_files_storage/views/pages/files_cache_page.dart:252-270` (`_expandSemester`)
- [ ] FilesCachePage file eye button — expanded semester — pushes PDFScreen for the raw file — `files_cache_page.dart:121-135`
- [ ] Settings→"Manage" — cache section — pushes FilesCachePage — `settings/views/settings_page.dart:156-163`

## 12. Settings tab (dock gear)

- [ ] Info icon (AppBar) — tap — pushes InfoPage — `settings/views/settings_page.dart:50-55`
- [ ] "Show profile" switch — Homepage section — toggles Home profile card (+ app-bar title) live; persists — `settings_page.dart:~86-92`
- [ ] "Show avg grade" switch — Homepage section — profile avg/ECTS layout swaps live; persists — `settings_page.dart:~93-97`
- [ ] Language dropdown (System/Deutsch/English) — Appearance section — WHOLE app re-renders in new language immediately (routes included); missing EN strings fall back to DE, never raw keys — `settings_page.dart:~102-106` → `l10n/l10n.dart:36-46`, `main.dart:168-169` — EDGE: "system" follows device locale captured AT STARTUP (no live device-change tracking), `l10n.dart:49`
- [ ] Theme dropdown (System/Light/Dark) — Appearance section — instant light/dark re-theme app-wide (seed #009682) — `settings_page.dart:~107-116` → `main.dart:161-167`
- [ ] ILIAS start-page dropdown (Dashboard / Meine Kurse & Gruppen) — ILIAS section — changes which ILIAS page the paperclip opens when a module has no direct link; stored as scraped German page title (fragile — C11) — `settings_page.dart:~125-135` → `ilias_page_view.dart:145-149`
- [ ] Own-timetable ICS: save-from-URL — paste https URL (localhost http allowed), tap Save — parses VEVENT blocks, events appear in agenda/home immediately, status line shows count; bad body → "bad"; network → "fetch" toasts — `settings_page.dart:341-346` (`_run` `:277-290`)
- [ ] Own-timetable ICS: pick file — tap "Datei" — FilePicker (.ics/.txt only) → same merge; cancel → no-op — `settings_page.dart:347-360`
- [ ] Own-timetable ICS: clear — tap "Löschen" — personal events removed from agenda; URL+body prefs cleared — `settings_page.dart:362-366`
- [ ] Own-timetable ICS: export/share — tap share icon — same single-flight export as agenda (shared `_inFlight` — C98) — `settings_page.dart:369-373`
- [ ] Cache size row — Cache section — one-shot directory walk byte size rendered — `settings_page.dart:150-155` (`_CacheSizeText` `:~404-441`)
- [ ] Debug → Modul-Baum — Debug section chevron — ModuleTreeDebugPage (STILL PRESENT IN RELEASE — C87) — `settings_page.dart:166-180`
- [ ] Logout button — bottom of page — multi-second wipe (creds zeroed, cookies, prefs DATA_*/RMR /module_cache_/MIL, alarms, file bytes); loggedOut / logoutFailed toast; guarded while running (`_loggingOut`) — `settings_page.dart:193-231` → `credentials/data/credentials_provider.dart:212-278`
- [ ] "LiquidAss" glass toggle — NOT REACHABLE — only row is commented out in source; setting stays default false (glass BlockContainer dormant) — `settings_page.dart:67-81` (commented block), effect `common_ui/block_container.dart:29-32`
- [ ] Edge: post-logout state — after logout — AnimatedSwitcher back to LoginPage; queued notification taps held (shellGone); GEO_ snapshot + PREF_* survive by design — `main.dart:295`, `kit_nav_container.dart:37-42`

## 13. ModuleTreeDebugPage (Debug section)

- [ ] Row inspection — open via Settings → Debug — one row per Studienverlauf entry: L<level>, "no page" tag, green check when admitted, else reason tag (feedMiss/duplicateClash/placeholderGhost/unexplained) — `settings/views/module_tree_debug_page.dart:84-118` (entries), `:277-288` (`_reasonLabel`)
- [ ] Long-press a row — copies title to clipboard + haptic + hint (no setState) — `module_tree_debug_page.dart:161-165`
- [ ] Lazy "load more" slice + empty-tree message — scroll — snapshot-once semantics `:140-143`

## 14. InfoPage (from login "i", Home, or Settings app bar)

- [ ] GitHub icon (AppBar) — tap — opens https://github.com/DEMIDOB/ka_uni externally — `info/views/info_page.dart:~47-58`
- [ ] Privacy policy button — tap — opens https://dandemidov.com/ka_uni/privacy_policy/ — `info_page.dart:~94-98`
- [ ] FAQ expandable cards (static, e.g. security question) — tap to expand — `info_page.dart:~100-103` (InfoViewFaqSection)

## 15. Tutorials (TimetableEditPage)

- [ ] Add "+" — tap below the tutorial list — add/edit dialog (module / weekday / block dropdowns; HH:MM–HH:MM block labels excluding lunch); Save → tutorial row appears in the day's timetable — `timetable/pages/timetable_edit_page.dart:127-133` (+), dialog `:229-450`, merge `timetable/models/timetable_daily.dart:14-17`
- [ ] Add with zero modules — tap "+" before any module fetched — "no modules" GlassContainer dialog with Dismiss — `timetable_edit_page.dart:532-600` (`_showNoModulesDialog`)
- [ ] Pencil edit per tutorial — per-row trailing pencil — same dialog prefilled; Save updates — `timetable_edit_page.dart:~113-117`, tile `:~650-665`
- [ ] Trash delete — per-row trailing trash — CupertinoAlertDialog cancel/delete (destructive); async-gap mounted guard — `timetable_edit_page.dart:~118-122` → `_confirmRemoveTutorial` `:465-509`
- [ ] Notes — DEAD SURFACE: notes field commented out of the dialog; notes always null; controller still allocated per dialog (leak — C83) — `timetable_edit_page.dart:~246-248`
- [ ] Tutorial shown in day card — after adding — "Tutorium: <title>" row in the block (notes text when non-empty) — `timetable/views/timetable_daily_view.dart:~125-135`, notes `:~160-166`
- [ ] Per-semester persistence — restart app — tutorials reload from DATA_tutorialsFor<semester> (logout-swept; in-memory cleared on logout) — `tutorials/data/tutorial_manager.dart:104-160`, `clearAll` `:16-24`

## 16. Notifications & deep links (Android-only; iOS/desktop silently no-op)

- [ ] Morning digest tap (07:30) — tap digest notification — opens AgendaPage top — payload 'agenda' → `navigation/notification_deep_links.dart:13-19` (mapping), `:116-127` (push)
- [ ] Lecture reminder tap ("in 30 min") — tap — AgendaPage scrolled to TODAY (re-anchored until content real) — payload 'agenda:today' `:119-124` + `agenda_page.dart:95-103,115-128`
- [ ] Timetable-change alert tap — tap — AgendaPage with CHANGED-band PULSE — payload 'agenda:changes' `:120-125`
- [ ] ILIAS-announcement push tap — tap — lands on agenda with pulse on the TIMETABLE changes band — WRONG band (hardcoded payload — C60) — `notifications/mei_notifications.dart:~113` (payload), `state_management/ilias/ilias_watcher.dart:74-88`
- [ ] Exam-deadline alert tap (−24 h) — tap — ExamsPage — payload 'exams' `:126`
- [ ] Notification launched app (cold start) — kill app, tap notification, relaunch — deep link queued, drained once shell exists — `main.dart:49-53`
- [ ] Burst of taps — tap 3 notifications quickly — never stacks multiple agenda/exams pages (one-page rule removes stale pushed route first) — `notification_deep_links.dart:103-110,127-131`
- [ ] Tap while logged out / on login screen — tap while profileReady false — held in queue; no push onto dying shell — `main.dart:264-270`, `kit_nav_container.dart:37-42`
- [ ] Tap with detached Navigator → resume — background, tap, foreground — drain retried on resumed — `main.dart:275-280`
- [ ] Home orange badge ↔ CHANGED band — dismiss band on agenda — badge clears instantly; a later foreground fetch re-lights it from a non-empty changes key — `agenda_page.dart:296-302`, `campus_manager.dart:1919-1921`
- [ ] No in-app notification settings — there is NO notification on/off surface; always-on on Android by design — no toggle exists in settings/ (grep-verified)
- [ ] Alarms survive reboot — reboot device — plugin boot receivers re-deliver persisted exact alarms (BOOT/TIMESET/TZ/MY_PACKAGE_REPLACED) — `android/app/src/main/AndroidManifest.xml`

## 17. Global / edge surfaces

- [ ] Toast overlay — any toast trigger — floating toast above everything (ToastsOverlay global builder) — `main.dart:170-179`, `toasts/views/toasts_overlay.dart`
- [ ] Alpha badge / KIT logo variant — every logo render — `const isAlpha = true` at `main.dart:26` drives logo width/badge — `common_ui/kit_logo.dart:9`, `common_ui/alpha_badge.dart:5`
- [ ] Failure banner edge — bot-challenge algorithm change — red "bannerBotProtection" strip — `mei_failure_banner.dart:17-19`, `state_management/kit_login_manager.dart:~100-107`
- [ ] Placeholder-state sweep — empty surfaces: home modules empty card (§3), exams empty text (§7), agenda ILIAS "none" + pending cards (§5), place search "Keine Treffer" (§6), tutorial "no modules" dialog (§15), files empty cache — all listed above
- [ ] Logout sweep verification — log out, relogin as other account — no DATA_*/RMR/MIL/module_cache_ residue; ILIAS card cache, watched-announcement ids, pinned files + BYTES gone; GEO_/PREF_* survive — `credentials_provider.dart:212-278`

---

# SECTION 2 — CONTENT FOR /home/phan/ka_uni/audit/candidates.md
