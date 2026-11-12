// ignore_for_file: library_private_types_in_public_api
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:kit_mobile/library/anny_auth.dart';

/// Canned pages of the captured KIT→Anny SSO chain (audit/anny_api.md).
/// Nothing here touches the network: the whole chain runs against the
/// _StubClient below, mensa-test style.

const pw = "s3cr3t-pw!";

// ---- fixtures -----------------------------------------------------------

const _ssoLoginPage =
    '<!DOCTYPE html><html><head><title>Anny Login</title></head>'
    '<body><div id="root"></div></body></html>';

/// Laravel ships the XSRF cookie url-encoded; the chain must send the
/// ENCODED value back as cookie and the DECODED one in X-XSRF-TOKEN.
const _xsrfCookie = "XSRF-TOKEN=eyJFXCRAbQ%3D%3D%24xyz; path=/; "
    "expires=Thu, 12 Nov 2026 14:37:00 GMT; Max-Age=3600";

const _handoffUrl =
    "https://anny.eu/federation/saml/login/provider?trp=https%3A%2F%2Fanny.eu%2Fhome";

const _idpSsoUrl =
    "https://idp.scc.kit.edu/idp/profile/SAML2/Redirect/SSO?SAMLRequest=nZBdT6sw"
    "FIf%2FzenVNtrSmT3yJ0wUE2Pc6LxwCeDbi0%2BRmGwKJ5z8n3d55s5czAYnrZvWSnm17SlFCinl"
    "86TfLye4vvzW9TlKJcY1eZjBnpZL1g%2FT0e0%2FbHt90QvVn48Pm2339T1Ue37Wj6vJ6V%2Bz3N"
    "02XVU9nL%2F755%2B3d7V1Xt9eHm%2B2%2B31dHm%2B3x3Vfvj7f7jYv5%2Bf73dVl371fnj%2B3"
    "q9d3%2B%2FPT9nJ1%2Bf54%2B3R3%2FfR%2FfPfxenP9%2BHB383D1vNqsn1br1VW7Xtfr9bquXt"
    "63T6vV4%2Bb9ZVX9BQX7jtF0&RelayState=ssmbatch%3A0d2f8";

/// Real IdP page shape: decoy search form FIRST, then the credentials form
/// whose action contains /idp/ only AFTER HTML-entity unescaping.
const _idpFormPage = """<!DOCTYPE html>
<html><head><title>Login : KIT-Credentials</title></head>
<body>
<form id="search" action="https://stage.scc.kit.edu/search.php" method="get">
<input type="search" name="q" value="" />
</form>
<main>
<h1>Anmeldung mit KIT-Credentials</h1>
<form id="loginform" method="post" action="&#x2F;idp&#x2f;profile&#x2f;SAML2&#x2f;Redirect&#x2f;SSO;JSESSIONID=node01abc?execution=e1s1">
<input type="hidden" name="execution" value="e1s1" />
<input type="hidden" name="csrf_token" value="9f8e7d6c-csrf-token" />
<input type="hidden" name="fudis_web_authn_assertion_input" value="fudispreset%3D1" />
<input type="text" name="j_username" value="" autocomplete="username" />
<input type="password" name="j_password" autocomplete="current-password" />
<button name="_eventId_proceed" value="login">Anmelden</button>
</form>
</main>
</body></html>""";

/// SAML relay auto-POST page — the captured quirk: the action arrives with
/// every "/" escaped as &#x2f;/&#x2F;; posting the raw string would 404.
const _samlAutoPostPage = """<!DOCTYPE html>
<html>
<head><title>SAML 2.0 SSO post</title>
<script>function submitIfNotDisabled() { document.forms[0].submit(); }</script>
</head>
<body onload="submitIfNotDisabled()">
<noscript><p>JavaScript is disabled. Enable JavaScript to continue.</p></noscript>
<form method="post" action="https:&#x2F;&#x2F;anny.eu&#x2f;federation&#x2f;saml&#x2f;consume">
<input type="hidden" name="SAMLResponse" value="PHNhbWxwOlJlc3BvbnNlIHhtbG5zOnNhbWw9InVybjpvYXNpczpuYW1lczp0YzpTQU1MOjIuMDphc3NlcnRpb24iPkJBTkFOSUQ8L3NhbWxwOlJlc3BvbnNlPgo=" />
<input type="hidden" name="RelayState" value="https&#x3a;&#x2f;&#x2f;anny.eu&#x2f;home" />
</form>
</body></html>""";

const _samlResponse =
    "PHNhbWxwOlJlc3BvbnNlIHhtbG5zOnNhbWw9InVybjpvYXNpczpuYW1lczp0YzpTQU1MOjIuMDphc3NlcnRpb24iPkJBTkFOSUQ8L3NhbWxwOlJlc3BvbnNlPgo=";

const _jwt =
    "eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiJ1anB1dSJ9.RS256sig";
const _uuid = "4cfe53f7-83b4-4504-a207-cf551a474361";

/// Repeated Set-Cookie headers arrive folded into one comma-joined string;
/// the Expires date carries commas — the jar splitter must not bite there.
const _mintCookies = "anny_shop_jwt=$_jwt; Path=/; Domain=.anny.eu; "
    "Expires=Wed, 12 Nov 2026 13:37:00 GMT, "
    "anny_shop_alvo=9d2f-visit-77; Path=/; Domain=.anny.eu, "
    "anny_shop_refresh_token=rt-9f8e7d; Path=/; Domain=.anny.eu; HttpOnly";

/// Wrong password: the IdP re-renders its login form with the error block.
const _wrongPasswordPage = """<!DOCTYPE html>
<html><head><title>Login : KIT-Credentials</title></head>
<body>
<div class="login-error"><div class="error"><span class="field-error">Ihre Anmeldedaten wurden nicht erkannt. Bitte versuchen Sie es erneut.</span></div></div>
<form id="loginform" method="post" action="&#x2f;idp&#x2f;profile&#x2f;SAML2&#x2f;Redirect&#x2f;SSO;JSESSIONID=node01abc?execution=e1s2">
<input type="hidden" name="execution" value="e1s2" />
<input type="hidden" name="csrf_token" value="9f8e7d6c-csrf-token" />
<input type="text" name="j_username" value="alice" autocomplete="username" />
<input type="password" name="j_password" autocomplete="current-password" />
<button name="_eventId_proceed" value="login">Anmelden</button>
</form>
</body></html>""";

const _noConsumePage =
    "<!DOCTYPE html><html><body><h1>Danke</h1><p>Sie sind angemeldet.</p>"
    "</body></html>";

const _bookingsWithUuid = '{"data":[],"included":[{"type":"bookings",'
    '"id":"8217","attributes":{"status":"accepted"}},'
    '{"type":"customer-accounts","id":"$_uuid","attributes":{}}]}';

/// The literal pair shape from the capture.
const _bookingsCaptureShape =
    '{"data":[],"meta":{"customer":["customer-accounts","$_uuid"]}}';

// ---- stub client ---------------------------------------------------------

class _Canned {
  const _Canned(this.status, {this.body = "", this.headers = const {}});
  final int status;
  final String body;
  final Map<String, String> headers;
}

class _Route {
  const _Route(this.method, this.urlPart, this.respond);
  final String method;
  final String urlPart;
  final _Canned Function() respond;
}

class _StubClient extends http.BaseClient {
  _StubClient(this.routes);

  final List<_Route> routes;
  final List<http.Request> requests = [];
  Object? throwing;

  http.Request? call(String method, String urlPart) {
    for (final r in requests) {
      if (r.method == method && r.url.toString().contains(urlPart)) return r;
    }
    return null;
  }

  int count(String method, String urlPart) => requests
      .where((r) => r.method == method && r.url.toString().contains(urlPart))
      .length;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final req = request as http.Request;
    requests.add(req);
    final t = throwing;
    if (t != null) throw t;
    final url = req.url.toString();
    for (final r in routes) {
      if (r.method == req.method && url.contains(r.urlPart)) {
        final c = r.respond();
        return http.StreamedResponse(
            Stream.value(utf8.encode(c.body)), c.status,
            headers: c.headers, request: req);
      }
    }
    throw StateError("stub: unexpected ${req.method} $url");
  }
}

/// The full captured chain, cookies and all. Each knob replaces one stage's
/// canned answer for failure fixtures.
List<_Route> happyRoutes({
  _Canned? ssoEntry,
  _Canned? inertia,
  _Canned? idpPage,
  _Canned? credsPage,
  _Canned? consumeRelay,
  _Canned? probe,
  _Canned? bookings,
}) =>
    [
      _Route(
          "GET",
          "auth.anny.eu/login/sso",
          () =>
              ssoEntry ??
              const _Canned(200,
                  body: _ssoLoginPage, headers: {"set-cookie": _xsrfCookie})),
      _Route(
          "POST",
          "auth.anny.eu/login/sso",
          () =>
              inertia ??
              const _Canned(409, headers: {"x-inertia-location": _handoffUrl})),
      _Route("GET", "/federation/saml/login/provider",
          () => const _Canned(302, headers: {"location": _idpSsoUrl})),
      _Route("GET", "idp.scc.kit.edu",
          () => idpPage ?? const _Canned(200, body: _idpFormPage)),
      _Route("POST", "/idp/",
          () => credsPage ?? const _Canned(200, body: _samlAutoPostPage)),
      _Route(
          "POST",
          "federation/saml/consume",
          () =>
              consumeRelay ??
              const _Canned(302, headers: {
                "location": "https://anny.eu/home?withoutIntent=true"
              })),
      _Route(
          "GET",
          "home?withoutIntent",
          () => const _Canned(302, headers: {
                "location":
                    "https://anny.eu/oauth/authorize?client_id=9ecadc4d-1091-4203-8312-88cce205908f&returnTo=https%3A%2F%2Fanny.eu%2Fhome"
              })),
      _Route(
          "GET",
          "/oauth/authorize",
          () => const _Canned(302, headers: {
                "location": "https://anny.eu/login/callback?code=abc123"
              })),
      _Route(
          "GET",
          "/login/callback",
          () => const _Canned(302, headers: {
                "location": "https://anny.eu/home?intent=x",
                "set-cookie": _mintCookies
              })),
      _Route("GET", "home?intent",
          () => const _Canned(200, body: "<html>home</html>")),
      _Route("GET", "count-unseen",
          () => probe ?? const _Canned(200, body: '{"data":{"count":0}}')),
      _Route("GET", "bookings?filter",
          () => bookings ?? const _Canned(200, body: _bookingsWithUuid)),
    ];

Future<Object?> signInFailure(_StubClient stub) => AnnyAuth(client: stub)
    .signIn(kitUser: "alice", password: pw)
    .then<Object?>((_) => null, onError: (Object e) => e);

Future<AnnyAuthReason> failReason(_StubClient stub) async {
  final e = await signInFailure(stub);
  expect(e, isA<AnnyAuthError>(), reason: "only AnnyAuthError may escape");
  return (e as AnnyAuthError).reason;
}

// ---- tests ---------------------------------------------------------------

void main() {
  test("R21: an off-allowlist redirect hop aborts the chain", () async {
    // the minting chain gets a 302 to a FOREIGN host: it must die there,
    // carrying no assertion and no cookie across - and the foreign URL
    // must never even be requested
    final stub = _StubClient(happyRoutes(
      consumeRelay: const _Canned(302, headers: {
        "location": "https://anny.eu/steer?to=https%3A%2F%2Fevil.example.com%2Fsteal"
      }),
    ))
      ..routes.insert(
          0,
          _Route("GET", "steer?to", () => const _Canned(302,
              headers: {"location": "https://evil.example.com/steal"})));
    final e = await signInFailure(stub) as AnnyAuthError;
    expect(e.reason, AnnyAuthReason.markupChanged);
    expect("${e.detail}", contains("off-allowlist"));
    expect(
        stub.requests
            .any((r) => r.url.origin == "https://evil.example.com"),
        isFalse,
        reason: "the foreign ORIGIN must never be requested - the steer "
            "URL merely names it in a query parameter");
  });

  test("R21: credentials POST pinned to idp.scc.kit.edu exactly", () async {
    // a federated page pointing the login form at a LOOKALIKE host must
    // not drink the KIT password
    final evilForm = _idpFormPage.replaceAll(
        r'action="&#x2F;idp&#x2f;profile',
        r'action="https:&#x2F;&#x2F;idp.scc.kit.edu.sso-secure.example&#x2F;idp&#x2f;profile');
    final stub = _StubClient(
        happyRoutes(idpPage: _Canned(200, body: evilForm)));
    final e = await signInFailure(stub) as AnnyAuthError;
    expect(e.reason, AnnyAuthReason.markupChanged);
    expect("${e.detail}", contains("credentials form moved"));
    expect(stub.count("POST", "sso-secure.example"), 0,
        reason: "the password POST is refused before it is built");
    // and the password never appears in any recorded request
    expect(stub.requests.map((r) => "${r.url}${r.body}").join(),
        isNot(contains(pw)));
  });

  test("happy path: full chain mints a proven session", () async {
    final stub = _StubClient(happyRoutes());
    final s =
        await AnnyAuth(client: stub).signIn(kitUser: "alice", password: pw);

    expect(s.jwt, _jwt);
    expect(s.visitToken, "9d2f-visit-77");
    expect(s.refreshToken, "rt-9f8e7d");
    expect(s.accountUuid, _uuid);
    expect(s.isExpired, false);

    // step 2: Inertia domain POST — encoded cookie raw, token decoded,
    // 409-with-x-inertia-location treated as success
    final dpost = stub.call("POST", "auth.anny.eu/login/sso")!;
    expect(dpost.body, '{"domain":"kit.edu"}');
    expect(dpost.headers["content-type"], "application/json");
    expect(dpost.headers["x-inertia"], "true");
    expect(dpost.headers["x-requested-with"], "XMLHttpRequest");
    expect(dpost.headers["x-xsrf-token"], r"eyJFXCRAbQ==$xyz");
    expect(
        dpost.headers["cookie"], contains("XSRF-TOKEN=eyJFXCRAbQ%3D%3D%24xyz"));

    // step 3/4: the /idp/ form won over the stage.scc.kit.edu decoy, and
    // exactly the captured field set went out urlencoded
    final creds = stub.call("POST", "/idp/")!;
    expect(
        creds.url.toString(),
        "https://idp.scc.kit.edu/idp/profile/SAML2/Redirect/SSO;"
        "JSESSIONID=node01abc?execution=e1s1");
    expect(creds.headers["content-type"], "application/x-www-form-urlencoded");
    final f = Uri.splitQueryString(creds.body);
    expect(f["csrf_token"], "9f8e7d6c-csrf-token");
    expect(f["j_username"], "alice");
    expect(f["j_password"], pw);
    expect(f["_eventId_proceed"], "");
    expect(f["fudis_web_authn_assertion_input"], "fudispreset%3D1");

    // step 4/5: the escaped consume action was unescaped before use
    final saml = stub.call("POST", "federation/saml/consume")!;
    expect(saml.url.toString(), "https://anny.eu/federation/saml/consume");
    final sf = Uri.splitQueryString(saml.body);
    expect(sf["SAMLResponse"], _samlResponse);
    // ref parity: field values pass through raw (the relay echoes RelayState)
    expect(sf["RelayState"], "https&#x3a;&#x2f;&#x2f;anny.eu&#x2f;home");

    // step 6: the probe ran like the API client does — Bearer + app key and
    // NO cookies to b.anny.eu (plan: personal data only via Bearer)
    final probeReq = stub.call("GET", "count-unseen")!;
    expect(probeReq.headers["authorization"], "Bearer $_jwt");
    expect(probeReq.headers["x-app-key"], "anny_shop");
    expect(probeReq.headers["accept"], "application/vnd.api+json");
    expect(probeReq.headers.containsKey("cookie"), false);

    // the decoy never got a request
    expect(stub.requests.any((r) => r.url.toString().contains("stage.scc")),
        false);
  });

  test("bookings without a customer node → session with null uuid", () async {
    final stub = _StubClient(happyRoutes(
        bookings: const _Canned(200, body: '{"data":[],"meta":{}}')));
    final s =
        await AnnyAuth(client: stub).signIn(kitUser: "alice", password: pw);
    expect(s.jwt, _jwt);
    expect(s.accountUuid, null);
  });

  test("uuid: capture-shape pair and JSON:API relationship both parse",
      () async {
    final captureShape = _StubClient(
        happyRoutes(bookings: const _Canned(200, body: _bookingsCaptureShape)));
    final s1 = await AnnyAuth(client: captureShape)
        .signIn(kitUser: "alice", password: pw);
    expect(s1.accountUuid, _uuid);

    final relShape = _StubClient(happyRoutes(
        bookings: const _Canned(200,
            body: '{"data":[{"type":"bookings","id":"8217","relationships":'
                '{"customer":{"data":{"type":"customer-accounts","id":"$_uuid"}}'
                '}}}]}')));
    final s2 =
        await AnnyAuth(client: relShape).signIn(kitUser: "alice", password: pw);
    expect(s2.accountUuid, _uuid);
  });

  test("uuid scrape failure never throws a proven session away", () async {
    final routes = happyRoutes()
      ..removeWhere((r) => r.urlPart == "bookings?filter");
    final stub = _StubClient(routes);
    // bookings route missing → stub StateError inside the scrape → swallowed
    final s =
        await AnnyAuth(client: stub).signIn(kitUser: "alice", password: pw);
    expect(s.jwt, _jwt);
    expect(s.accountUuid, null);
  });

  test("wrong password → badCredentials, and the error never leaks it",
      () async {
    final stub = _StubClient(
        happyRoutes(credsPage: const _Canned(200, body: _wrongPasswordPage)));
    final err = await signInFailure(stub) as AnnyAuthError;
    expect(err.reason, AnnyAuthReason.badCredentials);
    expect(err.toString(), isNot(contains(pw)));
    expect(err.toString(), isNot(contains("alice")));
  });

  test("no SAML consume form after credentials → markupChanged", () async {
    final stub = _StubClient(
        happyRoutes(credsPage: const _Canned(200, body: _noConsumePage)));
    expect(await failReason(stub), AnnyAuthReason.markupChanged);
  });

  test("SAML form without SAMLResponse field → markupChanged", () async {
    final stub = _StubClient(happyRoutes(
        credsPage: const _Canned(200,
            body: '<form action="https://anny.eu/federation/saml/consume">'
                '<input name="RelayState" value="x" /></form>')));
    expect(await failReason(stub), AnnyAuthReason.markupChanged);
  });

  test("no x-inertia-location on the 409 → ssoUnavailable", () async {
    final stub = _StubClient(happyRoutes(
        inertia: const _Canned(409, body: '{"message":"Unprocessable"}')));
    expect(await failReason(stub), AnnyAuthReason.ssoUnavailable);
  });

  test("no XSRF-TOKEN cookie on login/sso → markupChanged", () async {
    final stub = _StubClient(happyRoutes(
        ssoEntry: const _Canned(200,
            body: _ssoLoginPage,
            headers: {"set-cookie": "remember_web=xyz; path=/"})));
    expect(await failReason(stub), AnnyAuthReason.markupChanged);
  });

  test("anny.eu answers 403 → blocked", () async {
    final stub = _StubClient(
        happyRoutes(ssoEntry: const _Canned(403, body: "<html>WAF</html>")));
    expect(await failReason(stub), AnnyAuthReason.blocked);
  });

  test("cookie names are case-sensitive: Anny_Shop_JWT does not count",
      () async {
    final stub = _StubClient(happyRoutes(
        consumeRelay: const _Canned(302,
            headers: {"location": "https://anny.eu/home?withoutIntent=true"}))
      ..removeWhere((r) => r.urlPart == "/login/callback")
      ..add(_Route(
          "GET",
          "/login/callback",
          () => const _Canned(302, headers: {
                "location": "https://anny.eu/home?intent=x",
                "set-cookie": "Anny_Shop_JWT=$_jwt; Path=/; Domain=.anny.eu"
              }))));
    expect(await failReason(stub), AnnyAuthReason.markupChanged);
  });

  test("chain follows at most 8 hops of a redirect loop", () async {
    const authorize = "https://anny.eu/oauth/authorize?client_id=x&returnTo=y";
    final stub = _StubClient([
      ...happyRoutes(
          consumeRelay:
              const _Canned(302, headers: {"location": authorize})).where((r) =>
          r.urlPart != "home?withoutIntent" &&
          r.urlPart != "/oauth/authorize" &&
          r.urlPart != "/login/callback" &&
          r.urlPart != "home?intent" &&
          r.urlPart != "count-unseen" &&
          r.urlPart != "bookings?filter"),
      // endless self-redirect, never mints a cookie
      _Route("GET", "/oauth/authorize",
          () => const _Canned(302, headers: {"location": authorize})),
    ]);
    expect(await failReason(stub), AnnyAuthReason.markupChanged);
    expect(stub.count("GET", "/oauth/authorize"), 8);
  });

  test("probe 401 rejects the fresh session → ssoUnavailable", () async {
    final stub = _StubClient(
        happyRoutes(probe: const _Canned(401, body: '{"error":"bad jwt"}')));
    expect(await failReason(stub), AnnyAuthReason.ssoUnavailable);
  });

  test("transport failure → network reason, never raw", () async {
    final stub = _StubClient(happyRoutes())
      ..throwing = http.ClientException("socket says no");
    expect(await failReason(stub), AnnyAuthReason.network);
  });

  test("unclassifiable failure → markupChanged, never raw", () async {
    final stub = _StubClient(happyRoutes())..throwing = Exception("weird");
    expect(await failReason(stub), AnnyAuthReason.markupChanged);
  });

  test("missing credentials form on the landing → markupChanged", () async {
    final stub = _StubClient(happyRoutes(
        idpPage: const _Canned(200,
            body:
                "<html><body><p>Shibboleth is having a day.</p></body></html>")));
    expect(await failReason(stub), AnnyAuthReason.markupChanged);
  });

  test("AnnySession.isExpired: 50 min budget, log-safe toString", () {
    expect(
        AnnySession(
                jwt: "x",
                obtainedAt:
                    DateTime.now().subtract(const Duration(minutes: 49)))
            .isExpired,
        false);
    expect(
        AnnySession(
                jwt: "x",
                obtainedAt:
                    DateTime.now().subtract(const Duration(minutes: 51)))
            .isExpired,
        true);
    expect(AnnySession(jwt: "topsecretjwt").toString(),
        isNot(contains("topsecretjwt")));
  });
}
