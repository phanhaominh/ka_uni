# FixIlias fix brief
Owned files: lib/ilias/, lib/state_management/ilias/

C47: split the webview gate into loading vs auth-failed (error scaffold + retry button re-invoking PHPSESSID future). C53: persist-seen AFTER successful notify + cap-eviction resurrection guard. C48: mounted check in _pathFor; drop dead pagesStackSize.



## Assigned verdicts (FULL verifier detail — authoritative)
- **C47** [REAL/med] ilias_page_view.dart build gate: `if (!snapshot.hasData || _phpsessid.isEmpty) return Scaffold(body: Center(KITProgressIndicator()))`. Callers pass `vm.iliasManager.getPHPSESSID()` (module_page.dart:5
  → FIX: Split the gate: `snapshot.hasData && _phpsessid.isEmpty` should render an error scaffold with a retry button (re-invoke the PHPSESSID future / authorize) instead of KITProgressIndicator; same for the post-refresh empty state (ilias_page_view.dart ~314-322 and refreshSession ~:330).
- **C48** [REAL/low] Core claim verified: `static final Map<String, Future<void>> _downloadsInFlight = {}` (ilias_page_view.dart:167) is keyed by URL only; the follow-up caller resolves via `inFlight.then((_) => _pathFor(
  → FIX: In `_pathFor`, `if (!mounted) return null` before Provider.of (ilias_page_view.dart:~177); drop the unused `pagesStackSize` field and its increment (:118, :121).
- **C50** [REAL/low] All three sub-claims verified in ilias_scraper.dart. (1) `_unreadFrom` :176-185 takes `RegExp(r'class="badge[^"]*"[^>]*>\s*(\d{1,4})').firstMatch(body)` over the WHOLE dashboard document, not a topbar
  → FIX: Add pure-parser fixture tests pinning the observed shapes (badge position, title regex, news block); scope `_unreadFrom` to the topbar region and have fetchCourses log/toast when 200+not-logged-out parses zero courses (ilias_scraper.dart:155-185).
- **C51** [REAL/low] Mechanism half-corrected. The bounded wait is real (ilias_manager.dart:26-30, `for (var i = 0; i < 120 && isBusy; i++)`), and getPHPSESSID can return "" both after a wedged >60 s chain and after any f
  → FIX: In getPHPSESSID, when the wait expires with isBusy still set, `await _authInFlight` once before returning, and have callers treat "" as an error state (pairs with C47 fix).
- **C53** [BY-DESIGN/?] ilias_watcher.dart documents both halves. Persist-before-notify is an explicit choice: 'persist the seen-marking BEFORE notifying so a redelivered board never re-notifies' (:64-66), and marking beyond
  → FIX: (derive from evidence)
- **C54** [BY-DESIGN/?] Code exactly as claimed (`diffAndNotify`: `final running = _inFlight; if (running != null) return running;` — the second caller's `fresh` is dropped), but the drop is the acknowledged cost of the docu
  → FIX: (derive from evidence)
- **C55** [REAL/low] file_viewer.dart:66-77 delete button: `unpinFile(...)` returns a Future and is not awaited — `File(widget.path).deleteSync(); Navigator.pop(context);` run immediately; an unhandled rejection or a proc
  → FIX: Make the delete callback async: `await unpinFile(...)` (with catch+toast) before `deleteSync()`, or filter missing files in getFilesForSemester (file_viewer.dart:67-76 / files_manager.dart:170-179).
- **C56** [COSMETIC/?] Confirmed inconsistency: `downloadFile` (ilias_manager.dart:105-139) calls `netGet(...)` directly, while every scraper path runs through `_withSessionBody` (ilias_scraper.dart:70-84) with its re-autho
  → FIX: (derive from evidence)
- **C57** [REAL/low] Chain verified end-to-end: `hasIliasLink` is `link.toLowerCase().contains("ilias")` on the raw href (module_info_table_cell.dart:96-98) → row.iliasLink = cell.link, last ilias-cell wins (module_info_t
  → FIX: Validate the scraped href the same way as the manual path (https + *.kit.edu host, ilias.studium.kit.edu preferred) before assigning row.iliasLink (module_info_table_cell.dart:96-98 / module_info_table_row.dart:31-35), e.g. reuse `KITLoginManager.kitHttps`.
- **C58** [COSMETIC/?] Anchor exact: agenda_page.dart:177 `await vm.iliasAuth; // don't race the auto-login SSO`. Termination is structural: `vm.iliasAuth = vm.iliasManager.authorize().catchError((_) {})` (credentials_provi
  → FIX: (derive from evidence)
- **C60** [COSMETIC/?] Confirmed: notifyChange hardcodes `payload: NotificationPayload.agendaChanges` (mei_notifications.dart:112); IliasWatcher reuses it via `notify = MeiNotifications.notifyChange` (ilias_watcher.dart:30-
  → FIX: Add a payload parameter to notifyChange (mei_notifications.dart:99, default agendaChanges) and pass NotificationPayload.agenda from IliasWatcher (ilias_watcher.dart:30-31) so the ILIAS push lands without the false changes-pulse.
