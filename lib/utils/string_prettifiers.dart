import 'package:kit_mobile/utils/regexps.dart';

String sanitizeModuleTitle(String title) {
  // this method solves the problem when a hierarchic table's entry
  // like "Lineare Algebra - Prüfung" is used as module.title
  // so we split by "-" and filter out words like ["Prüfung", "Klausur"]
  // IMPORTANT: if you encounter some other

  const filterOutLower = ["prüfung", "klausur"]; // lowercased!

  // the initial split by "-"
  final split = title.split("-");

  // a fragment only counts as an exam annotation when one of the words
  // appears STANDALONE: a plain substring test also dropped legit
  // fragments such as "Klausurplanung"
  final filterOutRegexps = [
    for (final ignored in filterOutLower)
      RegExp("(^|[^a-zäöüß0-9])$ignored([^a-zäöüß0-9]|\$)"),
  ];

  split.removeWhere((entry) {
    final entryLower = entry.toLowerCase();
    for (final filterRegexp in filterOutRegexps) {
      if (filterRegexp.hasMatch(entryLower)) {
        // ignore immediately
        return true;
      }
    }

    return false;
  });

  // trimming: when the first (or last) fragment is dropped, the space
  // it was separated with must not survive as a leading-space artifact
  return split.join("-").trim();
}

String prettifyTemporaryModuleTitle(String title) {
  // TODO: explain why we need this

  final split = title.split("_");
  if (split.isEmpty) {
    return "";
  }

  if (split.first.length <= 1) {
    split.removeWhere((element) => prettifyTemporaryModuleTitleNumberRegex.hasMatch(element));
  }

  return split.join(" ");
}