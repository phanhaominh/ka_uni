# Library seat reservation (Anny) — implementation plan  [approved design 2026-11-12]

Evidence: audit/anny_api.md (live capture) + research fleet (docs.anny.co, wiestju prior art, ToU, KIT rules).
DECISION LOG:
- Auth = **headless SAML in Dart** (KITLoginManager pattern): no new webview dep, silent refresh, app never sees more than campus login does. Password NEVER logged. Fallback: card stays 100% anonymous, booking button explains + opens web.
- Book via **proven cart flow** (POST order/bookings → POST order?oid&oat), cancel via **GET /bookings/{id}/cancel?access_token=** — captured live, beats docs. `/bookings/instant` NOT used (unverified).
- Failed/expired cart → `GET /order/bookings/delete-all?stateless=1&oid&oat` (quota-lock lesson).
- Room catalog: 8 slugs hardcoded (public), runtime-discover service ids via anonymous `GET /resources/{slug}?include=services` (wiestju lesson: never hardcode service ids).
- Never re-implement booking rules client-side: legality from `intervals/start` + `availability/start-dates`.
- Rate discipline: sequential calls, in-memory 4-req/s guard, 429→Retry-After honored, backoff; card refresh = 5 min cadence max (existing timer).
- Privacy: only `anny_shop_jwt` (+ uuid) in prefs+keychain, never in logs; browse = zero cookies sent with personal data.

## Room catalog (hardcoded in anny_api.dart)
```dart
const annyRooms = [ // (slug, section, seatish)
  ('1-lehrbuchsammlung-eg-und-1-og', seats), // 3191
  ('2-lesesaal-naturwissenschaften-2-og-und-empore', seats), // 3404 138
  ('2-lesesaal-naturwissenschaften-2-og-und-empore-kopie-nnlimpvbvg', seats), // 35674
  ('lesesaal-medienzentrum-vk0dz5dkh9', seats), // 3965
  ('gruppenraume-kit-bibliothek-sud', groups), // 3155
  ('gruppenraume-informatikom-ezitnsnlmv', groups), // 22912
  ('beratungsbox-bwpevfbngt', groups), // 10561
  ('hka', groups), // 3143
];
```

## Files & contracts (pool slices; W-batches parallel-safe)

### lib/library/anny_api.dart  (W1)
Pure JSON:API client. No Flutter imports.
```dart
class AnnyHttp {
  AnnyHttp({Client? client}); // injectable for tests
  Future<Map<String, dynamic>> get(String path, {Map<String, String>? q, String? bearer});
  Future<Map<String, dynamic>> post(String path, Object? body, {Map<String, String>? q, String? bearer});
  // headers: accept/content-type vnd.api+json, x-app-key anny_shop, UA browser-ish
  // 429: throws AnnyRateLimited(retryAfterSec); 401: AnnyUnauthorized; others AnnyError(status, details)
}
class AnnyRoom { id, slug, name, quantity, section, color, minDuration, maxDuration, interval, advanceDays, openFrom, openTo, serviceId }
class AnnySlot { DateTime start; int free; String unavailability /*'' when available*/ }
Future<List<AnnyRoom>> fetchRooms(AnnyHttp h); // 8x resources?include=services, cached by caller
Future<List<AnnySlot>> fetchIntervals(AnnyHttp h, String slug, int serviceId, DateTime day); // intervals/start
Future<Map<DateTime, int>> fetchBookableDays(AnnyHttp h, String slug, int serviceId); // availability/start-dates
Future<int> freeNow(AnnyHttp h, String slug, int serviceId); // intervals/start now-rounded .free sum (quota of first)
Future<({String oid, String oat, String bookingId, String number})> cartAdd(AnnyHttp h, String bearer, {required String childResourceId, required int serviceId, required DateTime start, required DateTime end});
Future<String> cartCheckout(AnnyHttp h, String bearer, {required String oid, required String oat, required String givenName, required String familyName, required String email, required String visitToken}); // → booking number
Future<void> cartDeleteAll(AnnyHttp h, String bearer, {required String oid, required String oat});
Future<String> childSeats(AnnyHttp h, String slug, {required DateTime from, required DateTime to, required int serviceId}); // children w/ availability filter (pick free seat id)
Future<void> cancelBooking(AnnyHttp h, String bearer, {required String bookingId, required String accessToken});
Future<List<AnnyBooking>> myBookings(AnnyHttp h, String bearer, String accountUuid); // customer-accounts/{u}/all-resources OR /bookings?filter[upcoming_only]
```

### lib/library/anny_auth.dart  (W2)
```dart
class AnnyAuth {
  AnnyAuth({Client? client});
  Future<AnnySession> signIn({required String kitUser, required String password}); // throws AnnyAuthError(reason)
  // chain: GET auth.anny.eu/login/sso (XSRF cookie, inertia version from data-page)
  //      POST login/sso {domain:'kit.edu'} → x-inertia-location header
  //      GET idp SSO url → csrf; POST j_username/j_password/_eventId_proceed/fudis...
  //      POST SAMLResponse+RelayState → /consume → capture cookies anny_shop_jwt + anny_shop_alvo
  //      GET anny all-resources (authed) → regex customer-account uuid
}
class AnnySession { jwt, visitToken, accountUuid, savedAt } // isExpired = savedAt>50min
// persistence inside manager: prefs 'ANNY_jwt','ANNY_alvo','ANNY_uuid'; keychain 'ANNY_pass' (like KIT pw)
```

### lib/library/anny_manager.dart  (W3) — mirrors MensaManager idioms
```dart
class AnnyManager extends ChangeNotifier {
  // state: rooms, freeCounts per room, todaySlots(fav), bookings, session/signedIn, loading, error enum
  // boot(): load cache→notify; if !FLUTTER_TEST kick refresh (anon part only)
  // signIn(kitUser,pw)/signOut()/refreshBookings() (authed); book(room, start, dur): free seat pick → cartAdd→checkout→notify; cancel(b)
  // auto-refresh token on expiry while pw present; all failures → stale cache kept, error enum set (never clear)
  // prefs: ANN_fav (room slug), ANN_first, ANN_last, ANN_email derived '${kitUser}@student.kit.edu'
}
```

### lib/library/library_today_card.dart + library_page.dart  (W4)
Card: PaddedTitle('Bibliothek'/'Library') + refresh ↻; favorite room "{n} seats free" + open/closed + next-free chip; ACTIVE BOOKING banner w/ 15-min check-in countdown (red) → detail; not-configured state → "Sign in with KIT account" CTA; failure dialect identical to mensa card (cloud_off + retry + toast).
Page: sections Einzelplätze/Gruppenräume rows (name, free now/total, open-closed); row → day strip (start-dates) + start-time list (intervals/start; grey reasons) + duration chips (30min–5h / 15-180 by room) → Confirm sheet (room, window, check-in hint, cancel-until line, name fields pre-filled) → book; "My bookings" section: upcoming list, cancel w/ confirm dialog; sign-in dialog = same two-field layout as campus login; EN/DE via L10n.
Home wiring: `home_page.dart` card slot + settings toggle 'Bibliothek' section + `kit_provider.dart` `late final AnnyManager anny` boot like mensa.

### lib/l10n/strings_library.dart  (W4b)
Keys: library.title/freeNow/nextFree/openUntil/closedOpens/book/roomBook/duration/confirm/checkinHint/expires15/cancel/cancelConfirm/justTaken/loginKit/signInTitle/myBookings/noBookings/advanceDays/capacity/signedInAs/signOut/loadFailed/bookingFailed/canceledOk/checkinBanner. de+en parity test must pass.

### Notifications  (W5)
On booking success: schedule at start+1.. start+14 min "check in now / verfällt in X" local notif (existing flutter_local_notifications channel pattern); on cancel: cancel it. Skip if not feasible cleanly — card countdown is primary.

## Test plan (W6 tests, real fixtures)
- anny_api_test: fixture-driven (captured JSON bodies) — rooms parse, intervals parse, 429 retryAfter, cart flow sequence + delete-all-on-fail, cancel URL shape, rate-guard (4 identical/1s → throttled).
- anny_auth_test: fixture HTML chain (login/sso form, inertia header, idp form, consume w/ Set-Cookie) — incl. failure fixtures (bad password page, changed markup → AnnyAuthError not hang).
- anny_manager_test: cache-first paint, anon boot no-auth no-pw, book happy-path with fake http (picks free seat, calls cart endpoints in order, notifies once), 401→auto re-sign-in once then surface, booking expiry countdown logic.
- widget: card 5 states (not-signed-in, signed-in no booking, active booking pre-start, active-in-lapse-window, failure) + EN parity + cancel confirm dialog.
- l10n_parity_test untouched-green.

## Ship gate
1. auth headless PoC (me, live, NOW) — GO/NOGO for in-app booking; NOGO → anonymous browse + web-deeplink booking (still v1).
2. implement W1+W2 → W3 → W4/W5, dart analyze clean, all tests green.
3. device E2E: sign-in (real KIT creds, user-authorized), book a real slot, cancel it, screenshots.
4. post-feature audit fleet (code + device), fix survivors, commit v0.9.0+58.
