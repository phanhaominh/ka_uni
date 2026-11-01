import 'package:flutter_test/flutter_test.dart';
import 'package:kit_mobile/state_management/kit_login_manager.dart';

const idp = "https://idp.scc.kit.edu";

Uri? pin(String target) => KITLoginManager.kitHttps(Uri.parse(idp), target);

void main() {
  test("KIT https SSO endpoints are accepted", () {
    expect(pin("https://idp.scc.kit.edu/idp/profile/SAML2/POST/SSO"),
        isNotNull);
    expect(pin("https://campus.studium.kit.edu/exams/registration.php?login=1"),
        isNotNull);
    expect(pin("https://ilias.studium.kit.edu/shib_login.php"), isNotNull);
    expect(pin("https://plus.campus.kit.edu/api/user/info"), isNotNull);
    expect(pin("https://kit.edu/"), isNotNull); // exact host is allowed
    expect(pin("https://IDP.SCC.KIT.EDU/x"), isNotNull,
        reason: "accepted regardless of host casing");
  });

  test("relative targets resolve against the current KIT base", () {
    expect(
        pin("/idp/profile/SAML2/Redirect/SSO;jsessionid=DEADBEEF"
                "?execution=e1s2")
            ?.toString(),
        "$idp/idp/profile/SAML2/Redirect/SSO;jsessionid=DEADBEEF"
        "?execution=e1s2");
    expect(KITLoginManager.kitHttps(Uri.parse("https://campus.studium.kit.edu"),
            "/campus/student/timetable.asp")
        ?.host, "campus.studium.kit.edu");
  });

  test("plain http is rejected", () {
    expect(pin("http://idp.scc.kit.edu/idp/profile/SAML2/POST/SSO"), isNull);
    expect(pin("http://evil.example/x"), isNull);
  });

  test("foreign hosts are rejected", () {
    expect(pin("https://evil.example/x"), isNull);
    // protocol-relative: inherits the https scheme, so only the host check
    // can stop it
    expect(pin("//evil.example/x"), isNull);
    expect(pin("ftp://idp.scc.kit.edu/x"), isNull);
    expect(pin("javascript:alert(1)"), isNull);
  });

  test("subdomain-suffix trap is rejected", () {
    expect(pin("https://kit.edu.evil.example/y"), isNull);
    expect(pin("https://kit.edu.attacker.example/z"), isNull);
    expect(pin("https://notkit.edu/x"), isNull);
    expect(pin("https://evil.kit.edu.attacker.example/x"), isNull);
  });

  test("garbage does not throw", () {
    expect(pin("https://[bad"), isNull);
    expect(pin(""), isNotNull); // resolves to the base itself
  });

  test("hardcoded login seeds still pass the pin", () {
    // every url the chain itself navigates to must survive the check
    expect(
      pin("https://idp.scc.kit.edu/idp/profile/SAML2/Redirect/SSO"
          "?execution=e1s1"),
      isNotNull,
    );
    final cas = Uri.parse("https://campus.studium.kit.edu");
    expect(KITLoginManager.kitHttps(cas, "https://campus.studium.kit.edu/"
        "?login=1"), isNotNull);
    expect(KITLoginManager.kitHttps(cas, "https://campus.studium.kit.edu/"
        "redirect.php?system=cascampus&url=/campus/student/timetable.asp"),
        isNotNull);
    expect(
      KITLoginManager.kitHttps(
          cas,
          "https://campus.studium.kit.edu/Shibboleth.sso/Login?target="
          "https://campus.studium.kit.edu/exams/registration.php?login=1"),
      isNotNull,
    );
    expect(
      pin("https://idp.scc.kit.edu/idp/profile/SAML2/POST/SSO"),
      isNotNull,
    );
  });
}
