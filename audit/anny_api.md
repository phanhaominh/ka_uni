# Anny (KIT-Bibliothek) API catalog — captured live 2026-11-12 via session inspection

## Hosts & common headers
- Backend: `https://b.anny.eu/api/v1/` (JSON:API, `application/vnd.api+json`)
- Realtime (unused by us): pusher via `/api/broadcasting/auth`
- Auth host (login only): `auth.anny.eu` — KIT account = **SAML SSO via idp.scc.kit.edu**, no password box.
- Mandatory headers on every call:
  - `accept: application/vnd.api+json`
  - `x-app-key: anny_shop`
  - `authorization: Bearer <JWT>` — ONLY for authed calls (bookings own-data). **Browsing is anonymous.**
- JWT lives in cookie `anny_shop_jwt` on `.anny.eu` (readable, not HttpOnly), minted after web SSO. `exp = iat + 3600s` (1h lifetime). Companion cookie `anny_shop_alvo` = visit token.
- Community: `kit-bibliothek-OTNRQaXc` (members-only for account data; resources browsable anonymous).

## Anonymous (browse) endpoints — PROVEN 200 without auth
- `GET /communities/{com}/all-resources?include=category,...&page[number]=1&page[size]=14&stateless=1`
  → 8 rooms, attributes: slug, name, quantity, color_map, max_booking_quantity, services meta (duration_preview "From 30 minutes to 5 hours"), location, lat/long, sub-resources in services[].meta.
- `GET /availability/periods?r[]={parentId}&start_date={ISO}&end_date={ISO}&timezone=Europe/Berlin`
  → `{ "<parentId>": [ {id:"schedules:...", quota:138, start_date, end_date(=day open window 00:00-23:45)} ... ] }`
- `GET /calendar-events?filter[exclude_child_resources]=0&filter[without_availability]=0&start_date={ISO}&end_date={ISO}&resource_id[]={child...}&resource_id[]=...&timezone=Europe/Berlin`
  → per-day seat occupancy: one event per child desk per day: `resource_id, resource_name ("A2.001"), quota, occupancy, count, display_label "0 / 138 booked", bookings[], is_available, resource_availability_result{serviceAvailabilityResults[{unavailability_type:"before_lead_time",...}]}`
- `GET /resources/{slug}/children?page[number]=1&page[size]=250&filter[available_from]={ISO}&filter[available_to]={ISO}&...`
  → desk children (id, name "A2.004", per-desk availability for the slot window).
- `GET /intervals/start?date={YYYY-MM-DD}&service_id[{sid}]=1&resource_id={parentId}&timezone=Europe/Berlin` → selectable start times
- `GET /intervals/end?date_time={ISO}&resource_id={parentId}&service_id[{sid}]=1&timezone=Europe/Berlin` → selectable end times
- `GET /availability/start-dates?start_date={D}&end_date={D}&service_id[{sid}]=1&resource_id={parentId}&timezone=...` → bookable dates

## Room inventory (KIT-Bibliothek)
| # | resource | parentId | serviceId | capacity | duration |
|---|----------|----------|-----------|----------|----------|
| 1 | Lehrbuchsammlung EG+1.OG | 3191 | 449 | 70 | 30m–5h |
| 2a | Lesesaal Naturwissenschaften 2.OG | 3404 | 452 | 138 | 30m–5h |
| 2b | Lesesaal NW Empore | 35674 | – | 48 | 30m–5h |
| 3 | Lesesaal Medienzentrum | – | – | 72 | 30m–5h |
| 4 | Gruppenräume Süd | – | – | 13 | 30m–3h |
| 5 | Gruppenräume InformatiKOM (Adenauerring 12) | – | – | 12 | 30m–3h |
| 6 | Beratungsbox | – | – | – | 15m–1h |
| 7 | Gruppenräume HKA (A-107..111) | – | – | 5 | 15m–3h |
Rules (from resource descriptions): max 3 days ahead, max 20 open bookings, max 12/day, check-in by QR at desk within 15 min or booking lapses, cancel when not coming.

## Authed endpoints — PROVEN with session
- `GET /customer-accounts/me` — 401 without Bearer; web uses uuid `4cfe53f7-...` variant from community-accounts include.
- `GET /customer-accounts/{uuid}/community-accounts?include=community.owner_organization.agent`
- `GET /customer-accounts/{uuid}/all-resources?page[number]=1&page[size]=5` — "my bookings" list
- `GET /bookings/{id}` — single booking (status accepted/reserved/canceled, code "!TIX…", cancelable_until)

## Booking flow — PROVEN end-to-end (booking #BB469411363 created + canceled)
1. `POST /order/bookings?include=<big include list>&stateless=1` (Bearer)
   body: `{"resource_id":["3416"],"service_id":{"452":1},"timeslot_series_id":null,
           "start_date":"2026-11-13T10:00:00+01:00","end_date":"2026-11-13T11:00:00+01:00",
           "description":"","customer_note":"","add_ons_by_service":{"452":[[]]},
           "sub_bookings_by_service":{},"strategy":"multi-resource","prevent_applying_default_quota":false}`
   → 200 order draft `{data:{id:"82176221",attributes:{access_token:"<oat>",status:"draft"}},
      included:[booking status:"reserved", meta.cancelable_until]}`
   (optional pre-step: `POST /order/bookings/calculate?check_availability=0`)
2. `POST /order?visit_token={anny_shop_alvo}&oid={orderId}&oat={access_token}&stateless=1` (Bearer)
   body: `{"customer":{"given_name":"…","family_name":"…","email":"ujpuu@student.kit.edu"},
           "accept_terms":true,"payment_method":"","success_url":"https://anny.eu/…","cancel_url":"…","meta":{"timezone":"Europe/Berlin"}}`
   → order completed, booking `status:"accepted"`
3. Cancel: `GET /bookings/{id}/cancel?access_token={booking.code}` → status "canceled"
   (PATCH /bookings/{id} {status:"canceled"} = 401; POST cancel = 405. Token route is THE way.)

## Notes
- Booking auto-accepts (auto_accept_bookings:true); email confirmation with QR ticket; check-in kiosk QR.
- Times carry explicit `+01:00` offsets; server returns UTC in some fields (start_date "09:00Z" = 10:00 local) — normalize carefully.
- Child/desk slugs are opaque random strings; use numeric ids.
- Rate limits: none observed in session; be polite anyway (no polling storms; pusher exists but skip it).
- ToS: research fleet will report; assume unofficial-API risk = graceful degradation is mandatory.
- Cancellation deadline: `cancelable_until` = start − 1h (observed).
