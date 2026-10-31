// NO package:collection here on purpose: parseTr's element/td parameters are
// untyped, so `.firstOrNull` on a returned List<Element> would compile but
// die at RUNTIME with NoSuchMethodError (dynamic dispatch skips extension
// methods) - which silently killed every course-tree row parse, leaving
// rowsSorted empty ("no grade row") and login permanently broken.
import 'dart:math';


class HierarchicTableRow  {
  final int level;
  String title;
  String href;
  final String type;
  final String statusStr;
  String grade;
  final String pointsAcquired;
  final String pointsMax;
  int year = 0;

  String technicalName = "";

  List<HierarchicTableRow> children = [];

  HierarchicTableRow({required this.level, required this.title, required this.href, required this.type, required this.statusStr, required this.grade, required this.pointsAcquired, required this.pointsMax});

  String get id => "${level}_${title}_$year";
  
  bool get isGradeEmpty => grade.isEmpty || grade.startsWith("0") || grade.startsWith("&");
  
  int get relevancyRank {
    return isGradeEmpty ? 10 : 1;
  }

  static HierarchicTableRow? parseTr(element, Map<int, List<HierarchicTableRow>> rowsSorted) {
    int level = 0;
    final classes = element.attributes["class"]?.split(" ");
    if (classes == null) {
      return null;
    }

    for (var rowClass in classes) {
      if (rowClass.contains("hierarchy")) {
        level = int.tryParse(rowClass[rowClass.length - 1]) ?? 0;
        break;
      }
    }

    final cells = element.getElementsByTagName("td");
    // campus emits header/summary <tr>s with too few cells: cells[1] would
    // throw RangeError and cells[4..7] below would throw, killing the whole
    // course-tree parse mid-fetch
    if (cells.length < 8) {
      return null;
    }
    // .first would throw on link-less rows before the null check below
    final links = cells[1].getElementsByTagName("a");
    final firstLink = links.isEmpty ? null : links[0];

    if (firstLink == null) {
      return null;
    }

    firstLink.children.forEach((child) {
      child.remove();
    });

    final newRow = HierarchicTableRow(
      level: level,
      // cascampus embeds layout whitespace/entities ("Mechanical Design  A")
      title: firstLink.text.replaceAll(RegExp(r"\s+"), " ").trim(),
      href: firstLink.attributes["href"],
      type: cells[2].innerHtml,
      statusStr: "",
      grade: cells[4].innerHtml,
      pointsAcquired: cells[6].innerHtml,
      pointsMax: cells[7].innerHtml,
    );
    if (newRow.grade.contains(",")) {
      final commaIndex = newRow.grade.lastIndexOf(",");
      newRow.grade = newRow.grade.substring(max(0, commaIndex - 1), min(commaIndex + 2, newRow.grade.length));
    }

    newRow.clearTitle();
    newRow.clearHref();

    if (level > 1) {
      if (rowsSorted.containsKey(level - 1)) {
        rowsSorted[level - 1]?.last.children.add(newRow);
      }
    }

    if (rowsSorted[level] == null) {
      rowsSorted[level] = [];
    }

    rowsSorted[level]!.add(newRow);

    return newRow;
  }

  // often there is is a title like T-MATH-106335 – Analysis 1 where the first
  // part before the long "–" is some technical name of the entry
  // so we remove that from the title and store in a separate variable
  void clearTitle() {
    final titleSplit = title.split("–");
    if (titleSplit.length > 1) {
      String newTitle = "";
      for (int i = 1; i < titleSplit.length; ++i) {
        newTitle += "${titleSplit[i].trim()} ";
      }
      newTitle = newTitle.trim();

      final newTitleSplit = newTitle.split(" ");
      newTitle = "";
      for (var element in newTitleSplit) {
        final num = int.tryParse(element);
        if (num == null || (num / 1000).floor() != 2) {
          newTitle += "$element ";
        } else {
          year = num;
        }
      }

      title = newTitle.trim();
      technicalName = titleSplit.first.trim();
    }
  }

  void clearHref() {
    final base = "https://cascampus.studium.kit.edu/";
    while (href.startsWith("../")) {
      href = href.substring(3);
    }

    href = base + href;
  }
}