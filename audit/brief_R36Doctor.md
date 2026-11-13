# Lane brief R36.1 — FEED DOCTOR (on-device health surface)

Repo /home/phan/ka_uni (Flutter, KIT student app). Read RUNBOOK.md sections
"device", "support bundle" (R29) and lib/diagnostics/{support_bundle.dart,
support_state.dart} FIRST.

## Goal
Settings gains a "Feed doctor" section making every data source's health
visible ON DEVICE: per-source status table + one "check now" action +
notification-permission row. When a scraper goes dark (R32.4 class), the
owner must be TOLD here, not have to suspect.

## Hard rules
1. ONE-VOICE: health rows MUST be assembled by a NEW pure function in
   lib/diagnostics/support_state.dart (or new feed_health.dart) reading the
   SAME diagnostics map entries that buildSupportBundle consumes. Add a
   pure `List<FeedStatus> feedHealth(Map<String,String> diag, {required
   bool notificationsPermission, required bool credentialsStored,
   DateTime now})` + data class FeedStatus{source,labelKey,state,detailKey?}
   with state in {ok, degraded, dead, unknown}. Unit tests pin per-source
   verdicts from synthetic diag maps. UI renders ONLY from feedHealth —
   shared≠rendered divergence is the failure mode to make impossible.
2. scrubDiag: any detail string shown may embed diag values — pass every
   rendered detail through scrubDiag (same redaction as the exported
   bundle; the token URL lives in DATA_webcalDiag).
3. Heartbeat: write DATA_lastPollAt (epoch minutes, plain int) from the
   existing background poll entry point(s) in main.dart (grep for the
   poll/alarm bootstrap that already exists; one write site per isolate
   path, best-effort). Doctor shows "app heartbeat: last poll HH:MM /
   never". Old/absent = degraded row ("background refresh not running —
   battery optimization?"). Do NOT invent new alarms.
4. "Check now" button = vm.forceRefetchEverything() (the exact refresh the
   pull-down uses) + toast on error (same catchError idiom as home).
   Table repaints because it watches the providers/settings the fetches
   notify. No bespoke per-source fetch calls.
5. Notification-permission row: state read (already exported into the
   bundle as notificationsPermission — reuse that source) + "Open system
   settings" button only when not granted (existing permission-channel
   pattern in lib/notifications/**; reuse, never a new channel).
6. Sources to cover (grep the real keys; do not guess): webcal feed
   (WebcalKeys diag/fetchedAt), ILIAS watcher stamp, SignMeUp mine stamp,
   Anny rooms (fetchedAt persisted), mensa cache stamp, grades/campus
   session state (credentialsStored + last successful fetch stamp if one
   exists; else state unknown with honest detail). Missing key = unknown,
   never ok.
7. l10n: add doctor keys to BOTH de and en maps in lib/l10n/l10n.dart
   (base table near "settings.*" rows; keep the two lists symmetric —
   test/l10n_parity_test.dart fails otherwise). German wording like the
   rest, English mirror en map.
8. Files you may touch: lib/diagnostics/**, lib/settings/views/
   settings_page.dart (append section after the existing R29 support
   bundle row), lib/settings/providers/settings_provider.dart ONLY if a
   pref is truly needed (prefer none), lib/main.dart ONLY the heartbeat
   write, lib/l10n/l10n.dart, lib/notifications/** READ-ONLY (reuse),
   test/feed_health_test.dart (new), RUNBOOK.md (append R36.1 entry).
   NEVER touch lib/home/**, lib/mensa/**, lib/library/** (sibling lane
   owns those; your doctor reads their PERSISTED keys via prefs/diag map
   only, never imports their managers).
9. Verification: flutter analyze clean on touched files; new tests pass;
   l10n_parity passes. NO full-suite runs, NO builds, NO device, NO git.
   Device truth: 800x1280 if you ever read bounds in fixtures — but you
   have no device.

Report: files touched, per-source key inventory (key -> verdict logic),
test names binding each skeptic condition (unknown-not-ok, scrub-before-
render, heartbeat degraded).
