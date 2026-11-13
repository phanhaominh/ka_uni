# Fix brief — Wave R31 (from the R31 fleet audit + 5-lens panel)
Prereq context: audit/r31fleet/REPORT.md, audit/r31fleet/PANEL.md.
Order = panel consensus (Pragmatist costs + RootCause/DataIntegrity findings);
AdversarialVerifier adjudication appends at bottom when delivered.

## 0. Ground-truth gate (owner input required — decides item B's severity)
`isTakingThisSemester == false` (lecture absent from the webcal timetable) silently gates ALL
urgency surfaces: deadline alarms (campus_manager:2777 `!= false`), Act-now (exams_page:58 via
catalog :52-55), agenda Deadlines rows (agenda_page:559). Observed victim: "IT and Data Science"
(exam 26.11.2026, registration closes 22.11.) — zero alarms, invisible from all three.
OWNER QUESTION: is ITDS actually planned this term?
  YES  -> tri-state must not vote false from timetable absence alone. Rule: an exam whose
          registration window is OPEN forces the verdict to null ("unknown -> stay loud").
          One function, campus_manager.isTakingThisSemester; + tri-state test (open window +
          absent lecture => !false) + alarm-schedule test.
  NO   -> app is correct; catalog section label is doing its job. Downgrade to none.

## A. F-9 support-bundle version drift (~25 min, do first — later bundles measure correctly)
kAppVersion const (diagnostics/support_state.dart:11) prints 0.8.9+63 on +64 installs.
package_info_plus is only a TRANSITIVE dep — add it as a direct dependency, await
PackageInfo.fromPlatform() in buildBundle (already async), format "$version+$buildNumber",
keep kAppVersion as fallback for tests. Test: bundle version matches pubspec at runtime or
injectable PlatformInfo fake.

## B. F-1 home hero / stale-banner never heals (2–4h, memory-first fix ~8 lines)
MECHANISM (conf 0.8): card is the ONLY SharedPreferencesAsync reader of webcal stamp/cache;
all writers legacy (campus_manager/mei_notifications getInstance); async/legacy mismatch for
these keys is documented on-device (campus_manager:2690-2697). Ghost null gets ADOPTED
(_readCache no null guard) => _seenFetchedAt=null => _feedFresh hard-false (banner) + empty
feed (no hero) + probe compares null==null forever. ~30-min heal = poll process write finally
converging the async view. Report's "notify never fires" RETRACTED (notify proven post-write;
single root KITProvider verified). Adversarial also retracted two evidence legs: the Fire PTR
pull never moved the stamp (banner survival was correct), and no frame proves the self-heal.
Hard surviving evidence: prefs stamp 32s old under a visible banner (r31f3_nocanteen) +
banner-vs-grid divergence IN FRAME on every Pixel top shot all night (banner stale-claim while
grid renders today's lectures — exactly this mechanism's signature).
FIX (prose):
1 campus_manager: on _fetchWebcalTimetableInner success store memory-first handoff fields
  `webcalWrittenAt` (the exact stamp string written — hoist the now() local) +
  `webcalMergedFeed = merged`.
2 home_page._resyncIfStale: memory-first — if campusManager.webcalWrittenAt != _seenFetchedAt,
  adopt (stamp, feed) directly; SharedPreferencesAsync probe demoted to cross-process (poll)
  fallback only.
3 home_page._readCache: null stamp OR null cache => return, keep last good state, never latch.
PROBE first on debug build (5 min): NUHC debugPrints in _resyncIfStale/_readCache + stuck-banner
window => background/foreground (resume runs _readCache unconditionally, bypassing notify+probe):
  heals on resume  => ghost+latch confirmed (proceed with fix)
  doesn't heal     => notify/dCD chain dead instead — re-diagnose before touching code.
Pull leg (Adversarial's evidence rule): during a debug PTR pull, read the prefs stamp via run-as
IMMEDIATELY after PTR returns (success must move it — if not, the pull's webcal step failed and
no banner conclusion may be drawn), then scroll to top and screenshot the banner region before
any verdict.
Regression test: fake store serving null stamp once then real values; assert card keeps last
good feed and heals on next notify (latch must be impossible).

## C. F-2 cache projection loss (deterministic; repro FIRST, fence second)
MECHANISM: DATA_webcalIcsCache = projection of memory layers at every R1 foreground write
(:2746-2752); signMeUpSynth has NO load/carry (only exam layer does — carryExamSynthFromCache
:2601) => cold-start writes DROP the tutorial block; :2742 assigns feed-dedupe-TRIMMED block
back to memory (one coverage blip persists); R2 poll can preserve but never restore layers and
can clobber mid-flight writes (:1048-69); R3 RMWs (reapplyExamSynth :2151,
reapplySignMeUpSynth :2105, publishDueBlock :1863, _applyPersonalIcs :2061) write blind AND
never move DATA_webcalFetchedAt => content churns under a frozen stamp (feeds F-1's confusion);
personal URL success replaces the block wholesale with no superset check (:1954).
Cable/HTML-fallback theories REFUTED (all personal failure paths keep old copy; HTML fallback
writes only DATA_timetableSrc_currentSemester :3053-3060; '(Problemclass) (Ü)' is webcal-native,
fixture wc_now.ics:98).
TESTS (write first, all fail today — from DataIntegrityLens):
1 R1 synth-drop: cold signMeUpSynth="" + cache containing synth block + successful feed fetch
  => extractSignMeUpSynth(cache) non-empty.
2 presence-vector monotonicity across alternating writers (R1/R2/R3 over canned bodies):
  layer vector may only shrink via its owner's prove-stale event.
3 personal poison: valid-but-fewer-events personal feed => block NOT replaced wholesale.
4 poll clobber race: poll read(:1048) held, reapplySignMeUpSynth lands, poll releases => new
  synth survives.
5 fetchedAt invariant: any cache-content-changing write either moves fetchedAt or is fenced by
  the (fetchedAt,fingerprint,len) tuple.
FENCE (one rule + one guard): carried layer := union(persisted canonical key, extractLayer(live
cache)); memory may override only after PROVEN (extend carryExamSynthFromCache pattern to
signMeUp; move dedupe to merge time, persist full block, stop :2742's assignment) + every
setString site re-checks (fetchedAt,fingerprint,len) against its baseline read (C10 family).

## D. F-6 dock dead-zone (45–90 min)
Home already ships 140px clearance (home_page.dart) — the gap is module_page.dart:115 ListView,
exams/grades/agenda lists. Add kDockClearance const (view_constants.dart; precedents 140/150/120
in-tree), apply .copyWith(bottom:) to those scrollables, adb spot-check: last module ⓘ and last
exam row tappable at scroll end on Pixel.

## E. F-10 duplicate exam attempt rows (30–60 min)
Five identical "Wed, 24.02.2027 11:00 - 13:00" rows on the module page (F2+F3 both confirmed).
Fix at the parse choke point ModuleInfoTable.parseFromHtml: dedup rows with identical cells, or
label them Versuch 1..n (source order). Fixture test with the 5-row block.

## F. D1 countdown conditional tier (60–90 min AFTER bugs land) — product spec in PANEL.md
"If you register"/"Bei Anmeldung" tier: !registered && window!=impossible && future dated
sitting && window open|closing-in-horizon; NO isTakingThisSemester gate. Muted day-offset row +
"register by <windowEnd>" sub-line (scheme.error <3d). Registered first, shared limit 6, silent
graduation, calendar/digest/clash stay registered-only. New l10n keys EN+DE, parity test.

## G. Housekeeping
- Fire clock: 30-min timebox (NTP server swap / auto_time cycle); if it doesn't stick, RUNBOOK
  rule: "Fire clock untrusted; drive.py stamps host wall-time on every Fire artifact; date
  verdicts normalized host-side."
- RUNBOOK known-degraded: F-3 tablet cross-column ruler (dev tablet, no human audience — revisit
  only if a human reads the tablet display), F-5 ILIAS WebView a11y (single user, TalkBack off),
  F-4 Edit-timetable naming, F-7 merged-event course-page gap, F-11/F-12 cosmetic batch.
- Kit-side data typo '…democratic socityes' — upstream, report-worthy to ILIAS? no, handbook data.
