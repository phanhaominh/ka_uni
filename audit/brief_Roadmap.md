# KA.Uni roadmap R32–R36 — 43-idea ideation × 4-lens judging (2026-11-13)
Method: 6 ideation lenses over the repo (agent://r32ideas-1..6, packet local://ideas_packet.md),
then 4 adversarial judges: feasibility (r32judges-1), owner-value (r32judges-2), fragility+privacy
skeptic (r32judges-3), completeness critic (r32judges-4, +5 new ideas). Integration rules: a
verified doctrine violation outranks a verified buildability; skeptic conditions are binding.

Independently verified this round (main thread): FlutterSharedPreferences.xml with 12×
flutter.DATA_* keys on Fire root fs (widget substrate real); exam_clash.dart zero geo; blockedBy
computed (ampel.dart:100-108) never alarmed; deregEnd parsed-then-discarded
(exam_list.dart:186-187,:255); digestTexts no room (day_decision.dart:101-142); DATA_webcalChanges
cap-50 with zero historical reader; _diffLedgerAndNotify sole caller campus_manager.dart:656
(app-open only); manifest exports only LAUNCHER+BOOT/MY_PACKAGE_REPLACED; router exists at
lib/navigation/notification_deep_links.dart.

## WAVE R32 — "already paid for" (8×S, zero new scraping/substrate; every claim code-verified)
R32.1 ROOM-IN-DIGEST — digestTexts line gains `· {room}` (displayRoom, placeholder→"Raum folgt").
      [owner-value #1; feasibility GO]
R32.2 SMART DIGEST SLOT — digest time = max(07:30, firstStart−75min) from cached feed, re-armed
      on feed change; free days stay 07:30. Same PR as R32.1, one noticed moment. [owner #3]
R32.3 DE-DOOR (deregEnd) — parse "Abmelden bis" + literal "Unregister until" (no \b — EN \b
      provably can't match inside "Unregister"); ExamEntry field inert by construction, zero
      toJson → no migration; chip "abmelden bis X", cockpit row, T-24h ping on FRESH 1300 band —
      NEVER reuse 500-600 (exam family cancels+re-arms its whole range). [owner #4, feas top-1]
R32.4 SEATS-FILLED sub-line — "13/20 belegt · First-come" on exam cards + opens-now ping; render
      only when placesNumber>0 (`?? 0` conflates absent-vs-zero). [owner #5, feas top-4]
R32.5 PREREQ-GATE ALARM — blockedBy set GROWS across ledger writes → one-shot alarm (DATA_*
      snapshot dedupe, 1300 band), wording "KNOWN blocks" only. [owner #7, feas top-2]
R32.6 HERO ROOM-CHANGE — IcsChange kind/room/oldRoom/oldWhen (webcal.dart:749-756): struck old
      room → new on hero. Audit's wrong-room hazard at the most-stared surface. [owner #11, feas top-3]
R32.7 CHRONICLE (critic#3) — "letzte Änderungen" page from DATA_webcalChanges; header admits
      poll-bounded coverage + visible /50 cap; agenda band footer "ältere Änderungen".
R32.8 EXAM ROOM→DOOR (critic#5) — exam card + countdown ping "30.95 · Route" via existing
      resolver/maps_url; resolver miss → no line, ever.
R32.9 CELLS DUMP GATE (L1#7 pre-gate, binding) — commit ModuleTreeDebugPage dump as test fixture
      FIRST; parser arm only if cells[5] is a date; 8-cell gate untouched; "laut Studienverlauf"
      wording. Not-a-date → idea dead, not descoped.

## WAVE R33 — the pocket era
R33.1 WINDOW-OPENS PING (scope-reduced per skeptic): T-0 "opens now" only — at-most-once per
      window via snapshot, work-hour slot, cockpitPlan's own provenance gates (smuProven),
      rides EXISTING mei_deadlines channel. The "closes tonight" arm VETOED as cockpit-row
      duplicate → closing deadlines surface in the morning digest line instead (zero new pings).
      [owner-value #2 vs skeptic; digest-line is the joint resolution]
R33.2 ACTION BUTTON ON PINGS (L3#5) — "Jetzt anmelden" = deep link open, never claims registered.
R33.3 GRADE-PUBLISH POLL (critic#2) — 6h Workmanager task → existing ledgerDiff → existing
      1200-band ping; seed-only run posts nothing; poll failure never cancels the fast task;
      logout kills it; body "grade published as of HH:MM".
R33.4 LAST-LECTURE SOFT-ALARM (L1#4) — T-3d digest row + one confirmation ping; "schedule says"
      phrasing.
R33.5 SOP EARLY-WARNING (L2#6) — "at least N CP · kth module fails if X fails" cockpit row;
      "at least" phrasing locked by test. [owner #10]

## WAVE R34 — the Fristenbuch era
R34.1 FRISTENBUCH (L6#1) — manual dates → synth VEVENT (prefix kauni-frb-, "Frist:" title
      prefix). Skeptic/feasibility mandatory arms, same commit: sanitizeSentinels at its own
      injection point (Round-10 BEGIN/END smuggle class); cockpit.dart:72-74 prefix arm (unknown
      prefixes are DROPPED); skip-list :1705-1706; gridTemplate :2272 exclusion (weekday-carousel
      repeat bug); enrolledTitleKeys :2426 (no isTaking pollution); digest non-class counting;
      fence test gains writer case; logout regression test (agenda/digest/ICS export); rows render
      as "you". Logout death free (DATA_* sweep verified). M at top of range. [owner #13]
R34.2 BÜROKRATIE-STARTER-PACK (L6#2) — asset JSON (handbook precedent), editorial leash
      (skeptic, binding): every row = official source URL + rendered "stand: <date>"; Karlsruhe-
      specific claims cite Karlsruhe pages or go generic; advisory phrasing load-bearing; NEVER
      auto-alarm — copy-into-Fristenbuch flips provenance to "you noted" and only then can it
      ping. Immigration-status-wrong advice > any timetable bug; leash is the idea. [owner #9]
R34.3 PAPIERKRAM-LAUNCHER (L6#4) — EN label + DE jargon + copy-Matrikel + url-launch rows.
      [owner #8, thank-within-a-week #3]
R34.4 OFFICIAL TERM CALENDAR (L2#2) — SignMeUp terms[] start/end/cancel → cockpit milestones
      with per-row source citation. Unlocks R34.5/6.
R34.5 NÄCHSTE 90 TAGE (L2#3) — pure-join cockpit card over term calendar + windows + Fristenbuch
      + due-synths. The "explain my semester" answer to the owner's original question.
R34.6 DOC EXPIRY WATCH (L6#3) — RE-ADMIT conditions (skeptic veto as specified): same commit adds
      logout() DOC_* keychain enumeration+deletion into PartialLogoutException (purge-first,
      reported not skipped) + logout regression test. 90/30/7 tier fine. Never skip this: R21
      precedent was "critical", same device.
R34.7 EXAM-WINDOW STATE MACHINE (R31 F-1/F-2) — open/closed/unbekannt persisted; transitions
      drive R33.1; kills the "+N mehr" flap root cause.

## WAVE R35 — subtraction + joins
R35.1 ONE ACTION LIST (L5#1, M+, skeptic conditions binding): per-kind floors BEFORE deletion
      (cap-8 dues-first evicts a Klausurphase Anmeldung — the core-purpose miss that flips this
      to veto); pending/not-current cards ("signMeUpNotCurrent", "examsLoading") port into
      cockpit as first-class unknown-rows (collapse is only honest if unknown still renders);
      SignMeUpMineCard (outcomes ledger, no tap handlers) stays OUT of the action list; port
      _nextExamCard semantics (≤45d gate, registered-term selection, room disambiguation,
      day-offset weight) — ~50-80 lines render, not pure deletion; per-card deep links preserved;
      one-release revert switch.
R35.2 ONE FRESHNESS VOICE (L5#4) — DataTrust{fresh,aging,untrusted} + source-specific subline
      slot (mensa weekend-vs-dead-cache distinction preserved or it's a regression). [owner #15]
R35.3 HOME=TODAY — SPLIT (skeptic): (A) delete home module-tree (HierarchicTableView sole use
      verified) + grades-page "full tree" footer. Ship. (B) ProfileView deletion ships ONLY with
      degree/semester relocated in same commit (it is the UNIQUE renderer of those two lines) +
      PREF_showingProfile/PREF_showAvgGrade reads+writes deleted together (PREF_ never swept →
      orphans are permanent residue) + F-11 "0,0" fix-or-delete with the block. Tablet audit
      dumps show "Show profile" was TAPPED 16× — this is a demotion, not a removal-of-unused.
R35.4 GEO-CLASH (L4#1) — walk_hint distance into exam_clash red verdict ("12 min walk between").
R35.5 GAP-HOUR PLANNER (L4 join#1) — ≥45-min gaps × AnnyManager.freeCounts × mensa windows,
      fresh-only gate (stale → omit clause entirely).
R35.6 SCRAPE REFUSAL TEST (L5#6) — host-allowlist test + RUNBOOK won't-list; new host requires
      fenced parser + proof no existing join answers it. Doctrine adoption, wave-agnostic.
R35.7 kauni:// (critic#4) — ~40-line exported Kotlin activity → existing deep-link payload queue;
      route tokens only, never data/URL params; unknown host = silent no-op.
R35.8 DOCK DEAD-ENTRY CUT (skeptic's find) — kit_nav_container.dart:105-111: the index-2 body
      entry rebuilt every setState with a fake empty PHPSESSID, unreachable trap. The real dead
      thing in the dock.

## WAVE R36 — health + polish
R36.1 FEED DOCTOR (critic#1; critic's anti-omit pick) — support bundle ON-device: per-source
      health table (login/webcal/ILIAS/SignMeUp/Anny/mensa) + "check now" + DATA_lastPollAt
      heartbeat + notification-permission row; reuses scrubDiag so shared≠rendered can't diverge;
      doubles as webcal-URL onboarding checklist. Makes every scraper feature self-explaining when
      markup breaks (R32.4 going dark will be TOLD, not suspected).
R36.2 CAMPUS-NOW STRIP (L5#5) — mensa+library → one 2-line glance card, per-row DataTrust chip,
      tap-through kept, 2 PREF keys → 1.
R36.3 cells[5] date column (L1#7) — only if R32.9 dump validates; fixture-driven arm.

## PARKED (trigger-armed, not rejected)
- GLANCE WIDGET (L3#1): substrate PROVEN (prefs XML verified on device; feasibility confirms
  shared_preferences plain-XML + flutter. prefix; feasibility: L honest, not 2x). Owner-value:
  L-effort for one reader, speculative dock/watch generality — "after R33, if lock-screen glance
  count justifies it". Skeptic leash (all binding): Kotlin logic-free (CountDownView + absolute
  target + one 30h compare, ≤150 LOC or kill), Dart writes pre-formatted strings + committed
  schema-contract fixture, snapshot embeds writtenAt + ALWAYS an "as of HH:MM" line (Android 12+
  update rate-limits freeze the countdown between process deaths — self-explaining absence is the
  only honest answer), logout gains explicit widget repaint/clear + regression test (widget pixels
  live OUTSIDE app storage; prefix sweep cannot reach them).
- DOCK-GLANCE-FIRE (L3#6): test rig with retracted clock; owner lives on Pixel. Needs a real
  second-screen life first.
- MILESTONE-LEDGER (L2#5): only its proven rows (SOP deadline, Sprachenzentrum) fly — inside
  R34.2's data. No hand-edit treadmill product.
- STUDY-BLOCK-SUGGESTER (L4#5): advice self-cancels under honesty doctrine; PARK unless owner
  asks for a write-back planner.
- EXAM-WEEK-STUDY-BUDGET (L4#3): admitted only as citable ECTS 25–30h/CP RANGE with standard
  cited in-row; invented crunch weighting dropped; never rendered on grades/ampel surfaces
  (reads as achievement claim). Effectively PARK: R34.5 covers the felt need.
- ANERKENNUNG-TRACKER (L6#7): PARK until an actual transfer exists; if built: DATA_-scoped with
  join-test proving ampelPlan empties at logout (every manual-toggle precedent here is PREF_ —
  that default would bleed A's statuses into B; skeptic named it).
- SUBMISSION DIARY (L6#5): dies/dooms with DocWatch's storage story — inherits R34.6 outcome.

## REJECTED with reasons
- ONGOING HERO NOTIFICATION (L3#2) — hard (skeptic): frozen countdown after process death with no
  stale marker = ghost text; permanent non-dismissible ping = fatigue bait with no in-app mute
  (OS-nuke kills T-30 too); with the widget parked-but-alive it is a 7th family delivering the
  same snapshot worse.
- PING BUDGET GOVERNOR (L5#2) — hard (skeptic; DISSENT noted: feasibility ranked it top-5):
  PREF_-scoped daily counter is behavioral data surviving logout by design — category error vs
  storage doctrine; second account inherits A's consumed budget + sees A's counts in the support
  bundle; spec lets the cap swallow the T-30 core contract invisibly. Re-admit form (DATA_-scope,
  T-30 exempt) is a no-op → correct conclusion: R33.1 digest-folding + restraint is the governor.
- ILIAS LEAVES THE DOCK (L5#7) — hard (skeptic): audit shows tab USED on both devices (62 taps
  tablet, full-SSO drills pixel+fire); paperclip is the SAFETY FALLBACK when module scan fails
  (C50 silent enrolment drop → no per-module button; C57 → button opens WRONG course); zero code
  saved. Subtract C1 instead (R35.8).
- "Closes tonight" + "red-clash" ping arms (L3#4 b/c) — cockpit-row / CHANGED-band duplicates;
  closing surfaces via digest line (R33.1).
- Non-gaps (critic disproved): backup/export (allowBackup=false is load-bearing doctrine),
  offline story (owned; R35.2 unifies dialects), Fire second-screen product (single-user).

## Cross-cutting rules this round established
1. Skeptic-named logout violations are the failure class: L6#3 (keystore), L5#2 (PREF_
   behavioral), L6#7 (toggle-default), L3#1 (rendered pixels) — every new persistence/storage
   claim must name its sweep mechanism in the same commit.
2. Notification families need a joint resolution (owner wants pings, skeptic guards the mute):
   new pings ride existing channels; cockpit-duplicate info folds into the digest line; budget
   is enforced by authorship, not runtime.
3. Deletions ship with relocation of unique content (R35.3B) — audit dumps are the usage oracle.
4. Editorial content is advice: source + date-stamp + advisory phrasing + no auto-alarm (R34.2).
