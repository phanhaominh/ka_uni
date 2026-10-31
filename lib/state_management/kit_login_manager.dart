import 'dart:convert';
import 'dart:io' as io;

import 'package:flutter/foundation.dart';
import 'package:html/parser.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:http_session/http_session.dart';

import '../credentials/models/kit_credentials.dart';

class KITLoginManager {
  late KITCredentials credentials = KITCredentials(); // empty at the beginning

  bool ready = false;

  final HttpSession session =
      HttpSession(acceptBadCertificate: false, maxRedirects: 15);

  // ---- cascampus access (tguid + bot-challenge + SP bootstrap; verified 2026-10-30) ----
  String? tguid;
  bool cascampusReady = false;
  bool botChallengeAlgorithmChanged = false;
  // KIT's ASP/IdP endpoints intermittently accept a connection and then
  // stall indefinitely; an unbounded await used to freeze the whole fetch
  // chain (and every spinner waiting on it) for minutes. Every request goes
  // through netGet/netPost below so it always terminates.
  static const netTimeout = Duration(seconds: 30);

  Future<http.Response> netGet(Uri uri,
      {Map<String, String>? headers, Duration? timeout}) {
    final jar = session;
    return jar
        .get(uri, headers: headers)
        .timeout(timeout ?? netTimeout)
        .then(fixUtf8Body);
  }

  Future<http.Response> netPost(Uri uri,
      {Object? body, Map<String, String>? headers, Duration? timeout}) {
    final jar = session;
    return jar
        .post(uri, body: body, headers: headers)
        .timeout(timeout ?? netTimeout)
        .then(fixUtf8Body);
  }

  /// package:http decodes a body as latin1 whenever the Content-Type carries
  /// no charset - the webcal endpoint and any self-hosted .ics do exactly
  /// that, which turned "Hörsaal" into "HÃ¶rsaal" on screen. When no charset
  /// is declared, re-decode the raw bytes as UTF-8 (KIT serves UTF-8).
  static http.Response fixUtf8Body(http.Response r) {
    final ct = r.headers['content-type'];
    if (ct != null && ct.toLowerCase().contains("charset")) return r;
    String utf;
    try {
      utf = utf8.decode(r.bodyBytes);
    } on FormatException {
      return r; // not utf8 at all - keep package:http's lenient latin1 body
    }
    if (utf == r.body) return r;
    // Response.bytes + a stamped charset: package:http re-derives the body
    // encoding from the content-type header on every .body read, so without
    // 'charset=utf-8' the corrected bytes would read back as latin1 again.
    // (Response(String) can't be used at all: it latin1-encodes and throws
    // on the non-latin1 chars a corrected body legitimately contains.)
    return http.Response.bytes(
        utf8.encode(utf), r.statusCode,
        headers: {
          ...r.headers,
          'content-type':
              "${ct ?? 'application/octet-stream'}; charset=utf-8",
        },
        request: r.request);
  }

  int? solveBotChallenge(String body) {
    final m = RegExp(r"var seed = (\d+);").firstMatch(body);
    if (m == null) {
      botChallengeAlgorithmChanged = true;
      if (kDebugMode) {
        print("Bot challenge 503 but unknown shape -> ALGORITHM CHANGED");
      }
      return null;
    }
    final seed = int.parse(m.group(1)!);
    botChallengeAlgorithmChanged = false;
    return (seed * 7) % 100000 + seed % 3;
  }

  Future<bool> passBotChallenge(Uri url) async {
    var posted = false;
    for (var attempt = 0; attempt < 3; attempt++) {
      final challenge = await netGet(url);
      if (challenge.statusCode != 503 ||
          !challenge.body.contains("botchallenge")) {
        return true;
      }
      final answer = solveBotChallenge(challenge.body);
      if (answer == null) {
        return false;
      }
      final pr = await netPost(url, body: {"botchallenge": answer.toString()});
      posted = pr.statusCode == 302;
      var loc = pr.headers["location"];
      var cur = pr;
      for (var hop = 0;
          hop < 6 && cur.statusCode == 302 && loc != null;
          hop++) {
        final next = loc.startsWith("http") ? Uri.parse(loc) : url.resolve(loc);
        cur = await netGet(next);
        url = next; // any new challenge lives at the current hop
        loc = cur.headers["location"];
        if (kDebugMode) {
          print("  chase $hop -> ${cur.statusCode} len=${cur.body.length}");
        }
        if (cur.statusCode == 200 && !cur.body.contains("botchallenge")) {
          // The chain may surface the cascampus SP SAML relay (auto-submit
          // SAMLRequest form); posting it completes cascampus SSO. Without
          // this the token URL only ever shows the IdP login page again.
          if (cur.body.contains("SAMLRequest") ||
              cur.body.contains("SAMLResponse")) {
            final next2 = await _postFirstForm(cur, next);
            if (next2 == null) {
              return false;
            }
            cur = await netGet(next2);
            loc = cur.headers["location"];
            url = next2;
            if (kDebugMode) {
              print("  relay -> ${cur.statusCode} len=${cur.body.length}");
            }
          }
          if (cur.statusCode == 200 &&
              posted &&
              !sessionExpired(cur.body) &&
              !cur.body.contains("botchallenge")) {
            cascampusReady = true;
            return true;
          }
          if (cur.statusCode == 302 && loc != null) {
            continue;
          }
        }
        if (cur.body.contains("botchallenge")) {
          break; // new challenge at the new url; outer loop handles it
        }
      }
      if (kDebugMode) {
        print("challenge a$attempt ans=$answer -> ${pr.statusCode}"
            " len=${pr.body.length}");
      }
    }
    return false;
  }

  /// GET on cascampus .asp surfaces: passes the bot challenge and completes a
  /// pending SAML relay form if the SP session needs bootstrapping.
  Future<http.Response> guardedCasGet(String url) async {
    var uri = Uri.parse(url);
    var response = await netGet(uri);
    if (response.statusCode == 503 && response.body.contains("botchallenge")) {
      if (!await passBotChallenge(uri)) {
        return response;
      }
      response = await netGet(uri);
    }
    // cascampus SP login relay: page hosting the SAMLRequest/RelayState form
    for (var hop = 0;
        hop < 4 &&
            response.statusCode == 200 &&
            response.body.contains("SAMLRequest");
        hop++) {
      final relayed = await _postFirstForm(response, uri);
      if (relayed == null) {
        break;
      }
      uri = relayed;
      response = await netGet(uri);
    }
    return response;
  }

  Future<http.Response> guardedCasPost(
      String url, Map<String, String> body) async {
    final uri = Uri.parse(url);
    final probe = await netGet(uri);
    if (probe.statusCode == 503 && probe.body.contains("botchallenge")) {
      await passBotChallenge(uri);
    }
    return netPost(uri, body: body);
  }

  Future<Uri?> _postFirstForm(http.Response response, Uri from) async {
    final document = parse(response.body);
    for (var form in document.getElementsByTagName("form")) {
      final action = form.attributes["action"];
      final formData = <String, String>{};
      for (var input in form.getElementsByTagName("input")) {
        final name = input.attributes["name"];
        if (name != null) {
          formData[name] = input.attributes["value"] ?? "";
        }
      }
      if (formData.isEmpty || action == null) {
        continue;
      }
      final actionUri = from.resolve(action);
      final posted = await netPost(actionUri, body: formData);
      if (posted.statusCode == 302 && posted.headers.containsKey("location")) {
        return actionUri.resolve(posted.headers["location"]!);
      }
      return actionUri;
    }
    return null;
  }

  Future<String?> bootTguid() async {
    final response =
        await netGet(Uri.parse("https://campus.studium.kit.edu/?login=1"));
    final m = RegExp(r"tguid=(0x[0-9A-Fa-f]+)").firstMatch(response.body);
    tguid = m?.group(1);
    if (tguid == null && kDebugMode) {
      print("tguid bootstrap FAILED (no tguid on ?login=1 shell)");
    }
    return tguid;
  }

  /// One pass per campus-SP session: redirect.php issues a login-token URL,
  /// which (after the bot challenge) leads to the cascampus SAML relay form.
  Future<bool> bootCascampusSession() async {
    if (tguid == null && await bootTguid() == null) {
      return false;
    }
    var uri = Uri.parse("https://campus.studium.kit.edu/redirect.php"
        "?system=cascampus&url=/campus/student/timetable.asp");
    for (var hop = 0; hop < 12; hop++) {
      var response = await netGet(uri);
      if (kDebugMode) {
        print("boot hop $hop ${response.statusCode} $uri");
      }
      if (response.statusCode == 302 &&
          response.headers.containsKey("location")) {
        // redirect.php / Shibboleth hand off via 302; session.get does not
        // follow redirects, so hop manually (relative Location possible).
        final loc = response.headers["location"]!;
        uri = loc.startsWith("http") ? Uri.parse(loc) : uri.resolve(loc);
        continue;
      }
      if (response.statusCode == 503 &&
          response.body.contains("botchallenge")) {
        if (!await passBotChallenge(uri)) {
          return false;
        }
        response = await netGet(uri);
      }
      if (response.statusCode == 200 && response.body.contains("SAMLRequest")) {
        final next = await _postFirstForm(response, uri);
        if (next == null) {
          return false;
        }
        uri = next;
        continue;
      }
      if (response.statusCode == 200 && !sessionExpired(response.body)) {
        cascampusReady = true;
        return true;
      }
      return false;
    }
    return false;
  }

  bool sessionExpired(String body) {
    final i = body.indexOf("message message-error");
    if (i < 0) {
      return false;
    }
    final t = body.substring(i, (i + 260).clamp(0, body.length));
    return t.contains("abgelaufen") || t.contains("nicht angemeldet");
  }

  Future<void> clearCookiesAndCache() async {
    session.clear();
    tguid = null;
    plusReady = false;
    cascampusReady = false;
  }

  String get cookiesString {
    final cookies = session.cookieStore.cookies;
    return cookies.map((c) => "${c.name}=${c.value}").join("; ");
  }

  bool sessionContainsCookieNamed(String cookieName) {
    final cookies = session.cookieStore.cookies;

    for (final cookie in cookies) {
      if (cookie.name.contains(cookieName)) {
        return true;
      }
    }

    return false;
  }

  // ---- Campus+ (plus.campus.kit.edu) session ----
  // The SignMeUp API sits behind an ASP.NET + Keycloak OIDC code flow
  // (response_mode=form_post, SAML broker to idp.scc.kit.edu). Its
  // intermediate cookies are only survives by a path-aware jar that the
  // shared cookie store does not implement (multi-cookie Set-C headers,
  // path=/signin-oidc correlation), so the handshake is driven here with a
  // raw client; the resulting identity cookie is merged back into the
  // shared session and all later API calls use it normally.
  bool plusReady = false;

  Future<bool> ensurePlusSession({bool force = false}) async {
    if (plusReady && !force) return true;
    final probe = await netGet(
        Uri.parse("https://plus.campus.kit.edu/api/user/info"),
        headers: {"Accept": "application/json"});
    if (probe.statusCode == 200 &&
        probe.body.trim().isNotEmpty &&
        probe.body.trim() != "null") {
      plusReady = true;
      return true;
    }
    final raw = IOClient(io.HttpClient());
    try {
      final jar = <String, Map<String, String>>{}; // host -> "path|name"

      String? headerFor(Uri u) {
        final parts = <String>[];
        for (final entry in jar.entries) {
          if (entry.key != u.host) continue;
          for (final c in entry.value.entries) {
            final path = c.key.substring(0, c.key.indexOf("|"));
            if (u.path.startsWith(path)) {
              parts
                  .add("${c.key.substring(c.key.indexOf("|") + 1)}=${c.value}");
            }
          }
        }
        if (u.host == "idp.scc.kit.edu") {
          // reuse the already-authenticated IdP session (auto SAML SSO)
          for (final c in session.cookieStore
              .getCookiesForRequest("idp.scc.kit.edu", u.path)) {
            parts.add("${c.name}=${c.value}");
          }
        }
        return parts.isEmpty ? null : parts.join("; ");
      }

      void absorb(Uri u, http.Response resp) {
        final sc = resp.headers["set-cookie"];
        if (sc == null) return;
        final hostJar = jar.putIfAbsent(u.host, () => {});
        for (final cookie in sc.split(RegExp(r',(?=\S+=)'))) {
          final attrs = cookie.split(';');
          final kv = attrs.first;
          final eq = kv.indexOf('=');
          if (eq <= 0) continue;
          final name = kv.substring(0, eq).trim();
          var path = "/";
          for (final a in attrs.skip(1)) {
            final ai = a.indexOf('=');
            if (ai > 0 && a.substring(0, ai).trim().toLowerCase() == "path") {
              path = a.substring(ai + 1).trim();
            }
          }
          final key = "$path|$name";
          if (attrs.any((a) => a.contains("01 Jan 1970"))) {
            hostJar.remove(key);
          } else {
            hostJar[key] = kv.substring(eq + 1).trim();
          }
        }
      }

      Future<http.Response> step(
          String method, Uri u, Map<String, String>? fields) async {
        final req = http.Request(method, u)
          ..followRedirects = false
          ..headers["accept"] = "text/html,application/xhtml+xml";
        if (fields != null) req.bodyFields = fields;
        final h = headerFor(u);
        if (h != null) req.headers["cookie"] = h;
        final resp = await http.Response.fromStream(await raw.send(req))
            .timeout(netTimeout);
        absorb(u, resp);
        return resp;
      }

      var url = Uri.parse("https://plus.campus.kit.edu/api/user/oidc-login"
          "?returnUrl=/plus/");
      var resp = await step("GET", url, null);
      for (var hop = 0; hop < 14; hop++) {
        if (resp.statusCode == 200) {
          final doc = parse(resp.body);
          var advanced = false;
          for (final form in doc.getElementsByTagName("form")) {
            final action = form.attributes["action"];
            final fields = <String, String>{};
            var credentialForm = false;
            for (final inp in form.getElementsByTagName("input")) {
              final n = inp.attributes["name"];
              if ((inp.attributes["type"] ?? "").toLowerCase() == "password" ||
                  (n ?? "").toLowerCase().contains("user")) {
                credentialForm = true; // idp login page: session vanished
              }
              if (n != null) fields[n] = inp.attributes["value"] ?? "";
            }
            if (credentialForm || action == null || fields.isEmpty) continue;
            url = url.resolve(action);
            resp = await step("POST", url, fields);
            advanced = true;
            break;
          }
          if (!advanced) break;
        } else if ((resp.statusCode == 302 || resp.statusCode == 303) &&
            resp.headers["location"] != null) {
          url = url.resolve(resp.headers["location"]!);
          resp = await step("GET", url, null);
        } else {
          break;
        }
      }

      final plusJar = jar["plus.campus.kit.edu"] ?? const {};
      if (!plusJar.keys.any((k) => k.contains(".AspNetCore.Identity"))) {
        if (kDebugMode) {
          print("plus OIDC chain ended at ${resp.statusCode} without identity");
        }
        return false;
      }
      for (final e in plusJar.entries) {
        session.cookieStore.updateCookies(
            "${e.key.substring(e.key.indexOf("|") + 1)}=${e.value}"
                "; path=/; secure; httponly",
            "plus.campus.kit.edu",
            "/");
      }
      final check = await netGet(
          Uri.parse("https://plus.campus.kit.edu/api/user/info"),
          headers: {"Accept": "application/json"});
      plusReady = check.statusCode == 200 && check.body.trim().trim() != "null";
      if (kDebugMode && !plusReady) {
        print("plus session check failed: ${check.statusCode}");
      }
      return plusReady;
    } catch (e) {
      if (kDebugMode) {
        print("plus session bootstrap failed: $e");
      }
      return false;
    } finally {
      raw.close();
    }
  }

  Future<bool> fetchJSession() async {
    String url =
        "https://idp.scc.kit.edu/idp/profile/SAML2/Redirect/SSO?execution=e1s1";

    await netGet(Uri.parse(url));
    if (sessionContainsCookieNamed("JSESSIONID")) {
      return true;
    }

    if (kDebugMode) {
      print("Failed to fetch JSESSIONID!");
    }

    return false;
  }

  Future<int> fetchStage0_Init(
      {notify = true, retryIfFailed = true, secondRetryIfFailed = true}) async {
    if (!credentials.isFormatValid) {
      return -1;
    }

    // scheduleFetchingTimer = null;

    // `ready` deliberately NOT cleared here: fetchStage0 runs inside every
    // periodic refresh too, and the old unconditional `ready = false` meant
    // one transient timeout between here and the final parse dumped a
    // logged-in user onto LoginPage although the stored credentials were
    // fine. Only a *definitive* auth failure (login() -> credentials.valid
    // == false) or logout tears the session down now.
    await clearCookiesAndCache();

    // if (notify) {
    //   notifyListeners();
    // }

    if (!(await fetchJSession())) {
      return -2;
    }

    return 0;
  }

  Future<http.Response> fetchStage1_TryToOpenLoginPage(String url) async {
    var response = await netGet(Uri.parse(url));

    // sometimes, server wants us to manually "redirect" to the login page, idk why
    if (isManualRedirectRequired(response)) {
      final currentResponse = await handleNoJSResponse(response.body);
      if (currentResponse == null) {
        if (kDebugMode) {
          print("Stage 1: Manual redirect has failed");
        }
        return response;
      }
      response = currentResponse;
    } else if (kDebugMode) {
      print("Stage 1: No manual redirect is required! Going forward...");
    }

    return response;
  }

  Future<http.Response?> fetchStage2_(http.Response previousResponse) async {
    var document = parse(previousResponse.body);
    var forms = document.getElementsByTagName("form");
    String url = "";
    Map<String, dynamic> formData = {};
    bool foundLoginForm = false;

    for (var form in forms) {
      if (form.innerHtml.toLowerCase().contains("login")) {
        final String? action = form.attributes["action"];
        if (action == null) {
          if (kDebugMode) {
            print("login form action is null. Reporting failure...");
          }
          return null;
        }

        url = "https://idp.scc.kit.edu$action";
        final inputs = form.getElementsByTagName("input");

        for (var input in inputs) {
          String? name = input.attributes["name"];
          if (name != null) {
            formData[name] = input.attributes["value"] ?? "";
          }
        }

        foundLoginForm = true;
        break;
      }
    }

    if (!foundLoginForm) {
      if (kDebugMode) {
        print("Failed to find the login form!");
        print(previousResponse.body);
      }
      return null;
    }

    formData["_eventId_proceed"] = "";
    formData["_shib_idp_revokeConsent"] = "false";
    formData["j_username"] = credentials.username;
    formData["j_password"] = credentials.password;

    if (kDebugMode) {
      print("Successfully found the login form.");
    }

    if (kDebugMode) {
      print("Stage2 POST url=$url fields=${formData.keys.toList()}");
    }

    var response = await netPost(Uri.parse(url), body: formData);
    if (kDebugMode) {
      final t = response.body;
      print("Stage2 POST -> ${response.statusCode} len=${t.length} "
          "loc=${response.headers['location']}");
      print(
          "Stage2 text: ${RegExp('<title>([^<]*)').firstMatch(t)?.group(1)} | "
          "relay=${t.contains('RelayState')} saml=${t.contains('SAMLResponse')} "
          "err=${RegExp(r'(?:wurden nicht|ung[^<]{0,40}|Fehler[^<]{0,60})').firstMatch(t)?.group(0)}");
      print(
          "Stage2 forms: ${RegExp('<form[^>]*action="([^"]*)"').allMatches(t).map((m) => m.group(1)).toList()}");
      print(
          "Stage2 inputs: ${RegExp('name="([^"]+)"').allMatches(t).map((m) => m.group(1)).toSet().toList()}");
    }

    // The IdP answers a valid credential POST with a 302 to the next execution
    // state (e1s2) which then carries the SAMLResponse. netPost() does not
    // follow it, so the SAML relay never ran and every login failed downstream.
    var guard = 0;
    while (response.statusCode == 302 &&
        response.headers.containsKey("location") &&
        guard++ < 8) {
      final location = response.headers["location"]!;
      final next = location.startsWith("http")
          ? Uri.parse(location)
          : Uri.parse("https://idp.scc.kit.edu$location");
      if (kDebugMode) {
        print("Stage2 following 302 -> $next");
      }
      response = await netGet(next);
      if (kDebugMode) {
        final t = response.body;
        print("Followed -> ${response.statusCode} len=${t.length} "
            "relay=${t.toLowerCase().contains("relaystate")} "
            "saml=${t.contains("SAMLResponse")}");
      }
    }

    if (isManualRedirectRequired(response)) {
      final currentResponse = await handleNoJSResponse(response.body);
      if (currentResponse == null) {
        if (kDebugMode) {
          print("Stage 2: Failed to handle NO-JS RelayState response!");
        }
        return response;
      }

      response = currentResponse;
    } else if (kDebugMode) {
      print("Stage 2: Skipped manual redirect");
    }

    if (response.statusCode == 302) {
      if (kDebugMode) {
        print("Stage 2: redirect required!");
      }

      if (response.headers.containsKey("location")) {
        final location = response.headers["location"]!;
        url = "https://idp.scc.kit.edu$location";
        if (kDebugMode) {
          print(url);
        }

        response = await netGet(Uri.parse(url));
      }
    }

    return response;
  }

  bool isManualRedirectRequired(http.Response response) {
    final body = response.body.toLowerCase();
    return body.contains("you must press the continue button") ||
        body.contains("relaystate");
  }

  Future<http.Response?> handleNoJSResponse(String body) async {
    if (kDebugMode) {
      print("Attempting to handle the no-js manual redirect...");
    }

    final document = parse(body);
    final forms = document.getElementsByTagName("form");
    Map<String, String> formData = {};
    String url = "";

    for (var form in forms) {
      if (form.innerHtml.toLowerCase().contains("relaystate")) {
        final String? action = form.attributes["action"];
        if (action == null) {
          if (kDebugMode) {
            print(
                "Handling no-js redirect: action is null. Reporting failure...");
          }
          return null;
        }

        url = action;
        final inputs = form.getElementsByTagName("input");

        for (var input in inputs) {
          String? name = input.attributes["name"];
          if (name != null) {
            formData[name] = input.attributes["value"] ?? "";
          }
        }

        break;
      }
    }

    if (url.isEmpty) {
      if (kDebugMode) {
        print("Handling no-js redirect: url is empty. Reporting failure...");
      }
      return null;
    }

    if (kDebugMode) {
      // print(
      // "Handling no-js redirect: url is $url, cookies: ${session.cookieStore.cookies.toString()}");
      print("Handling no-js redirect: url is $url");
      print("formData: ${formData.keys}");
    }

    var response = await netPost(Uri.parse(url), body: formData);

    if (response.statusCode == 302 &&
        response.headers.containsKey("location")) {
      url = response.headers["location"]!;
      response = await netGet(Uri.parse(url));
    }

    return response;
  }
}
