# R31 decision panel — 5-lens verdicts (FINAL)

All five lenses delivered (ProductOwner, Pragmatist, DataIntegrity, RootCause, Adversarial);
Main independently verified every load-bearing code claim. Positions are code/artifact-grounded;
panel was isolated per-lens by design. Supersedes REPORT.md findings F-1/F-2/F-3 and D-pending.

## D1 (unregistered-exam countdown) — PRODUCTOWNER: conditional tier
- POSITION: neither status quo nor bare countdown — gated **"If you register" / "Bei Anmeldung"** tier
  inside the Countdown card. Eligibility: `!registered && window != impossible && future dated sitting
  && window open|closes in horizon`. **No `isTakingThisSemester` gate** (proven wrong — see collateral
  bug). Row = day-offset in muted weight + sub-line `register by <windowEnd>`, error-colored <3 days
  (cockpit runway doctrine). Registered rows first, share limit 6, never displaced. Graduation to the
  registered tier on success = silent; disappearance at window close = self-explained by its own
  sub-line. Calendar/digest/clash stay registered-only (exam_synth doctrine untouched).
- REVERSAL: on ONE observed noise incident, on owner's taste veto, or on an evaporation harming trust.
- PRAGMATIST agrees it's the highest felt value but ranks it after the bug wave (feature, not fix;
  60–90 min once bugs are done).

## Collateral bug found by panel — HIGHEST SEVERITY (verified by Main in code)
`isTakingThisSemester == false` (lecture absent from webcal timetable) gates ALL urgency surfaces:
- deadline alarms: `parsed.where(... != false)` campus_manager:2777
- Act-now section: `!inCatalog` exams_page:58 (catalog = `!registered && taking==false`, :52-55)
- agenda Deadlines rows: agenda_page:559 `!= false`
=> IT and Data Science (26.11. exam, reg closes 22.11.): zero alarms, invisible from all urgency
surfaces. WHETHER THIS IS A BUG DEPENDS ON USER GROUND TRUTH: is ITDS actually in their plan this
term? If yes: tri-state heuristic must stop voting `false` solely from timetable absence (an exam
with an OPEN registration window is the institution asking you to decide — that should flip null).
If no: app correct, catalog label correct, downgrade to cosmetic.

## D3/F-2 (feed flap) — DATAINTEGRITY: VERDICT = cache is a memory-fed projection
- My report's "webcal-vs-HTML-fallback" story: **REFUTED** — HTML fallback writes only
  DATA_timetableSrc_currentSemester (:3053-3060); `(Problemclass) (Ü), Nepechiy, MATH` is the
  webcal-native SUMMARY style (fixture wc_now.ics:98). Cable unplugging: **red herring** — every
  personal-ICS failure path provably keeps the old copy (:1996-2001, :2016-2035).
- Real mechanism: ≥7 writers, 3 merge rules, no fence:
  R1 foreground (:2746-52): cache := feed + MEMORY blocks; signMeUp layer has NO load/carry ->
    cold-start writes drop tutorial block; :2742 assigns feed-dedupe-TRIMMED block back to memory
    (one coverage blip persists until next SignMeUp scrape).
  R2 poll isolate (:1048-69): cache := fresh feed + layers extracted from stale cache; can preserve
    but never RESTORE a dropped layer; blind setString can clobber a mid-flight main write.
  R3 RMW re-apply/publish/publish-due/_applyPersonal: no read-before-write, no generation check;
    RMWs move content WITHOUT moving DATA_webcalFetchedAt => content fresh under a stale banner
    (ties F-2 to F-1).
  Personal URL success: valid-but-older block replaces wholesale, no superset check (:1954).
- The 3 observed screenshot variants = which writer stamped last (boot_15 memory-empty vector,
  boot_30/60 synth+personal restored, postpull personal-spellings + trimmed synth). Home renders
  straight from the cache (:418-419) so every stamp is user-visible.
- REPRO: 5 deterministic offline tests specified (R1 synth-drop assert, presence-vector monotonicity
  across alternating writers, personal-poison, poll-clobber race) — all fail today.
- FENCE: every carried layer = union(persisted canonical, extract(live cache)), memory overrides only
  after PROVEN (extend existing carryExamSynthFromCache pattern to signMeUp; dedupe at merge time,
  persist full block) + C10-style (fetchedAt,fingerprint,len) tuple guard on every setString site.

## D2 ordering — PRAGMATIST (measured costs)
1 F-9 version string (20–30 min; package_info_plus only transitive — real plugin wiring, not one-liner)
2 F-6 dock clearance (45–90 min; home already has 140px precedent; module/exams/grades/agenda lists
  lack it — one constant per page)
3 F-1 heal bug (2–4h honest, crime scene = campus_manager 2546–2800 + R16a probe; stop-loss: land
   diagnostic capture + RUNBOOK note if the notify hunt exceeds budget)
4 F-10 dup exam rows (30–60 min, parse-time dedup choke point)
5 D1 countdown tier (60–90 min after bugs)
6 F-2 cache fence (DataIntegrity repro-first: 5 failing tests, then fence; ~2-3h — moved UP:
   deterministic offline repro exists, cable variable dead, three lenses concur on mechanism)
7 F-3 tablet axis: RETRACTED by Adversarial (no wide artifacts exist; cited shots measure delta=0)
WONT-FIX this wave: mid-scroll dock transparency, F-5 (sole user proven non-TalkBack),
F-4/F-7/F-11/F-12 batch.
D4 Fire clock: 30-min timebox, else permanent RUNBOOK rule "Fire clock untrusted; drive.py stamps
host wall-time on artifacts; date verdicts normalized host-side".
FINAL MERGED ORDER (post-adjudication): F-9 -> F-6 -> F-1 (probe first, see PANEL F-1) -> F-10 ->
F-2 fence -> D1 countdown tier. Ground-truth gate for the ITDS alarm bug in brief_FixR31 item 0
awaits owner answer.

## F-1 mechanism — ROOTCAUSE ENGINEER (conf 0.8; report's "probe never fires" RETRACTED)
- Notify chain PROVEN intact (single root KITProvider; notify strictly after durable stamp write;
  provider semantics guarantee dCD re-entry). The card instead reads stamp+cache via
  SharedPreferencesAsync — it is the ONLY async reader of the webcal keys; all writers are legacy-API,
  two processes; THE REPO ALREADY DOCUMENTS THIS CHANNEL LYING for these keys (campus_manager
  :2690-2697 comment: async read null right after successful write, device-observed; Main verified
  every campus_manager/mei_notifications writer uses legacy getInstance).
- Latch half (code-certain): _readCache has no null guard -> ghost null adopted -> _seenFetchedAt=null
  -> _feedFresh hard-false (banner) + _feed empty (hero absent) + probe compares null==null forever.
- Explains pull-fails-to-heal (probe fires, reads ghost, relatches; every later notify re-confirms it)
  and the ~30-min heal (poll process write eventually converges the async view).
- MINIMAL FIX (~8 lines, 2 files): (1) campus_manager stores webcalWrittenAt+webcalMergedFeed in
  memory on success; (2) _resyncIfStale memory-first (same-isolate handoff, synchronous with the
  notify), async-prefs probe demoted to poll-fallback; (3) _readCache: null stamp/body = keep last
  good, never latch. API unification = separate hygiene wave (touches every fence).
- 5-MIN PROBE on debug build: stuck-banner window -> background+foreground (resume bypasses
  notify+probe via _readCache). Resume heals => ghost+latch (this mechanism). Resume does NOT heal
  while prefs file is new => notify chain dead after all. Two debugPrints (NUHC) if build allows.

## F-2 mechanism — DATAINTEGRITY (see above), CONFIRMED INDEPENDENT by ADVERSARIAL
Three lenses concur: flap real, cable refuted (all personal-ICS failure paths keep old copy;
first flap transition was 63s post-replug inside one cold boot), HTML-fallback refuted (writes
only DATA_timetableSrc_currentSemester). Variants = layers appearing/disappearing per writer
timing. Fence + 5 offline tests stand.

## F-1/F-2/F-3 ADJUDICATION — ADVERSARIAL VERIFIER (ruling accepted with 2 notes)
- F-1 DOWNGRADES-TO: two evidence failures in my report, accepted:
  (a) NO artifact ever shows the heal — r31p4_home_top/de_home/nomensa are all scrolled past the
      banner region; "self-healed 00:51->00:57" was P4's verbal claim, Main repeated it unchecked.
      RETRACTED as artifact-verified fact.
  (b) Fire's only PTR (00:25:49) did NOT move the stamp (00:51:58, poll-plausible) -> that pull's
      webcal step failed -> banner surviving it was CORRECT behavior. The "pull heals nothing"
      row for Fire is premise-broken. Surviving hard core: stamp present in prefs 32s before
      r31f3_nocanteen shows the banner (00:52:30), AND — unreported by the original audit —
      EVERY Pixel top frame all night shows the banner claiming staleness WHILE the grid in the
      same frame renders today's lectures (00:29, 00:39, 00:45, 00:52).
  NOTE 1: the divergence is not an unexplained contradiction — it is the ROOTCAUSE mechanism's
  signature: ghosted null latch => card feed empty/banner-hard-false while the legacy-reading
  grid is fresh. RootCause predicted exactly these frames. Conflicting claims resolved: keep
  ghost+latch as mechanism; keep severity (permanent user-visible lie + hero absence on daily
  driver); drop the PTR-pull and self-heal legs from the evidence.
  NOTE 2: "poll writes can't notify" (adversarial's rival mechanism) cannot produce persistent
  divergence through the P1->P3 notify/dCD storm — latch is required for that. Probe unchanged
  (resume discriminator), now with: PTR pull + immediate run-as prefs stamp read + scroll-to-top
  frame, so future pull legs carry real evidence.
- F-3 REFUTED — Main confirmed: no R31 artifact is landscape at all (39/39 fire shots 800x1280;
  zero *wide*), and cited shots measure column delta = 0 px (teal labels + ruler 1.20 px/min
  linear). The "60-145px at 1280x800" claim had no artifact. Retracted. Wide layout remains
  verified only by R18-era code guard + old tablet_audit shots; revisit via emulator -screen
  only if a human ever uses the tablet in landscape.
- Clock notes: "Pixel clock anomaly" = AM/PM 12h rendering misread (12:45 == 00:45). Fire is
  simply EST-set and internally consistent. D4 stays a 30-min timebox, severity minimal.
- Audit-process lesson (logged): agent verbal claims must cite a frame Main has opened; prefs
  timestamps must be paired to the specific action they're claimed to prove.


