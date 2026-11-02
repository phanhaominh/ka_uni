# Slice S5 — BIlias-UI + Geo-input
Wave B operability polish. Build 0.7.0+40; wave-A ILIAS fixes (C47/C48/C50/C53/C56/C57) are LIVE.

## OWNED FILES (edit ONLY these)
- lib/ilias/views/ilias_page_view.dart
- lib/geo/views/place_search_page.dart   (the VIEW; NOT lib/geo/logic/place_search.dart — the ranking logic stays untouched, agenda walk-hints depend on it)
- lib/l10n/strings_places.dart

Do NOT edit l10n.dart — for ILIAS chip labels/tooltips, MESSAGE `Main` with the exact de+en keys you need (ILIAS has no own strings file), and use a placeholder that compiles (I'll wire the core keys). For geo strings use strings_places.dart.

## Rules
- VERIFY against current code. Do NOT touch place_search.dart LOGIC (rank/tiers/fuzzy) — only the page's transient UI state.
- Keep-list (do NOT regress): agenda room lines are tinted, tappable, carry the distance anchor into the room finder; place-search quick chips show localized labels while searching German directory; the exact>prefix>alias>tier ranking.

## Items
1. **#1 ILIAS floating chips occlude the site** (ilias_page_view.dart ~359-407): four glass controls (top-left back chip over the ILIAS HINWEIS banner + KIT logo; top-right refresh chip over the site's overflow menu; two bottom-right history chips over the site's own bottom nav, hiding/intercepting taps on the 'Lernerfolge' tab — a real dead zone on every ILIAS page). Consolidate all four into ONE slim translucent toolbar row placed ABOVE or BELOW the webview (so it never overlaps web content), OR auto-fade the two history chips ~2s after appearing. Also enlarge the glass chip hit target from 40×40 to ≥44 and add tooltips (Semantics/tooltipMessage). Preserve existing behavior (back = webview history back then pop; refresh = re-auth). Pick the toolbar approach if it fits the layout cleanly; the auto-fade if the toolbar would fight the Scaffold. State which you chose and why.

2. **C92 (optional)**: place_search_page.dart `_onChanged` setState (~107) — clear or dim `_results` while a new query is in flight so stale results for the previous keystroke don't linger. Only if it's a clean, low-risk change; else skip.

## Report
Per item VERIFIED-STALE / FIXED(hunk) / SKIPPED. List any core l10n keys you need from Main (exact de+en text). Do NOT build/test.
