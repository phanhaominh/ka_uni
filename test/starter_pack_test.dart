// R34.2 + R34.3 editorial leash tests: the shipped starter pack asset and
// the launcher rows must be verifiable packaging — every row an https URL,
// every row a `stand:` ISO stamp, both languages present. The parser is
// strict BY DESIGN (an unlabelled claim must never ship), and the tests
// pin both directions: the real asset passes, a doctored row throws.
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:kit_mobile/bureaucracy/papierkram.dart';
import 'package:kit_mobile/bureaucracy/starter_pack.dart';

const _good = '{"rows":[{"id":"a","url":"https://x.de/p",'
    '"stand":"2026-11-13","title":{"de":"d","en":"e"},'
    '"text":{"de":"d","en":"e"}}]}';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test("every shipped starter row: https URL + stand: stamp + de&en copy",
      () async {
    final pack =
        StarterPack.parse(await rootBundle.loadString(StarterPack.assetPath));
    expect(pack.rows.length, inInclusiveRange(6, 10));
    final iso = RegExp(r"^\d{4}-\d{2}-\d{2}$");
    final ids = <String>{};
    for (final r in pack.rows) {
      expect(ids.add(r.id), isTrue, reason: "duplicate id ${r.id}");
      expect(r.url.startsWith("https://"), isTrue, reason: r.id);
      expect(Uri.parse(r.url).host, contains("."), reason: r.id);
      expect(iso.hasMatch(r.stand), isTrue,
          reason: "${r.id} needs a stand: yyyy-mm-dd stamp");
      expect(r.titleDe.trim(), isNotEmpty, reason: r.id);
      expect(r.titleEn.trim(), isNotEmpty, reason: r.id);
      expect(r.textDe.trim(), isNotEmpty, reason: r.id);
      expect(r.textEn.trim(), isNotEmpty, reason: r.id);
    }
    // the leash: a Karlsruhe/KIT-specific claim must cite the Karlsruhe or
    // KIT page itself — a row talking about the city on a foreign host is
    // exactly the generic-claim-drift this test forbids
    final ka = pack.rows.where((r) =>
        r.textDe.contains("Karlsruhe") ||
        r.textDe.contains("KIT") ||
        r.textEn.contains("Karlsruhe") ||
        r.textEn.contains("KIT"));
    for (final r in ka) {
      final host = Uri.parse(r.url).host;
      expect(
          host.endsWith("karlsruhe.de") ||
              host.endsWith("kit.edu") ||
              host.endsWith("sw-ka.de"),
          isTrue,
          reason: "${r.id}: Karlsruhe claim on ${r.url}");
    }
  });

  test("parse refuses rows without https, without stand, without copy", () {
    expect(() => StarterPack.parse(_good), returnsNormally);
    expect(() => StarterPack.parse(_good.replaceFirst("https://", "http://")),
        throwsA(isA<FormatException>()));
    expect(
        () => StarterPack.parse(
            _good.replaceFirst('"stand":"2026-11-13",', '')),
        throwsA(isA<FormatException>()));
    expect(
        () => StarterPack.parse(
            _good.replaceFirst('"stand":"2026-11-13"', '"stand":"13.11.2026"')),
        throwsA(isA<FormatException>()));
    expect(
        () => StarterPack.parse(
            _good.replaceFirst('"title":{"de":"d"', '"title":{"de":""')),
        throwsA(isA<FormatException>()));
    expect(() => StarterPack.parse('{"rows":[]}'), returnsNormally);
    expect(() => StarterPack.parse('{"nope":1}'),
        throwsA(isA<FormatException>()));
  });

  test("launcher rows pair EN label with DE jargon and are https", () {
    expect(kPortalRows.length, greaterThanOrEqualTo(6));
    for (final r in kPortalRows) {
      expect(r.url.startsWith("https://"), isTrue, reason: r.id);
      expect(r.en.trim(), isNotEmpty, reason: r.id);
      expect(r.de.trim(), isNotEmpty, reason: r.id);
    }
    // the Matrikel mini-action is data-gated in settings_page: the card
    // renders only when vm.student.matriculationNumber is non-empty
    // (no login -> the whole card is hidden, pinned by the build gate)
  });
}
