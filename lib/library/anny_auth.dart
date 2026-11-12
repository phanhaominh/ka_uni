import 'dart:convert';

import 'package:http/http.dart' as http;

import '../state_management/kit_login_manager.dart';

/// Why a KIT → Anny sign-in failed. [AnnyAuth.signIn] never throws anything
/// but this, so the manager can map every outcome to its error enum.
enum AnnyAuthReason {
  /// idp.scc.kit.edu rejected the credentials — it re-rendered its login
  /// form. Retyping the password is the only recovery.
  badCredentials,

  /// A page or field the chain depends on vanished or changed shape
  /// (XSRF cookie, csrf_token input, SAML auto-POST form, jwt cookie).
  markupChanged,

  /// anny.eu answered 403 (WAF). Back off; not the user's fault.
  blocked,

  /// Connection/socket/timeout trouble — NOT a site change (house rule:
  /// see [KITLoginManager.isNetworkError]).
  network,

  /// auth.anny.eu refused to hand off to KIT's SSO at all
  /// (no x-inertia-location, unusable federation landing, JWT rejected).
  ssoUnavailable,
}

/// Typed sign-in failure. [detail] is a static structural hint (page name +
/// status code) and NEVER contains credentials, cookies, JWTs or page bodies.
class AnnyAuthError implements Exception {
  const AnnyAuthError(this.reason, [this.detail]);

  final AnnyAuthReason reason;
  final String? detail;

  @override
  String toString() =>
      'AnnyAuthError(${reason.name}${detail == null ? '' : ': $detail'})';
}

/// Everything a successful headless SSO yields — and nothing more.
class AnnySession {
  AnnySession(
      {required this.jwt,
      this.refreshToken,
      this.visitToken,
      this.accountUuid,
      DateTime? obtainedAt})
      : obtainedAt = obtainedAt ?? DateTime.now();

  /// `anny_shop_jwt` — RS256, `exp = iat + 3600` (one hour) per the capture.
  final String jwt;

  /// `anny_shop_refresh_token`, when the chain set one.
  final String? refreshToken;

  /// `anny_shop_alvo` visit token — the cart-checkout `visit_token` param.
  final String? visitToken;

  /// Own customer-account uuid when the account exposed one. OPTIONAL by
  /// design: `customer-accounts/me` answers 401 even with a live JWT (the
  /// SPA learns the uuid from its SSR payload, which we do not parse), so
  /// it is scraped opportunistically from the authed own-bookings list.
  /// Every v1 call the app makes also works without it.
  final String? accountUuid;

  final DateTime obtainedAt;

  /// The JWT lives 60 min; retire it at 50 so a booking is never attempted
  /// on a token that dies mid-flow.
  static const maxAge = Duration(minutes: 50);

  bool get isExpired => DateTime.now().difference(obtainedAt) > maxAge;

  /// Log-safe on purpose: the JWT must never reach a log.
  @override
  String toString() =>
      'AnnySession(obtainedAt: $obtainedAt, uuid: $accountUuid)';
}

/// Headless KIT → Anny (KIT-Bibliothek) sign-in.
///
/// Chain (all steps captured live, validated 2026-11-12):
/// 1. `GET auth.anny.eu/login/sso` → `XSRF-TOKEN` cookie (url-encoded).
/// 2. `POST` `{"domain":"kit.edu"}` with the decoded token in
///    `X-XSRF-TOKEN` → **HTTP 409 carrying `x-inertia-location`** — for
///    this Inertia endpoint 409-with-header IS the success shape.
/// 3. Follow that URL to the idp.scc.kit.edu credentials form. The page
///    also carries a decoy form aimed at stage.scc.kit.edu; the real one
///    is the whose action contains `/idp/` after HTML-entity unescaping.
/// 4. POST `csrf_token`/`j_username`/`j_password`/`_eventId_proceed`/
///    `fudis_web_authn_assertion_input` → 200 page hosting the SAML
///    auto-POST form, whose action arrives escaped (`&#x2f;`) and MUST be
///    unescaped before use ([_unescapeHtml]).
/// 5. POST `SAMLResponse`+`RelayState`, then follow the 302 chain (max 8
///    hops) until the `anny_shop_jwt` cookie appears.
/// 6. Probe `GET b.anny.eu/api/v1/notifications/count-unseen` (Bearer) —
///    200 proves the session; the account uuid is then scraped from the
///    authed own-bookings list if present (see [AnnySession.accountUuid]).
///
/// The endpoint shapes, headers and every quirk above are grounded in the
/// live capture documented in `audit/anny_api.md` — that capture is the
/// source of truth for this class; where docs.anny.co differs, it loses.
///
/// The password is only ever written into the urlencoded IdP body — never
/// into an exception, a log line or the returned session.
class AnnyAuth {
  AnnyAuth({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  /// Signs in with KIT credentials. Throws [AnnyAuthError] for every
  /// failure — transport noise included — so callers branch on `.reason`.
  Future<AnnySession> signIn(
      {required String kitUser, required String password}) async {
    try {
      return await _SsoChain(_client).run(kitUser: kitUser, password: password);
    } on AnnyAuthError {
      rethrow;
    } on Object catch (e) {
      // A dead socket is not a redesigned website; anything unclassifiable
      // counts as "the site changed shape". The original exception is
      // deliberately NOT attached: it can carry request URIs (SAMLRequest
      // blobs) and we wrap before anything user-entered could leak.
      throw AnnyAuthError(KITLoginManager.isNetworkError(e)
          ? AnnyAuthReason.network
          : AnnyAuthReason.markupChanged);
    }
  }
}

/// One sign-in attempt = one ephemeral cookie jar: anonymous browsing
/// elsewhere must never ride on cookies collected here, and a re-login
/// starts clean.
class _SsoChain {
  _SsoChain(this._client);

  final http.Client _client;
  final _cookies = _CookieJar();

  static const _ua = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36";
  static const _loginSso = "https://auth.anny.eu/login/sso";
  static const _api = "https://b.anny.eu/api/v1";

  Future<AnnySession> run(
      {required String kitUser, required String password}) async {
    // 1 — SSO entry: sets the Laravel XSRF-TOKEN cookie.
    final entry = await _get(Uri.parse(_loginSso), headers: _browser);
    _guardBlocked(entry, "login/sso");
    final xsrfRaw = _cookies["XSRF-TOKEN"];
    if (xsrfRaw == null) {
      throw const AnnyAuthError(
          AnnyAuthReason.markupChanged, "no XSRF-TOKEN cookie on login/sso");
    }
    final xsrf = _urlDecode(xsrfRaw); // cookie is url-encoded

    // 2 — domain POST; 409 + x-inertia-location is the SUCCESS shape.
    final domain = await _post(Uri.parse(_loginSso),
        body: jsonEncode({"domain": "kit.edu"}),
        headers: {
          ..._browser,
          "content-type": "application/json",
          "x-xsrf-token": xsrf,
          "x-inertia": "true",
          "x-requested-with": "XMLHttpRequest",
          "referer": _loginSso,
        });
    _guardBlocked(domain, "login/sso domain POST");
    final handoff = domain.headers["x-inertia-location"];
    if (handoff == null) {
      throw AnnyAuthError(AnnyAuthReason.ssoUnavailable,
          "no x-inertia-location on domain POST (HTTP ${domain.statusCode})");
    }

    // 3 — federation handoff → idp.scc.kit.edu credentials form.
    final landing = await _follow(_resolve(_loginSso, handoff));
    _guardBlocked(landing.response, "federation landing");
    if (landing.response.statusCode != 200) {
      throw AnnyAuthError(AnnyAuthReason.ssoUnavailable,
          "federation landing answered HTTP ${landing.response.statusCode}");
    }
    final idpAction = _idpFormAction(landing.response.body, landing.url);
    if (idpAction == null) {
      throw const AnnyAuthError(AnnyAuthReason.markupChanged,
          "no /idp/ credentials form on the federation landing");
    }
    final fields = _inputValues(landing.response.body);
    final csrf = fields["csrf_token"];
    if (csrf == null) {
      throw const AnnyAuthError(
          AnnyAuthReason.markupChanged, "no csrf_token on the idp form");
    }
    final creds = await _post(idpAction,
        headers: {..._form, "referer": landing.url.toString()},
        body: _urlEncode({
          "csrf_token": csrf,
          "j_username": kitUser,
          "j_password": password,
          "_eventId_proceed": "",
          "fudis_web_authn_assertion_input":
              fields["fudis_web_authn_assertion_input"] ?? "",
        }));
    _guardBlocked(creds, "idp credentials POST");

    // 4 — IdP verdict. Re-rendering its own form = rejected credentials
    // (the error text is localized and changes; the field name does not).
    if (creds.body.contains("j_username")) {
      throw const AnnyAuthError(AnnyAuthReason.badCredentials);
    }
    final saml = _samlFormRe.firstMatch(creds.body);
    if (saml == null) {
      throw const AnnyAuthError(AnnyAuthReason.markupChanged,
          "no SAML auto-POST form after the credentials POST");
    }
    // The relay action arrives HTML-entity-escaped
    // ("https://anny.eu&#x2f;federation&#x2f;saml&#x2f;consume") —
    // posting the raw string would 404; unescaping is mandatory.
    final consume = Uri.parse(_unescapeHtml(saml.group(1)!));
    final samlFields = _inputValues(creds.body);
    final samlResponse = samlFields["SAMLResponse"];
    if (samlResponse == null) {
      throw const AnnyAuthError(
          AnnyAuthReason.markupChanged, "SAML form without SAMLResponse");
    }

    // 5 — SAML consume + the minting redirect chain.
    final relay = await _post(consume,
        headers: _form,
        body: _urlEncode({
          "SAMLResponse": samlResponse,
          "RelayState": samlFields["RelayState"] ?? "",
        }));
    _guardBlocked(relay, "saml consume POST");
    var next = relay.headers["location"] == null
        ? consume
        : consume.resolve(relay.headers["location"]!);
    _guardHost(next); // R21: the JWT-bearing walk is allowlisted from
    // its very first hop — pre-fix the 302 answer of the consume POST
    // was fetched before any guard could see it
    for (var hop = 0; hop < 8 && !_cookies.has("anny_shop_jwt"); hop++) {
      final hopResp = await _get(next, headers: _browser);
      _guardBlocked(hopResp, "SSO redirect chain");
      final loc = hopResp.headers["location"];
      if (loc == null) break;
      next = _guardHost(next.resolve(loc));
    }
    final jwt = _cookies["anny_shop_jwt"];
    if (jwt == null) {
      throw const AnnyAuthError(
          AnnyAuthReason.markupChanged, "chain ended without anny_shop_jwt");
    }

    // 6 — session probe + optional uuid.
    final probe = await _get(Uri.parse("$_api/notifications/count-unseen"),
        headers: _apiHeaders(jwt), cookies: false);
    if (probe.statusCode != 200) {
      if (probe.statusCode == 403) {
        throw const AnnyAuthError(
            AnnyAuthReason.blocked, "403 (WAF) at api probe");
      }
      if (probe.statusCode == 401) {
        throw const AnnyAuthError(AnnyAuthReason.ssoUnavailable,
            "API rejected the freshly minted JWT (401)");
      }
      throw AnnyAuthError(AnnyAuthReason.markupChanged,
          "session probe answered HTTP ${probe.statusCode}");
    }

    return AnnySession(
        jwt: jwt,
        refreshToken: _cookies["anny_shop_refresh_token"],
        visitToken: _cookies["anny_shop_alvo"],
        accountUuid: await _scrapeAccountUuid(jwt),
        obtainedAt: DateTime.now());
  }

  /// Best effort: `customer-accounts/me` 401s even on a live session (the
  /// SPA gets the uuid from its SSR payload), so the uuid comes from the
  /// authed own-bookings list, where JSON:API spells relationship data as
  /// `"type":"customer-accounts","id":"<uuid>"`. No bookings → no uuid →
  /// null: everything else in v1 works without it. A failure HERE must not
  /// throw the already-proven session away, so it degrades to null.
  Future<String?> _scrapeAccountUuid(String jwt) async {
    try {
      final bookings = await _get(
          Uri.parse("$_api/bookings?filter[upcoming_only]=1"),
          headers: _apiHeaders(jwt),
          cookies: false);
      if (bookings.statusCode != 200) return null;
      return _customerUuidRe.firstMatch(bookings.body)?.group(1);
    } on Object {
      return null;
    }
  }

  // ---- request plumbing ------------------------------------------------

  static const _browser = {
    "accept": "text/html, application/xhtml+xml",
    "user-agent": _ua,
  };

  static const _form = {
    ..._browser,
    "content-type": "application/x-www-form-urlencoded",
  };

  static Map<String, String> _apiHeaders(String jwt) => {
        "accept": "application/vnd.api+json",
        "x-app-key": "anny_shop",
        "authorization": "Bearer $jwt",
      };

  Future<http.Response> _get(Uri uri,
          {Map<String, String>? headers, bool cookies = true}) =>
      _send("GET", uri, headers: headers, cookies: cookies);

  Future<http.Response> _post(Uri uri,
          {required String body,
          Map<String, String>? headers,
          bool cookies = true}) =>
      _send("POST", uri, body: body, headers: headers, cookies: cookies);

  /// Every hop runs with redirects OFF so each Location, each Set-Cookie
  /// and the 409 handoff stay under this chain's control.
  Future<http.Response> _send(String method, Uri uri,
      {String? body, Map<String, String>? headers, bool cookies = true}) async {
    final req = http.Request(method, uri);
    req.followRedirects = false;
    headers?.forEach((k, v) => req.headers[k] = v);
    if (body != null) req.body = body; // after content-type is in place
    if (cookies) {
      final jar = _cookies.headerFor(uri);
      if (jar != null) req.headers["cookie"] = jar;
    }
    final streamed =
        await _client.send(req).timeout(KITLoginManager.netTimeout);
    final response =
        KITLoginManager.fixUtf8Body(await http.Response.fromStream(streamed));
    _cookies.storeFromResponse(uri, response.headers);
    return response;
  }

  Future<({Uri url, http.Response response})> _follow(Uri start,
      {int maxHops = 6}) async {
    var url = _guardHost(start);
    var resp = await _get(url, headers: _browser);
    for (var hop = 0; hop < maxHops; hop++) {
      if (!_isRedirect(resp.statusCode)) break;
      final loc = resp.headers["location"];
      if (loc == null) break;
      url = _guardHost(url.resolve(loc));
      resp = await _get(url, headers: _browser);
    }
    return (url: url, response: resp);
  }

  /// The SAML assertion + session cookies may only ever travel inside
  /// the KIT federation and anny's own domains: an off-allowlist or
  /// plaintext-HTTP hop aborts the chain instead of leaking it (R21).
  static Uri _guardHost(Uri url) {
    final h = url.host;
    final ok = url.isScheme("https") &&
        (h == "anny.eu" ||
            h.endsWith(".anny.eu") ||
            h == "kit.edu" ||
            h.endsWith(".kit.edu"));
    if (!ok) {
      throw AnnyAuthError(
          AnnyAuthReason.markupChanged, "off-allowlist hop: ${url.origin}");
    }
    return url;
  }

  static bool _isRedirect(int status) =>
      status == 301 ||
      status == 302 ||
      status == 303 ||
      status == 307 ||
      status == 308;

  static void _guardBlocked(http.Response r, String where) {
    if (r.statusCode == 403) {
      throw AnnyAuthError(AnnyAuthReason.blocked, "403 (WAF) at $where");
    }
  }

  // ---- parsing ----------------------------------------------------------

  static final _formActionRe = RegExp('<form[^>]*action="([^"]*)"');
  static final _inputValueRe = RegExp('name="([^"]+)"[^>]*?value="([^"]*)"');
  static final _samlFormRe = RegExp(
      '<form[^>]*action="([^"]+)"[^>]*>(?:(?!</form>).)*SAMLResponse',
      dotAll: true);
  // Either shape the payloads take: the captured pair
  // `customer-accounts","<uuid>"` and the JSON:API relationship spelling
  // `"type":"customer-accounts","id":"<uuid>"`.
  static final _customerUuidRe =
      RegExp('customer-accounts","(?:id":")?([0-9a-fA-F-]{36})"');

  /// Federation/IdP pages ship a decoy `<form action="...stage.scc.kit.edu
  /// /search.php">`; the credentials form is the one whose action — after
  /// HTML-entity unescaping — contains `/idp/`.
  Uri? _idpFormAction(String body, Uri pageUrl) {
    for (final m in _formActionRe.allMatches(body)) {
      final action = _unescapeHtml(m.group(1)!);
      if (!action.contains("/idp/")) continue;
      final uri = pageUrl.resolve(action);
      // The password POST goes to ONE host over https: an action
      // escaping it means a hijacked/reshaped page, and credentials are
      // already in hand. (R21: this used to trust every *.kit.edu sub —
      // a single compromised campus host was enough to drink the KIT
      // password of every user running this chain.)
      if (uri.scheme != "https" || uri.host != "idp.scc.kit.edu") {
        throw AnnyAuthError(AnnyAuthReason.markupChanged,
            "credentials form moved to ${uri.host}");
      }
      return uri;
    }
    return null;
  }

  static Map<String, String> _inputValues(String body) {
    final fields = <String, String>{};
    for (final m in _inputValueRe.allMatches(body)) {
      fields[m.group(1)!] = m.group(2)!; // last occurrence wins
    }
    return fields;
  }

  static Uri _resolve(String base, String target) =>
      Uri.parse(target).isAbsolute
          ? Uri.parse(target)
          : Uri.parse(base).resolve(target);

  static String _urlEncode(Map<String, String> fields) =>
      Uri(queryParameters: fields).query;

  static String _urlDecode(String raw) {
    try {
      return Uri.decodeFull(raw);
    } on FormatException {
      return raw;
    }
  }
}

/// Tiny dependency-free HTML entity unescape. The SAML relay escapes its
/// form action with `&#x2f;` (and the IdP a few more), and pulling a full
/// parser dependency through the auth chain for that is overkill.
String _unescapeHtml(String s) => s
    .replaceAllMapped(RegExp(r'&#x([0-9a-fA-F]{1,6});'),
        (m) => String.fromCharCode(int.parse(m.group(1)!, radix: 16)))
    .replaceAllMapped(RegExp(r'&#(\d{1,6});'),
        (m) => String.fromCharCode(int.parse(m.group(1)!)))
    .replaceAll("&quot;", '"')
    .replaceAll("&apos;", "'")
    .replaceAll("&lt;", "<")
    .replaceAll("&gt;", ">")
    .replaceAll("&nbsp;", " ")
    // &amp; LAST so double-escaped "&amp;#x2f;" decodes to a literal
    // "&#x2f;" instead of dissolving into "/" two rounds early.
    .replaceAll("&amp;", "&");

/// Minimal cookie jar: package:http sends no cookies itself, and the chain
/// needs exactly two behaviors — the Laravel XSRF cookie back to
/// auth.anny.eu, and spotting `anny_shop_jwt` when the callback sets it.
/// Cookie NAMES keep their case (case-sensitive by RFC 6265; the chain
/// checks `anny_shop_jwt` verbatim).
class _CookieJar {
  /// domain key → cookie name → value. Keys beginning with `=` are
  /// host-only (no Domain attribute), the rest are domain-suffix cookies.
  final Map<String, Map<String, String>> _byDomain = {};

  void storeFromResponse(Uri requestUri, Map<String, String> headers) {
    final raw = headers["set-cookie"];
    if (raw == null) return;
    for (final part in _splitSetCookies(raw)) {
      final attrs = part.split(";");
      final pair = attrs.first.trim();
      final eq = pair.indexOf("=");
      if (eq <= 0) continue;
      final name = pair.substring(0, eq);
      final value = pair.substring(eq + 1).trim();
      var key = "=${requestUri.host}";
      for (final attr in attrs.skip(1)) {
        final a = attr.trim().toLowerCase();
        if (a.startsWith("domain=")) {
          key = a.substring(7).replaceFirst(".", "");
        } else if (a.startsWith("max-age=0")) {
          _byDomain[key]?.remove(name);
        }
      }
      (_byDomain[key] ??= {})[name] = value;
    }
  }

  String? headerFor(Uri uri) {
    final host = uri.host;
    final parts = <String>[];
    _byDomain.forEach((domain, cookies) {
      final send = domain.startsWith("=")
          ? host == domain.substring(1)
          : host == domain || host.endsWith(".$domain");
      if (send) cookies.forEach((n, v) => parts.add("$n=$v"));
    });
    return parts.isEmpty ? null : parts.join("; ");
  }

  bool has(String name) => _byDomain.values.any((c) => c.containsKey(name));

  String? operator [](String name) {
    for (final cookies in _byDomain.values) {
      final v = cookies[name];
      if (v != null) return v;
    }
    return null;
  }

  /// package:http folds repeated Set-Cookie headers into ONE comma-joined
  /// string; the only legal commas inside are in `Expires=Wed, 21 Oct …`
  /// dates, so splitting on "comma followed by another name=" is exact.
  static final _joinSplitter = RegExp(r",(?=\s*[^\s,;=]+\s*=)");

  static List<String> _splitSetCookies(String raw) => raw.split(_joinSplitter);
}
