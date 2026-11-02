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

## Failure states

`MeiFailureBanner` on home distinguishes, loudly:

- **session dead** — auto-recovered silently (SSO re-run).
- **bot challenge algorithm changed** — cascampus `.asp` returned an
  unsolvable challenge; `botChallengeAlgorithmChanged`.
- **markup changed** — a page fetched fine (200) but the parser found nothing
  (`timetableSurfaceBroken` / `examsSurfaceBroken`): update the parser, don't
  re-login.

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
