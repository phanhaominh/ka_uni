# FixGeoTtl fix brief
Owned files: lib/geo/, lib/timetable/views/, lib/timetable/pages/, lib/timetable/models/timetable_*.dart, lib/utils/, lib/module/models/module.dart

C14: bounded-token building-number matcher in walk_hint resolveRoomPlace (fixes wrong distances + walk hints). C15: shared-token requirement for fuzzy bind. C89: minute tryParse + null guard. C90: controller listener leak in appointment page (store+dispose). C91: rename isEmpty→hasEmptySlot. C93: horizonDefault stale static (recompute per expansion).



## Assigned verdicts (FULL verifier detail — authoritative)
- **C14** [REAL/med] Verbatim as claimed: `final number = _buildingNumber.firstMatch(room)?.group(0); if (number != null) { final hits = places.where((p) => p.title.contains(number)).toList(); if (hits.isNotEmpty) return 
  → FIX: walk_hint.dart:17 — match the number as a bounded token instead of raw contains (e.g. `RegExp('(^|[^0-9.])' + RegExp.escape(number) + '([^0-9.]|$)')` per title) and prefer an exact-token hit over prefix hits before falling through to the fuzzy pass.
- **C15** [REAL/low] Gate confirmed: only `bestScore >= 75` (line 33) separates a bind from null. But the entry's headline example is refuted by simulation of the exact Dart algorithm (fuzzywuzzy-1.2.0 WeightedRatio: base
  → FIX: walk_hint.dart:33 — beyond the bare score, require a shared alphanumeric token of length ≥4 or equal `category`, and reject pairs whose differing tokens are both number-like.
- **C89** [REAL/low] Deciding lines: `appointment.begin = appointment.begin.copyWith(hour: int.tryParse(beginStringSplit[0]), minute: int.parse(beginStringSplit[1]));` (and same for end). No app-local `on DateTime` extens
  → FIX: timetable_appointment.dart:157-158: use int.tryParse for the minute fields too and `if (h == null || m == null ...) return null;` before copyWith, mirroring the existing length guards at :140-155.
- **C90** [REAL/med] `builder: (context, controller) { controller.addListener(() { setState(() { _draggableSheetOffset = controller.offset; }); });` — listener registered on every builder invocation; the file has no remov
  → FIX: timetable_appointment_page.dart:104-109: keep `controller` + listener closure in state fields; only addListener when the controller instance changes (remove the previous one first), and removeListener in dispose().
- **C91** [COSMETIC/?] Code matches the claim exactly: isEmpty returns true on the FIRST empty appointment (i.e. 'has a free block', since genericAppointmentsSchedule pre-seeds all 7 slots with empties — a fully-loaded day 
  → FIX: Rename to `hasEmptySlot` or delete (timetable_daily.dart:27).
- **C95** [REAL/low] Both sub-claims hold verbatim. (1) Substring filter: `if (entryLower.contains(ignored))` — any fragment CONTAINING 'prüfung'/'klausur' dies, so a legit '... - Klausurplanung' fragment vanishes from th
  → FIX: string_prettifiers.dart:14-26: match whole trimmed fragments (entry.trim().toLowerCase() == ignored, or word-boundary regex) and return split.join('-').trim().
- **C96** [REAL/low] Both halves confirmed. (a) `final startIdx = rawResponseBody.indexOf("["); final endIdx = rawResponseBody.lastIndexOf(";");` — a bracket in any leading JS comment or code after the array's last assign
  → FIX: KITTopographyManager.dart:43-46: anchor extraction on the array assignment (e.g. regex `=\s*\[` to the matching first `]` before `;`) and log/count parse failures instead of silent catch.
- **C97** [COSMETIC/?] Alias loop uses strict `if (tier == null || s > score)` (line 97), so among equal-scoring aliases the FIRST in p.aliasList wins matchedAlias; the sort tie-break is by score, so display rank is unaffec
  → FIX: Optional determinism: on ties keep the shorter alias or lexicographically smallest (place_search.dart:95-101).
