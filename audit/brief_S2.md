# Slice S2 — BShell (timetable visuals + home + profile)
Wave B UI polish. Build 0.7.0+40 on device; suite green; wave-A fixes LIVE.

## OWNED FILES (edit ONLY these)
- lib/timetable/pages/timetable_appointment_page.dart
- lib/timetable/views/timetable_daily_view.dart
- lib/timetable/views/timetable_weekly_view.dart
- lib/home/views/home_page.dart
- lib/profile/views/profile_view.dart
- lib/common/kit_progress_indicator.dart   (and other lib/common/*.dart ONLY if a fix needs it — you are the common/ owner, but keep changes additive/backward-compatible since many screens use these widgets)
- lib/l10n/strings_timetable.dart

Do NOT edit lib/l10n/l10n.dart (S1 owns it) — new strings go in strings_timetable.dart; if you need a key in the core l10n map, message `Main`.

## Rules
- VERIFY each claim against CURRENT code first; if already satisfied, no-op + report.
- Keep-list: hero transition from timetable block title into the detail sheet (keep it smooth); room-line distance anchor.

## Items
1. **#2 map marker** (timetable_appointment_page.dart ~74-97): a 25dp red circle with blur+spread shadow renders ~3x too large on the campus map, covers the whole building footprint, shows no room label — defeats the map's purpose. Replace with a standard map-pin icon (e.g. Icons.location_on / place) at a sensible size, PLUS a small room-label chip (the appointment room, e.g. "10.91") anchored just above/below the pin. Remove the heavy BoxShadow blob.

2. **#3 expanded appointment sheet** (timetable_appointment_page.dart ~118-173): the ListView ends with `SizedBox(height: 500)` phantom drag-padding and `maxChildSize: 0.4`, so expanding scrolls the title/ID/Ort off-screen leaving an empty blur panel. Delete the 500px spacer (minChildSize already gives drag room). Add `overflow: TextOverflow.ellipsis` to the maxLines:2 title (currently hard-clips mid-word). Put real content in the expanded state (full address + a campus/room link if available) so expansion is worth doing.

3. **#4 time badge overlap** (timetable_daily_view.dart ~99-212): the "HH:MM" badge is top-right `Positioned` while the title Column spans full width, so long titles run under the badge and cut mid-word; title Texts use maxLines:2 without ellipsis. Reserve the badge width (right-padding on the title column, or title+badge in one Row) and add `overflow: TextOverflow.ellipsis` to the title Texts.

4. **#5 carousel header collision** (timetable_weekly_view.dart + home header): the "Today, November 2"/"Heute" date heading floats over adjacent pages' peeking weekday columns → ghost half-letters at the carousel edges. Give the date heading its OWN fixed band above the carousel viewport instead of overlaying it on the page viewport. (Home's date header may live in home_page.dart — yours too.)

5. **#6 refresh spinner** (home_page.dart ~147 RefreshIndicator + kit_progress_indicator.dart): set RefreshIndicator `displacement` so the disc rests in the header gap, not centered over the profile-card name row / agenda banner. Give the app-bar profileReady spinner a `Semantics(label:)` so screen readers say what's loading (the bare KITProgressIndicator is reused everywhere and is indistinguishable — add an optional `semanticsLabel` param to kit_progress_indicator.dart, default null, and set it at the app-bar site).

6. **#7 name hard-clip** (profile_view.dart ~53): the headline name Text has no overflow policy → "HaoMinh Phan…" slices mid-glyph. Add `overflow: TextOverflow.ellipsis` (maxLines: 1).

7. **C44 (optional)**: if home_page adds a repeating Timer per exam window, replace with a single one-shot Timer for the nearest future windowStart/windowEnd among unregistered exams, setState on fire, cancel in dispose. Only if the code actually does the repeating-timer thing.

## Report
Per item VERIFIED-STALE / FIXED(hunk) / SKIPPED(reason). List any new strings_timetable.dart keys. Do NOT build/test.
