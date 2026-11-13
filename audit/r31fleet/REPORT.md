# Fleet UI/UX Evaluation — R31 (build 0.8.9+64, 2026-11-13)

## Scope & method
Two live devices, two parallel serial lanes driven exclusively through
`audit/drive.py` (uiautomator-coordinate taps, every verdict backed by a
screenshot the agent actually read; `ensure_foreground` guard = zero taps
ever landed in another app):
- **Pixel 3** (1080x2160, local USB `8A8X0N6BY`) — clusters P1 home/cockpit,
  P2/P3 agenda/exams/timetable/ILIAS/files + hero-repro drill, P4 grades/settings/exams-gap-fill.
- **Fire HD 8** (1280x800, LineageOS via `ssh nuc`, `G090MJ05736402TB`) — clusters
  F1 home/cockpit (tablet lens), F2 agenda/exams/module, F3 timetable/ILIAS/grades/settings.
96 artifacts in `audit/pixel/` + `audit/fire/` (prefix `r31*`), plus one
root-shell read of the Fire's SharedPreferences (read-only) as diagnostic ground truth.
Build shipped for the audit: R30 (`51f0ec7`), 626 tests green, installed
`versionName=0.8.9` on both devices.

## Scorecard vs promised features

| Promise (RUNBOOK catalog) | Pixel 3 | Fire HD 8 | Evidence |
|---|---|---|---|
| EN portal-locale parsing (**R30 headline**) | **PASS** — module page `in 103 days · 24.02.2027` | **PASS** — same, no `unbekannt` anywhere | r31p4_advmath_module.png, r31f2_advmath_module.png |
| Timetable home grid (ICS-driven, absolute ruler) | PASS data; **F-2 flap**, F-3 tablet misalignment | PASS data; **F-3 broken invariant** | r31p3_boot_*.png, r31f1_grid_scroll_1.png |
| Agenda today+tomorrow merge | PASS | PASS (internal to its clock) | r31p2_agenda_*.png, r31f2_agenda_*.png |
| CHANGED band | not exercised — no pending deltas in window (unit-tested only) | same | — |
| Prüfungsanmeldung seal page | PASS: Act-now, windows, `• ILIAS` plain-text placeholder, red-dot badge | PASS: 13 cards, windows quoted | r31p4_exams_1.png, r31f2_exams_*.png |
| Exam countdown + clash warner | PASS-by-absence (no dated-registered exam ⇒ no card, consistent) | same | **F-8** design gap |
| SignMeUp card + ranks/countdown | PASS: countdowns quoted, `+73 more` | PASS: 3 rows, rank chips await first draw (null rank ⇒ chip correctly hidden, signmeup_manager.dart:81) | r31p3/postpull extras |
| ILIAS SSO handoff (dock + per-module) | PASS signed-in (course `3173008 – Materials…` tabs Inhalt/Info) | PASS signed-in at 20 s | r31p3_moduleilias.png, r31f3_ilias_20s.png |
| Raum-Finder tiers | (F2-lane: on Fire) | PASS: `30.95` → building 4 m → hall → distance-sorted | r31f2_roomfinder_1.png; F-12 expand dead-end |
| Grades ledger + SPO bar + Ampel | PASS: 0/0/52, `not yet met`, SPO-2024 handbook cited, planned rows wrap | PASS same at 800 px | r31p4_grades_*.png, r31f3_grades_1.png |
| Mensa card + EN translation | PASS: EN dish + DE tail, prices, chips, expand/collapse | PASS same | r31p1_mensa_expanded.png, r31f1_mensa_tomorrow.png |
| Library (Anny) anon scope | PASS: counts + `Next free` + `As of` + CTA | PASS | r31p1_library_3.png, r31f1_cards_1.png |
| Personal ICS (127.0.0.1:8080 via adb-reverse) | PASS: `29 courses imported from own calendar` | n/a (reverse would point at NUC) | r31p4_settings_*.png |
| Settings: EN↔DE instant, section toggles | PASS: full UI flip both ways, restored to user's `English` | PASS same, restored `System` | r31p4_de_home.png, r31f3_de_home2.png |
| Failure-banner honesty + webcal self-heal (R17) | **FAIL heal** — F-1; token itself healthy (heal path not blamed) | **FAIL heal** — F-1; prefs prove fetch success | r31p3_boot_*.png |
| Notifications/alarm plumbing | PASS static: 238 alarms; digest/deep-link not live-exercised (time-window) | 47 alarms | dumpsys quotes in P1/F1 |
| Support bundle (R29) | PASS share sheet; **F-9** version string wrong | n/a | r31p4_share.png |
| Dock/nav | **WAI: 3 tabs** `[SettingsPage, KITHPage] + ILIAS push` (kit_nav_container.dart:170) — the "5 tabs" report was a stale audit prompt, retracted | WAI, pinned, never floats | r31p1_home_final.png |

## Findings ledger

| ID | Sev | Finding | Evidence / notes |
|---|---|---|---|
| F-1 | **broken** | Home hero absent + `Timetable not current – feed older than a day` survives boot, agenda-verified refresh, and pull-refresh; self-heals only ~30 min later (likely the background poll's notify). Fire's prefs prove `DATA_webcalFetchedAt` moved to the pull's timestamp while the banner still claimed stale ⇒ the R16a stamp-probe never fires on the pull's notification. Suspect: the pull chain's completion notify vs probe race / chain choice. Fix wave must first capture `DATA_webcalDiag` + which notify path PTR uses. **Trap for repro: the home `Last updated` stamp is the MODULE stamp, not the webcal stamp — it moved while webcal state was unchanged and misled one lane.** | r31p3_boot_15/60, afteragenda, postpull_home; Fire root prefs read 18:52 |
| F-2 | **broken (env-confounded)** | Feed flap: same home grid cycles ≥3 source variants (`…(Problemclass) (Ü), Nepechiy…` ↔ `Tutorial: …(Problem Class)` ↔ webcal variant; `09:00 Seminar IC USA` appears/disappears). Two candidate mechanisms: webcal-vs-HTML-fallback cache writes, or the personal-ICS merge toggling — the Pixel flap window exactly overlaps the user unplugging the USB (adb-reverse drop). Code claims `keeps the old copy on any failure` for personal top-up ⇒ needs re-pro without the cable variable. Impact: schedule visibly changes between screens (wrong-room hazard). | r31p3_boot_15 vs _60 vs postpull; P4 notes banner self-cleared 00:51→00:57 unpulled (F-1 late heal) |
| F-3 | degraded | Tablet (1280x800): equal wall times land at different pixels across adjacent day columns (`09:45`/`13:00` ≈ 60–145 px apart) — violates the R18 one-wall-window invariant; side-by-side day comparison wrong. | r31f1_home_1.png (adjudicated by pixels), grid_scroll_1 |
| F-4 | degraded | No full-screen timetable route exists; `Edit timetable` opens the star **editor**. Naming misleads; only day grid = home card. | r31f3_ttfull_1/2 |
| F-5 | degraded | ILIAS WebView: 20–30 s blank with only a thin progress bar (looks hung) and **zero a11y nodes** — TalkBack users cannot navigate it; also blocks automation. | r31f3_ilias_20s vs _60s; F3 dump |
| F-6 | degraded | Dock pill overlays the last ~90–120 px of scrollables ⇒ systematic dead taps (module `ⓘ` bottom row, `+26 more dishes`, first tap silently lost). Missing bottom scroll padding. | F3 friction, P1 friction |
| F-7 | degraded | Merged/personal grid events have no course-ID ⇒ appointment sheet lacks `Open course page`; agenda rows are non-tappable **by design** (agenda_page.dart:953) — combined: merged events offer no drill path anywhere. | r31p3_daypage_2/3 |
| F-8 | design gap | Exam countdown + clash warner are registered-only; this user's nearest dated Klausur (26.11. Audimax, not yet registered) is counted down nowhere — the exact perception that motivated the original "where is the countdown" report. Recommendation: countdown section for dated-not-registered exams with an explicit `register by` framing, kept visually distinct. | exam_countdown.dart `if (!e.registered) continue` |
| F-9 | cosmetic | Support bundle prints `App version: 0.8.9+63` on a +64 install — `kAppVersion` constant drifts every release; use package_info_plus at runtime. | r31p4_share.png; support_state.dart:60 |
| F-10 | cosmetic | Module page prints 5 identical `Wed, 24.02.2027 11:00 - 13:00` attempt rows, unlabeled, pushing content off-screen. Dedup or label `Versuch n`. | r31f2_advmath_module.png |
| F-11 | cosmetic | SPO card renders `not yet met` but never the 2027-03-31 deadline date (logic uses it); profile card `0,0` vs page `—`; one planned-module title ellipsized at phone width. | r31p4_grades_*.png |
| F-12 | cosmetic | Friction set: Raum-Finder result tap toggles an expansion that renders nothing when no alias/website (dead-end affordance); `Hide details` shown while collapsed; system back at home root exits app silently; profile-collapse chevron has no affordance hint (returning user sees near-empty home); `Free · 1:45` was end-based correctly in code — its wrongness was an F-2 variant symptom, closed. | multiple shots |

**Upstream data notes (not app bugs):** KIT-side typo `…in democratic socityes`; transient `Could not read the exam list (KIT site changed?)` banner appeared once, self-cleared in <6 min (honest banner, honest recovery).

## Audit-honesty section
- **Retracted during adjudication:** "dock missing 2 of 5 tabs" (my lane prompt carried a stale 5-tab assumption; code + both devices agree on 3 — WAI) and "0,0 grade is fake zeros" (first-semester account; card and ledger agree — PASS).
- **Not live-exercised:** CHANGED-band UI, notification delivery + deep links, Anny authenticated scope (user-present policy), large-font passes, landscape (rotation is banned on this tablet class per RUNBOOK). All carry unit tests; treat as green-by-test only.
- **Fire device clock** is stuck at `Thu Nov 12 … EST` with `auto_time=1` (NTP not sticking) — every date-adjacent Fire verdict is judged internally-consistent against that clock; fix the tablet's time service before the next date-sensitive audit.
- **Pixel clock** ran ~00:30–01:00 local — the now-line's daytime rendering remains UNVERIFIED (window clamp explains its absence at night; `Current time:` chip live-advanced across shots).

## Recommended next wave (R31) priority
1. **F-1** hero/banner resync: capture `DATA_webcalDiag` + PTR notify path; make the pull's completion unconditionally re-probe (or notify post-write for real). Both devices reproduce.
2. **F-2** flap: scripted repro (no cable variable) diffing `DATA_webcalIcsCache` byte-for-byte across writes; fence whichever source alternates.
3. **F-9** one-liner: runtime PackageInfo version in the support bundle (drifts every release — do it now).
4. **F-6** dock scroll-padding: cheap, kills a whole dead-tap class on both form factors.
5. **F-3** tablet axis: extend the weekly-view prepass to the home carousel columns at wide widths.
6. **F-8** countdown scope decision (product call: count unregistered dated exams distinctly?).
7. Cosmetic batch F-10…F-12 + `Edit timetable` label.
