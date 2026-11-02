// Campus feeds embed invisible break/shy characters; on a narrow module
// card they split titles mid-word with no visible hyphen at all.
import 'package:flutter_test/flutter_test.dart';
import 'package:kit_mobile/utils/string_prettifiers.dart';

void main() {
  test("soft hyphens never survive into card titles", () {
    expect(
      sanitizeModuleTitle("Tech\u00ADnische Ther\u00ADmodynamik"),
      "Technische Thermodynamik",
    );
  });

  test("zero-width spaces are stripped", () {
    expect(sanitizeModuleTitle("Basis\u200bkurven"), "Basiskurven");
  });

  test("non-breaking spaces become normal break opportunities", () {
    expect(
      sanitizeModuleTitle("Basics\u00A0of Manufacturing"),
      "Basics of Manufacturing",
    );
  });

  test("existing exam-annotation stripping keeps working", () {
    expect(
      sanitizeModuleTitle("Lineare Algebra - Prüfung"),
      "Lineare Algebra",
    );
  });
}
