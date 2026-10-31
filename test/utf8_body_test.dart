import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:kit_mobile/state_management/kit_login_manager.dart';

http.Response _resp(List<int> bytes, {String? ct}) => http.Response.bytes(
    bytes, 200, headers: ct == null ? {} : {'content-type': ct});

void main() {
  test("charsetless umlaut body re-decodes as utf8", () {
    final bytes = utf8.encode("Gaede-Hörsaal, Ferdinand-Redtenbacher-Hörsaal");
    final fixed = KITLoginManager.fixUtf8Body(_resp(bytes));
    expect(fixed.body, "Gaede-Hörsaal, Ferdinand-Redtenbacher-Hörsaal");
    expect(fixed.statusCode, 200);
  });

  test("declared charset is left to package:http", () {
    const latin = [0x48, 0xe4, 0x6c, 0x6c, 0x6f]; // "Hällo" in latin1
    final same = KITLoginManager.fixUtf8Body(
        _resp(latin, ct: "text/plain; charset=ISO-8859-1"));
    expect(same.body, "Hällo");
  });

  test("undecodable bytes do not throw", () {
    final fixed = KITLoginManager.fixUtf8Body(_resp([0xC3, 0x28, 0xA0, 0xFF]));
    expect(fixed.body, isNotEmpty);
  });
}
