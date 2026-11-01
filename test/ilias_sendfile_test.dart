import 'package:flutter_test/flutter_test.dart';
import 'package:kit_mobile/ilias/views/ilias_page_view.dart';

const docsDir = "/data/user/0/com.example.app/app_flutter/ilias_cache/WS_26_27";

/// A real-looking ILIAS download URL; only the ref_id changes per case.
String sendfile(String refId) => "https://ilias.studium.kit.edu/w/getfile/"
    "plugin/file_download.php/xy/sendfile.php?ref_id=$refId";

void main() {
  test("only https ILIAS sendfile urls are intercepted", () {
    expect(isIliasSendfileUrl(sendfile("%2Fps%2Fkiu%2F123456")), isTrue);
    expect(
        isIliasSendfileUrl("http://ilias.studium.kit.edu/"
            "w/sendfile.php?ref_id=1"),
        isFalse);
    expect(isIliasSendfileUrl("https://evil.example/sendfile"), isFalse);
    expect(isIliasSendfileUrl("https://kit.edu.evil.example/sendfile"),
        isFalse);
    expect(
        isIliasSendfileUrl(
            "https://ilias.studium.kit.edu.evil.example/w/sendfile.php"),
        isFalse);
    // browsing traffic must not be swallowed by the interception
    expect(
        isIliasSendfileUrl(
            "https://ilias.studium.kit.edu/ilias.php?baseClass=ildashboardgui"),
        isFalse);
    expect(isIliasSendfileUrl("not a url"), isFalse);
  });

  test("evil.example sendfile yields no destination", () {
    expect(sendfileFileName("https://evil.example/sendfile"), isNull);
    expect(
        iliasSendfilePath(docsDir, "https://evil.example/sendfile?ref_id=1"),
        isNull);
  });

  test("path traversal in ref_id is scrubbed", () {
    final name = sendfileFileName(sendfile("..%2F..%2Fevil"))!;
    expect(name, "_.._evil");
    expect(name, isNot(contains("/")));
    expect(name.startsWith("."), isFalse);
  });

  test("destination path stays inside the download directory", () {
    final path = iliasSendfilePath(
        docsDir, sendfile("..%2F..%2F..%2Fwindows%2Fsystem32%2Fevil"),
        title: "Security / Hacks: 100%!?")!;
    expect(path.startsWith("$docsDir/"), isTrue);
    expect(path.split("/").length, docsDir.split("/").length + 1);
    expect(path.endsWith(".pdf"), isTrue);
  });

  test("dots-only or missing ref_id yields nothing", () {
    expect(sendfileFileName(sendfile("%2E%2E")), isNull);
    expect(
        sendfileFileName("https://ilias.studium.kit.edu/w/sendfile.php"),
        isNull);
    // Dart decodes invalid escapes leniently (kept literally); the
    // scrubber neutralises the '%' and no separator can survive anyway
    expect(sendfileFileName(sendfile("%zz")), "_zz");
  });

  test("title is scrubbed and total name length capped", () {
    final name =
        sendfileFileName(sendfile("ref7"), title: "Mathe I/II: Analysis 1")!;
    expect(name, "Mathe I_II_ Analysis 1ref7");
    final long = sendfileFileName(
        "https://ilias.studium.kit.edu/sendfile.php?ref_id=${"a" * 500}",
        title: "T" * 200)!;
    expect(long.length, lessThanOrEqualTo(120));
  });
}
