# RUNBOOK — MEI Cockpit fork of KA.Uni

Personal KIT cockpit for Mechanical Engineering International (WS 2026/27).
Upstream app: KA.Uni (`com.dandemidov.kit_mobile`), kept as package id so the
APK installs over the existing app.

Project lives at `/home/phan/ka_uni` — **never** work in `/tmp`: it is
tmpfs here, so a 4 GB `build/` silently eats 4 GB of RAM and release builds
get OOM-killed. `android/gradle.properties` is capped (`-Xmx1600m`,
workers=1) to coexist with a busy desktop.

## What this fork adds

| Surface | Source | Notes |
|---|---|---|
| Timetable (home grid) | cascampus **WebCal ICS** (token URL, auto-provisioned) | primary source, no bot wall; cascampus HTML as fallback |
| Agenda screen (calendar icon, home app bar) | ICS cache + ILIAS + exams | merged today/tomorrow + CHANGED band |
| CHANGED band | `WebcalFeed.changesSince` diff of cached vs fresh ICS | neu / entfällt / verschoben / Raumwechsel; "Verstanden" clears it |
| Prüfungsanmeldung (seal icon) | campus `possibleexams` + `sqassign` | red badge while a window is open and unregistered |
| Meine Anmeldungen (agenda card) | SignMeUp `fetchMine` (Campus+ session, fetched at login and on force-refresh; the agenda only awaits the in-flight refresh) | state chip (accepted/rejected/open), Platz rank, countdown to confirmation deadline / first draw; display-only, no own fetch |
| ILIAS page + scraper | `ilias.studium.kit.edu` via KIT SSO | courses, per-course materials (recursive folder walk), announcements, unread badges |
| Notifications | exact alarms + WorkManager (30-min ICS poll, OS-batched) + boot receiver | lecture reminders from expanded ICS dates, Anmeldung deadline alerts, timetable-change push |
| Round 3: notification deep links | payload on tap -> push on the root Navigator | agenda / agenda:today (scroll re-anchors after the agenda data renders) / agenda:changes (CHANGED-band pulse) / exams; **one-behind-page dedupe**: while a previous deep-link page is still mounted a new tap removes it before pushing, so repeated taps can never stack pages that each run a full refresh (SSO chain + up to 45 s SignMeUp wait); SignMeUp reminders land on the agenda (the card renders there), and logout re-arms the queue the moment profileReady flips false |
| Round 4: exam sittings as calendar events | exam list (`possibleexams`) -> synthetic `kauni-exam-*` VEVENTs in the webcal cache (`X-EXAM-SYNTH` sentinel block) | agenda rows + countdown, morning digest (exam-only days: "Klausur um HH:MM"), 30-min reminders (start-only "ab HH:MM" when the KIT label has no end token — such events export WITHOUT DTEND, guessed ends never leave the app), raw ICS export; deterministic DTSTAMP/UID (sitting-keyed) so refetches update instead of duplicate; past sittings drop out at the date boundary; **home grid deliberately excludes them**: `toWeeklyTemplate` is a per-(weekday, block) one-appointment template — one-off sittings would repeat on every same-weekday carousel page, lose block collisions to recurring lectures and vanish on weekends; agenda/digest/reminders/export keep reading `feed.occurrences`/raw |
| Round 5: Raum-Finder | campus directory `data_de.js` via KITTopographyManager (824 live places, 2026-11) | agenda room rows are the ONE entry point (`AgendaRoomLine`): tinted `scheme.primary` when tappable, "-" / "--" / "ILIAS" placeholders (per `ExamTerm.isPlaceholderRoom`) stay plain Text, query = `displayRoom` (dup-token fold only); offline snapshot under **GEO_placeSearchSnapshot** — GEO_*, not the logout-swept DATA_*, because the directory is public KIT data that must survive logout (legacy DATA_ key read once as fallback); empty parses and byte-identical payloads never touch the snapshot; keystroke debounce 200 ms around the rank (multi-token rooms measure 16-22 ms > frame budget; initial load defers to post-frame); tiers exact > prefix > alias > fuzzy, fuzzy gated at floor 65 + ≥4 chars + 12-row cap; no-results hint suggests the bare building number |
| Round 6: current-modules dedupe + Modul-Baum (Debug) | `addRelevantModuleRow` title guard / `campusManager.moduleRows` dump | **one card per module**: the Studienverlauf tree carries some modules twice (two section headings -> two row ids, since the id is "<level>\_\<title\>\_\<year\>"), which printed two identical cards; admission now refuses a row whose normalized title (`lectureTitleKey` of the feed title) already matches an admitted one — same numeric-token guard as `moduleKeyMatchesLectureKey`, so EM I / EM III stay two cards, and deliberately **no** fuzzy ratio, because "Mechanical Design A" vs "... B" and "Analysis 1" vs "Analysis 2" are two modules; the copy whose page carries the ILIAS course wins regardless of which parallel fetch returns first, and `prepareRelevantModuleRows` collapses duplicate ids persisted by older builds (written back through `storeRelevantModuleRows`); settings -> Debug -> **Modul-Baum (Debug)** (`ModuleTreeDebugPage`) lists every tree row with level >= 3 with its level, a green check where the feed rule matches and "(noch keine Seite geladen)" where `rowModules` never fetched it — long-press copies a title, so "is Advanced Mathematics I in the tree, and what is it called there?" is answerable on the phone instead of by reinstalling a debug build |
| Round 7: manual ILIAS link | `CampusManager.setManualIliasUrl` / module-page attach dialog | some ILIAS courses exist although CampusKIT never links them ("Advanced Mathematics I", course 0140000): when a module page has no ILIAS button it offers "ILIAS verknüpfen" -> URL dialog (only `https://ilias.studium.kit.edu` and subdomains accepted, else toast); stored per semester under **`MIL <semester>`** ({lectureTitleKey -> url}, logout-swept like RMR) and applied at the `fetchModule` choke point as a **fallback only** - an empty `iliasLink` picks it up, a CampusKIT-printed link is never overwritten; admission (`addRelevantModuleRow`) still judges the genuine page link, manual attaches run after it |
| Round 8: grades ledger + ILIAS new-material push | `GradeBook.fromRows(cm.moduleRows)` (profile card -> GradesPage) / `IliasWatcher.diffAndNotify` (agenda refresh) | **no new scraping anywhere**: the ledger aggregates the already-fetched Studienverlauf tree - level>=3 rows deduped by **exact** titleKey (deliberately NOT the loose feed matcher: it swallowed "Brückenkurs Analysis 1" into "Analysis 1" with its credits; retake attempts supersede chronologically, a recorded pass is never demoted), classification "nicht*"/>4,0 -> failed, <=4,0 or "bestanden" -> passed, else pending; grade cells parse across inner whitespace/NBSP; 30 CP orientation bar (deadline 2027-03-31, `GradeBook.sopDeadline`) driven by `student.ectsAcquired` (fallback: summed passed CP), rounded ONCE in the model so text/bar/threshold can never disagree. The watcher diffs the personal news the agenda already fetches against **`DATA_iliasWatchSeen`** (ids `refId|lowercased-squeezed-title` - punctuation kept: stripping it merged "Übungsblatt 7." into "Übungsblatt 7" and swallowed posts forever; titles without one letter/digit are scraping residue), age-ordered JSON cap 300 incl. the seed write: first run seeds silently, seen-marking persists AFTER a successful push (a throwing push leaves the id unmarked - late push beats swallowed; late ledger: C53), ids still on the current board are never cap-evicted (no resurrection re-notify), max 3 per refresh oldest-first with beyond-cap overflow marked, per-item try/catch, teardownEpoch-fenced + single-flight (pull-to-refresh over an orphaned fetch must not double-push). Logout sweeps it like every DATA_* key - shared-device privacy beats re-notify convenience |
| Round 9: Wave-A hardening | `audit/candidates.md` §J dispositions | startup `cancelAll`+rebuild from cached ICS + exam snapshot (no update-ghost alarms); exam reminders replay from snapshot on cold start; digest no longer claims "geändert" (unverified suffix dropped); `WebcalKeys` single source for `DATA_webcal*`; webcal series key stays `title\|series-DTSTART` + longest-UNTIL-wins — room/UID must NEVER join it (clone snapshots of ONE course differ in UID+LOCATION+UNTIL, see C74 revert); logout bumps a teardown-epoch fencing late exam/reminder writes; background poll self-unregisters when the URL is gone; `_authorize` retry bypasses its own single-flight memo (was a self-await wedge) |
| Round 10: post-review hardening | 8-file review round after Wave-B commit | **splices are line-anchored**: strip/extract of the three sentinel blocks only honour whole-line sentinels (a byte indexOf desyncs from the parse side — one smuggled END line silently dropped every event after it from re-injection, a forged BEGIN cut the FEED short); `sanitizeSentinels` strips sentinel-carrying lines from ALL external ICS bytes at every entry (foreground parse, poll body, personal-ICS import); foreground webcal fetch fenced like the poll (teardown-epoch + live-URL probe) so a logout mid-GET can no longer reseed the purged store; `fetchModulesForRows` uses `_fetchModuleForChain` (ready-shortcut kept, per-row memo NEVER joined — the owner-refetch chain joining the tap memo it serves was a deadlock until restart); exam scheduler + snapshot gated on logged-in state, resyncOnStartup rebuilds nothing logged-out, poll→reminder rebuild staggered 12 s behind cold-start resync (R101 initialDelay race), changeSeq seeded from epoch-ms (30-min-bucket seed collided across isolates, pushes replaced each other); ILIAS auth-join timeout no longer escapes as unhandled zone error; single launch path after refreshSession (gate retry had double-loaded); agenda a11y (named merge-only button, non-launchable rows lose chevron+tap), sigmeup CTA shows deadline DATE not invented "23:59"; weekly/daily views scale with system text (band reserve, HH:MM badge width, ghost columns); profile restored matriculation-number line |
| Round 11: background ILIAS diff (C28 closed) | `mei-webcal-poll` callback now also runs `_iliasBackgroundDiff()` | ILIAS new-material pushes used to depend on OPENING the agenda; the 30-min poll now piggy-backs the same announcements diff: fresh `IliasManager` per run (jar is per-instance in-memory -> one full SAML chain ~4 requests per cycle, the same cadence CampusKIT's session keeps), creds from `FlutterSecureStorage` (**iOS accountName `kit-student` MUST stay mirrored**), PHPSESSID-proved session required before the fetch (an unproved empty board never seeds `DATA_iliasWatchSeen`), and `IliasWatcher.diffAndNotify(stillOurs:)` re-probes the live webcal URL before seed/push/persist — the static `teardownEpoch` is invisible across isolates, platform prefs are the only cross-isolate logout fence; diff itself (ids, caps, seed-silently, late-never-lost) unchanged and covered by `ilias_watcher_test` |
| Round 12: now-line + polish (C29) | NEW `lib/timetable/logic/now_clock.dart` (static `NowClock`: one shared minute heartbeat — refcounted `arm()`/`disarm()`, aligned to wall-minute boundaries, AppLifecycleListener republishes on resume, `timeSource` seam + `debugPublish` for tests; NEVER per-tick whole-screen setState — consumers use ValueNotifier/repaint) + `now_line.dart` (pure `nowLineY`/`dayColumnFactor`: piecewise y across blocks incl. the 1px border rows and 2–5min gap seams; column factor 0.9 cap, shrinks to `(vp−borders)/Σdur` so Large-font columns FIT instead of clipping the evening block). Daily view: now-line overlay (2px+dots+HH:MM chip, `repaint: NowClock.minutesOfDay` via CustomPainter super — SDK removed CustomPaint.repaint), ghost-cancelled cards + room-delta lines from the CHANGED feed (`IcsChangeIndex.byDayKey/blockKeys/removedOrMovedBlocks`, W3, keyed yyyy-MM-dd), free-gap minutes, all-day-empty zzz, `MITTAGSPAUSE` now l10n `timetable.mittagspause`, running-lecture `läuft · bis` chip reusing `agenda.nowRunning`, Hero tags carry `_{weekday.index}` (pageView keeps 7 same-tagged heroes alive; detail ctor `heroSuffix`). Weekly: pageDate helper, midnight rolls today-page via ONE listener on `NowClock.dateOfDay`, past pages dim 0.45, lectureFree week state, ghost-column tap → animateToPage. Nav: KITNavContainer → **IndexedStack** (Settings round-trip no longer wipes carousel page; C13-audited: settings has zero Timers, accepted cold-start of its 2 one-shot loads). Home: NextUp hero card shared via NEW `lib/agenda/logic/next_up.dart` (pure compute + NextUpCard, agenda delegates), agenda's 30s setState ticker → one minute-tick setState (TickerMode-gated). Deep links: `IcsOccurrence.url` (campus.studium.kit.edu/ev/<token> per VEVENT, token stable across one-shot→RRULE flip — fixture-proven; NOT in fingerprint/dedupeKey) → "Kursseite öffnen" in agenda rows + lecture sheet. roomVaries: template post-pass flags alternating-room courses (fixture: 3173008 Thu 11:30 40.50↔20.40 — grid previously showed October's room forever) → "Raum wchs." chip. Notifications: digest payload → agendaToday, T−15 CHANGED-rearm band ids **410–499** (`_cancelRange(410,499)` INCLUSIVE — 500 is exam band, contract's (410,500) was an off-by-one caught by W4), badge restored from prefs in `loadCachedTimetable` (cold-start CHANGED-but-dark-badge fixed). animateToPage under `itemCount:1` is DELTA-based (carousel_controller folds getRealIndex) — use `_animateDelta`, never absolute pages. W1 ghost-tap/hero/w1-w4 IRC handoffs all landed; 318 tests green. |
| Round 13: dead daily-view row taps (C29 follow-up) | `timetable_daily_view.dart` row `GestureDetector` → `HitTestBehavior.opaque` + height-clipped text | taps on lecture blocks did nothing while the now-line overlay was mounted: the row's GestureDetector wrapped a `Stack` whose children are mostly non-opaque, so hit-testing slipped through to the page; `opaque` claims the full block rect. Device-verified end-to-end (sheet opens, "Open course page" row launches `campus.studium.kit.edu/events/catalog.php#!campus/all/event.asp?gguid=…` — the R12 "missing course link" was never missing: URL arrives (drill print), row sits below the sheet's map fold and only became reachable once taps worked). Regression tests promoted to `test/timetable_daily_view_tap_test.dart` (tap opens sheet with AND without now-line, faked `NowClock`) |
| Round 14: floating dock + input false-alarm post-mortem | `kit_nav_container.dart` dock wrapper `Center` → `Row(mainAxisAlignment.center)` + `Flexible` + `ConstrainedBox(480)` | the bottomSheet slot hands the child loose-TALL-to-full-height constraints: `Center` expands to full height and floated the pill dead-center of every phone screen (the b47 "floating pill"); Row sizes to the pill. Device-verified on Pixel 3 (dock pinned to bottom edge). The b47 "dead inputs" report was NOT an app bug: my own debug session had left **TalkBack enabled** (single taps get consumed for exploration — restored `enabled_accessibility_services=""`) plus adb taps were sent at screenshot-DISPLAY coords instead of device PHYSICAL coords (Pixel3 logical×2.75: calendar icon = `input tap 736 148`, not `552 250`). Proven healthy via profile-build VMS services (pointer-packet watcher, per-node hitTest verdict walk, synthetic `handlePointerEvent` tap opens agenda/exams). Rules: NEVER leave accessibility services enabled on the user's device; adb coords = logical × dpr; screenshot display coords need ×scale BEFORE use. |
| Round 15: timetable grid glitches (wrap/void/clip) | `timetable_daily_view.dart` layout core: `_rowMin` gap ownership, phantom-row drop, row budget + FittedBox + column centering | four stacked causes behind the "wrapped texts, unbalanced spaces, glitchy" report: (1) scaffold placeholder rows between two ADJACENT classes fell back to their generic 90-min span → invisible voids splitting flush classes; (2) EVERY empty row of a run claimed the same gap minutes → 2-3x fat free-bands and a squashed fit-factor for the whole day — now only the LAST row of the run owns the gap, zero-gap placeholders are dropped from `day` entirely; (3) row text was centre-anchored with a magic `+24` place-line budget: 90-min boxes ellipsised the title to 1 line while reserving a place line that was never painted (roomless personal-ICS rows), and 2-line wraps sliced through the seam hairline — now top-anchored, budget = pure line math, place reserves only what the title leaves AND nothing at all when the row has no place/delta, place text itself ellipsises 1/2 lines by remaining height, `FittedBox(scaleDown)` shrinks short (≤45min) boxes instead of painting RenderFlex stripes under the ClipRect; (4) a light day (2 lectures) dangled at the card top over a dead void — the whole column incl. the now-line now centers as one unit (columnH = Σ mins×factor + seams). Golden probes at the real carousel size (313×553 @ Ahem) drove the fix; regression test "adjacent classes leave no phantom band; a gap run counts ONCE" (assert via the ` · h:mm` suffix — test locale is German, `Frei` ≠ `Free`). |
| Round 16a: home staleness + fake zeros + header overflow | `home_page.dart` (NextUpHomeCard, profile card), `padded_title.dart`, `profile_view.dart` | (1) the "hero updates after refresh" fix never worked: `_feed` was only re-read on init/resume while the campus path rewrites the ICS cache underneath it — now a `WebcalKeys.fetchedAt` stamp probe in `didChangeDependencies` (async, re-entrancy-guarded, stamp read BEFORE the ICS body so a racing refresh over-invalidates) re-reads via the live `SharedPreferencesAsync` fence; (2) `Student.empty` painted "Note (⌀): 0,0"/"0,0 LP" until profileReady — replaced by the existing loading placeholder; (3) PaddedTitle titles were inflexible → RenderFlex stripes on every home section header at wide German strings/large fonts → Flexible+ellipsis (test-proven non-vacuous); (4) dead `_relevantModulesTitleKey` GlobalKey plumbing deleted; (5) ECTS row got the Flexible treatment its sibling rows already had |
| Round 16b: now-line through gap bands + free-row clipping | `timetable_daily_view.dart`, `now_line_test.dart`, `timetable_seam_policy_test.dart`, `timetable_daily_view_tap_test.dart` | R15 gave gap rows the REAL gap duration but left the now-line feed with the placeholder's NOMINAL start — band `beginMin=phBegin, duration=realGap` matched wall minutes that its pixels don't cover: the now-line walked through "Frei" bands for up to 2 h (including while a lecture ran, then teleporting ~54px). Extracted `dayColumnBlocks()` as the single feed for painted rows AND the walk (gap rows get `prevEnd` as beginMin; test pins lecture/placeholder/lecture). Also: ghost "entfällt" card and free-gap chip had none of the R15 row protections → ClipRect+FittedBox recipe on the ghost, chip SUPPRESSED (not shrunk) under one text line-height; chip flip-below now clamped to the strip's BOTTOM edge (was top-only → clock label over the next row's text); running-chip compares `beginMin+_spanMin` (22:00→02:00 rows finally show it) |
| Round 16c: module page German captions + weekly/date dupes | `module_info_table` (table+cell models, sensible/generic views, appointment_cell), `l10n/strings_files.dart`, `l10n.dart`, new `l10n_parity_test.dart` + `module_info_table_test.dart` | the "hardcoded German" on the module page was NOT l10n — `Prüfungen (WS…)`/`Veranstaltungen` are CampusKIT-scraped TABLE CAPTIONS rendered verbatim: `ModuleInfoTable.localisedCaption` now maps the fixed caption set at render time (unknown captions pass through; favourite-toggle matching keeps the German caption on purpose; first b48 device pass caught KIT ALSO serving the term suffix on "Veranstaltungen (WS 26/27)" - the map now splits an optional (TERM) tail off EVERY caption); scraped appointment labels got `localisedDateLabel` ("Do, wöchentlich" → "Thu, weekly" in EN); the same table lists the weekly rule AND every expanded date — `prepare()` tags rule rows once (`isWeeklyRule`) and drops dated rows covered by a `weekday|time` rule key (Einzeltermine survive); full `_de`/`_en` key-set diff via test-visible tables: ZERO missing EN keys app-wide — remaining German on module pages is server content (titles, generic column heads), flagged not translated |
| Round 16d: non-PDF ILIAS materials + webview hardening | `ilias_manager.dart` (download gate), `ilias_page_view.dart`, `ilias_scraper.dart`, new `ilias_download_gate_test.dart` | tapping any zip/pptx/docx material was a dead end: navigation prevented + PDF magic-byte gate threw on the proved-session body + no DownloadListener → only "Download failed". New pure `extensionForDownloadBody`: PDF magic bytes → .pdf (in-app viewer unchanged), `text/html` refused (wall can never cache again), mapped lecture-material content types → real extension, else Content-Disposition filename fallback (rejects lying `.pdf` names and web-page extensions — the corrupt-pdf-cache class stays dead); delivery = share_plus system-viewer chooser + `ilias.savedToFiles` toast (PDFScreen is flutter_pdfview-only, pinning a zip would just relocate the dead end). Plus: whole save path wrapped (no more unobserved zone errors on I/O failure), wall-URL reload now restarts the handshake via the entry link instead of reloading the SSO wall, root-level course files parsed into the file list (seenUrls dedupe), `_onBack` mounted-guarded after the canGoBack round-trip |
| Round 16e: settings/files/geo/module-page layout + async lifetimes | `settings_page.dart`, `settings_provider.dart`, `block_container.dart`, `local_files_storage/**`, `geo/**`, `module_info_table_sensible.dart`, `appointment_cell.dart`, `exams_page.dart`, `grades_page.dart` | German ICS button trio (~430dp) pushed "Entfernen" off-card at DEFAULT scale → Wrap + own row; SettingRow titles inflexible → Flexible/ellipsis; dead `liquidAssEverywhere` pref + commented row + permanently-false GlassContainer branch deleted (no shim); pinned-files 4th text line past isThreeLine box → maxLines 1; two per-dialog TextEditingController leaks disposed in finally; files_cache delete handlers setState after dialog+loop awaits → mounted guards; PDFViewer's four platform callbacks setState after pop → guarded + self-shadowed `pages = pages` no-op actually stores pageCount now; module row's `mq.width*0.5` box + inflexible scraped Semester term pushed the favourite star off-screen → Expanded/Flexible; appointment cell stacks date/time in Expanded (250dp date lists were cut); room search: 61-char dependency-free accent fold (Dart has no NFD normalize — probed) certifies "cafe"→"KIT-Café" alias tier, one null aliasList entry no longer zeroes all 824 places, cold-open search page adopts the live directory when it lands (one-shot provider listener); exams retry button now reports failure like pull-to-refresh; grades pull-to-refresh finally CAN show an error (`scheduleFetchFailed`, since `cm.ready` is deliberately never cleared) |
| Round 16f: cross-isolate notification correctness | `ilias_watcher.dart`, `mei_notifications.dart`, `ilias_watcher_test.dart` (async-store harness + 2 new), new `notification_change_slot_test.dart` | IliasWatcher inverted to CLAIM-BEFORE-NOTIFY against the live SharedPreferencesAsync store (the legacy snapshot made the main-isolate agenda diff and the WorkManager poll each see the pre-other's seen-list → same announcement pushed twice; a claim-write failure aborts the run — delayed, never duplicated — and ids whose PUSH threw are un-claimed via live re-read+filter preserving "late, never lost"); heads-up ids 1000-1019 now derived per-push from minute bucket + per-process rotation (C63's epoch-ms seed "differing to practical certainty" confused seed inequality with id inequality — modulo-20 collisions across isolates silently replaced unopened pushes; pure bucket would collapse the watcher's back-to-back burst into one heads-up, hence the rotation); poll purge-race narrowed: live-URL probe moved directly in front of the changes/feedSource writes+notify, logout bails WITHOUT advancing the fingerprint (transition surfaces once later), notifyChange wrapped so its throw can't strand the fingerprint while changes persist (double-push next poll); merge input for DATA_webcalChanges reads live (stale snapshot could re-seed dismissed changes); device follow-up: the poll's synth CARRY-OVER re-injected the pre-dedupe block verbatim (reviving the double agenda rows the foreground paths filter) - carried block now runs through dropSignMeUpSynthCoveredByFeed against the fresh feed |
| Round 16g: session-death hardening + synth determinism/dedupe | `campus_manager.dart`, `kit_provider.dart`, `credentials_provider.dart`, `exam_list.dart`, `signmeup_manager.dart` (+ exam_list/signmeup tests) | logout/account-switch races closed: dropInFlightFetches now drops ALL five in-flight memos (a new login could JOIN the dead account's schedule/refetch/module chains — B's login persisted A's display name from A's parsed page) + resets the one-shot SignMeUp cold-retry; every `finally` memo clear is identity-bound (orphan chain can no longer null the NEW account's memo nor bump signMeUpGen and fake the agenda's handshake); _fetchScheduleInner/HTML-timetable/relevant-module writes got the teardown-epoch fences they lacked (post-logout re-seeding of purged DATA_student/DATA_timetableSrc/RMR + ready=true over the login form); logout sweep enumerates the LIVE async prefs store (keys first created by the poll isolate — token-bearing feed URL, change log — were invisible to the legacy snapshot and survived "none may survive"); foreground fingerprint/cache/changes reads switched to the live fence (stale snapshot merge base clobbered poll-merged CHANGED entries); favourite toggle treats the documented "Sitzung abgelaufen" 200 page as failure (was: optimistic star silently never reached the server); fuzzyFindHierarchicTableRowSimilarTo got the sibling's strict `>` + accept threshold (score-0 garbage used to return moduleRows[0]); EXAMLIST empty state must be PROVEN (table exists, zero ≥2-td rows) — missing table or id-reflow now runs the surface-broken funnel instead of "Keine Prüfungen gefunden" with a dead badge; SignMeUp synth block: content-keyed UIDs + data-derived DTSTAMP (byte-identical refetches no-op the cache/alarm re-arm, exports update instead of duplicating) and new dropSignMeUpSynthCoveredByFeed: synthetic VEVENTs the feed already carries (same weekday+time, normalized title containment either direction — "(Tutorial - X)"≡"(X)") are suppressed while synth-only events (AdvMath, MINT) survive — kills the b47 double agenda rows |
| Round 16h: agenda truth + deep-link intent + logout stack purge | `agenda_page.dart`, `webcal.dart` (IcsChange.titleKey), `notification_deep_links.dart`, `kit_nav_container.dart`, new `agenda_page_test.dart`, deep-links/webcal tests | today-card empty state named a date AFTER tomorrow whenever tomorrow had lectures (tomorrow fallback sat in the else of the after-tomorrow list) — precedence reversed; CHANGED-band row emphasis keyed on start-time alone → a room change for one 14:00 lecture dotted + printed "old→new room" on an UNRELATED parallel 14:00 lecture (walk-to-wrong-room hazard): per-row resolution now requires titleKey match (course-id prefix/lecturer tail folded, same family as the feed-clone dedupe) — added/removed/moved deltas now get their promised dots too (per-row whole-change loop replaces the kind-limited key sets); " → HS 1" arrow only when there was an old room; deep links stopped dropping their intent on an already-open agenda (AgendaResync carries scrollToToday/highlightChanges, pulse RE-KEYED via _pulseSeq so repeat taps visibly re-sweep) and a deadline tap on an open exams page now actually refreshes; session death pops every pushed page (stale exam lists/ILIAS content no longer sit over the login form, ActivePages keys self-clean via popped futures); KITNavContainer revokes shellGone through a generation token so a fast profileReady flap can't kill deep links until next login; 3-row cuts in exams/SignMeUp sections get the "+N mehr" caption; section-header/pending-row Texts Expanded (stripes at 2.0x gone); webcal fixture count pinned exact (94) |
| Round 17: dead webcal token self-heal + honest offline banner | `kit_login_manager.dart` (`isNetworkError`), `campus_manager.dart` (`feedFromResponse` gate, re-provision retry, `offlineSuspected`), `mei_failure_banner.dart`, `strings_notifs.dart`, new `offline_feed_test.dart` | live device: feed stale 188 h while modules/exams worked - `_ensureWebcalUrl` only provisions when the stored key is EMPTY, so a KIT-retired token could NEVER heal (and the exact server status is undiagnosable from a release build: no creds on the laptop, prefs unreadable). Every non-calendar response on the stored URL now drops it, re-provisions from webcal.asp once and refetches; the source-switch guard reseeds the fingerprint, so rotation heals without a CHANGED flood. Second live finding: an airplane-mode spell pinned `timetableSurfaceBroken` ("KIT site changed?") because socket deaths walked into the markup funnel via fetchTimetable's retry loop and exams' catch-all - `isNetworkError` (Socket/Handshake/Http/Client/Timeout) now short-circuits BOTH funnels to a blue-grey `notifs.bannerOffline` row (checked BEFORE the surface flags: they may hold yesterday's connected verdict), cleared by any fetch that reaches KIT; surface flags untouched while offline. Gate + classification pinned in `offline_feed_test.dart` (5 cases). Device b49 proved the offline banner + exams funnel live, but the reprovision did NOT heal the feed and a release build could not say why - added `WebcalKeys.diag`: the fetch funnel persists the last failure reason ("feed 403/512", "reprovision: no token link ...", "threw: SocketException") and the agenda stale footer appends it verbatim, cleared on success; `\_rerenderFromCache` now RE-READS fetchedAt/diag instead of carrying them (it kept the stale footer lit forever after a healing fetch). FOOTPRINT OF THE FIRST SELF-HEAL SHIP: b49/b50 pulls never healed and the footer diag stayed EMPTY until breadcrumbs were added - `fence: logout/reprov mid-fetch` finally proved the feed fetch was SUCCEEDING all along: the account fence's `urlLive != url` clause (written when a URL swap could only mean logout) rejected every re-provisioned body, and boot-chain + pull-chain each poisoned the other's fence by swapping the stored URL mid-flight - stale FOREVER by design. Fence now keys on ACCOUNT (epoch + key-empty) only, and fetchWebcalTimetable is single-flight (dropped by dropInFlightFetches on logout like the other memos). Lesson: a self-heal path must be tested against the safety fences of the path it heals, and release diagnostics belong in prefs, not prints |
| Round 18: home grid = ABSOLUTE TIME GRID (calendar ruler) + overlap lanes | `now_line.dart` full rewrite (`TimeAxis`, `weekTimeAxis`, `axisPxPerMin`, linear `nowLineY`, `blockRect`, `overlapClusters`, `packLanes`; deleted dayColumnHeights/weekPxPerMin/dayColumnBlocks/dayColumnSeams/gap-cap/gap-floor/content-floor), `timetable_daily_view.dart` Positioned stack, `timetable_weekly_view.dart` axis prepass, `now_line_test.dart` rewrite + new `timetable_grid_pipeline_test.dart` (deleted `timetable_seam_policy_test.dart`) | every earlier row-stack re-flowed each day on its own (fit factor, centering, 40-min folded gap rows) so the SAME wall time sat at different pixels per page - "not consistent / not aligned / huge gap" (11.+12.11 reports). Now ONE wall window per week (earliest content begin..latest end rounded to full hours, `weekTimeAxis`) at ONE px/min: every lecture is `Positioned(top:(begin-axis)*px, height:dur*px)` - 09:45 lands at the same y on Monday and Friday, a 90-min block is the same height everywhere, free time is real space with the "Free · h:mm" chip centred in its true band (suppressed under one text line). Card height = range*px (min 320, capped); no per-day trimming. Overlaps (Friday 13:11: 08:00 tut + 09:00 Seminar Block 1/3 **09:00-17:00** + 09:45 tut) get the classic calendar lane packing: transitive-overlap clusters, greedy first-free-lane, width/n offset lane/n - device shot pre-fix showed them printing ink on ink ("09:45" straight into "Block 1/3"); seams + gap chips now sit at CLUSTER ends (a per-block line would cut a side-by-side neighbour mid-box). Standalone fallback (tests/detail): axis+px derived from own day. HOUR GRIDLINES (follow-up same day, "separate bar between those times"): one faint bar (dividerColor @35%) at EVERY full hour of the shared axis - the axis edges being whole hours, these are exactly the :00 marks; drawn BELOW event rows/ghosts, which paint `cardColor` behind their text, so the lines own the free bands and vanish behind events, the gap chip masking its own line too - paper-agenda convention. RAIL + TITLE-FIRST layout (11.20 report "Basics of Manufacturing cut off"; detail sheet ground truth: the 09:00-17:00 Seminar IC block repeats weekly, Basics is 14:00-15:30 titled "Basics of Manufacturing Technology (V), Schulze"): THREE stacked causes. (1) The 8-h seminar transitively overlaps tutorials/lunch/basics, so the 50/50 lane split squeezed every row to half width - new `placeCluster`: rows >= `blockEventMinMinutes` become RAILS (longest outermost right, 0.30/k each, 0.70 left region; first attempt's 180 threshold wrongly made Basics itself a rail - caught by the test, raised to 240; 0.45 rails still ellipsised on the 316dp card - 0.30). A row's right edge = left edge of the INNERMOST overlapped rail (largest rail index, not a count - counting let a row overlapping only the inner rail drive through the outer band; pair-sweep test). (2) The 90-min box's line budget always reserved the place line, leaving the 44-char title ONE ellipsised line - `TimetableDailyView._row` now MEASURES the title (TextPainter maxLines 1): no one-line fit + room for two -> title claims line 2 and the room (itself only ellipsisable) yields; short titles keep their room untouched. (3) Card chrome: the px budget now subtracts the BlockContainer's 2x`cardGutter` gutters and adds them back to the carousel height, so a full column no longer loses its bottom minutes to the rounded frame. Device-verified 0.8.3+55 (rail20/final20 shots): Nov 20 shows the FULL Basics title across two lines from the left edge, seminar in its right rail, hour bars intact; widget test `timetable_row_text_test.dart` pins all three on a simulated 306dp card. Verified on device 0.8.3+53/55: Wed chip "Free · 2:00" at true 9:30-11:30 width, 17:32 now-line on the shared ruler, Thursday 08:00/09:45/11:30/13:00 at identical offsets to Wednesday, Friday renders the 8-h seminar as a right-column block (tap detail: Time 09:00-17:00 - the day genuinely has no gap; the old "huge gap" was the folded-row artifact), 398 tests green |
| Round 19: home section = MENSA MENU (Studierendenwerk Karlsruhe) | NEW `lib/mensa/` (models/mensa_models.dart, mensa_html_parser.dart, mensa_manager.dart, views/mensa_today_card.dart), NEW `test/mensa_test.dart` + fixture `test/fixtures/mensa_adenauerring_kw46.html`, NEW `lib/l10n/strings_mensa.dart` (+l10n registry + parity slice), home_page.dart section (settings-gated), kit_provider.dart (`mensa` field, boot kick behind `FLUTTER_TEST`, pull-refresh hook UNAWAITED), settings showMensa toggle | user request "section that shows menu for each day" — SW KA publishes no JSON/XML API (official json_interface auth-gated since 04.2023, api.* hosts don't resolve); the maintainable source is the site's OWN a11y view `mensa_<id>/?view=ok&STYLE=popup_plain&c=<id>&p=1&kw=<isoWeek>` (75 KB server-rendered vs 520 KB page; one price class = Studierende, `p=` ignored by that view - verified live; recipe battle-tested by kronos MensaApp + meyfa/ka-mensa-fetch for years, both user-supplied as prior art). `?kw=` MUST be passed: without it the page serves only the REMAINDER of the week (measured: Thu page ≠ Wed page sizes). Parser: h1 day stamps ("Mi 11.11." / EN twin) each followed by a lines-table of 2-cell rows, meal rows exactly 3 cells `[classifier] | name (additives) | price`; <br>-runs split (a "Linie 1Gut & Günstig" glue bug caught by test); year-less stamps resolve to the candidate CLOSEST to the fetch date (Dec stamps fetched Jan 1 = LAST year - ISO weeks 1-3 straddle the new year); SW legend quirk pinned in tests: VEG=vegetarian, VG=vegan (cheese Gnocchi [VEG], plain Krautsalat [VG]). Manager mirrors KITTopographyManager (public feed, self-contained errors, restore-then-refresh) + CampusManager mechanics (single-flight, response gate, prefs diag trail); keys `MENSA_*` DELIBERATELY NOT `DATA_*` - logout sweep deletes only DATA_/RMR /module_cache_/MIL (verified) so the menu survives logout on shared devices; opt-out honored at BOTH layers (settings hides the card, `_fetch` re-reads PREF_showingMensa - hidden = zero third-party GETs, review L1). Failures NEVER touch campusManager surface/offline flags (SW KA is not KIT - no "KIT site changed?" poisoning). ADVERSARIAL REVIEW HARVEST (4-lens pool): restore() no-ops after any successful fetch (late restore used to reseed the OLD cache over fresh days); fetched pages are verified to serve the REQUESTED ISO week before the fence lies about it (else a served-remainder page would label the wrong week fresh 3 h and show "closed" on a serving weekday); spinner only while `isFetching` (fetchedAt==null spun FOREVER on fresh installs in Semesterferien); fetchWeek reports Future<bool> so the card's retry/refresh toasts actually fire (they were dead code); stale closed-day admits staleness in its footer (Friday cache + dead Monday ≠ "no meals today" truth); pull-refresh unawaits mensa (a hung sw-ka must not extend the spinner 15 s after campus finished); meal rows go TWO-LINE at textScale>=1.4x (one-line shrank names to ~4 readable glyphs at 2.0x); midnight NowClock.dateOfDay flip resets today/tomorrow; future-skewed fetchedAt never counts as fresh. Device-verified 0.8.4+56: live 40-dish Wednesday menu, badges/prices correct, +28-more collapse, Today/Tomorrow flip (Thu 12.11 different dishes), EN strings; 425 tests green (26 mensa: fixture parser with EXACT counts, year-edge isoWeek, week-fence refusal, opt-out traffic stop, restore-clobber, outcome semantics, 5 widget states) |
| Round 20: mensa UX audit + EN menu translation | NEW `lib/mensa/mensa_translate.dart` + `test/mensa_translate_test.dart`; mensa_html_parser.dart parseWeek rewrite; mensa_manager.dart (translate field), mensa_today_card.dart (tr + Tooltip), kit_provider.dart (mensa relays notifyListeners) | user request "visual/UX check + english menu". AUDIT (device, DE+EN, dark+light, font 1.0/1.4/2.0): collapsed/expanded/weekend/stale states all render clean, no overflow stripes at 2.0x, l10n maps verified both directions (an apparent EN-UI-"show less"-in-German and mixed DE/EN header were my frame reads during a cache swap + user's own language toggle, not bugs). THE REAL CATCH (logcat probe + on-screen diag build): the parser paired every h1 day stamp with the next table it found - live in the midnight window SW rolls stamps off the page, and a stamp whose table vanished filed the NEXT day's dishes under itself (cachedDays [11,12,13] showing Friday's menu under "today"); duplicate same-date stamps (lunch+dinner) also produced two entries per day and dayFor served the first, incomplete one. parseWeek is now a strict document-order walk over h1/table: a stamp claims only the first table that follows before any newer stamp opens (no table = claims nothing), and same-date tables MERGE into one entry - two regression tests pin exactly those shapes. TRANSLATION: no offline dish dictionary exists, so gtx (Google's keyless web endpoint, the translate-site UI itself calls) behind `MensaTranslate`: per-dish-name PERSISTED cache (MENSA_trx_en, FIFO 900 - translated once per install, then fully offline), polite 2-in-flight queue, per-name session-fail memory (429/blocked = German stays, no retry storm), ONLY fires while L10n.isEnglish (DE users: zero third-party traffic), only public menu text ever leaves the device; translated names keep a Tooltip with the German original (the printed board speaks German); line names + subs translated too. kit_provider relays mensa notifications (translate results repaint the card the moment they land; was boot-notify-only). New tests: 6 service (one-shot+notify, offline cache reuse, DE zero-traffic, fail-no-storm, garbage-not-a-name, ≤2 concurrent) + EN widget (names + tooltip originals) + 2 parser pairing regressions; pumpCard gains extraPrefs + translate 503 stub; suite 434 green. Device-verified live 0.8.4+56: Thursday menu fully English on first load ("Lentil curry with sweet potatoes and fragrant rice", "Line 2 · Vegan line", "Good & cheap"), long-press tooltip prints the Sellerie-Knusperschnitzel German original |

## Library (Anny) — Round 21: KIT UB seat booking end-to-end

| Round 21: library seat booking via **Anny API** (KITUB) | NEW `lib/library/` (anny_api.dart, anny_auth.dart, anny_manager.dart, library_page.dart, library_today_card.dart) + tests (anny_api/anny_auth/anny_manager incl. card widgets) + `strings_library.dart` (+registry+parity), home section + settings toggle, kit_provider field/kick/pull-refresh, `LibraryNotifications` check-in alarms (W5) | headless SSO: auth.anny.eu/login/sso → 409+`x-inertia-location` (that IS the success shape) → idp.scc.kit.edu form (**decoy form** aimed at stage.scc — the real action contains `/idp/` AFTER HTML-entity unescaping) → callback sets `anny_shop_jwt` (~50 min). API dialect ground truth = `audit/anny_api.md` captures: anonymous browse needs `accept: application/vnd.api+json` + `x-app-key: anny_shop` + Mozilla UA (403 without); intervals/start + availability/start-dates answer **bare flat arrays**, not JSON:API; `unavailability_type:"none"` = bookable (24h pre-open slots report available:true — web shows them too, faithful, NOT a bug); booking = cart flow POST order/bookings (Bearer, `add_ons_by_service:{svc:[[]]}`) → POST /order?visit_token=ALVO&oid&oat, quota lock released ONLY via GET /order/delete-all on checkout failure; cancel = GET /bookings/{id}/cancel?access_token=**!TIX-code**; the web's visible uuid path 401s — real user uuid comes from a Bearer-scoped bookings include, session proof = count-unseen 200 |
| "  ″ wall-time contract (THE bug class of this round) | `_isoBerlin` + `_parseT` in anny_api.dart | AnnySlot/AnnyBooking times are Berlin **WALL** times: `_isoBerlin` sends wall fields AS-IS stamped with the date's offset (old code treated wall as UTC and ADDED the offset → every booked slot would go out 1 h winter / 2 h summer late; UTC inputs still convert). `_parseT(dayOnly)` keys start-dates by the **date prefix as written** — live entries are `2026-11-13T00:00:00+01:00` instants and `DateTime.parse().year/.day` are UTC-shifted → whole day strip a day early. Both pinned by tests (WALL cartAdd body byte = captured `10:00:00+01:00`); suite green under TZ=America/New_York/Asia/Tokyo/America_São_Paulo (relative-tile fixtures derive offsets from the date, never the host TZ) |
| "  ″ test-fixture hazard (tool gap) | test/anny_api_test.dart | dart `format` happily parses **unterminated string literals** (next literal's opening quote closes them): three fixtures shipped as syntactically-valid Dart but broken JSON, and `jsonDecode` failure inside `_send`'s try{} **returns 200-with-empty-map**, so the suite was red-on-arrival while every parse looked like a lib bug. Validate every fixture with a JSON parser, not just analyze; `// legacy 'available'`-style apostrophes in inter-literal comments also poison naive line-based extractors |
| "  ″ device E2E (anonymous scope, live) | Pixel 3, release 0.8.4+56 | home card "0 seats free" + CTA; library page all 7 rooms with live 0/138·0/72·0/1; sheet: capacity + "up to 3 days ahead", Fri day-switch refetches, 23:30 chip greyed (off_schedule, matches live), durations 30 min–5 h straight from service min/max/interval; confirm sheet; one cosmetic fix on device (confirm line printed start twice → now `Fri, 13.11. · 10:00–11:00 · 60 min`). Auth scope (real SSO + booking + check-in alarm + cancel) requires the keychain password → runs with the user present |
| "  ″ audit-fix batch (three-lens fleet review, all verified in-code) | commit 138b705: manager/api/auth/pages/notifications/l10n + 10 new tests | lifecycle: global logout now calls `anny.signOut()` + prefs sweep extended to `ANN_*`; signOut also removes email/first/last and wipes `ANNY_pass` (was: account+PII survived logout on a shared device). At-rest: prefs hold only a `pending` marker, never the JWT/alvo; `_silentReauth` re-mints in memory; boot SCRUBS legacy real tokens. `reauthFailed` makes `signedIn` false after a failed re-mint (dead sessions must offer sign-in). Notifications: check-in ping posts on `mei_library` (the `channel` arg reached `_zoned` for the first time — before, every ping landed on "Deadlines"), text prints the start+15 DEADLINE, payload `library:checkin` registered → tap deep-links the library page, teardownEpoch fence added. Races: fav-slots single-flight keyed by slug; `book()` gate set synchronously (cancel pattern); room-sheet generation counter + mounted guards. Honesty: empty catalog 200 never blanks the cache (reports markup), freeNow tail past last selectable start = last tile's count, slot-fetch failure renders loadFailed+retry not fake "Closed", book names validated in-sheet (identity failure was kind=auth → sign-in dead-end), just-taken pops+refetches the strip. Hardening: every SSO hop (incl. the minting loop's first hop) allowlisted https `*.{anny.eu,kit.edu}`, credentials form pinned EXACTLY `idp.scc.kit.edu` (was *.kit.edu wildcard), `_detail` scrubs URL/token-shaped text; PII scrubbed from audit doc + fixtures (alice/BB000000000). UX: tooltips+star target, card footer "Stand HH:MM", lapsed banner hidden past window, Cupertino sign-in dialog with controllers disposed before signIn (values captured first — pass.clear() in finally BEFORE reading was the near-miss) |
| "  ″ post-fix regression hunt (second pass over the fix batch itself) | commit 5f6c984 | the hunt found what the batch's own verification missed: (a) the fav join-key fix was HALF a fix — setFav(A)->setFav(B) mid-flight now correctly starts B's fetch, but A's LATER reply still overwrote favSlots; the closure must drop replies whose captured slug != favSlug (test forces exactly that interleaving). (b) _guardHost covered _follow + the minting loop but NOT the step-5 SAML consume POST, whose URL arrives in the IdP page body — the assertion was POSTed off-allowlist before any guard ran; guard the parsed target BEFORE the POST. (c) my boot() scrub removed ANN_alvo/uuid BEFORE reading them — restored sessions lost visitToken/uuid (read locals first). (d) cancel() had no try/finally around the isBooking gate (_authed swallows API errors, so the throw path is narrow, but any escape locked book+cancel for the session) | Lesson: after fixing a race, test the OTHER interleaving of the same actors (join-key fixed the start side, not the completion side) | 
| "  ″ device re-check (anonymous scope, fixed build) | Pixel 3, release 0.8.5+58 | card: counts + new "As of HH:MM" footer + login CTA; page: all 7 rooms + star switch A→B moves the single favorite; sheet: day strip Thu–Sun, 15-min slot grid with past starts grey (03:00 dim vs 03:15 bright at 03:09 — live intervals honest), RAPID 3-day tapping settles on the visible day's own slots (generation guard holds on device); Cupertino sign-in dialog renders centered with Cancel/Log-in; empty-username "Log in" closes without any SSO traffic. Auth scope (booking/check-in/cancel) stays user-present only |

## Build

```sh
export PATH=/home/phan/dev/flutter/bin:$PATH   # Flutter 3.x, JDK 17+
flutter pub get
flutter test                 # all suites; live probes skip without credentials
flutter build apk --release  # signed via android/key.properties
```

### Signing (one-time per machine)

`android/key.properties` + `android/mei-release.jks` are gitignored. Recreate:

```sh
keytool -genkeypair -storetype PKCS12 -keystore android/mei-release.jks \
  -alias mei-cockpit -keyalg RSA -keysize 2048 -validity 10000 \
  -dname "CN=MEI Cockpit, OU=Personal, O=student, L=Karlsruhe, C=DE"
# then key.properties: storeFile/storePassword/keyAlias/keyPassword
```

Losing the keystore means uninstall/reinstall (signature mismatch).

### Remote builds (Trinity HPC, optional)

A slurm job (name MUST start with `staging-` for the ais-cpu partition) runs
`kbagent.sh`: polls `/beegfs/home/a.phan/kbtasks/*.task`, executes each serially,
streams to `kbtasks/<name>.out`, renames to `kbout/<name>.out.<rc>` on finish,
logs TASK-BEGIN/END to `kblobs/`. Submit: `sbatch` an sb-file with the agent
loop (see `git log` for 8519149); drop tasks as base64-over-ssh.

Node constraints learned the hard way (all worked around inside the task
scripts, `/dev/shm/aphan/` layout):
- compute nodes: **glibc 2.17 (CentOS 7)** — Flutter's dart/gen_snapshot binaries need ≥2.18 → run builds inside
  `apptainer exec --bind /dev/shm/aphan --bind $HOME --bind /beegfs /dev/shm/aphan/u24`
  (Ubuntu 24.04 sandbox, glibc 2.39; `apptainer build --sandbox` docker://ubuntu:24.04, ~1 min)
- **Dart TLS is dead from this egress** (middlebox kills Dart's handshake to pub.dev AND the flutter-io mirror;
  curl + Java TLS are fine). Gradle/Maven therefore fetch natively; pub needs `pubrelay.py`
  (in `kbfiles/`): plain-HTTP shim on :8642, Python TLS egress, `PUB_HOSTED_URL=http://127.0.0.1:8642`.
  CAVEATS: the 3.6-safe port dropped `content-encoding` forwarding (gzip bodies misparse → resolution hangs —
  add the header back before trusting it) and re-TLS-handshakes per request (~3 s × hundreds = slow cold path).
  Warm alternative that works today: rsync `~/.pub-cache` → node `/dev/shm/aphan/pubcache` and build
  `--offline`; flutter's SDK self-bootstrap for `packages/flutter` ignores `--offline` (first-run only —
  one online run via relay fixes it permanently)
- JDK: Adoptium 21 tarball on tmpfs; keystore: copy `android/{key.properties,mei-release.jks}`
  from `kbfiles/` into the project tree (rsync excludes them via .gitignore)
- NEVER `pkill -f <pattern>` on the node — the ssh wrapper's own argv matches and kills itself; use
  `pkill -x <comm>` or kill by exact PID. An orphans `starter-suid` deadlocks every later apptainer start →
  `pkill -x starter-suid` to recover.

Warm incremental on the NUC is ~80 s; prefer local builds for single iterations and the cluster only to keep
the laptop responsive during long/batch builds.

## Sideload

```sh
adb install -r build/app/outputs/flutter-apk/app-release.apk
```

Login on the device via UI. If automating with `adb input text`, wrap the
password in **single quotes** — `$` and `?` get eaten by the shell otherwise.

## Persistent state (SharedPreferences)

| Key | Meaning |
|---|---|
| `DATA_webcalUrl` | provisioned WebCal token URL (delete to re-provision) |
| `DATA_webcalIcsCache` | last good ICS body (feeds agenda + diff base) |
| `DATA_webcalFingerprint` | occurrence-set fingerprint |
| `DATA_webcalChanges` | JSON of pending timetable deltas (CHANGED band) |
| `DATA_webcalFeedSource` | URL the cache/fingerprint belong to (baseline reseeds on switch) |
| `DATA_webcalIcsCache` + `DATA_personalIcs`/`Url` | merged cache embeds the personal VEVENT block; URL is re-fetched quietly ≤1×/30 min per session |
| `DATA_iliasCardCache` | last ILIAS unread/announcement snapshot (agenda card paints instantly; wiped at logout) |
| `DATA_iliasWatchSeen` | ILIAS announcement ids already pushed (age-ordered JSON, cap 300; wiped at logout) |
| `DATA_examReminderSnapshot` | JSON of exam titles/registration/windows at last reminder rebuild; startup replays it so reminders survive cold starts (logout-swept) |

The six `DATA_webcal*` keys are constants on `WebcalKeys`
(`timetable/models/webcal.dart`) — background poll isolate and app share
them; `mei_notifications` keeps its own literals by design (isolate must
not import app state).

Killing everything: app settings → clear storage, or log out (credentials are
in secure storage; ILIAS/campus sessions are cookie-only).

## Personal ICS feed (laptop side)

`systemctl --user cat kit-ics` serves `~/.local/share/kit-ics/` on
`127.0.0.1:8080` (enabled at login). The phone reaches it **only** while the
USB cable is attached, via `adb reverse tcp:8080 tcp:8080` — re-run that
after every reconnect (adb drops reverses). The app survives any of this
dying: personal events live in the merged ICS cache; the URL fetch only
topps up. Update the calendar = overwrite the file in the served dir (same
name keeps the phone URL working).

## Live dev probes

`test/live_login_test.dart`, `test/ilias_live_test.dart` hit the real portals
when `/tmp/.mei_c` exists (one line: `user password`). They print what they
found and are the fastest way to tell "my parser broke" from "KIT changed the
markup". Everything else in `flutter test` is offline/hermetic.

## Dev tablet: rooted Fire HD 8 (LineageOS)

Fire HD 8 via the NUC's adb (`nuc:/home/abspuser/tools/platform-tools/adb -s
G090MJ05736402TB`); magisk root is available for `su -c` work. Same APK as
the Pixel; `audit/drive.py fire shot|dump|tapxy|swipe|launch` drives it
(artifacts in `audit/fire/`). `ensure_foreground()` aborts (exit 3) unless
KA.Uni is the resumed activity — taps never land in someone else's app.

- **Never poke `settings put system user_rotation` remotely.** On this
  Lineage 14.1 build the Flutter view keeps a stale display transform
  after a remote rotation flip: appbar and nav pill keep working, but ALL
  taps AND scrolling inside the home scrollable silently go dead while
  uiautomator coordinates still look right. Recovery is
  `am force-stop com.dandemidov.kit_mobile` + relaunch — no reboot needed.
  (Cost me an entire hunt through carousel hit-stacking before `am
  force-stop` proved the app was innocent.)
- After a clean start the drill is at phone parity: grid-block tap opens
  the full-page route with flutter_map tiles loaded over WiFi, glass sheet
  (title/ID/Ort/Time), Back-tap dismiss.
- `adb shell input tap` (InputManager injection) is sufficient; rooted
  sendevent on `/dev/input/event3` exists as fallback, unneeded.
- Day-rollover tests: `su -c "settings put global auto_time 0; date
  11020930"` then restore with `auto_time 1`.
- Horizontal drag over the carousel never pages (the parent vertical
  scroll wins the arena); navigation is ghost-edge taps -> animateToPage,
  verified working on the tablet.

## Failure states

`MeiFailureBanner` on home distinguishes, loudly:

- **session dead** — auto-recovered silently (SSO re-run).
- **bot challenge algorithm changed** — cascampus `.asp` returned an
  unsolvable challenge; `botChallengeAlgorithmChanged`.
- **markup changed** — a page fetched fine (200) but the parser found nothing
  (`timetableSurfaceBroken` / `examsSurfaceBroken`): update the parser, don't
  re-login.
- **webcal feed silently stale** — live device 10.11: agenda footer said
  `No update since 188 h` while modules/exams/ILIAS all fetched fine and a
  pull-to-refresh on the agenda changed nothing. So `fetchWebcalTimetable`
  has been failing (or never writing) for ~8 days with NO banner:
  `DATA_webcalFetchedAt` only moves on success, and home's "Last updated"
  reads `lastModuleFetchTime`, not the webcal stamp — the two stamps disagree
  by days and nothing but the agenda footer notices. Suspect the feed URL /
  its token expiring server-side (the personal-feed pattern) or a silent
  non-200. Reproduce by logging the status in `fetchWebcalTimetable` and
  reading `DATA_webcalFetchedAt` cold; fix means surfacing it (banner or
  badge) the way `examsSurfaceBroken` does, not just the footer.

## ILIAS scraping notes

- Login is SAML: campus TGC → `Shibboleth.sso/SAML2/POST` autoform → PHPSESSID.
  `http` follows it; plain `requests` cannot (JS auto-POST) — use the Dart path.
- ILIAS emits a duplicated `Content-Type` header; always decode via
  `IliasManager.bodyOf`.
- Folder/course listings only render children in the *first* repository view
  of a session context; the working entry point is
  `ilias.php?baseClass=ilrepositorygui&cmdClass=ilobjcoursegui&ref_id=…`
  (see `fetchCourseFiles`). Announcements: `ul.ilTimeline` panels on the
  personal news page — do not scrape every anchor (nav chrome pollutes).

## Release checklist

1. `flutter test` green (live probes included).
2. `flutter analyze` — no errors (infos are pre-existing upstream style).
3. Bump `versionName`/`versionCode` (android/app/build.gradle defaults).
4. `flutter build apk --release`, `adb install -r`, log in, check agenda CHANGED
   band + exams badge, then let it idle one WorkManager cycle (~30 min) and
   confirm the poll leaves `DATA_webcalChanges` untouched (no false CHANGED).

## Wave b49+b50 post-mortem: the stale-FOREVER fence (0.8.2+50)

Symptom: agenda pinned "as of 190 h", self-heal never healed. Root cause
chain, three layers deep, each fix exposing the next:

1. Dead webcal token → 403/HTML → `feed==null` path silently returned;
   now: purge + re-provision via the Activate-webcal page form (login
   page only carries the tguid; token URL is POST-gated - `bootTguid`
   must run first or the page is empty).
2. `_ensureWebcalUrl` returned the old stored URL whenever the stored
   string was non-empty - a DEAD token is also non-empty. Dead-token
   detection = one GET of the stored URL; HTML/4xx body means dead
   (KIT answers a live token with `text/calendar` even when the term is
   empty, verified with curl).
3. THE actual staleness bug: post-parse fence `urlLive != url`. Two
   chains (schedule boot + agenda pull) each re-provision the token;
   chain A parsed old-URL body, chain B swapped stored URL, A's fence
   saw `urlLive != url`, rejected its own healthy parse - and B then
   failed the same way against A's swap. Every healed feed vetoed;
   fetchedAt never updated; stale forever. Live footer: `stale-feed`,
   diag `fence ... key:present`.

Fix: fence on ACCOUNT, not URL: `epoch != _teardownEpoch` only
(`wipeAccountMemory` bumps synchronously before logout's async sweep,
so epoch is the complete signal). A `SharedPreferencesAsync().getString`
probe of the webcal URL key returns NULL in-process even right after
legacy writes (confirmed `got=null` while a healthy feed parsed; the
async API and legacy store disagree for this key on this device -
fences on that handshake are permanent vetoes). Diag writes compose
state SYNCHRONOUSLY before any await (first fence diag printed
"present" because the await let re-provision repopulate between eval
and report) and `null` must not fall into the empty/present ternary.

Verified 10.11: after boot chain, footer `As of 11:04`, new lecture
PDFs, MSE exam-registration card appeared; exams-brief banner from the
boot race cleared on first refresh; exam sheet renders full list.

Diagnostic footer (`As of <stamp>`) + `WebcalKeys.diag` kept until the
next stale-scare proves them dead weight - then cut.

## Wave b51: one rhythm for the whole week (0.8.3+51)

Complaint: home strip "sometimes huge gaps, sometimes cramped, blocks
placed inconsistently". Culprit: R15 per-day fitting - every carousel page
chose its OWN px/min from [0.3, 0.9] to fill the 742px viewport AND the
column centred vertically (`Alignment.centerLeft`). A light day therefore
rendered at 0.9 centred mid-card while the neighbour day squashed to 0.35
flush: same lecture, different height, different y - and 3h voids scaled
up to 160px of dead band.

New model (`logic/now_line.dart`, pure): `weekPxPerMin` picks ONE px/min
from the BUSIEST weekday (gaps count folded at 40 min via `dayEffort`),
`dayColumnHeights` pays every row: content floored at 48px (never a
text smear), free rows folded at 40-min-worth (chip still names the real
gap) with honest small gaps untouched below it, and a uniform shrink pass
as the only overflow route (never a clip/stripe). Column is TOP-anchored
like every calendar: 08:00 sits at the same pixel on every page; a light
day simply ends early. Now-line walks the SAME height list (minutes
interpolate per row), keeping painted == measured. `dayColumnFactor` and
vertical centring are gone.

`TimetableDailyView.dayRows`/`blocksFor` are static now (weekly pre-pass
feeds the scale picker with the same occurrence-filtered geometry the
pages render). Tests: floor/cap/uniform-fit/busiest-decides/equal-durations-
equal-pixels + seam-policy walk updated to `heights:`.

## Wave b52: content-sized cards, honest floor, chip-only now-label (0.8.3+52)

b51 fixed the SCALE but two inconsistencies survived on-device:

1. BOTTOMLESS CARDS: the carousel kept the old fixed 742px frame while
   top-anchoring made light days end early - today's card was ~45% content,
   neighbour days fuller ("big gaps", second report). The card is now as
   tall as the WEEK'S TALLEST day column (clamped [320, cap]); the weekend
   /free-day placeholders lost their screen-relative padding (Center +
   min-size Column) so a short card can never stripe them.
2. SHRUNK INDENTED ROWS: the content floor (48) sat BELOW a row's natural
   time+title+pad height (~52) - those rows FittedBox-scaled their whole
   subtree: smaller text, visually indented (lunch row). The floor is now
   text-scale-adapted and ≥ that sum everywhere (weekly computes it per
   build, passes it to every day view AND the tallest-card pre-pass): a
   floor row renders at scale 1.0 flush-left like every other row.
3. NOW-LABEL vs RUNNING CHIP: the "running · until HH:MM" chip exists for
   exactly as long as the line is inside the row, so the painter's own
   HH:MM label could only ever collide with it (old <40px band missed
   lines below the time line; measured "12:39" straight on
   "running · until 13:00"). Label is skipped for content rows entirely
   now; gap rows and seam snaps keep it (they carry no chip).

## Wave R22: full-repo sweep integration (0.8.5+59)

11-subsystem review pool + 6 cross-cutting lenses, adversarially verified;
this batch integrates the survivors. 507 tests green, no new analyzer
warnings (the one resetForTest visible-for-testing warning predates it).

- cascampus: red "KIT site changed" banner only ever cleared by the NEXT
  solved 503 - one interstitial without a seed pinned it for the whole
  process (across logouts); now any healthy cascampus page disproves it.
- signmeup: procedures/meta fetches left the bare-get outside any try ->
  offline throw REJECTED forceRefetchEverything instead of the contract's
  false; wall-clock guard: free-text DATE descriptions ("12.04 - 30.04")
  matched the dd.MM sweep and minted phantom 02:00 weekly tutorials.
- exams: self-heal lacked !offlineSuspected -> unthrottled offline retry
  storm on every rebuild.
- agenda: midnight day-cross rerender never consumed stale deltas (home
  badge stayed lit for changes that render nowhere); same-`when` room
  re-edits walked to the stale intermediate (isAfter can't tie-break -
  ties now resolve stored-order-last); ILIAS prefs write re-checks the
  teardown epoch AFTER its own awaits (logout purge double).
- webcal: EXDATE matched raw strings - UTC and VALUE=DATE stamps (what
  Google/Apple/Outlook export) never cancelled -> alarms for lectures
  that will not happen; date-only UNTIL missed the regex -> series
  expanded past its end (date-only UNTIL = last DAY, 23:59:59);
  INTERVAL=0 filled the 400-guard with identical rows; blockKeys tie
  rule = newer-or-equal `when` (regression test pins both directions).
- timetable: midnight tick stepped +1 per publish - a weekend-cached
  process stayed N days behind the wall date (now-line on yesterday);
  band "Heute" compared day-of-month only (a page one year out said
  Heute); tutorial Save double-tap persisted duplicate tutorials (new id
  per press); appointment sheet re-fetched the room page EVERY scroll
  frame (placeData is an async getter passed inline to FutureBuilder);
  OSM attribution tap printed the URL instead of opening it.
- ILIAS: proved non-PDF saves ("<stem>.zip/.pptx") were never reused -
  probe only knew ".pdf" -> re-downloaded tens of MB per re-tap; retry
  gate could hit _refreshSession after dispose.
- mensa: fetchWeek joined ANY waiter regardless of args - a boot pull of
  week N crossing midnight answered the card's force:true pull for N+1
  and skipped it; join now keyed on canteen|isoWeek + force (test pins
  all four combos + TTL skip).
- files: disk-side deletes (cache page single + semester wipe) left
  pinned prefs entries pointing at deleted bytes -> dead tiles; new
  unpinFilesByPaths sweeps them; removeFile/deleteSync tolerate vanished
  bytes (the wipe loop no longer aborts on the first eviction).
- login: both TextEditingControllers leaked on every logout cycle.
- test-fixture honesty: webcal's rruleEv emitted UNTIL without the T
  separator (malformed ICS the widened regex would truncately parse) -
  fixed to real format; new tests: date-only UNTIL, UTC/VALUE=DATE
  EXDATE, blockKeys ties, mensa join matrix.

## Wave R23: async + UI-cost pool integration (0.8.6+60)

9 fresh lenses (async containment, rebuild cost, decode tolerance, boot
guards, ICS emitter hygiene). 518 tests green, 0 analyzer errors.

- async containment: anny _authed's retry ran INSIDE its own `on
  AnnyUnauthorized` handler - Dart does not route a throw from a handler
  into the sibling `catch`, so a socket blip during the re-mint escaped
  as an uncaught error (and refreshBookings left isLoadingBookings stuck
  for the whole session - now try/finally). exam-snapshot replay decoded
  per-entry (one renamed status name used to kill exam alarms AND the
  library ping replay behind it); IcsChange.decode likewise.
- boot guard: DATA_student was the last unguarded warm-start parse - one
  corrupt blob parked the app on the LOGIN FORM every cold start despite
  valid sessions (loadStudentData threw before ready=true); now a cache
  miss: key dropped, boot continues (3 new tests pin all four shapes).
- ICS emitter hygiene: name/topicName are instructor-set free text;
  _icsEscape never escaped CR/LF, so a pasted newline smuggled physical
  property lines (even a forged END:VEVENT) into the merged cache.
  Shared utils/ics_text.dart icsFoldable now guards both synth emitters.
- ilias: ".pdf" probe candidates - the corrupt file that just failed the
  magic check re-qualified via startsWith("$stem.") and was served
  forever; the magic gate's healing loop was defeated by its own naming.
- UI cost: toast provider listen:false (every toast rebuilt the whole
  home tree twice), _weekBlocks memoized per (timetable, page, day)
  (one carousel fling = up to 5 full grid recomputes), _rerenderFromCache
  gated on (ics bytes, day) (pull-refresh parsed the feed up to 4x with
  nothing new), translate drain notifies throttled to 1/2s + final flush,
  files-page size labels stat() once per row instead of per rebuild.
- alarms: exact-alarm settings prompt is UI-process-only now (the
  WorkManager isolate used to S+ startActivity a settings page the user
  never asked for); library check-in pings no longer re-show within the
  window, expire honestly, and survive force-stop; manifest receiver
  actions corrected (TIMESET was a dead typo the plugin ignores).
- tests: global DE/EN key + placeholder-arity parity (the 417-key table
  as ONE guard, was two area subsets), dynamic month keys pinned,
  kit_https pin test asserts the PRODUCTION seed const (was a drifted
  local copy), exam_synth weekday prefixes derived from the date,
  orphan 6.9k-line ref.ics fixture deleted.

## Wave R24–R27: deadlines -> cockpit -> Ampel -> prep (0.8.7+61)

Five waves, one user story: "what do I have to do and when". 550 tests
green, 0 analyzer errors.

- R24 Wave A (shipped in 0.8.6+60 commit): morning decision line + export
  leak fix (see git log; entry backfilled here).
- R25 Wave B — ILIAS deadline parser (`lib/ilias/due_parse.dart`):
  announcement TITLES only (dashboard carries no body); fence = deadline
  keyword + date, year-less rolls to nearest future, >210d refused, time
  needs "Uhr" (bare "18.01" is a room), no-time = 23:45 end-of-day;
  deterministic UIDs `kauni-due-<refId>-<key>`; emitted as the FOURTH
  sentinel block (X-DUE-SYNTH, mirrors exam synth: line-anchored
  strip/extract/inject, fold, wipe on logout). Persisted under
  DATA_dueSynthBlock (survives restart before any ILIAS fetch), rebuilt by
  agenda fetch + the 30-min poll diff (proven boards only — an EMPTY board
  never retracts), merged at every cache write, EXCLUDED from the change
  fingerprint and the ICS export sentinels (block content itself stays
  shareable — it is university data). T−30 reminders and digest pick dues
  up via the merged feed with zero alarm-family changes.
- R26 Wave C — deadline cockpit (`lib/agenda/logic/cockpit.dart` + agenda
  card): dues + exam sittings + exam/SignMeUp registration windows in ONE
  sorted timeline; strictly tomorrow onward (today sections own today);
  28d horizon (60d for sittings — the Klaus phase lives further out);
  smu rows only behind proven `loadedMine`; <3d items painted error.
- R26 Wave D — Schein-Ampel (`lib/handbook/`, `assets/mei/
  handbook_spo2024.json`): official MEI SPO 2024 handbook (86 modules,
  17 prerequisite parts, 28 gates — EVERY rule page-cited; pinned to the
  2024-08-29 edition, drift of newer reprints recorded in meta.note).
  Card on grades page: CP bar is LEDGER passedEcts / 180 (handbook sum
  303 counts every elective option — never a denominator), states from
  ledger/exam/feed only, gates block ONLY on a positively failed
  prerequisite (unknown never shouts), unmatched titles read "planned"
  (under-report, never inflate). next-term candidate list included.
- R27 Wave E — prep bundle: hero tap -> sheet with the CERTIFIED ILIAS
  bind (manual map only, auto-guess never deep-links), that course's open
  dues (guarded lecture-key match — EM I never borrows EM III) and the
  exam registration state.

## R28 — two-pool review wave over R25-R27 (7 review lenses + 3 adversarial verify lenses)
- Due parser hardened (lens-2 HIGHs): date candidates are ALL scanned and
  must be real calendar dates — KIT room codes ("Raum 20.11/30.20") can
  no longer bind as the deadline nor abort the item; the keyword BEFORE
  the date wins; times attach only AFTER the chosen date (a lecture
  "16:15 Uhr" ahead of "Abgabe bis 20.11." moved the T−15 reminder hours
  early); "12.10 Uhr" is a time; 31.02 dies instead of rolling to 01.03;
  first-paren due-course split (announcement parens no longer cut the
  course); UID gained a full-title checksum + URL salt (24-char key-cap
  collisions dropped deadlines silently); recall keywords + abgeben/
  Abgabetermin/-schluss/Nachfrist; DTSTART now TZID=Europe/Berlin like
  the exam family; empty course prints the announcement ONCE.
- publishDueBlock (verify-1): undo NEVER removes the shared cache body
  (that severed the next account's fingerprint<->body pair and swallowed
  its first real change forever) — it strips only OUR byte-identical
  splice via extract/stripDueSynth, both stores; issuedUrl fence closes
  the cross-isolate epoch blindspot (poll captures the URL before
  scraping; rotation A->B mid-cycle = refuse).
- Course join: SUMMARY reads "Due: <course> (<ann>)" — callers pass an
  ILIAS fetchCourses refId->title map (label-only; a failed join never
  loses the deadline).
- Point-in-time honesty for DTEND-less dues (verify-3): hero never
  says "running until <+90 invented>" (also kills the pre-existing
  all-day-event leak); agenda rows print "bis 18:00"/"ab HH:MM" and dim
  at the deadline, not 90 min after; prep sheet drops expired dues at
  their start; onDay never bleeds a guessed end into tomorrow; digest
  due-only day says "Abgabe fällig", mixed days count lectures only
  and name the first lecture's time.
- Cockpit: dues are never evicted by the 8-row cap (a Klaus phase with
  8 sittings lost every deadline row); signup-opens row requires a
  known window status.
- Export: a SUMMARY carrying an ILIAS URL no longer exports the event
  titleless (catch-all now exempts SUMMARY only; DESCRIPTION/ATTACH
  token privacy unchanged).
- Ampel/handbook: PDF page-number artifacts scrubbed from asset titles
  (contaminated keys silently read passed modules as "planned");
  handbookKey folds en/em-dashes (handbook "Do it! – …" vs ledger
  hyphen); load() future memoized; blocked section = planned-only
  (no duplicate rows).
- publish/fetch fingerprint chain: poll diff strips the due block on the
  OLD side too (was: every feed change after a publish re-announced
  every due as CHANGED); logout-trip live probe via SharedPreferences
  Async; asset load + dash + ledger-carry fixes from the UI lens;
  _AgendaLoad carries `occurrences` through ALL four setState sites
  (cockpit dues + prep hero died on every ILIAS-settling rebuild).
