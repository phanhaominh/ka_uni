# Lane brief R36.2 — CAMPUS-NOW STRIP (merge mensa+library home cards)

Repo /home/phan/ka_uni (Flutter, KIT student app). Read RUNBOOK.md "home"
+ "gap planner (R35.5)" sections, then lib/mensa/views/mensa_today_card.dart,
lib/library/library_today_card.dart, lib/home/views/home_page.dart (seats
around line 233-260), lib/common/data_trust.dart FIRST.

## Goal (roadmap R36.2)
The two home cards (MensaTodayCard, LibraryTodayCard) become ONE compact
"Campus now" glance card: two lines, one per source, each with its own
DataTrust verdict marker; each row tap-through goes to exactly where the
old card's own "view all"/detail tap went today. Two PREF keys
(PREF_showingMensa, PREF_showingLibrary) collapse to one
(PREF_showCampusNow, default true).

## Hard rules
1. NEW lib/home/views/campus_now_card.dart. It READS the same providers
   (Provider<KITProvider> -> vm.mensa / vm.anny) and reuses the same
   freshness decisions — DataTrust.evaluate(...) per row with the EXACT
   thresholds already in use (mensa 6h aging/24h untrusted from
   mensa_today_card, seats 15 min from gap_plan_card/anny wording; import
   and reuse, do NOT re-tune). Per-row marker from the verdict enum
   (fresh: none — silence is the fresh voice; aging: subtle dot;
   untrusted: explicit "veraltet"/stale word, matching the mensa footer
   wording via existing l10n keys).
2. Line content = honest glance only: mensa row "Mensa · open 11:30-14:00"
   / "closed" / valueNone from existing mensa model state; library row
   "Library · {n} seats free" (same zero-is-news? NO — in the strip 0
   seats IS the news: render "0" with the untrusted-free wording already
   in library card; grep its exact strings; reuse l10n keys, add only
   genuinely new ones). Never invent claims the full cards would not
   make; strip text is a SUBSET of what each card already certifies.
3. Tap-through: mensa row -> the route MensaTodayCard's detail CTA pushes
   (grep pushPageOnce there); library row -> LibraryTodayCard's. F12: no
   dead chevrons — only render the chevron when a target route exists.
4. home_page.dart: replace the two settings-gated card blocks with one
   showCampusNow-gated block at the MESA seat (the old mensa seat; the
   library block deleted; keep the GapPlanCard block and spacing idiom
   untouched). Legacy-home branches: they share the same blocks today —
   strip lives in both like the cards did.
5. PREF cutover (clean, precedent PREF_showingProfile in RUNBOOK R35.3):
   delete showingMensaKey/showingLibraryKey BoolSettings, their two
   settings_page rows, ALL reads/writes; add showCampusNow (
   showingCampusNowKey = "PREF_showCampusNow", default true) + one
   settings row (label de/en reuse the old section's words where apt).
   Orphan PREF_* residue on old devices stays inert (documented
   liquidAssEverywhere precedent) — no purge shim.
6. Old card files: delete BOTH card dart files ONLY if nothing else
   imports them (grep; if the full-page detail views import shared
   widgets from them, relocate those widgets to the owning feature dir
   instead — never import from lib/home into features).
7. l10n: new keys go to the mensa/library/settings sections of BOTH de
   and en tables in lib/l10n/l10n.dart — parity test is binding.
8. Files you may touch: lib/home/** (campus_now_card.dart new;
   home_page.dart seats), lib/settings/** (rows/provider), the two card
   files (delete or strip to relocated shared widgets), lib/mensa/** and
   lib/library/** ONLY for widget relocation, lib/l10n/l10n.dart +
   strings_settings.dart, test/campus_now_test.dart (new: strip renders
   both rows from faked provider state incl. untrusted marker path and
   the 0-seats line; tap-through targets exist), RUNBOOK.md (R36.2
   entry). NEVER touch lib/diagnostics/**, lib/settings/views row areas
   belonging to the doctor section, lib/gapplan/**, lib/main.dart —
   sibling lane owns doctor. Coordinate point: settings_page.dart — you
   EDIT the two existing rows (delete) and add ONE row near them; keep
   edits minimal-distance to reduce merge friction.
9. Verification: analyze clean on touched files; new test + l10n parity +
   home_r35_split_test still pass (it asserts card absence in legacy
   branch? re-read and keep it green — if it references deleted
   constants, update that test's composition assertions to the strip,
   that is contract evolution, allowed for this file). NO full suite,
   NO build, NO device, NO git.

Report: files touched, deleted inventory (what moved where), pref cutover
summary, test names.
