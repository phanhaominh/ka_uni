import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;

import 'package:kit_mobile/mensa/models/mensa_models.dart';

/// Parses the SW Karlsruhe "popup_plain" Speiseplan view.
///
/// URL contract (lives in MensaManager):
/// `https://www.sw-ka.de/de/hochschulgastronomie/speiseplan/mensa_<id>/?STYLE=popup_plain&view=ok&c=<id>&kw=<isoWeek>`
/// That stripped render is: one <h1> with the canteen name, then per
/// plan DAY an <h1> with a "Mi 12.11." stamp followed by one <table>
/// whose direct rows are `line name | nested meal table`; meal rows are
/// exactly three cells: `[classifier]`, `name (additives)`, `price`.
/// Layout invariants verified live 11.2026 and matching the structure
/// meyfa/ka-mensa-fetch has parsed for years.
class MensaHtmlParser {
  /// "Mo 11.11." / English twin "We 11.11." day stamps; no year in the
  /// feed - see [_resolveDate]. The DE page uses DE prefixes, the EN
  /// page EN prefixes; both are accepted so either locale's page parses.
  static final RegExp _dayStamp = RegExp(
      r'^(?:Mo|Di|Mi|Do|Fr|Sa|So|Mon|Tue|Wed|Thu|Fri|Sat|Sun)\s+(\d{1,2})\.(\d{1,2})\.');

  /// Trailing "(Se,We,ML)" allergen suffix on the meal-name cell -
  /// only comma/short-code shaped, so a real "(Mensa) " in a name stays.
  static final RegExp _additives = RegExp(r'\((\w{1,3}(?:,\s*\w{1,3})*)\)\s*$');

  /// "[VG]" / "[VEG,LAB]" classifier cell.
  static final RegExp _classifiers = RegExp(r'^\[([\w,]+)\]$');

  /// "3,80 €" (tolerates "3.80 €") -> cents.
  static final RegExp _price = RegExp(r'(\d{1,2})[,.](\d\d)\s*€');

  /// Parses every plan day in [html]. [ref] is the date whose ISO week
  /// was fetched; undated stamps are anchored to it. A day whose table
  /// cannot be interpreted is SKIPPED, never guessed, so a site layout
  /// change degrades to "no data" instead of wrong data.
  List<MensaDay> parseWeek(String html, DateTime ref) {
    final dom.Document doc = html_parser.parse(html);
    final List<dom.Element> h1s = doc.querySelectorAll('h1');
    final List<MensaDay> days = [];
    for (int i = 1; i < h1s.length; i++) {
      // h1[0] is the canteen title; day stamps may mix with other
      // headings, so every later h1 matching the stamp opens a day
      final RegExpMatch? stamp = _dayStamp.firstMatch(h1s[i].text.trim());
      if (stamp == null) continue;
      final dom.Element? table = _nextElement(h1s[i], 'table');
      if (table == null) continue;
      final List<MensaLine> lines = _parseLines(table);
      if (lines.isEmpty) continue;
      days.add(MensaDay(
          date: _resolveDate(
              int.parse(stamp.group(1)!), int.parse(stamp.group(2)!), ref),
          lines: lines));
    }
    return days;
  }

  /// Direct <tr> children of [table] (package:html builds the real tree
  /// including implied tbody wrappers - rows can sit one level deeper).
  static List<dom.Element> _rows(dom.Element table) => [
        for (final dom.Element c in table.children)
          if (c.localName == 'tr')
            c
          else if (c.localName == 'tbody')
            ...c.children.where((dom.Element e) => e.localName == 'tr'),
      ];

  List<MensaLine> _parseLines(dom.Element dayTable) {
    final List<MensaLine> lines = [];
    for (final dom.Element tr in _rows(dayTable)) {
      // a line is exactly name|meals - rows of the nested meal table are
      // never direct children of the day table, so no exclusion needed
      if (tr.children.length != 2) continue;
      // the name cell stacks runs with <br>: "Linie 1<br>Gut & Günstig",
      // "[pizza]werk<br>Pizza<br>11-14 Uhr" - collapse each run, keep the
      // first as the name, join the rest as the muted sub label
      final List<String> runs = _runs(tr.children[0]);
      if (runs.isEmpty) continue;
      final dom.Element? mealTable =
          tr.children[1].querySelector('table');
      lines.add(MensaLine(
          name: runs.first,
          sub: runs.length > 1 ? runs.sublist(1).join(" · ") : null,
          meals: mealTable == null ? const [] : _parseMeals(mealTable)));
    }
    return lines;
  }

  /// Text runs of [cell], split at every <br> (which package:html drops
  /// from .text, gluing "Linie 1" onto "Gut & Günstig").
  static List<String> _runs(dom.Element cell) {
    final List<String> runs = [];
    final StringBuffer cur = StringBuffer();
    void flush() {
      final String s = cur.toString().replaceAll(RegExp(r'\s+'), ' ').trim();
      if (s.isNotEmpty) runs.add(s);
      cur.clear();
    }

    void walk(dom.Node n) {
      if (n is dom.Text) {
        cur.write(n.data);
        return;
      }
      if (n is dom.Element && n.localName == 'br') {
        flush();
        return;
      }
      for (final dom.Node c in n.nodes) {
        walk(c);
      }
      if (n is dom.Element && n.localName == 'div') flush(); // block boxes
    }

    walk(cell);
    flush();
    return runs;
  }

  List<MensaMeal> _parseMeals(dom.Element table) {
    final List<MensaMeal> meals = [];
    for (final dom.Element tr in _rows(table)) {
      if (tr.children.length != 3) continue;
      final String nameCell = _collapse(tr.children[1].text);
      if (nameCell.isEmpty) continue;
      List<String> additives = const [];
      String name = nameCell;
      final RegExpMatch? am = _additives.firstMatch(nameCell);
      if (am != null) {
        additives = am
            .group(1)!
            .split(',')
            .map((String s) => s.trim())
            .where((String s) => s.isNotEmpty)
            .toList(growable: false);
        name = _collapse(
            nameCell.substring(0, nameCell.length - am.group(0)!.length));
      }
      final RegExpMatch? cm =
          _classifiers.firstMatch(_collapse(tr.children[0].text));
      meals.add(MensaMeal(
        name: name,
        priceCents: _cents(tr.children[2].text),
        classifiers: cm?.group(1)?.split(',') ?? const [],
        additives: additives,
      ));
    }
    return meals;
  }

  int? _cents(String s) {
    final RegExpMatch? m = _price.firstMatch(s);
    if (m == null) return null;
    return int.parse(m.group(1)!) * 100 + int.parse(m.group(2)!);
  }

  /// The next element sibling named [tag]; pure-text siblings are
  /// skipped, any OTHER element means the layout changed under us.
  /// (package:html Nodes have no nextSibling - walk the parent's kids.)
  dom.Element? _nextElement(dom.Element from, String tag) {
    final dom.Element? parent = from.parent;
    if (parent == null) return null;
    final List<dom.Node> kids = parent.nodes;
    final int i = kids.indexOf(from);
    if (i < 0) return null;
    for (int k = i + 1; k < kids.length; k++) {
      final dom.Node n = kids[k];
      if (n is dom.Element) {
        final bool hit = n.localName == tag;
        return hit ? n : null;
      }
      if ((n is dom.Text ? n.data : "").trim().isNotEmpty) return null;
    }
    return null;
  }

  /// The feed stamps no year: the candidate (previous/current/next
  /// year) CLOSEST to the fetch reference date wins. A Dec stamp seen
  /// on 1.1. belongs to LAST year (ISO weeks 1-3 start in December -
  /// a forward-only bump would file them a year ahead); the Jan stamp
  /// of a Dec 28 fetch flips the same way.
  DateTime _resolveDate(int day, int month, DateTime ref) {
    List<DateTime> candidates = [
      DateTime(ref.year - 1, month, day),
      DateTime(ref.year, month, day),
      DateTime(ref.year + 1, month, day),
    ];
    candidates.sort((DateTime a, DateTime b) => a
        .difference(ref)
        .abs()
        .compareTo(b.difference(ref).abs()));
    return candidates.first;
  }

  static String _collapse(String s) =>
      s.replaceAll(RegExp(r'\s+'), ' ').trim();
}
