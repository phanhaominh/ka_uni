import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;

/// R34.2 — the bureaucracy starter pack for incoming international MEI
/// bachelor students.
///
/// Editorial rules (the leash, bound into the format):
/// * every row cites ONE official source URL that was fetched and read
///   when its `stand` date was set — Karlsruhe-specific claims cite the
///   City of Karlsruhe / KIT page, everything else stays generic;
/// * wording is strictly advisory ("in der Regel / prüfe …") — the app
///   never claims legal certainty and NEVER raises an alarm from these
///   rows (auto-alarm VETOED; there is nothing here to fire one from);
/// * the `stand: <ISO date>` stamp of the last verification renders in
///   the row — stale editorial data must be visibly stale.
///
/// Parsing is strict on purpose: a row without an https URL or without a
/// stand date is a packaging bug, so [StarterPack.parse] throws instead of
/// shipping a silently unlabelled claim. test/starter_pack_test.dart
/// asserts the shipped asset passes it.
class StarterRow {
  final String id;
  final String url;

  /// ISO `yyyy-mm-dd` — when the URL + claim were last verified.
  final String stand;
  final String titleDe;
  final String titleEn;
  final String textDe;
  final String textEn;

  const StarterRow(
      {required this.id,
      required this.url,
      required this.stand,
      required this.titleDe,
      required this.titleEn,
      required this.textDe,
      required this.textEn});

  String title({required bool english}) => english ? titleEn : titleDe;
  String text({required bool english}) => english ? textEn : textDe;

  static final _isoDate = RegExp(r"^\d{4}-\d{2}-\d{2}$");

  static StarterRow _decode(Object? raw) {
    if (raw is! Map) throw FormatException("starter row is not an object");
    String req(String k) {
      final v = raw[k];
      if (v is! String || v.trim().isEmpty) {
        throw FormatException("starter row '$raw' field '$k' missing");
      }
      return v.trim();
    }

    final url = req("url");
    if (!url.startsWith("https://")) {
      throw FormatException("starter row ${raw["id"]} url is not https: $url");
    }
    final stand = req("stand");
    if (!_isoDate.hasMatch(stand)) {
      throw FormatException("starter row ${raw["id"]} stand is not ISO: $stand");
    }
    final t = raw["title"];
    final b = raw["text"];
    if (t is! Map || b is! Map) {
      throw FormatException("starter row ${raw["id"]} needs title+text maps");
    }
    return StarterRow(
      id: req("id"),
      url: url,
      stand: stand,
      titleDe: _reqLang(t, "de", raw),
      titleEn: _reqLang(t, "en", raw),
      textDe: _reqLang(b, "de", raw),
      textEn: _reqLang(b, "en", raw),
    );
  }

  static String _reqLang(Map raw, String lang, Object? rowRef) {
    final v = raw[lang];
    if (v is! String || v.trim().isEmpty) {
      throw FormatException("starter row $rowRef missing $lang copy");
    }
    return v.trim();
  }
}

class StarterPack {
  final List<StarterRow> rows;

  const StarterPack(this.rows);

  static const assetPath = "assets/starter_pack.json";

  static Future<StarterPack> load() async =>
      parse(await rootBundle.loadString(assetPath));

  static StarterPack parse(String raw) {
    final j = jsonDecode(raw);
    if (j is! Map || j["rows"] is! List) {
      throw const FormatException("starter pack needs a rows list");
    }
    final rows = (j["rows"] as List).map(StarterRow._decode).toList();
    final ids = rows.map((r) => r.id).toSet();
    if (ids.length != rows.length) {
      throw const FormatException("starter pack has duplicate row ids");
    }
    return StarterPack(rows);
  }
}
