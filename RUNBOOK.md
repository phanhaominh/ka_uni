# RUNBOOK — MEI Cockpit fork of KA.Uni

Personal KIT cockpit for Mechanical Engineering International (WS 2026/27).
Upstream app: KA.Uni (`com.dandemidov.kit_mobile`), kept as package id so the
APK installs over the existing app.

Project lives at `/home/student/ka_uni` — **never** work in `/tmp`: it is
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
| ILIAS page + scraper | `ilias.studium.kit.edu` via KIT SSO | courses, per-course materials (recursive folder walk), announcements, unread badges |
| Notifications | exact alarms + WorkManager (2 h ICS poll) + boot receiver | lecture reminders from expanded ICS dates, Anmeldung deadline alerts, timetable-change push |

## Build

```sh
export PATH=/home/student/dev/flutter/bin:$PATH   # Flutter 3.x, JDK 17+
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

Killing everything: app settings → clear storage, or log out (credentials are
in secure storage; ILIAS/campus sessions are cookie-only).

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
   band + exams badge, then let it idle one WorkManager cycle (~2 h) and
   confirm the poll leaves `DATA_webcalChanges` untouched (no false CHANGED).
