# FixLogin fix brief
Owned files: lib/state_management/campus/kit_login_manager.dart

C52: stage0 cookie wipe scope — ILIAS-only clear (clear webview/PHPSESSID cookies + ilias jar entries) instead of full clearCookiesAndCache(), OR gate behind in-flight campus fetch check — pick the boring safe variant. C80: case-insensitive contains for the manual-redirect heuristics.



## Assigned verdicts (FULL verifier detail — authoritative)
- **C52** [REFUTED/?] Anchor real (kit_login_manager.dart:481-502, `fetchStage0_Init` ends with unconditional `await clearCookiesAndCache();`, reached from every ILIAS `_authorize`), but the shared-jar premise is false: `f
  → FIX: (derive from evidence)
- **C72** [REAL/low] kit_login_manager.dart:194-216 `_postFirstForm` takes the first <form> with non-null action and non-empty fields and POSTs all its inputs to `from.resolve(action)` (:208-209) with no kitHttps() check 
  → FIX: kit_login_manager.dart:208: `final actionUri = kitHttps(from, action); if (actionUri == null) continue;` (same for the Location resolve at :110 and :247) so no POST or hop leaves https *.kit.edu on any SSO path.
- **C77** [REAL/low] kit_login_manager.dart:91-155 `passBotChallenge`: `for (var attempt = 0; attempt < 3; attempt++)` GETs the 503 challenge, POSTs `solveBotChallenge`'s answer (:103) and immediately loops — no delay/bac
  → FIX: kit_login_manager.dart:99-103: after the FIRST rejected answer for a given seed pattern, set `botChallengeAlgorithmChanged = true` and return false once the current answer is rejected (detect rejection at :117/:134) instead of retrying the same formula; add a static consecutive-failure counter with a cool-down gate in passBotChallenge.
- **C79** [REAL/low] kit_login_manager.dart:446 `plusReady = check.statusCode == 200 && check.body.trim().trim() != "null";` — duplicated `.trim()` confirmed (harmless no-op). The surrounding `catch (e) { ...; return fals
  → FIX: kit_login_manager.dart:429-434/451-455: return a tri-state (or set a `plusUnavailable` flag) when the chain ends cleanly without an identity cookie vs when it threw, and have kit_provider._doFetchSignMeUp skip the 20 s cold retry when plus is known-absent for this account.
- **C80** [REFUTED/?] The deciding line is kit_login_manager.dart:695: `final body = response.body.toLowerCase();` — isManualRedirectRequired LOWERCASES the whole body before testing `body.contains("you must press the cont
  → FIX: (derive from evidence)
