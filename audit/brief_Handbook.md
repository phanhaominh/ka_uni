# Brief — Modulhandbook integration (feature design, Wave R32 candidate)
Owner-originated: "module handbook integration with the app is going to be strong feature".
Validated against the real artifact 2026-11-13 (MHB 82-804-H-2024 v1 2025-02-21 EN, 199 pp).

## Why it is strong (each point closes a gap this audit PROVED exists)
1. `isTakingThisSemester` today guesses relevance from *timetable presence* — a heuristic that
   almost silently hid the 26.11 ITDS exam window (proved correct only because ITDS is a summer
   module; the same logic is a coin-flip for any module offering exam sittings in a semester it
   is not taught — SPO §1.3 guarantees ≥1 exam date per semester for every module).
   A curriculum model makes the verdict principled: module belongs to plan ∧ recurrence term ∧
   recommended semester ∧ registration-window state.
2. D1 countdown eligibility becomes program-aware ("sitting open NOW for a module planned SS27"
   = informational; "sitting for your current-semester module closes 22.11" = loud).
3. Grades page today shows raw Campus rows. Handbook gives per-module CP, grading scale, PA
   weightings, and the SPO §7 formula (thesis double-weighted; ungraded modules excluded) —
   the app can compute the ACTUAL final grade and subject grades, not averages.
4. PA tables encode admission gates ("AM I Prerequisite 0 CP coursework" must pass before the
   AM I written exam counts) — deadline alarms for *coursework prerequisites*, the failure mode
   that blocks exam admission silently.
5. Progress model: 180 CP / subject totals (Fundamentals 127, Specialization 12 = choose 1 of 4
   majors, International Studies 14, Internship 12, Thesis 15×2-weight) + Orientation Exam
   rule (AM I + EM I by end of 2nd Semester, SPO §8) → real degree-progress UI with a deadline
   that currently exists nowhere the student sees daily.
6. Repeat rule (one retake, SPO §1.3) → attempt tracking on grades rows.

## Data sourcing (validated 2026-11-13)
- PRIMARY: official handbook PDF, mach.kit.edu/download/MHB/82-804-H-<spo>_v<n>_<date>_{en,de}.pdf
  (MEI BSc SPO2024 = 82-804-H-2024; stable URL pattern; versioned + dated in filename).
  Machine-friendly: §9/§10 module+PA tables parse cleanly with pdftotext (module IDs
  M-MACH-*/M-MATH-*, PA IDs T-*, CP, weights, exam types, recurrence, responsible, prerequisites,
  mandatory/elective, language). Module descriptions carry "Recurrence: Each summer term" etc.
- KNOWN WEAKNESS: the sample-curriculum semester grid (embedded p.5, handbook p.70) is a RASTER
  image (4186×8 strips) — semester placement is NOT text-extractable from the PDF. Derive
  recommended semester from recurrence + level + PA chain instead, or overlay from
  SECONDARY source below.
- SECONDARY (optional overlay): Campus KIT "Studienaufbau" per-student curriculum tree
  (cascampus iframe, authenticated, HTML) — authoritative *for the student's own binding*,
  incl. individual deviations; scrape-once cache, never a runtime dependency.

## Architecture (deliberately boring)
- Offline one-shot parser (python/pdftotext, lives in tool/ or audit tooling) → versioned seed
  asset in-repo: assets/handbook/mei_bsc_spo2024.json {modules:[{id, name, abbr, cr, subject,
  recurrence, mandatory, language, pas:[{id,name,cr,type,weight,prereq}], responsible}],
  subjects:[{name, cr, rule}], spo:{orientation:{modules:[...], deadlineSemester}, thesisWeight,
  retakes}}. Handbook changes ~once/year/program → manual re-run, diff review, version field
  shown in support bundle alongside app version.
- Runtime = pure model layer (ProgramModel) loaded from asset + joined to live data by module
  name/ID: exams (module IDs match Campus names 1:1 for MEI), grades, timetable, countdown,
  alarms. ZERO network dependency → zero fragility; works offline; testable with fixture JSON.
- UI (v1, one screen each): (a) Progress card on cockpit: CP earned/180 per subject +
  orientation-exam status with its deadline; (b) module detail sheet: PA checklist with
  prerequisites + recurrence + repeat counter; (c) grades: computed SPO grade (module → subject
  → final) with double-weight thesis handled correctly.
- Scope discipline v1: MEI BSc SPO2024 only (the owner's program + the fork's user base). JSON
  schema program-agnostic; adding a program = one parser run + seed asset, no code.

## Cost / risk
- Parser: 3–4h (tables cooperative; raster grid is the only hard part — skip it in v1).
- Model+join+tests: 3–4h. UI progress card: 2–3h. Module sheet: 2h. SPO grade calc: 2h (formula
  in §7 EN translation; verify against one real grades screen via the fleet).
- Risks: name-drift between Campus strings and handbook names (join on module-ID-like tokens,
  fall back to manual alias map in seed); SPO version bump (version in asset + support bundle
  makes it visible); raster-only semester grid in other programs' handbooks (same fallback).
- Sequencing: AFTER R31 fix wave (brief_FixR31.md). It is the largest item here; nothing in the
  fix wave depends on it; D1 countdown tier lands first and the handbook later UPGRADES its
  eligibility from timetable-heuristic to plan-aware.
