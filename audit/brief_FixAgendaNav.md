# FixAgendaNav fix brief
Owned files: lib/agenda/, lib/navigation/, lib/home/, lib/common_ui/, lib/timetable/logic/ics_export*

C2: IliasPageView.routeName='/ilias' + skip duplicate push when frontmost (mirror notification_deep_links one-page rule). C1: delete dead body-list index-2 entry + its comment. C98: 'already exporting' toast when share tapped while _inFlight. C16: end RefreshIndicator after content setState (unawait the smu/exams tail). C18-C25: agenda lows per verifier prescriptions; C19 = scheme-gate the external launchUrl.



## Assigned verdicts (FULL verifier detail — authoritative)
- **C1** [COSMETIC/?] kit_nav_container.dart:105-111 confirmed: body is `[SettingsPage(), KITHomePage(), IliasPageView(KITModule(), PHPSESSID_Future: Future.value(""))][_selectedPage]` with the commented-out old entry dire
  → FIX: (derive from evidence)
- **C2** [REAL/med] kit_nav_container.dart:85-95: the paperclip's customAction unconditionally does `Navigator.of(context).push(MaterialPageRoute(builder: ... IliasPageView(KITModule(), PHPSESSID_Future: vm.iliasManager.
  → FIX: In kit_nav_container.dart:88-94, tag the push with a RouteSettings name (add `static const routeName = "/ilias"` to IliasPageView) and skip the push when `ModalRoute.of(context)?.settings.name == IliasPageView.routeName` (i.e. already frontmost), mirroring the one-page rule in notification_deep_links.dart.
- **C3** [REAL/low] Anchors confirmed (relevant_module.dart:99-116 `row.id.contains(module.title)`; relevant_modules.dart:84-85 placeholder title; string_prettifiers.dart:29-42), but the claim's central mechanism is WRON
  → FIX: relevant_module.dart:103-107: match on the placeholder's provenance instead of prettified-title substring — persist the rowID on the placeholder (KITModule.hierarchicalTableRowId is set at relevant_modules.dart:84-86 time) and look up `row.id == rowId`, falling back to the current scan only when empty.
- **C16** [COSMETIC/low] As claimed: all visible content is rendered by the first setState (:147-167), then `_refresh` still awaits `signMeUpDone` with a 45 s timeout (:217) and `examsDone` with another 45 s (:228) before ret
  → FIX: Resolve the RefreshIndicator future after the content setState (e.g. run the smu/exams tail unawaited, or return from _refresh once the second setState at :196 lands).
- **C18** [REAL/low] Confirmed end-to-end: `fetchPlaces()` is unawaited in the provider ctor (kit_provider.dart:142); `KITTopographyManager` holds NO notify callback and never touches ChangeNotifier; the agenda's build li
  → FIX: kit_provider.dart:142 — chain `.then((_) => notifyListeners())` onto fetchPlaces (and optionally seed `topographyManager.places` from `loadSnapshot()` before the live fetch).
- **C19** [REAL/low] Verbatim: `onTap: () => launchUrl(Uri.parse(a.url), mode: LaunchMode.externalApplication)` — no scheme gate, no try/catch. The app hardened exactly this elsewhere: `_launchableUrl` in place_search_pag
  → FIX: agenda_page.dart:767 — reuse the F12 pattern: parse+validate (http/https, non-empty host) when rendering, and wrap launchUrl in an error-handled helper.
- **C20** [REAL/low] Confirmed: in the catch, `iliasError = (iliasCached == null || (iliasCached.$1 == null && iliasCached.$2.isEmpty)) ? …agenda.iliasUnreachable : null;` — with ANY cached content the error is forced nul
  → FIX: agenda_page.dart:190-193 — keep a non-null soft error whenever the live fetch failed, and render it as a faint line inside _iliasSection instead of nulling it when cache exists.
- **C23** [REAL/low] Key and comment ("parallel groups share start+title: keep one row") verbatim. The data premise is proven by a REAL KIT feed fixture: test/fixtures/wc_now.ics lines 97-130 contain three distinct-UID VE
  → FIX: agenda_page.dart:275 — include the room in the key (`"${o.title}|${o.start.toIso8601String()}|${o.room}"`); apply the same fix to the parse-level key at webcal.dart:139 (C74) or the occurrence-level fix is masked for same-anchor groups.
- **C24** [REAL/low] Verbatim: `bestTerm = e.terms.firstWhere((t) => t.startAt == at, orElse: () => e.terms.first);` where `at = e.nextRegisteredTerm(now)` (exam_list.dart:103-110: earliest future start among REGISTERED t
  → FIX: exam_list.dart — give nextRegisteredTerm the winning ExamTerm (or agenda: filter `e.terms.where((t) => t.registered != false)` before firstWhere / collect all ties and show a combined room).
- **C25** [REAL/low] Confirmed: `_refresh` has no re-entrancy flag; it runs from initState (:90) and every pull (:338). Two interleaved pipelines mean duplicated ILIAS dashboard round-trips (fetchUnread/fetchAnnouncements
  → FIX: agenda_page.dart:130 — `Future<void>? _refreshInFlight; Future<void> _refresh() => _refreshInFlight ??= …whenClear`, plus capture a sequence number before awaits to discard stale setStates.
- **C98** [COSMETIC/?] `Future<void>? _inFlight;` is file-global and `if (running != null) return running;` (line 26) returns the running future with no toast of its own; both call sites — agenda_page.dart:333 and settings_
  → FIX: Optional polish: on the dedupe path, if the call comes from a different route than the in-flight one, show a brief 'already exporting' toast (ics_export_action.dart:26).
