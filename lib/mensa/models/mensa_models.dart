/// Studierendenwerk Karlsruhe canteen menu models.
///
/// Pure data: parsed from the SW KA "popup_plain" HTML by
/// MensaHtmlParser, cached by MensaManager, rendered by the Mensa
/// section. Deliberately independent of KIT/campus code - the feed
/// belongs to the Studierendenwerk, so its failures must NEVER light up
/// the campus "KIT site changed?" surface.
library;

/// One dish on one serving line.
class MensaMeal {
  MensaMeal({
    required this.name,
    required this.priceCents,
    required this.classifiers,
    required this.additives,
  });

  /// Full dish text as the feed prints it, e.g. "Jambalaya Kreolisches
  /// Reisgericht mit Hühnchen" (the plain view keeps name and marketing
  /// tail in one node - no reliable split exists, so none is invented).
  final String name;

  /// Student price in cents; the plain view prints exactly one price
  /// per dish (the Studierende price - the one the app's users pay).
  final int? priceCents;

  /// Uppercase short codes, e.g. ["VEG","MSC"]. SW KA legend: VEG =
  /// vegetarian, VG = vegan (deliberately counterintuitive, confirmed
  /// against the site legend and its dishes: cheese-sauce Gnocchi is
  /// [VEG], plain Krautsalat is [VG]) - mixing them up would mislead
  /// ethics-eaters, so the mapping is pinned in tests. S=pork,
  /// R=beef, G=poultry, Fi=fish, MSC=certified fish, B=bio,
  /// MV=MensaVital, LAB=animal rennet, GEL=gelatine. Unknown codes are
  /// kept, never dropped.
  final List<String> classifiers;

  /// Allergen/additive codes of the parenthesised suffix, e.g.
  /// ["Se","We","ML"] - detail-sheet material, not glance material.
  final List<String> additives;

  bool get isVegan => classifiers.contains("VG");
  bool get isVegetarian => isVegan || classifiers.contains("VEG");

  /// "3,80 €"; "" when the feed printed no price.
  String get priceText => priceCents == null
      ? ""
      : "${(priceCents! / 100).toStringAsFixed(2).replaceAll('.', ',')} €";

  List<dynamic> toJson() => [
        name,
        priceCents,
        classifiers.join(","),
        additives.join(","),
      ];

  factory MensaMeal.fromJson(List<dynamic> j) => MensaMeal(
        name: j[0] as String,
        priceCents: j[1] as int?,
        classifiers: (j[2] as String).isEmpty
            ? const []
            : (j[2] as String).split(","),
        additives: (j[3] as String).isEmpty
            ? const []
            : (j[3] as String).split(","),
      );
}

/// A serving line with its dishes, e.g. "Linie 2" or "[pizza]werk".
class MensaLine {
  MensaLine({required this.name, this.sub, required this.meals});

  /// Primary line name (first <br>-delimited run of the cell).
  final String name;

  /// Secondary label of the same cell, e.g. "Gut & Günstig" or the
  /// serving window "11-14 Uhr" - rendered muted after the name.
  final String? sub;
  final List<MensaMeal> meals;

  List<dynamic> toJson() =>
      [name, sub, [for (final m in meals) m.toJson()]];

  factory MensaLine.fromJson(List<dynamic> j) => MensaLine(
        name: j[0] as String,
        sub: j[1] as String?,
        meals: [for (final m in (j[2] as List)) MensaMeal.fromJson(m)],
      );
}

/// One canteen-day: date + the lines serving on it.
class MensaDay {
  MensaDay({required this.date, required this.lines});

  /// Local calendar date of the plan (the feed stamps "Mi 12.11."
  /// without a year; MensaHtmlParser resolves it against the fetch).
  final DateTime date;
  final List<MensaLine> lines;

  bool get isEmpty => lines.every((MensaLine l) => l.meals.isEmpty);

  int get mealCount =>
      lines.fold(0, (int n, MensaLine l) => n + l.meals.length);

  List<dynamic> toJson() => [
        "${date.year}-${date.month}-${date.day}",
        [for (final l in lines) l.toJson()],
      ];

  factory MensaDay.fromJson(List<dynamic> j) {
    final parts = (j[0] as String).split("-");
    return MensaDay(
      date: DateTime(int.parse(parts[0]), int.parse(parts[1]),
          int.parse(parts[2])),
      lines: [for (final l in (j[1] as List)) MensaLine.fromJson(l)],
    );
  }
}
