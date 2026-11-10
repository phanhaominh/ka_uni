import 'package:flutter_test/flutter_test.dart';
import 'package:kit_mobile/state_management/ilias/ilias_manager.dart';

/// The download gate decides which ILIAS sendfile bodies may be saved and
/// under which extension - the fix for genuine zip/pptx/docx material
/// being refused as "not a PDF" while login walls must stay refused.
void main() {
  String? gate(
          {bool isPdf = false, int status = 200, String? type, String? disp}) =>
      IliasManager.extensionForDownloadBody(
          isPdf: isPdf,
          statusCode: status,
          contentType: type,
          contentDisposition: disp);

  group("extensionForDownloadBody", () {
    test("PDF magic bytes win over any header", () {
      expect(gate(isPdf: true, type: "application/octet-stream"), ".pdf");
      expect(gate(isPdf: true), ".pdf");
    });

    test("non-200 and HTML bodies stay refused", () {
      expect(gate(status: 404, type: "application/zip"), isNull);
      expect(gate(status: 302, isPdf: true), isNull);
      expect(gate(type: "text/html; charset=UTF-8"), isNull);
      expect(gate(type: "text/html"), isNull);
      // nothing at all proves a saveable body
      expect(gate(), isNull);
    });

    test("genuine non-PDF content types map to their real extension", () {
      expect(gate(type: "application/zip"), ".zip");
      expect(gate(type: "application/x-zip-compressed"), ".zip");
      expect(gate(type: "application/x-7z-compressed"), ".7z");
      expect(gate(type: "application/vnd.rar"), ".rar");
      expect(gate(type: "application/epub+zip"), ".epub");
      expect(gate(type: "application/msword"), ".doc");
      expect(gate(type: "application/vnd.ms-powerpoint"), ".ppt");
      expect(
          gate(
              type:
                  "application/vnd.openxmlformats-officedocument.presentationml.presentation"),
          ".pptx");
      expect(
          gate(
              type:
                  "application/vnd.openxmlformats-officedocument.wordprocessingml.document"),
          ".docx");
      expect(
          gate(
              type:
                  "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"),
          ".xlsx");
      expect(gate(type: "application/vnd.oasis.opendocument.presentation"),
          ".odp");
      // media type parameters and casing must not defeat the mapping
      expect(gate(type: "TEXT/PLAIN; charset=UTF-8"), ".txt");
      expect(gate(type: " video/mp4 "), ".mp4");
    });

    test("unknown types fall back to the original filename extension", () {
      expect(
          gate(
              type: "application/octet-stream",
              disp: 'attachment; filename="Uebungsblatt Loesung.zip"'),
          ".zip");
      expect(
          gate(
              type: "application/octet-stream",
              disp: "attachment; filename*=UTF-8''Wortschatz.pptx"),
          ".pptx");
      // unquoted names and a totally missing content-type still work
      expect(gate(disp: "attachment; filename=skript.doc"), ".doc");
      // but no name, no known type: keep the old refusal, guess nothing
      expect(gate(type: "application/octet-stream"), isNull);
    });

    test("web-page names, lying .pdf names and junk extensions refused", () {
      expect(
          gate(
              type: "application/octet-stream",
              disp: 'attachment; filename="login.html"'),
          isNull);
      // a body the magic bytes refused is not a PDF, whatever it is called
      expect(
          gate(
              type: "application/octet-stream",
              disp: 'attachment; filename="page.pdf"'),
          isNull);
      expect(gate(type: "application/octet-stream", disp: "x"), isNull);
      expect(gate(type: "application/octet-stream", disp: "filename=no_ext"),
          isNull);
      expect(
          gate(
              type: "application/octet-stream",
              disp: "filename=evil.a12345678901"),
          isNull);
    });
  });
}
