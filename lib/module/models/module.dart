import 'package:html/parser.dart';
import 'package:kit_mobile/parsing/models/hierarchic_table_row.dart';

import '../../exams/models/exam_list.dart';
import '../../l10n/l10n.dart';
import '../../module_info_table/models/module_info_table.dart';

class KITModule {
  static const Duration cacheStaleAfter = Duration(days: 2);

  String id = "";
  String title = "";
  String assignmentType = "";
  String examDateStr = "unbekannt";
  DateTime examDate = DateTime.now();
  bool examDateParsed = false;
  String grade = "0,0";
  String pointsAcquired = "0,0";
  String pointsAvailable = "0,0";
  String hierarchicalTableRowId = "";
  String? iliasLink = "";
  HierarchicTableRow? row;

  List<ModuleInfoTable> tables = [];

  DateTime lastUpdated = DateTime.fromMillisecondsSinceEpoch(0);

  bool hasFavoriteChild = false;

  // Module({required this.csbrId, required this.title, required this.avgMark, required this.pointsAcquired});

  void parseModulePage(String src) {
    final document = parse(src.replaceAll("&nbsp;", " "));

    // get id
    var elements = document
        .getElementById("csbr_id-field")
        ?.getElementsByClassName("element");
    if (elements != null && elements.isNotEmpty) {
      id = elements.first.innerHtml;
    }

    // get title
    elements = document
        .getElementById("cabr_name-field")
        ?.getElementsByClassName("element");
    if (elements != null && elements.isNotEmpty) {
      title = elements.first.text.replaceAll(RegExp(r"\s+"), " ").trim();
    }

    // get assignment type
    elements = document
        .getElementById("csbr_assignmenttype-field")
        ?.getElementsByClassName("element");
    if (elements != null && elements.isNotEmpty) {
      assignmentType = elements.first.innerHtml;
    }

    // get exam date
    elements = document
        .getElementById("cagr_examdate-field")
        ?.getElementsByClassName("element");
    if (elements != null && elements.isNotEmpty) {
      examDateStr = elements.first.innerHtml.trim();
    }

    // get grade
    elements = document
        .getElementById("cagr_grade-field")
        ?.getElementsByClassName("element");
    if (elements != null && elements.isNotEmpty) {
      final gradeNode = elements.first;
      if (gradeNode.hasChildNodes()) {
        for (var child in gradeNode.children) {
          child.remove();
        }
      }

      grade = gradeNode.innerHtml;
    }

    // get LP
    elements = document
        .getElementById("csbr_credits-field")
        ?.getElementsByClassName("element");
    if (elements != null && elements.isNotEmpty) {
      for (var child in elements.first.children) {
        child.remove();
      }
      pointsAcquired = elements.first.innerHtml;
    }

    // get possible LP
    elements = document
        .getElementById("csbr_requiredcredits-field")
        ?.getElementsByClassName("element");
    if (elements != null && elements.isNotEmpty) {
      for (var child in elements.first.children) {
        child.remove();
      }
      pointsAvailable = elements.first.innerHtml;
    }

    // parse exam date (field spelling: German "24.02.2027" or, when the
    // student browses the portal in English, US "2/24/2027" — the field
    // follows the SESSION locale, and one MEI kid doing exactly that
    // used to get "exam date unknown" while the date sat on the page)
    examDateParsed = false;
    final fieldDate = ExamTerm.parseCasDate(examDateStr);
    if (fieldDate != null) {
      examDate = fieldDate;
      examDateParsed = true;
    }

    // Many bricks carry NO cagr_examdate-field at all: their sittings
    // live only in the #EXAMLIST table as hidden collapsible sub-rows
    // ("<span class=date>Wed, 2/24/2027</span>, <span class=time>11:00
    // AM - 1:00 PM</span>, <a class=room>…</a>" — observed live on
    // specificBrickView.asp, the very page this scrape fetches). Take
    // the earliest FUTURE sitting as "the" exam date (all past -> the
    // latest, so the card reads "X days ago" off real data); cancelled
    // sittings ("entfällt"/"cancelled") never become the countdown.
    if (!examDateParsed) {
      final sittings = <DateTime>[];
      for (final tr in document.querySelectorAll("table#EXAMLIST tr.collapsible")) {
        final dateEl = tr.querySelector("span.date");
        if (dateEl == null) continue;
        final rowText = tr.text.toLowerCase();
        if (rowText.contains("entfällt") ||
            rowText.contains("cancell") ||
            rowText.contains("canceled")) {
          continue;
        }
        final d = ExamTerm.parseCasDate(dateEl.text);
        if (d == null) continue;
        final hour = ExamTerm.startHourOf(tr.querySelector("span.time")?.text ?? "");
        sittings.add(DateTime(d.year, d.month, d.day, hour ?? 0, 0));
      }
      if (sittings.isNotEmpty) {
        sittings.sort();
        final today = DateTime.now();
        final next = sittings.firstWhere(
            (s) => !s.isBefore(DateTime(today.year, today.month, today.day)),
            orElse: () => sittings.last);
        examDate = next;
        examDateParsed = true;
        // the display string mirrors what the page itself shows
        examDateStr = "${examDate.day.toString().padLeft(2, "0")}."
            "${examDate.month.toString().padLeft(2, "0")}."
            "${examDate.year}";
      }
    }

    // parse all tables
    tables = ModuleInfoTable.extractAllFromHtml(src);
    for (final table in tables) {
      table.prepare(this);

      if (table.iliasLink != null) {
        iliasLink = table.iliasLink;
      }

      hasFavoriteChild |= table.hasFavoriteChild;
    }

    lastUpdated = DateTime.now();
  }

  String get timeAxisPositionString {
    if (!examDateKnown) {
      return L10n.t("module.examDateUnknown");
    }
    final delta = examDate.difference(DateTime.now());

    if (isUpcoming) {
      return L10n.t("module.examInDays", [delta.inDays]);
    }

    return L10n.t("module.examDaysAgo", [-delta.inDays]);
  }

  bool get isUpcoming {
    return DateTime.now().isBefore(examDate);
  }

  bool get examDateKnown {
    // only a string that really parsed to a DateTime may drive the
    // countdown: any other scrape text ("k.A.", WS wording drift) used to
    // pass the old string comparison and rendered the now() default as
    // "Prüfung in 0 Tagen"
    return examDateParsed;
  }

  bool get isEmpty => id == "";

  bool get requiresUpdate {
    if (isEmpty) {
      return true;
    }
    return DateTime.now().difference(lastUpdated) >= cacheStaleAfter;
  }

  @override
  String toString() {
    return """KITModule(
  id: $id,
  title: $title,
  assignmentType: $assignmentType,
  examDateStr: $examDateStr,
  grade: $grade,
  pointsAcquired: $pointsAcquired
)""";
  }
}
