# FixNotifs fix brief
Owned files: lib/notifications/mei_notifications.dart, lib/notifications/notification_payload.dart, lib/main.dart, lib/l10n/strings_notifs.dart

R99: dedupe identical occurrences (same displayTitle+start) before scheduling — user ICS mirrors CAS events → 3-4x alarms today (dumpsys-observed). R100: at app start (main.dart bootstrap), cancelAll() on flutter_local_notifications THEN rebuild all families from cached data — kills pre-update alarm ghosts (observed: stale 12:00 alarms to Feb 2027). R101: 30-min WM poll 'Delaying execution before schedule' on Android 9 + my force-runs re-arm window: mitigation only — on every app start re-register periodic (keep policy is set; consider update policy + initialDelay 0) and update the stale '2 h' comments (C59). C66: register-state staleness — verify verifier verdict; if fix is 'document only', skip code.



## Assigned verdicts (FULL verifier detail — authoritative)
- **C61** [REAL/?] Call sites confirmed (anchor drift noted): campus_manager.dart:1455-1456, :1475-1478, :1509-1510, :1923-1924, :2041 and kit_provider.dart:81-85 (inside a finally block) all use bare `unawaited(MeiNoti
  → FIX: Wrap the body of each schedule*/cancel* method in mei_notifications.dart (:159-333) in try/catch with the kDebugMode print, matching the fetchWebcalTimetable containment comment; call sites then need no changes.
- **C62** [REAL/?] Confirmed in code: scheduleLectureReminders (:159-178) has no single-flight/mutex; it runs `await _cancelRange(10, 400)` (:163) then awaits _zoned per occurrence. Two runs interleaving at those awaits
  → FIX: Add a static in-flight future memo (like campus_manager._examsInFlight) around scheduleLectureReminders at mei_notifications.dart:159 — second caller returns the running future after awaiting it, never interleaving.
- **C63** [REAL/?] Confirmed: `static int _changeSeq = 0` (mei_notifications.dart:96) with `1000 + (_changeSeq++ % 20)` (:103). Each WorkManager poll executes in a FRESH isolate → counter restarts at 0 → the first heads
  → FIX: Seed _changeSeq from wall-clock instead of 0, e.g. on first use `_changeSeq = DateTime.now().millisecondsSinceEpoch ~/ 1800000` (30-min buckets) in notifyChange (mei_notifications.dart:99-103), making ids distinct across isolates/runs without persistence.
- **C65** [REAL/?] Confirmed: scheduleMorningDigest bakes `changesFresh = (prefs.getString("DATA_webcalChanges") ?? "").isNotEmpty` at SCHEDULE time (:269-270) into digestTexts (:284-285, :297-313). The agenda dismiss c
  → FIX: Drop the pre-baked changes clause: remove the changesFresh read (mei_notifications.dart:269-270) and pass false in digestTexts, or omit the notifs.digestChanges suffix entirely — the CHANGED band + badge already carry that signal at open time.
- **C66** [REAL/?] Confirmed: scheduleExamReminders rebuilds ids 500-600 ONLY from the exams list handed in by the current fetch (:191-219; sole caller campus_manager.dart:2041, inside _fetchExamsInner success path). Sk
  → FIX: Re-run scheduleExamReminders from the cached `exams` list on every app start (campus_manager, where carryExamSynthFromCache/exams prefs rehydrate) and immediately after any in-app registration toggle, so alarms track last-known state instead of last-FETCH state.
- **C68** [REAL/?] Confirmed: main.dart:53 calls `await registerBackgroundPolling()` unconditionally on every start (no login/pref gate), with ExistingPeriodicWorkPolicy.keep (mei_notifications.dart:447). Logout does ca
  → FIX: In the empty-URL early-return at mei_notifications.dart:349-351, `await Workmanager().cancelByUniqueName("mei-webcal-poll")` before returning — self-heals the resurrected registration on its first logged-out fire (login re-registers via main.dart:53 on next start).
